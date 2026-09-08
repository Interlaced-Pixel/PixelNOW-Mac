import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation

extension NVSTCoreTransport {

    func startVideo(handoff: NVSTVideoHandoff, mediaReceiver: any NativeNVSTMediaReceiver) async throws {
        let videoLogger = self.logger
        let decoder = try NvstVideoToolboxDecoder(codec: handoff.codec)
        decoder.onDecodeFailure = { [weak self] frameIndex, message in
            videoLogger?("NVST \(message)")
            guard frameIndex != 0 else { return }

            Task { await self?.invalidateFrame(frameIndex) }
        }
        let sink = pixelBufferSink

        let recorder = self.recorder

        let coOpVideoRelay = self.remoteCoOpVideoRelay

        decoder.onPixelBuffer = { pixelBuffer, presentationTime, isKeyframe in
            recorder.appendNativePixelBuffer(pixelBuffer)
            coOpVideoRelay.renderPixelBuffer(pixelBuffer, presentationTime: presentationTime)
            sink?(pixelBuffer, presentationTime, isKeyframe)
        }
        self.decoder = decoder
        lastHandoff = handoff

        let descriptor = reserver?.takeWireDescriptor() ?? -1
        let receiver = try NVSTWireReceiver(
            handoff: handoff,

            sendsReceiverReports: true,
            existingDescriptor: descriptor
        )
        let logger = self.logger

        let (mediaFrames, mediaContinuation) = AsyncStream<NativeNVSTVideoFrame>.makeStream(
            bufferingPolicy: .bufferingNewest(4))
        mediaForwardingTask?.cancel()
        mediaForwardingTask = Task.detached(priority: .utility) {
            for await frame in mediaFrames {
                if Task.isCancelled { return }
                await mediaReceiver.receiveVideoFrame(frame)
            }
        }
        mediaFrameContinuation = mediaContinuation
        let pipeline = makeVideoPipeline(handoff: handoff, decoder: decoder, receiver: receiver, mediaContinuation: mediaContinuation)
        videoPipeline = pipeline
        receiver.onAccessUnit = { [weak pipeline] unit in pipeline?.submit(unit) }
        receiver.onRecoveryNeeded = { [weak self, weak receiver] brokenFrameIndex in

            receiver?.requestKeyframe()

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
        logger?("NVST Mjolnir receiver armed on port \((handoff.wireUDPPort ?? handoff.mjolnirUDPPort) ?? handoff.clientUDPPort) for peer \(handoff.videoPeerIP):\(handoff.videoPeerPort)")
    }

    private func makeVideoPipeline(handoff: NVSTVideoHandoff,
                                   decoder: NvstVideoToolboxDecoder,
                                   receiver: NVSTWireReceiver,
                                   mediaContinuation: AsyncStream<NativeNVSTVideoFrame>.Continuation) -> NvstVideoPipeline {

        let displayRefreshRate = StreamPreferences.loadDeviceCapabilities().maxDisplayRefreshRate
        let displayVsyncMicroseconds = displayRefreshRate > 0 ? UInt32(1_000_000 / displayRefreshRate) : 16000
        return NvstVideoPipeline(
            decoder: decoder,
            clock: clock,
            frameTimeMicroseconds: sessionFrameTimeMicroseconds,
            displayVsyncMicroseconds: displayVsyncMicroseconds,
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
            onKeyframeNeeded: { [weak self, weak receiver] in
                receiver?.requestKeyframe()
                Task { await self?.requestKeyframeOverControlChannel() }
            },
            onFatalDecodeError: { [weak self] message in
                Task { await self?.reportFatalDecodeError(message) }
            }
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
            self.bundle = bundle
            activeBundleHolder.set(bundle)
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
        bundle.onInputProtocolNegotiated = { [weak self] version in
            Task { await self?.inputDidNegotiate(version) }
        }
        bundle.onRemoteCursor = { [weak self] cursor in
            Task { await self?.handleRemoteCursor(cursor) }
        }
        bundle.onSeatStats = { [weak self] stats in
            Task { await self?.recordSeatStats(stats) }
        }
        bundle.onHapticEvents = { [weak self] events in
            Task { await self?.handleHapticEvents(events) }
        }
        bundle.onHdrMode = { [weak self] notification in
            Task { await self?.handleHdrMode(notification) }
        }
        bundle.onAudioSurroundInfo = { [weak self] surround in
            Task { await self?.handleAudioSurroundInfo(surround) }
        }
        bundle.onRemoteAudio = { [weak self] count in
            logger?("NVST bundle seat offered \(count) audio track(s)")
            Task { await self?.noteRemoteAudio(trackCount: count) }
        }

        let recorder = self.recorder
        let coOpAudioRelay = self.remoteCoOpAudioRelay
        bundle.onGameAudioFrame = { audioBufferList, frameCount, sampleRate, channels in
            recorder.appendGameAudio(audioBufferList: audioBufferList, frameCount: frameCount, sampleRate: sampleRate, channels: channels)
            coOpAudioRelay.renderAudioFrame(audioBufferList: audioBufferList, frameCount: frameCount, sampleRate: sampleRate, channels: channels)
        }
        bundle.onPartiallyReliableControlOpen = { [weak self] in
            Task { await self?.startQosFeedback() }
        }
        bundle.onControlChannelOpen = { [weak self] in
            Task {
                await self?.startControlKeepAlive()
                await self?.announceClientState()
                await self?.requestInitialKeyframe()
                await self?.activateInputIfNegotiated()
            }
        }
        bundle.onFeedbackChannelOpen = { [weak self] in
            logger?("NVST feedback channel open; starting receiver reports")
            sender.start()
            Task {
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

    static var announcesExtendedSettings: Bool { ProcessInfo.processInfo.environment["OPN_NVST_ANNOUNCE_EXTENDED"] == "1" }

    static var usesOwdCongestionControl: Bool { ProcessInfo.processInfo.environment["OPN_NVST_OWD_CC"] != "0" }
    static var echoesOfferedAttributes: Bool { ProcessInfo.processInfo.environment["OPN_NVST_ANNOUNCE_ECHO_OFFER"] == "1" }

    static var punchesVideoSocket: Bool { ProcessInfo.processInfo.environment["OPN_NVST_VIDEO_PUNCH"] != "0" }

    func startControlKeepAlive() {
        guard !isTornDown, controlKeepAliveTask == nil else { return }
        logger?("NVST control keepalive started (\(Int(NvstControlCommand.pingBackIntervalSeconds))s)")
        controlKeepAliveTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.sendControlKeepAlive()
                try? await Task.sleep(for: .seconds(NvstControlCommand.pingBackIntervalSeconds))
            }
        }
    }

    func noteRemoteAudio(trackCount: Int) {
        remoteAudioTrackCount = trackCount
    }

    func startQosFeedback() {
        guard !isTornDown, qosFeedbackTask == nil else { return }
        logger?("NVST QoS feedback started (\(String(format: "%.0f", 1 / NvstQosReport.interval))/s)")
        qosFeedbackTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.sendQosReport()
                await self.sendRtpStatsIfNeeded()
                await self.sendControlChannelStatsIfNeeded()
                try? await Task.sleep(for: .seconds(NvstQosReport.interval))
            }
        }
    }

    func sendQosReport() {
        guard let bundle, let receiver else { return }
        let counters = receiver.feedbackCounters
        let bytes = UInt32(truncatingIfNeeded: counters.bytesReceived)
        let now = Date()

        qosSequence += 1

        let capabilityKbps = UInt16(clamping: max(Int(NvstQosReport.defaultLinkCapabilityKbps),
                                                  configuredMaxBitrateKbps ?? 0))

        let jitterMicroseconds = UInt32(clamping: Int(Double(receiver.stats.lastJitter) * 1_000_000
            / Double(NvstVideoToolboxDecoder.clockRate)))

        let delayTrend = jitterMicroseconds >= lastQosDelayMicroseconds
            ? jitterMicroseconds - lastQosDelayMicroseconds
            : lastQosDelayMicroseconds - jitterMicroseconds
        lastQosDelayMicroseconds = jitterMicroseconds

        let deltaBytes = counters.bytesReceived >= lastQosBytesReceived
            ? counters.bytesReceived - lastQosBytesReceived
            : 0
        let previousBytes = UInt32(truncatingIfNeeded: lastQosBytesReceived)
        lastQosBytesReceived = counters.bytesReceived

        let report = NvstQosReport(
            sequence: qosSequence,
            framesReceived: UInt32(truncatingIfNeeded: counters.framesEmitted),
            bytesReceived: bytes,
            linkCapabilityKbps: capabilityKbps,
            rtpTimestamp: counters.lastRtpTimestamp,

            previousBytesReceived: previousBytes,
            delayMicroseconds: jitterMicroseconds,
            delayTrendMicroseconds: delayTrend,
            intervalBits: UInt32(clamping: deltaBytes * 8),
            isWarmedUp: sessionStartedAt.map { now.timeIntervalSince($0) >= NvstQosReport.warmUpSeconds } ?? false
        )

        if bundle.sendPartiallyReliableControl(report.command) {
            qosReportsSent += 1
        } else {
            qosReportFailures += 1
            if qosReportFailures == 1 { logger?("NVST QoS report write failed") }
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
        if !didDisableCursorCapture, let bundle {
            didDisableCursorCapture = true
            let sent = bundle.sendControl(NvstInputActivation.mouseCursorCapture(isEnabled: false))
            logger?("NVST seat cursor notifications started; server-composited cursor disabled sent=\(sent)")
        }
        guard cursor.isVisible != remoteCursorVisible else { return }
        let previous = remoteCursorVisible
        remoteCursorVisible = cursor.isVisible

        logger?(String(format: "NVST remote cursor %@ -> %@ at %.3fs",
                       previous.map { $0 ? "visible" : "hidden" } ?? "unknown",
                       cursor.isVisible ? "visible" : "hidden",
                       Double(clock.elapsedMicroseconds()) / 1_000_000))
        if let notify = onRemoteCursorVisibilityChanged {
            let isVisible = cursor.isVisible
            Task { @MainActor in notify(isVisible) }
        }
    }

    public func setRemoteCursorVisibilityHandler(_ handler: (@MainActor @Sendable (Bool) -> Void)?) {
        onRemoteCursorVisibilityChanged = handler
    }

    public func setHapticEventHandler(_ handler: (@MainActor @Sendable ([NvstHapticEvent]) -> Void)?) {
        onHapticEvents = handler
    }

    public func setHdrModeHandler(_ handler: (@MainActor @Sendable (NvstHdrModeNotification) -> Void)?) {
        onHdrModeChanged = handler
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
        guard let start = sessionStartedAt else { return 0 }
        return UInt64(max(0, Date().timeIntervalSince(start)) * 1_000_000)
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
        if let frameIndex { invalidateFrame(frameIndex) }
        requestKeyframeOverControlChannel()
    }

    func invalidateFrame(_ frameIndex: UInt32) {
        let now = Date()
        if let last = lastInvalidationAt, now.timeIntervalSince(last) < Self.invalidationCoalesceInterval {
            pendingInvalidationFirst = min(pendingInvalidationFirst ?? frameIndex, frameIndex)
            pendingInvalidationLast = max(pendingInvalidationLast ?? frameIndex, frameIndex)
            scheduleInvalidationFlush(after: Self.invalidationCoalesceInterval - now.timeIntervalSince(last))
            return
        }
        sendInvalidation(first: frameIndex, last: frameIndex, at: now)
    }

    private func scheduleInvalidationFlush(after delay: TimeInterval) {
        guard invalidationFlushTask == nil else { return }
        invalidationFlushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(max(1, Int(delay * 1000))))
            await self?.flushPendingInvalidation()
        }
    }

    private func flushPendingInvalidation() {
        invalidationFlushTask = nil
        guard let first = pendingInvalidationFirst, let last = pendingInvalidationLast else { return }
        sendInvalidation(first: first, last: last, at: Date())
    }

    private func sendInvalidation(first: UInt32, last: UInt32, at now: Date) {
        pendingInvalidationFirst = nil
        pendingInvalidationLast = nil
        lastInvalidationAt = now
        guard let bundle else { return }
        guard bundle.sendControl(.frameInvalidationRange(first: UInt64(first), last: UInt64(last))) else {
            logger?("NVST frame invalidation write failed")
            return
        }
        invalidationsSent += 1
    }

    static let invalidationCoalesceInterval: TimeInterval = 0.04

    func requestKeyframeOverControlChannel() {
        guard let bundle else { return }
        let now = Date()
        if let last = lastIdrRequestAt, now.timeIntervalSince(last) < Self.idrRequestInterval { return }
        lastIdrRequestAt = now
        guard bundle.sendControl(.idrRequest()) else {
            logger?("NVST IDR request write failed")
            return
        }
        idrRequestsSent += 1
    }

    func requestInitialKeyframe() {
        guard let bundle, bundle.isControlChannelOpen else { return }
        lastIdrRequestAt = Date()
        if bundle.sendControl(.idrRequest()) {
            idrRequestsSent += 1
            logger?("NVST initial IDR request sent")
        } else {
            logger?("NVST initial IDR request write failed")
        }

        initialKeyframeTask?.cancel()
        initialKeyframeTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                let frames = await self.receiver?.stats.framesEmitted ?? 0
                if frames > 0 { return }
                guard await !self.isTornDown else { return }
                await self.sendInitialIdrRetry()
            }
        }
    }

    func sendInitialIdrRetry() {
        guard let bundle, bundle.isControlChannelOpen else { return }
        lastIdrRequestAt = Date()
        if bundle.sendControl(.idrRequest()) {
            idrRequestsSent += 1
            logger?("NVST initial IDR request retry sent (#\(idrRequestsSent))")
            if idrRequestsSent == 10 {
                logger?("[error] NVST video stream timeout: No video frames received after 10s. The video port hole punch may have failed or UDP is blocked by a firewall.")
            }
        } else {
            logger?("NVST initial IDR request retry write failed")
        }
    }

    func activateInputIfNegotiated() {
        if bundle?.negotiatedInputProtocolVersion != nil {
            activateInput()
        }
    }

    static let maximumInitialBitrateKbps = 150_000

    static let idrRequestInterval: TimeInterval = 0.5

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
        guard ProcessInfo.processInfo.environment["OPN_NVST_RI_NO_ACTIVATION"] != "1" else {
            logger?("NVST input activation skipped by request")
            return
        }

        var sent: [String] = []
        sent.append("enableOff=\(bundle.sendControl(NvstInputActivation.enableInput(counter: 1, isEnabled: false)))")

        if connectedGamepadIndices.isEmpty { connectedGamepadIndices = [0] }
        let activationBitmap = NvstGamepadPacket.connectedBitmap(for: connectedGamepadIndices)
        sent.append("descriptor=\(bundle.sendControl(NvstInputActivation.deviceDescriptor(timestampMicroseconds: sessionElapsedMicroseconds(), connectedBitmap: activationBitmap)))")

        registeredGamepadBitmap = activationBitmap

        sent.append("cursorCapture=\(bundle.sendControl(NvstInputActivation.mouseCursorCapture(isEnabled: true)))")
        sent.append("cursorTrack=\(bundle.sendControl(NvstInputActivation.mimicRemoteCursor(isEnabled: true)))")
        sent.append("window=\(bundle.sendControl(.windowStateChange()))")
        sent.append("system=\(bundle.sendControl(.systemStateChange()))")
        sent.append("enableOn=\(bundle.sendControl(NvstInputActivation.enableInput(counter: UInt32((videoPipeline?.snapshot.frameAcksSent ?? 0) + 1))))")

        sent.append("haptics=\((try? sendFramedRemoteInput(NvstRemoteInput.hapticsState(enabled: true))) != nil)")
        logger?("NVST input activation sent (\(sent.joined(separator: " ")))")
    }

    func sendControlKeepAlive() {
        guard let bundle else { return }

        let value = receiver?.stats.framesEmitted ?? 0
        let sent = bundle.sendControl(.pingBackAck(streamValue: UInt32(truncatingIfNeeded: value)))
        if !sent { logger?("NVST control keepalive write failed") }
    }

    func beginVideoHolePunch() {
        guard Self.punchesVideoSocket else {
            logger?("NVST video socket hole punch suppressed (OPN_NVST_VIDEO_PUNCH=0)")
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
}
