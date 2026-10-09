import CoreGraphics
import CoreMedia
import CoreVideo
import CoreWLAN
import SystemConfiguration
import Foundation
import GameController

extension NVSTCoreTransport {

    func startVideo(handoff: NVSTVideoHandoff, mediaReceiver: any NativeNVSTMediaReceiver) async throws {
        try handoff.feedbackConfiguration.validate()
        let videoLogger = self.logger
        let decoder = try NvstVideoToolboxDecoder(codec: handoff.codec)
        decoder.onDecoderLog = { message in videoLogger?("NVST \(message)") }
        decoder.onDecodeFailure = { [weak self] frameIndex in
            Task { await self?.invalidateFrame(frameIndex) }
        }
        let sink = pixelBufferSink

        let recorder = self.recorder

        let coOpVideoRelay = self.remoteCoOpVideoRelay

        decoder.onPixelBuffer = { [weak self] pixelBuffer, presentationTime, isKeyframe, lifecycle in
            Task { await self?.didDecodeFrame(lifecycle.unit) }
            recorder.appendNativePixelBuffer(pixelBuffer)
            coOpVideoRelay.renderPixelBuffer(pixelBuffer, presentationTime: presentationTime)
            if let sink {
                sink(pixelBuffer, presentationTime, isKeyframe, lifecycle)
            } else {
                lifecycle.discard(decoded: true)
            }
        }
        self.decoder = decoder
        lastHandoff = handoff

        let descriptor = reserver?.takeWireDescriptor() ?? -1
        let receiver = try NVSTWireReceiver(
            handoff: handoff,

            sendsReceiverReports: true,
            existingDescriptor: descriptor
        )
        let qosManager = NvstQosManager()
        qosManager.configureFramePacing(handoff.framePacingConfiguration)
        qosManager.configureRetransmission(handoff.retransmissionConfiguration)
        let streamProcessor = NvstStreamProcessor(qosManager: qosManager,
            bandwidthConfiguration: handoff.bandwidthConfiguration)
        receiver.streamProcessor = streamProcessor
        self.qosManager = qosManager
        self.streamProcessor = streamProcessor
        let logger = self.logger

        let (mediaFrames, mediaContinuation) = AsyncStream<NativeNVSTVideoFrame>.makeStream(
            bufferingPolicy: .bufferingNewest(4))
        mediaForwardingTask?.cancel()
        mediaForwardingTask = Task.detached(priority: .userInitiated) {
            for await frame in mediaFrames {
                if Task.isCancelled { return }
                await mediaReceiver.receiveVideoFrame(frame)
            }
        }
        mediaFrameContinuation = mediaContinuation
        let pipeline = makeVideoPipeline(handoff: handoff, decoder: decoder, receiver: receiver, mediaContinuation: mediaContinuation, qosManager: qosManager)
        if let bundle {
            pipeline.attach(bundle: bundle)
            receiver.setRetransmissionWriter { [weak bundle] command in
                bundle?.sendPartiallyReliableControl(command) ?? false
            }
        }
        videoPipeline = pipeline
        pipeline.configurePresentation(presentationConfiguration)
        logger?("NVST feedback selected qos=\(handoff.feedbackConfiguration.qosVersion) processing=\(handoff.feedbackConfiguration.processingVersion) frameStats=\(handoff.feedbackConfiguration.frameStatsVersion)")
        receiver.onAccessUnit = { [weak pipeline] unit in pipeline?.submit(unit) }
        receiver.onFrameStatistics = { [weak pipeline] frameIndex, statistics in
            pipeline?.submitFrameStatistics(frameIndex: frameIndex, statistics: statistics)
        }
        receiver.onRecoveryNeeded = { [weak self] brokenFrameIndex in
            Task { await self?.recoverBrokenReferenceChain(frameIndex: brokenFrameIndex) }
        }
        receiver.onDiagnostic = { message in logger?("NVST \(message)") }

        receiver.onDrop = { _ in }
        receiver.onBoundSSRC = { [weak self] ssrc in
            Task { [weak self] in
                await self?.feedbackSender?.updateMediaSSRC(ssrc)
            }
        }
        if let ssrc = receiver.stats.boundSSRC {
            feedbackSender?.updateMediaSSRC(ssrc)
        }
        feedbackSender?.setReportProvider { [weak receiver] in
            receiver?.receiverReportBlock()
        }
        try receiver.start()
        self.receiver = receiver
        beginVideoHolePunch()
        if let sender = feedbackSender {
            adoptFeedbackSender(sender)
        }
        logger?("NVST Mjolnir receiver armed on port \((handoff.wireUDPPort ?? handoff.mjolnirUDPPort) ?? handoff.clientUDPPort) for peer \(handoff.videoPeerIP):\(handoff.videoPeerPort)")
    }

    private func makeVideoPipeline(handoff: NVSTVideoHandoff,
                                   decoder: NvstVideoToolboxDecoder,
                                   receiver: NVSTWireReceiver,
                                   mediaContinuation: AsyncStream<NativeNVSTVideoFrame>.Continuation,
                                   qosManager: NvstQosManager? = nil) -> NvstVideoPipeline {

        return NvstVideoPipeline(
            decoder: decoder,
            clock: clock,
            frameTimeMicroseconds: sessionFrameTimeMicroseconds,
            displayVsyncMicroseconds: displayVsyncMicroseconds,
            feedbackConfiguration: handoff.feedbackConfiguration,
            framePacingConfiguration: handoff.framePacingConfiguration,
            logger: logger,

            mediaSink: { unit in
                mediaContinuation.yield(NativeNVSTVideoFrame(
                    streamID: handoff.rtpSSRC,
                    codec: Self.mediaCodec(handoff.codec),

                    timestamp: MediaTimestamp(nanoseconds: UInt64(unit.rtpTimestamp) * 1_000_000_000 / UInt64(NvstVideoToolboxDecoder.clockRate)),
                    durationNanoseconds: 0,
                    width: 0,
                    height: 0,
                    isKeyFrame: unit.isKeyframe,
                    payload: unit.bytes
                ))
            },
            onKeyframeNeeded: { [weak self] in
                Task { await self?.requestKeyframeOverControlChannel() }
            },
            onFatalDecodeError: { [weak self] message in
                Task { await self?.reportFatalDecodeError(message) }
            },
            qosManager: qosManager
        )
    }

    private func resolvedMicrophoneSetup(microphoneOfferedOnBundle: Bool) -> NvstWebRtcBundle.MicrophoneSetup? {
        let logger = self.logger
        guard let configuration = microphoneConfiguration, configuration.captureRequested else { return nil }
        if !microphoneOfferedOnBundle {
            logger?("NVST seat did not offer bundle microphone carriage; the mic stays on its (not yet recovered) legacy transport")
            return nil
        }
        return NvstWebRtcBundle.MicrophoneSetup(volume: configuration.volume,
                                                deviceId: configuration.deviceId,
                                                initiallyEnabled: configuration.initiallyEnabled)
    }

    func bringUpBundle(handoff: NVSTVideoHandoff, microphoneOfferedOnBundle: Bool) async -> NvstBundleReservation? {
        let logger = self.logger
        self.microphoneOfferedOnBundle = microphoneOfferedOnBundle
        guard Self.usesWebRtcBundle else {
            logger?("NVST bundle disabled; punching the bundle socket with bare STUN only")
            startBundleProbe(handoff: handoff)
            scheduleVideoHolePunch()
            return nil
        }
        let microphoneSetup = resolvedMicrophoneSetup(microphoneOfferedOnBundle: microphoneOfferedOnBundle)
        let bundle = NvstWebRtcBundle(handoff: handoff, logger: logger)
        let sender = NvstFeedbackSender()
        do {
            let identity = try await bundle.prepare(microphone: microphoneSetup, channelCount: configuredAudioChannels)
            scheduleVideoHolePunch()
            sender.configure(
                channelWriter: { payload in _ = bundle.sendFeedback(payload) },

                senderSSRC: 0x4f4e_4f57,
                mediaSSRC: 0
            )
            if let currentReceiver = self.receiver {
                sender.setReportProvider { [weak currentReceiver] in currentReceiver?.receiverReportBlock() }
                if let ssrc = currentReceiver.stats.boundSSRC { sender.updateMediaSSRC(ssrc) }
            }
            clock.start()
            installBundleHandlers(bundle, sender: sender, logger: logger)
            self.qosManager?.setCommandSink { [weak bundle] command in
                _ = bundle?.sendPartiallyReliableControl(command)
            }
            self.bundle = bundle
            receiver?.setRetransmissionWriter { [weak bundle] command in
                bundle?.sendPartiallyReliableControl(command) ?? false
            }
            activeBundleHolder.set(bundle)
            if let configuredGameVolume {
                bundle.setRemoteAudioVolume(configuredGameVolume)
            }
            let microphone = bundle.microphoneNegotiation
            microphoneNegotiated = microphone.negotiated
            microphoneSenderSsrc = microphone.senderSsrc

            videoPipeline?.attach(bundle: bundle)
            self.feedbackSender = sender
            if !identity.usesOfficialIceCredentials {
                logger?("NVST bundle is announcing libwebrtc's own ICE credentials; Bifrost length checks may reject them")
            }
            return NvstBundleReservation(
                bundlePort: identity.bundlePort,
                mjolnirPort: (handoff.wireUDPPort ?? handoff.mjolnirUDPPort) ?? handoff.clientUDPPort,
                localAddress: identity.localAddress,
                iceCredentials: handoff.iceCredentials.map {
                    NvstRtspIceCredentials(usernameFragment: $0.localUsernameFragment, password: $0.localPassword)
                },
                dtlsFingerprint: identity.dtlsFingerprint,
                microphoneNegotiated: microphoneNegotiated,
                microphoneSenderSsrc: microphoneSenderSsrc
            )
        } catch {
            logger?("NVST bundle bring-up failed: \(error.localizedDescription); falling back to the STUN-only probe")
            bundle.close()
            startBundleProbe(handoff: handoff)
            scheduleVideoHolePunch()
            return nil
        }
    }

    private func installBundleHandlers(_ bundle: NvstWebRtcBundle,
                                       sender: NvstFeedbackSender,
                                       logger: (@Sendable (String) -> Void)?) {
        bundleGeneration = bundleGeneration &+ 1
        let generation = bundleGeneration
        bundle.onInputProtocolNegotiated = { [weak self] version in
            Task {
                guard await self?.bundleGeneration == generation else { return }
                await self?.inputDidNegotiate(version)
            }
        }
        bundle.onRemoteCursor = { [weak self] cursor in
            Task {
                guard await self?.bundleGeneration == generation else { return }
                await self?.handleRemoteCursor(cursor)
            }
        }
        bundle.onSeatStats = { [weak self] stats in
            Task {
                guard await self?.bundleGeneration == generation else { return }
                await self?.recordSeatStats(stats)
            }
        }
        bundle.onHapticEvents = { [weak self] events in
            Task {
                guard await self?.bundleGeneration == generation else { return }
                await self?.handleHapticEvents(events)
            }
        }
        bundle.onHdrMode = { [weak self] notification in
            Task {
                guard await self?.bundleGeneration == generation else { return }
                await self?.handleHdrMode(notification)
            }
        }
        bundle.onAudioSurroundInfo = { [weak self] surround in
            Task {
                guard await self?.bundleGeneration == generation else { return }
                await self?.handleAudioSurroundInfo(surround)
            }
        }
        bundle.onSeatTermination = { [weak self] reasonCode, summary in
            Task {
                guard await self?.bundleGeneration == generation else { return }
                await self?.handleSeatTermination(reasonCode: reasonCode, summary: summary)
            }
        }
        bundle.onSeatTerminationTimer = { [weak self] code, payload in
            Task {
                guard await self?.bundleGeneration == generation else { return }
                await self?.handleSeatTerminationTimer(code: code, payload: payload)
            }
        }
        bundle.onRemoteAudio = { [weak self] count in
            logger?("NVST bundle seat offered \(count) audio track(s)")
            Task {
                guard await self?.bundleGeneration == generation else { return }
                await self?.noteRemoteAudio(trackCount: count)
            }
        }
        bundle.onHidChangeResponse = { [weak self] deviceId, status in
            Task {
                guard await self?.bundleGeneration == generation else { return }
                await self?.handleHidChangeResponse(deviceId: deviceId, status: status)
            }
        }

        let recorder = self.recorder
        let coOpAudioRelay = self.remoteCoOpAudioRelay
        bundle.onGameAudioFrame = { audioBufferList, frameCount, sampleRate, channels in
            recorder.appendGameAudio(audioBufferList: audioBufferList, frameCount: frameCount, sampleRate: sampleRate, channels: channels)
            coOpAudioRelay.renderAudioFrame(audioBufferList: audioBufferList, frameCount: frameCount, sampleRate: sampleRate, channels: channels)
        }
        bundle.onPartiallyReliableControlOpen = { [weak self] in
            Task {
                guard await self?.bundleGeneration == generation else { return }
                await self?.startQosFeedback()
            }
        }
        bundle.onControlChannelOpen = { [weak self] in
            // startControlKeepAlive gets its own Task so it is not serialised behind
            // announceClientState / requestInitialKeyframe / activateInputIfNegotiated.
            // The seat starts its 10 s client-timeout the moment the SCTP association is
            // up; the first pingBackAck must leave before any of the other setup awaits.
            Task {
                guard await self?.bundleGeneration == generation else { return }
                await self?.startControlKeepAlive()
            }
            Task {
                guard await self?.bundleGeneration == generation else { return }
                await self?.announceClientState()
                await self?.announceRetransmissionState()
                if self?.configuredL4SEnabled == true {
                    try? await self?.setL4SEnabled(true)
                }
                await self?.requestInitialKeyframe()
                await self?.activateInputIfNegotiated()
            }
        }
        bundle.onFeedbackChannelOpen = { [weak self] in
            logger?("NVST feedback channel open; starting receiver reports")
            sender.start()
            Task {
                guard await self?.bundleGeneration == generation else { return }
                await self?.adoptFeedbackSender(sender)
                await self?.beginVideoHolePunch()
            }
        }
    }

    func punchVideoSocketBeforePlay() async {
        beginVideoHolePunch()

        try? await Task.sleep(for: .milliseconds(60))
    }

    func scheduleVideoHolePunch() {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            await self?.beginVideoHolePunch()
        }
    }

    static var announcesExtendedSettings: Bool { ProcessInfo.processInfo.environment["PIXELNOW_NVST_ANNOUNCE_EXTENDED"] == "1" }

    static var usesOwdCongestionControl: Bool { ProcessInfo.processInfo.environment["PIXELNOW_NVST_OWD_CC"] != "0" }
    static var echoesOfferedAttributes: Bool { ProcessInfo.processInfo.environment["PIXELNOW_NVST_ANNOUNCE_ECHO_OFFER"] == "1" }

    static var punchesVideoSocket: Bool { ProcessInfo.processInfo.environment["PIXELNOW_NVST_VIDEO_PUNCH"] != "0" }

    func startControlKeepAlive() {
        guard !isTornDown, controlKeepAliveTask == nil else { return }
        logger?("NVST control keepalive started (\(Int(NvstStreamingCommand.pingBackIntervalSeconds))s)")
        controlKeepAliveTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.sendControlKeepAlive()
                try? await Task.sleep(for: .seconds(NvstStreamingCommand.pingBackIntervalSeconds))
            }
        }
    }

    func noteRemoteAudio(trackCount: Int) {
        remoteAudioTrackCount = trackCount
    }

    func startQosFeedback() {
        guard !isTornDown, qosFeedbackTask == nil else { return }
        let milliseconds = lastHandoff?.qosFeedbackIntervalMilliseconds ?? 50
        let interval = Double(milliseconds == 0 ? 50 : milliseconds) / 1000
        logger?("NVST QoS feedback interval=\(milliseconds)ms")
        qosFeedbackTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.sendQosReport()
                await self.sendRtpStatsIfNeeded()
                await self.sendControlChannelStatsIfNeeded()
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    func sendQosReport() {
        guard let bundle, let receiver, let streamProcessor, let qosManager else { return }
        videoPipeline?.retryFrameStatistics()
        retryPendingIdrIfNeeded()
        retryPendingInvalidationIfNeeded()
        let stats = receiver.stats
        let now = DispatchTime.now().uptimeNanoseconds
        if lastNetworkLinkObservation.map({ now >= $0 && now - $0 < 1_000_000_000 }) != true {
            lastNetworkLinkObservation = now
            let interface = CWWiFiClient.shared().interface()
            let routing = SCDynamicStoreCopyValue(nil, "State:/Network/Global/IPv4" as CFString) as? NSDictionary
            let routedInterface = routing?.object(forKey: "PrimaryInterface") as? String
            let usesWireless = routedInterface != nil && routedInterface == interface?.interfaceName
            let speed = usesWireless && interface?.powerOn() == true ? interface?.transmitRate() ?? 0 : 0
            let available = speed.isFinite && speed > 0
            videoPipeline?.updateNetworkLink(
                signalStrength: available ? Int32(clamping: interface?.rssiValue() ?? 0) : 0,
                networkSpeedKbps: available ? UInt32(min(Double(UInt32.max), speed * 1000)) : 0)
        }
        bundle.refreshTransportStatistics()
        let rtt = bundle.roundTripMilliseconds
        if rtt.isFinite, rtt >= 0 { qosManager.updateRttEma(rttMs: rtt) }
        announceRetransmissionState()
        let network = streamProcessor.networkEstimate(forFeedback: true)
        qosManager.obtainFeedback(network: network, rtpStats: stats)
        let capacity = qosManager.processingCapacity
        let report = NvstQosReport(version: lastHandoff?.feedbackConfiguration.qosVersion ?? 5,
            sequence: qosSequence,
            lastFrameIndex: network.frameIndex,
            estimatedServerRtpTime: network.estimatedServerRtpTime,
            oneWayDelayMicroseconds: UInt32(clamping: Int(network.oneWayDelayMilliseconds * 1000)),
            jitterMicroseconds: network.jitterMicroseconds,
            packetLossBasisPoints: network.packetLossBasisPoints,
            bandwidthUtilizationPercent: network.utilizationPercent,
            maximumDecodeFramesPerSecond: capacity.decodeFramesPerSecond,
            maximumRenderFramesPerSecond: capacity.renderFramesPerSecond,
            clientRtpTime: UInt32(truncatingIfNeeded: clock.elapsedMicroseconds() * 90 / 1000),
            lossyFrames: network.lossyFrames,
            slowBandwidthKbps: network.slowBandwidthKbps,
            estimatedServerRtpTimeV2: network.estimatedServerRtpTimeV2,
            fastBandwidthKbps: network.bandwidthKbps,
            totalReceivedPackets: stats.authenticatedPackets,
            receiverDroppedPackets: UInt32(truncatingIfNeeded: stats.finalizedLossPackets),
            decodeQueueMilliseconds: qosManager.decodeQueueDelayMilliseconds,
            controlRoundTripMilliseconds: rtt.isFinite && rtt >= 0
                ? UInt16(min(Double(UInt16.max), rtt)) : 0)
        if lastHandoff?.qosFeedbackIntervalMilliseconds != 0 {
            if bundle.sendPartiallyReliableControl(report.command) {
                streamProcessor.didSendFeedback(network)
                qosSequence &+= 1
                qosReportsSent += 1
            } else {
                qosReportFailures += 1
                if qosReportFailures == 1 { logger?("NVST QoS report write failed") }
            }
        }
        if lastHandoff?.feedbackConfiguration.processingVersion == 5,
           let processing = qosManager.processingReport(displayVsyncMicroseconds: videoPipeline?.displayVsyncMicroseconds ?? 0) {
            let accepted = bundle.sendPartiallyReliableControl(processing.command)
            videoPipeline?.noteProcessingReport(accepted: accepted)
            if accepted { qosManager.didSendProcessingReport(processing) }
        }
    }

    func sendRtpStatsIfNeeded() {
        guard let bundle, let receiver else { return }
        let stats = receiver.stats
        let frame = stats.framesEmitted
        guard frame >= lastRtpStatsFrame + NvstRtpStatsReport.frameInterval else { return }
        lastRtpStatsFrame = frame
        let frameNumber = UInt32(truncatingIfNeeded: frame)
        let report = NvstRtpStatsReport(
            frameNumber: frameNumber,
            totalReceivedPackets: stats.authenticatedPackets,
            outOfOrderPackets: UInt32(clamping: stats.outOfOrderPackets),
            dropEvents: UInt32(clamping: stats.recoveries),
            latePackets: UInt32(clamping: stats.latePackets),
            droppedPackets: UInt32(clamping: stats.droppedPackets),
            recoveredPackets: UInt32(clamping: stats.recoveredPackets),
            maxDropBurstLength: stats.maxLossBurst,
            maxWaitingQueueDepth: stats.maxReorderDepth,
            duplicatePackets: UInt32(clamping: stats.duplicatePackets),

            micChatSentDataBytes: bundle.microphoneSentBytes)
        let nackStats = NvstRtpNackStatsReport(frameNumber: frameNumber)
        if bundle.sendPartiallyReliableControl(report.command),
           bundle.sendPartiallyReliableControl(nackStats.command) {
            rtpStatsReportsSent += 1
        }
    }

    func sendControlChannelStatsIfNeeded() {
        guard let bundle, sessionStartedAt != nil else { return }
        let now = Date()
        if let last = controlStatsLastSentAt,
           now.timeIntervalSince(last) < NvstControlChannelStatsReport.transmitInterval { return }
        let counters = bundle.controlChannelStats
        let report = NvstControlChannelStatsReport(
            timestampMicroseconds: sessionElapsedMicroseconds(),
            totalMessagesSent: counters.totalSent,
            totalMessagesFailed: counters.totalFailed,
            totalBytesSent: counters.totalBytes,
            commands: counters.commands)
        guard bundle.sendPartiallyReliableControl(report.command) else { return }
        controlStatsLastSentAt = now
        controlStatsReportsSent += 1
    }

    func handleRemoteCursor(_ cursor: NvstRemoteCursor) {
        cancelCursorCaptureWatchdog()
        if !didDisableCursorCapture {
            didDisableCursorCapture = true
            let sent = bundle?.sendControl(NvstInputActivation.mouseCursorCapture(isEnabled: false)) ?? false
            logger?("NVST seat cursor notifications started (\(cursor.summary)); server-composited cursor disabled sent=\(sent)")
            notifySeatCompositesCursor(false)
        }
        let isVisible = cursor.visibility(following: remoteCursorVisible)
        if let isVisible, isVisible != remoteCursorVisible {
            let previous = remoteCursorVisible
            remoteCursorVisible = isVisible

            logger?(String(format: "NVST remote cursor %@ -> %@ at %.3fs",
                           previous.map { $0 ? "visible" : "hidden" } ?? "unknown",
                           isVisible ? "visible" : "hidden",
                           Double(clock.elapsedMicroseconds()) / 1_000_000))
            if let notify = onRemoteCursorVisibilityChanged {
                Task { @MainActor in notify(isVisible) }
            }
        }
        if let notifyCursor = onRemoteCursorChanged {
            Task { @MainActor in notifyCursor(cursor) }
        }
    }

    public func setRemoteCursorVisibilityHandler(_ handler: (@MainActor @Sendable (Bool) -> Void)?) {
        onRemoteCursorVisibilityChanged = handler
    }

    public func setRemoteCursorHandler(_ handler: (@MainActor @Sendable (NvstRemoteCursor) -> Void)?) {
        onRemoteCursorChanged = handler
    }

    public func setRemoteCursorCaptureHandler(_ handler: (@MainActor @Sendable (Bool) -> Void)?) {
        onRemoteCursorCaptureChanged = handler
    }

    public func setHapticEventHandler(_ handler: (@MainActor @Sendable ([NvstHapticEvent]) -> Void)?) {
        onHapticEvents = handler
    }

    public func setHdrModeHandler(_ handler: (@MainActor @Sendable (NvstHdrModeNotification) -> Void)?) {
        onHdrModeChanged = handler
    }

    public func setSessionLimitUpdateHandler(_ handler: (@MainActor @Sendable (StreamSessionLimitUpdate) -> Void)?) async {
        onSessionLimitUpdate = handler
    }

    func handleHapticEvents(_ events: [NvstHapticEvent]) {
        hapticEventsReceived &+= UInt64(events.count)
        guard let notify = onHapticEvents else { return }
        Task { @MainActor in notify(events) }
    }

    func handleHdrMode(_ notification: NvstHdrModeNotification) {
        let previous = lastHdrMode
        lastHdrMode = notification
        if previous != notification {
            logger?(String(format: "NVST hdr mode %@ -> %@ at %.3fs", previous?.summary ?? "unknown", notification.summary,
                           Double(clock.elapsedMicroseconds()) / 1_000_000))
        }
        guard let notify = onHdrModeChanged else { return }
        Task { @MainActor in notify(notification) }
    }

    func handleAudioSurroundInfo(_ surround: NvstAudioSurroundInfo) {
        logger?(String(format: "NVST audio surround info %@ at %.3fs", surround.summary,
                       Double(clock.elapsedMicroseconds()) / 1_000_000))
    }

    func sessionElapsedMicroseconds() -> UInt64 {
        clock.elapsedMicroseconds()
    }

    static func sessionServerLocation(for allocation: NativeNVSTSessionAllocation) -> String? {
        let server = sessionServerLocation(fromRawSessionJSON: allocation.rawSessionJSON)
            ?? endpointLabel(forStreamingBaseURL: allocation.streamingBaseURL)
        let region = regionName(forStreamingBaseURL: allocation.streamingBaseURL)
        switch (server, region) {
        case let (server?, region?):
            return server.caseInsensitiveCompare(region) == .orderedSame ? server : "\(server) (\(region))"
        case let (server?, nil): return server
        case let (nil, region?): return region
        case (nil, nil): return nil
        }
    }

    static func sessionGPUType(for allocation: NativeNVSTSessionAllocation) -> String? {
        for json in [allocation.sessionInfoJSON, allocation.rawSessionJSON] {
            guard let data = json.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if let gpu = object["gpuType"] as? String, !gpu.trimmingCharacters(in: .whitespaces).isEmpty {
                return gpu
            }
        }
        return nil
    }

    static func sessionServerLocation(fromRawSessionJSON json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let rawSession = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let requestData = rawSession["sessionRequestData"] as? [String: Any] ?? [:]
        for value in [rawSession["serverLocation"], requestData["serverLocation"], rawSession["zoneName"]] {
            if let text = value as? String, !text.trimmingCharacters(in: .whitespaces).isEmpty {
                return text
            }
        }
        return nil
    }

    static func regionName(forStreamingBaseURL baseURL: String) -> String? {
        let name = StreamPreferences.regionName(forStreamingBaseUrl: baseURL)
        return name.isEmpty ? nil : name
    }

    static func endpointLabel(forStreamingBaseURL baseURL: String) -> String? {
        guard let host = endpointHost(baseURL) else { return nil }
        let label = String(host.split(separator: ".").first ?? "")
        guard !label.isEmpty, label.contains(where: { $0.isLetter }) else { return nil }
        return label
    }

    static func endpointHost(_ baseURL: String) -> String? {
        guard let host = URLComponents(string: baseURL)?.host ?? host(from: baseURL), !host.isEmpty else { return nil }
        return host
    }

    func recoverBrokenReferenceChain(frameIndex: UInt32?) {
        if let frameIndex {
            invalidateFrame(frameIndex)
        } else {
            requestKeyframeOverControlChannel()
        }
    }

    func invalidateFrame(_ frameIndex: UInt32) {
        let index = extendedRecoveryFrameIndex(frameIndex)
        pendingInvalidationFirst = min(pendingInvalidationFirst ?? index, index)
        pendingInvalidationLast = max(pendingInvalidationLast ?? index, index)
        retryPendingInvalidationIfNeeded()
    }

    private func scheduleInvalidationFlush(after delay: UInt64) {
        guard invalidationFlushTask == nil else { return }
        invalidationFlushTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: max(1_000_000, delay)) }
            catch { return }
            await self?.flushPendingInvalidation()
        }
    }

    private func flushPendingInvalidation() {
        invalidationFlushTask = nil
        retryPendingInvalidationIfNeeded()
    }

    private func retryPendingInvalidationIfNeeded() {
        guard !isTornDown, let first = pendingInvalidationFirst, let last = pendingInvalidationLast else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        if let sentAt = lastInvalidationAt, now >= sentAt, now - sentAt <= Self.recoveryRetryNanoseconds {
            scheduleInvalidationFlush(after: Self.recoveryRetryNanoseconds - (now - sentAt) + 1)
            return
        }
        guard let bundle, bundle.isControlChannelOpen else {
            scheduleInvalidationFlush(after: Self.recoveryRetryNanoseconds)
            return
        }
        if bundle.sendControl(.frameInvalidationRange(first: first, last: last)) {
            lastInvalidationAt = now
            invalidationsSent += 1
        } else {
            logger?("NVST frame invalidation write failed")
        }
        scheduleInvalidationFlush(after: Self.recoveryRetryNanoseconds + 1)
    }

    static let recoveryRetryNanoseconds: UInt64 = 100_000_000

    private func extendedRecoveryFrameIndex(_ index: UInt32) -> UInt64 {
        guard let previous = lastRecoveryFrameIndex else {
            lastRecoveryFrameIndex = UInt64(index)
            return UInt64(index)
        }
        let difference = Int64(Int32(bitPattern: index &- UInt32(truncatingIfNeeded: previous)))
        let extended = difference >= 0 ? previous &+ UInt64(difference)
            : previous - min(previous, UInt64(-difference))
        lastRecoveryFrameIndex = max(previous, extended)
        return extended
    }

    func requestKeyframeOverControlChannel() {
        guard !isWaitingForIdr else { return }
        sendIdrRequest()
    }

    func didDecodeFrame(_ unit: NvstAccessUnit) {
        let index = extendedRecoveryFrameIndex(unit.frameIndex)
        if unit.isKeyframe { isWaitingForIdr = false }
        let repairedReference = unit.isKeyframe || unit.frameType == 4 || (unit.frameType == 5 && !isWaitingForIdr)
        guard repairedReference, index >= (pendingInvalidationLast ?? 0) else { return }
        pendingInvalidationFirst = nil
        pendingInvalidationLast = nil
        invalidationFlushTask?.cancel()
        invalidationFlushTask = nil
    }

    private func retryPendingIdrIfNeeded() {
        guard isWaitingForIdr else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        guard let last = lastIdrRequestAt, now >= last,
              now - last > Self.recoveryRetryNanoseconds else { return }
        sendIdrRequest()
    }

    private func sendIdrRequest() {
        guard let bundle, bundle.isControlChannelOpen else {
            receiver?.requestKeyframe()
            return
        }
        guard bundle.sendControl(.idrRequest()) else {
            logger?("NVST IDR request write failed")
            return
        }
        lastIdrRequestAt = DispatchTime.now().uptimeNanoseconds
        isWaitingForIdr = true
        idrRequestsSent += 1
    }

    func requestInitialKeyframe() {
        requestKeyframeOverControlChannel()
    }

    func activateInputIfNegotiated() {
        if bundle?.negotiatedInputProtocolVersion != nil {
            activateInput()
        }
    }


    func announceClientState() {
        guard let bundle, !didAnnounceClientState else { return }
        didAnnounceClientState = true
        let window = bundle.sendControl(.windowStateChange())
        let system = bundle.sendControl(.systemStateChange())
        logger?("NVST client state announced (window=\(window) system=\(system))")
    }

    func inputDidNegotiate(_ version: UInt16) {

        logger?("NVST input negotiated at protocol version \(version); ready=\(bundle?.isInputReady == true)")
        activateInput()
    }

    func activateInput() {
        guard let bundle, !didActivateInput else { return }
        guard bundle.isControlChannelOpen else {
            logger?("NVST input activation deferred: control channel not yet open")
            return
        }
        didActivateInput = true
        guard ProcessInfo.processInfo.environment["PIXELNOW_NVST_RI_NO_ACTIVATION"] != "1" else {
            logger?("NVST input activation skipped by request")
            return
        }

        var sent: [String] = []

        if connectedGamepadIndices.isEmpty { connectedGamepadIndices = [0] }
        let activationBitmap = NvstGamepadEvent.connectedBitmap(for: connectedGamepadIndices)
        sent.append("descriptor=\(bundle.sendControl(NvstInputActivation.deviceDescriptor(timestampMicroseconds: sessionElapsedMicroseconds(), connectedBitmap: activationBitmap)))")

        registeredGamepadBitmap = activationBitmap

        sent.append("cursorCapture=\(bundle.sendControl(NvstInputActivation.mouseCursorCapture(isEnabled: true)))")
        sent.append("cursorTrack=\(bundle.sendControl(NvstInputActivation.mimicRemoteCursor(isEnabled: true)))")
        startCursorCaptureWatchdog()
        sent.append("window=\(bundle.sendControl(.windowStateChange()))")
        sent.append("system=\(bundle.sendControl(.systemStateChange()))")

        sent.append("haptics=\((try? sendFramedRemoteInput(NvstRemoteInput.hapticsState(enabled: true))) != nil)")
        logger?("NVST input activation sent (\(sent.joined(separator: " ")))")

        // Advertise connected Sony controllers for HID passthrough.
        sendHidChangeEventsForConnectedControllers()
    }

    private func announceRetransmissionState() {
        guard let bundle, let receiver, let qosManager, bundle.isControlChannelOpen else { return }
        let frame = max(1, qosManager.snapshot().lastFrameNumber)
        let enabled = qosManager.isRetransmissionFeasible(currentlyEnabled: receiver.isRetransmissionEnabled)
        receiver.updateRetransmissionState(frameNumber: frame, enabled: enabled,
            roundTripMilliseconds: bundle.roundTripMilliseconds) { [logger] command in
            let accepted = bundle.sendControl(command)
            logger?("NVST NACK activation frame=\(frame) enabled=\(enabled) accepted=\(accepted)")
            return accepted
        }
        if let request = qosManager.presentationRequestForRetransmission(enabled: receiver.isRetransmissionEnabled) {
            videoPipeline?.requestPresentation(request)
        }
    }

    func sendControlKeepAlive() {
        guard let bundle else { return }

        let value = receiver?.stats.framesEmitted ?? 0
        let sent = bundle.sendControl(.pingBackAck(streamValue: UInt32(truncatingIfNeeded: value)))
        if !sent { logger?("NVST control keepalive write failed") }
    }

    func beginVideoHolePunch() {
        guard Self.punchesVideoSocket else {
            logger?("NVST video socket hole punch suppressed (PIXELNOW_NVST_VIDEO_PUNCH=0)")
            return
        }
        receiver?.beginHolePunch()
        logger?("NVST video socket hole punch started")
    }

    func adoptFeedbackSender(_ sender: NvstFeedbackSender) {
        guard let receiver else { return }
        sender.setReportProvider { [weak receiver] in receiver?.receiverReportBlock() }
        if let ssrc = receiver.stats.boundSSRC { sender.updateMediaSSRC(ssrc) }
    }

    func startBundleProbe(handoff: NVSTVideoHandoff) {
        guard let descriptor = reserver?.takeBundleDescriptor(), descriptor >= 0 else {
            logger?("NVST bundle probe skipped: no reserved socket")
            return
        }
        do {
            let probe = try NvstBundleIceProbe(handoff: handoff, descriptor: descriptor, logger: logger)
            probe.start()
            bundleProbe = probe
            logger?("NVST bundle ICE probe started (STUN only, no DTLS)")
        } catch {
            close(descriptor)
            logger?("NVST bundle probe unavailable: \(error.localizedDescription)")
        }
    }

    func reportFatalDecodeError(_ message: String) {
        terminationContinuation?.yield(.transportFailed(NativeNVSTTransportFailure(
            message: "Native NVST could not decode video: \(message)",
            recoveryClassification: .permanent
        )))
    }

    func handleSeatTermination(reasonCode: UInt32?, summary: String) {
        let codeName = reasonCode.flatMap { NvstResult.name(for: $0) }
        let description = reasonCode.map { NvstResult.describe($0) } ?? summary
        logger?("NVST seat termination signaled by remote host: \(description)")
        Log.warning(.stream, "NVST seat termination signaled by remote host: \(description)")

        let terminationReason = NativeNVSTTerminationReason(rawValue: reasonCode ?? 0, resultName: codeName)
        let terminationValue = NativeNVSTTerminationValue(code: Int32(bitPattern: reasonCode ?? 0), name: codeName)
        let info = NativeNVSTSessionTermination(
            reason: terminationReason,
            extendedResult: terminationValue,
            isResumable: false,
            isSessionAlive: false,
            message: "GeForce NOW seat terminated the session: \(description)"
        )
        terminationContinuation?.yield(.sessionTerminated(info))
    }

    func handleSeatTerminationTimer(code: UInt16, payload: Data) {
        let hex = payload.map { String(format: "%02x", $0) }.joined()
        logger?("NVST seat termination timer signaled: code=\(String(format: "0x%04x", code)) payload=\(hex)")
        Log.warning(.stream, "NVST seat termination timer warning: code=\(String(format: "0x%04x", code)) payload=\(hex)")
        if let update = StreamSessionLimitUpdate.parse(from: payload), let notify = onSessionLimitUpdate {
            Task { @MainActor in notify(update) }
        }
    }

    // MARK: - HID Passthrough

    /// Sends `NvstHidPassthrough.ChangeEvent(.added)` for every connected Sony controller whose
    /// device kind is permitted by the current seat capability. Slots that have already been
    /// registered (pending or active) are skipped.
    func sendHidChangeEventsForConnectedControllers() {
        guard bundle != nil else { return }
        let capability = seatHidCapability ?? NvstHidPassthrough.SeatCapability(raw: 4)
        let controllers = GCController.controllers().filter { $0.extendedGamepad != nil }
        for controller in controllers {
            let playerIndex: Int
            if controller.playerIndex != .indexUnset {
                playerIndex = controller.playerIndex.rawValue
            } else if controllers.count == 1, let firstIndex = connectedGamepadIndices.first {
                playerIndex = firstIndex
            } else {
                continue
            }
            guard (0..<4).contains(playerIndex), connectedGamepadIndices.contains(playerIndex) else { continue }
            guard let identity = NvstHidPassthrough.deviceIdentity(for: controller, playerIndex: playerIndex) else { continue }

            // Gate: only register if the seat supports this controller family.
            switch identity.kind {
            case .dualShock4 where !capability.supportsDualShock4: continue
            case .dualSense  where !capability.supportsDualSense:  continue
            default: break
            }
            guard !pendingHidRegistrations.contains(playerIndex),
                  !hidPassthroughActive.contains(playerIndex) else { continue }

            let changeEvent = NvstHidPassthrough.ChangeEvent(
                deviceId: UInt8(clamping: playerIndex),
                change: .added,
                vendorId: identity.vendorId,
                productId: identity.productId
            )
            do {
                try sendFramedRemoteInput(changeEvent.packet)
                pendingHidRegistrations.insert(playerIndex)
                logger?("NVST HID ChangeEvent(.added) sent playerIndex=\(playerIndex) vid=0x\(String(format: "%04x", identity.vendorId)) pid=0x\(String(format: "%04x", identity.productId))")
            } catch {
                logger?("NVST HID ChangeEvent(.added) send failed playerIndex=\(playerIndex): \(error)")
            }
        }
    }

    func handleHidChangeResponse(deviceId: UInt8, status: UInt8) {
        let playerIndex = Int(deviceId)
        pendingHidRegistrations.remove(playerIndex)
        if status == 0 {
            hidPassthroughActive.insert(playerIndex)
            inputState.setHidActive(slot: playerIndex, active: true)
            logger?("NVST HID passthrough ACTIVE for playerIndex=\(playerIndex) — XInput suppressed on this slot")
        } else {
            inputState.setHidActive(slot: playerIndex, active: false)
            logger?("NVST HID ChangeResponse rejected playerIndex=\(playerIndex) status=\(status) — slot stays on XInput")
        }
    }
}
