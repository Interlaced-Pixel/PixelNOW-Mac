import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation

final class NvstActiveBundleHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: NvstWebRtcBundle?

    func set(_ bundle: NvstWebRtcBundle?) {
        lock.lock()
        storage = bundle
        lock.unlock()
    }

    func get() -> NvstWebRtcBundle? {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

final class NvstInputState: @unchecked Sendable {
    private let lock = NSLock()
    private var sequence: UInt32 = 0
    private var eventsSent: UInt64 = 0
    private var sendTotalMs: Double = 0
    private var sendPeakMs: Double = 0
    private var gamepadSequences: [UInt16: UInt16] = [:]

    func nextSequence() -> UInt32 {
        lock.lock()
        defer { lock.unlock() }
        sequence &+= 1
        return sequence
    }

    func nextGamepadSequence(padIndex: UInt16) -> UInt16 {
        lock.lock()
        defer { lock.unlock() }
        let seq = (gamepadSequences[padIndex] ?? 0) &+ 1
        gamepadSequences[padIndex] = seq
        return seq
    }

    func noteSend(durationMs: Double) {
        lock.lock()
        defer { lock.unlock() }
        eventsSent &+= 1
        sendTotalMs += durationMs
        if durationMs > sendPeakMs { sendPeakMs = durationMs }
    }

    var totalEventsSent: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return eventsSent
    }
}

public actor NVSTCoreTransport: NativeNVSTTransport {
    nonisolated let activeBundleHolder = NvstActiveBundleHolder()
    nonisolated let inputState = NvstInputState()

    public static var forcesLegacyPath: Bool {
        ProcessInfo.processInfo.environment["OPN_NVST_LEGACY_ANNOUNCE"] == "1"
    }

    public static var usesWebRtcBundle: Bool {
        ProcessInfo.processInfo.environment["OPN_NVST_WEBRTC_BUNDLE"] != "0"
    }

    public typealias PixelBufferSink = @Sendable (CVPixelBuffer, CMTime, Bool) -> Void

    let pixelBufferSink: PixelBufferSink?

    nonisolated let recorder = WebRTCStreamRecorder()

    nonisolated let remoteCoOpVideoRelay: RemoteCoOpHostVideoRelay
    nonisolated let remoteCoOpAudioRelay: RemoteCoOpHostAudioRelay
    let logger: (@Sendable (String) -> Void)?
    private let controlTimeout: Duration
    var reserver: NvstLocalBundleReserver?
    var session: NvstRtspSession?
    var receiver: NVSTWireReceiver?
    var bundleProbe: NvstBundleIceProbe?
    var bundle: NvstWebRtcBundle?
    var feedbackSender: NvstFeedbackSender?
    var qosManager: NvstQosManager?
    var streamProcessor: NvstStreamProcessor?
    var decoder: NvstVideoToolboxDecoder?

    var videoPipeline: NvstVideoPipeline?

    nonisolated let clock = NvstSessionClock()

    var mediaFrameContinuation: AsyncStream<NativeNVSTVideoFrame>.Continuation?
    var mediaForwardingTask: Task<Void, Never>?
    private var connection: NativeNVSTTransportConnection?
    var terminationContinuation: AsyncStream<NativeNVSTTransportTermination>.Continuation?
    private var terminationStream: AsyncStream<NativeNVSTTransportTermination>?
    var lastHandoff: NVSTVideoHandoff?
    private var heartbeatTask: Task<Void, Never>?
    var controlKeepAliveTask: Task<Void, Never>?
    var qosFeedbackTask: Task<Void, Never>?
    var initialKeyframeTask: Task<Void, Never>?
    var qosSequence: UInt32 = 0
    var lastQosBytesReceived: UInt64 = 0
    var lastQosDelayMicroseconds: UInt32 = 0

    static let targetFrameTimeMicroseconds: UInt32 = 16000

    var sessionFrameTimeMicroseconds: UInt32 {
        guard let fps = negotiatedFps, fps > 0 else { return Self.targetFrameTimeMicroseconds }
        return UInt32(1_000_000 / fps)
    }
    var remoteAudioTrackCount = 0

    var microphoneConfiguration: NativeNVSTMicrophoneConfiguration?

    var microphoneNegotiated = false
    var microphoneSenderSsrc: UInt32?

    var microphoneOfferedOnBundle = false

    var negotiatedFps: Int?

    var sessionServerLocation: String?

    var lastAudioJitterSample: (delaySeconds: Double, emitted: UInt64)?

    var lastAudioJitterBufferMilliseconds = -1.0

    var sessionGPUType: String?

    var latestSeatStats: NvstSeatStats?
    private var seatStatsReceived = 0

    func recordSeatStats(_ stats: NvstSeatStats) {
        latestSeatStats = stats
        seatStatsReceived += 1
        if seatStatsReceived <= 5 || seatStatsReceived % 60 == 0 {
            logger?("NVST \(stats.summary) n=\(seatStatsReceived)")
        }
    }
    var textCharactersTyped = 0
    var textBytesDropped = 0

    var gamepadSequences: [UInt16: UInt16] = [:]

    var registeredGamepadBitmap: UInt16?

    var connectedGamepadIndices: Set<Int> = []
    var didRegisterGamepad: Bool { registeredGamepadBitmap != nil }
    var gamepadPacketsSent = 0
    var gamepadSendFailures = 0

    var gamepadPacketsDroppedForUnannouncedPad = 0

    func seedGamepadSequenceForTesting(pad: UInt16, sequence: UInt16) {
        gamepadSequences[pad] = sequence
    }

    func seedMicrophoneBundleForTesting(negotiated: Bool) {
        if bundle == nil {
            bundle = NvstWebRtcBundle(
                handoff: NVSTVideoHandoff(
                    clientUDPPort: 0, videoPeerIP: "10.20.30.40", videoPeerPort: 5004,
                    srtpProfile: .aeadAes256Gcm8,
                    srtpAESKey: Data(repeating: 0xab, count: 32), srtpSalt: Data(repeating: 0x9e, count: 12),
                    codec: .h264, rtpPayloadType: 96, rtpSSRC: 0,
                    reorderWindowPackets: 32, maxAccessUnitBytes: 1024, timeoutMilliseconds: 5000,
                    pingVersion: 6, pingPayload: "PING", mjolnirUDPPort: 0,
                    iceCredentials: nil),
                preferredLocalAddress: nil)
        }
        microphoneNegotiated = negotiated
    }
    var didActivateInput = false
    var qosReportsSent = 0
    var qosReportFailures = 0
    var rtpStatsReportsSent = 0
    var controlStatsReportsSent = 0
    var lastRtpStatsFrame: UInt64 = 0
    var controlStatsLastSentAt: Date?
    var lastIdrRequestAt: Date?
    var idrRequestsSent = 0
    var lastInvalidationAt: Date?
    var pendingInvalidationFirst: UInt32?
    var pendingInvalidationLast: UInt32?
    var invalidationFlushTask: Task<Void, Never>?
    var invalidationsSent = 0
    var inputEventsSent = 0
    var inputSequence: UInt16 = 0
    var didAnnounceClientState = false

    var sessionStartedAt: Date? { clock.startDate }

    var isTornDown = false

    private let configuredFps: Int?

    let configuredMaxBitrateKbps: Int?

    private let configuredPrefilterMode: Int?
    private let configuredPrefilterSharpness: Int?
    private let configuredPrefilterDenoise: Int?
    private let configuredPrefilterModel: Int?

    let configuredColorQuality: String?
    let configuredGameVolume: Double?
    let configuredL4SEnabled: Bool

    var configuredAudioChannels: Int = 2

    public init(pixelBufferSink: PixelBufferSink? = nil,
                configuredFps: Int? = nil,
                configuredMaxBitrateKbps: Int? = nil,
                configuredPrefilterMode: Int? = nil,
                configuredPrefilterSharpness: Int? = nil,
                configuredPrefilterDenoise: Int? = nil,
                configuredPrefilterModel: Int? = nil,
                configuredColorQuality: String? = nil,
                configuredGameVolume: Double? = nil,
                configuredL4SEnabled: Bool = false,
                logger: (@Sendable (String) -> Void)? = nil,
                controlTimeout: Duration = .seconds(20),
                remoteCoOpVideoRelay: RemoteCoOpHostVideoRelay = RemoteCoOpHostVideoRelay(),
                remoteCoOpAudioRelay: RemoteCoOpHostAudioRelay = RemoteCoOpHostAudioRelay()) {
        self.remoteCoOpVideoRelay = remoteCoOpVideoRelay
        self.remoteCoOpAudioRelay = remoteCoOpAudioRelay
        self.pixelBufferSink = pixelBufferSink
        self.configuredFps = configuredFps
        self.configuredMaxBitrateKbps = configuredMaxBitrateKbps
        self.configuredPrefilterMode = configuredPrefilterMode
        self.configuredPrefilterSharpness = configuredPrefilterSharpness
        self.configuredPrefilterDenoise = configuredPrefilterDenoise
        self.configuredPrefilterModel = configuredPrefilterModel
        self.configuredColorQuality = configuredColorQuality
        self.configuredGameVolume = configuredGameVolume
        self.configuredL4SEnabled = configuredL4SEnabled
        self.logger = logger
        self.controlTimeout = controlTimeout
    }

    public func prepare() async throws {
        // Bifrost-free transport requires no native library loading.
    }

    public var isInputActivated: Bool { didActivateInput }
    public func connect(allocation: NativeNVSTSessionAllocation, mediaReceiver: any NativeNVSTMediaReceiver) async throws -> NativeNVSTTransportConnection {
        guard connection == nil else { throw NativeNVSTError.alreadyRunning }
        isTornDown = false

        let endpoints = NvstRtspEndpoints.collect(
            rawSessionJSON: allocation.rawSessionJSON,
            fallbackHost: Self.host(from: allocation.signalingServer),
            allowsAssumedControlPort: !allocation.isResume
        )
        guard !endpoints.isEmpty else {
            throw NativeNVSTError.transportFailed(allocation.isResume
                ? "This session has not published an RTSPS control endpoint, so the seat has not finished handing it over to this device."
                : "This session provided no RTSPS control endpoint, so NVST cannot be negotiated.")
        }
        sessionServerLocation = Self.sessionServerLocation(for: allocation)
        sessionGPUType = Self.sessionGPUType(for: allocation)
        let profile = Self.resolvedStreamProfile(allocation: allocation,
                                                 configuredFps: configuredFps,
                                                 configuredMaxBitrateKbps: configuredMaxBitrateKbps)
        let audioChannels = Self.sessionAudioChannels(from: allocation)
        self.configuredAudioChannels = audioChannels
        negotiatedFps = profile.fps
        negotiatedResolution = profile.resolution
        negotiatedCodec = profile.codec

        logger?("NVST profile fps=\(profile.fps.map(String.init) ?? "nil") resolution=\(profile.resolution ?? "nil")"
                + " codec=\(profile.codec ?? "nil") audioChannels=\(audioChannels) pacingTargetUs=\(sessionFrameTimeMicroseconds) maxKbps=\(profile.maximumBitrateKbps.map(String.init) ?? "nil") initKbps=\(profile.bitrateKbps.map(String.init) ?? "nil")")

        let stream = AsyncStream<NativeNVSTTransportTermination>.makeStream()
        terminationStream = stream.stream
        terminationContinuation = stream.continuation

        let reserver = NvstLocalBundleReserver(bundleProvider: { [weak self] handoff, microphoneOfferedOnBundle in
            await self?.bringUpBundle(handoff: handoff, microphoneOfferedOnBundle: microphoneOfferedOnBundle)
        })
        self.reserver = reserver
        let logger = self.logger
        let negotiator = NvstRtspNegotiator(reserver: reserver, logger: logger)
        let payload = NativeNVSTSessionPayload(allocation: allocation)
        let input = negotiationInput(sessionID: payload.sessionIdentifier, endpoints: endpoints, profile: profile)

        let negotiated: NvstRtspSession
        do {
            negotiated = try await negotiator.negotiate(
                input,
                onVideoReady: { [weak self] handoff in
                    try await self?.startVideo(handoff: handoff, mediaReceiver: mediaReceiver)
                },
                onAnnounceReady: { [weak self] _ in
                    await self?.punchVideoSocketBeforePlay()
                }
            )
        } catch {
            await teardown(reason: "negotiation failed")
            throw NativeNVSTError.transportFailed(error.localizedDescription)
        }
        session = negotiated
        logger?("NVST Bifrost-free session established (steps: \(negotiated.steps.joined(separator: " → ")))")

        startHeartbeat()
        try await prepare()
        let established = NativeNVSTTransportConnection(session: allocation.session)
        connection = established
        return established
    }

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled else { return }
                await self.logCounters()
            }
        }
    }

    private func logCountersSync() {
        guard let receiver else { return }
        let stats = receiver.stats

        let mediaNow = Double(stats.lastRtpTimestamp &- (stats.firstRtpTimestamp ?? 0)) / Double(NvstVideoToolboxDecoder.clockRate)
        let dFrames = stats.framesEmitted &- lastSummaryFrames
        let dMedia = mediaNow - lastSummaryMediaSeconds
        if dMedia > 0.25, dFrames > 0 {
            let intervalFps = Double(dFrames) / dMedia
            if intervalFps.isFinite, intervalFps > peakIntervalFps { peakIntervalFps = intervalFps }
        }
        lastSummaryFrames = stats.framesEmitted
        lastSummaryMediaSeconds = mediaNow
        if let maxBucket = stats.frameBytesPerSecond.max() {
            let mbps = Double(maxBucket) * 8 / 1_000_000
            if mbps > peakIntervalMbps { peakIntervalMbps = mbps }
        }

        let meanFrameBytes = stats.framesEmitted > 0 ? Double(stats.bytesReceived) / Double(stats.framesEmitted) : 0
        logger?(String(format: "NVST BITRATE meanFrameBytes=%.0f frames=%llu targetMbps=%@ decoderOutput=%@ bitstream=%@",
                       meanFrameBytes, stats.framesEmitted,
                       configuredMaxBitrateKbps.map { String(format: "%.0f", Double($0) / 1000) } ?? "-",
                       decoder?.outputPixelFormatName ?? "-",
                       decoder?.bitstreamFormat?.summary ?? "-"))
        logger?(String(format: "NVST SESSION SUMMARY peakStreamFps=%.1f peakStreamMbps=%.1f negFps=%@ | verdict fps%@60 bitrate%@24Mbps (fps cap lifted via announce maxFPS; bitrate bounded by initialBitrateKbps since the seat never ramps up — low-complexity scenes read low, that is content not a cap)",
                       peakIntervalFps, peakIntervalMbps,
                       negotiatedFps.map(String.init) ?? "nil",
                       peakIntervalFps > 60.5 ? ">" : "<=",
                       peakIntervalMbps > 24 ? ">" : "<="))
        let video = videoPipeline?.snapshot ?? NvstVideoPipeline.Counters()
        logger?("NVST counters auth=\(stats.authenticatedPackets) fec=\(stats.fecPackets) dropped=\(stats.droppedPackets) rtpLoss=\(stats.finalizedLossPackets) frames=\(stats.framesEmitted) keyframes=\(stats.keyframesEmitted) recoveries=\(stats.recoveries) sofFlagged=\(stats.startOfFrameFlagged) sofOk=\(stats.startOfFrameAccepted) abandoned=\(stats.abandonedFrames) rrFail=\(stats.receiverReportFailures)\(stats.lastReceiverReportFailure.map { " rrErr=\($0)" } ?? "") multiBlock=\(stats.multiBlockPackets) maxBlock=\(stats.highestFecLastBlock) decoded=\(decoder?.decodedFrameCount ?? 0) decodeFailed=\(decoder?.failedFrameCount ?? 0) decodeErr=\(decoder?.failureStatusSummary ?? "-") noParamSets=\(video.missingParameterSetFrames) idrOut=\(idrRequestsSent) invalidOut=\(invalidationsSent) inputOut=\(inputEventsSent) padOut=\(gamepadPacketsSent) padFail=\(gamepadSendFailures) padDropped=\(gamepadPacketsDroppedForUnannouncedPad) padReg=\(didRegisterGamepad) textTyped=\(textCharactersTyped) textDroppedBytes=\(textBytesDropped) inputReady=\(bundle?.isInputReady == true) rrOut=\(stats.receiverReportsSent) frac=\(stats.lastFractionLost) lost=\(stats.lastCumulativeLost) jitter=\(stats.lastJitter) seqSpan=\(stats.sequenceSpan) negFps=\(negotiatedFps.map(String.init) ?? "nil") mediaSeconds=\(String(format: "%.2f", Double(stats.lastRtpTimestamp &- (stats.firstRtpTimestamp ?? 0)) / Double(NvstVideoToolboxDecoder.clockRate))) fidxChanges=\(stats.frameIndexChanges) maxFrame=\(stats.maxFrameBytesPerSecond.map { String($0) }.joined(separator: ",")) bytesPerSec=\(stats.frameBytesPerSecond.map { String($0 / 1000) }.joined(separator: ",")) fpsPerSec=\(stats.framesPerSecond.map(String.init).joined(separator: ",")) paceOut=\(video.pacingReportsSent) paceFail=\(video.pacingReportFailures) ackOut=\(video.frameAcksSent) ackFail=\(video.frameAckFailures) qosOut=\(qosReportsSent) qosFail=\(qosReportFailures) rtpStatsOut=\(rtpStatsReportsSent) ccStatsOut=\(controlStatsReportsSent) ssrc=\(stats.boundSSRC.map { String(format: "0x%08x", $0) } ?? "-")")

        logger?(String(format: "NVST frame stages slow=%d frames=%llu resyncs=%d skipped=%d abandoned=%d lastLatency=%.1fms inputSendTotal=%.0fms inputSendPeak=%.1fms",
                       video.slowFrames, video.framesHandled, video.latencyResyncs,
                       video.framesSkippedForLatency, video.abandonedResyncs,
                       video.lastDecodeLatencyMilliseconds,
                       inputSendTotalMs, inputSendPeakMs)
                + " \(video.timingSummary)"
                + " decoderSessions=\(decoder?.sessionCreationCount ?? 0)"
                + " hwDecode=\(decoder?.isHardwareAccelerated == true)"
                + " decode\(decoder?.stageTimingSummary ?? "-")")
    }

    private func logCounters() async {
        guard let receiver else { return }
        logCountersSync()
        let audio = await bundle?.audioReception()
        logger?("NVST audio tracks=\(bundle?.remoteAudioTrackCount ?? 0) pktIn=\(audio?.packets ?? 0) bytesIn=\(audio?.bytes ?? 0)"
                + " samples=\(audio?.samples ?? 0) concealed=\(audio?.concealed ?? 0) discarded=\(audio?.discarded ?? 0) ssrc=\(audio?.ssrc.map(String.init) ?? "-")")
        let stats = receiver.stats
        await logHudCounters(receiver: receiver, stats: stats)
    }

    func logHudCounters(receiver: NVSTWireReceiver, stats: NvstReceiverStats) async {

        bundle?.refreshTransportStatistics()
        let keepAlive = await session?.controlKeepAliveSummary() ?? ""
        logger?(String(format: "NVST hud rtt=%.1fms mjolnirRtt=%.1fms ctrl[%@] jitter=%.1fms decodedRes=%@ negotiatedRes=%@ gameFps=%.1f audioJb=%.1fms",
                       bundle?.roundTripMilliseconds ?? -1,
                       receiver.roundTripMilliseconds,
                       keepAlive,
                       Double(stats.lastJitter) * 1000 / Double(NvstVideoToolboxDecoder.clockRate),
                       decoder?.decodedResolution ?? "-",
                       negotiatedResolution ?? "-",
                       latestSeatStats?.gameFramesPerSecond ?? -1,
                       lastAudioJitterBufferMilliseconds))

        logger?("NVST mjolnir \(receiver.inbound.summary) rcvbuf=\(receiver.receiveBufferBytes)"
                + " perPacket[\(receiver.processStageTimings.summary(packets: stats.authenticatedPackets + stats.droppedPackets))]"
                + " \(receiver.fecFindings.summary)"
                + " nacks=\(receiver.nackSummary.requests)/\(receiver.nackSummary.packets)pkt")
        if let bundle {
            logger?("NVST bundle \(bundle.diagnosticSummary) reportsSent=\(feedbackSender?.sentReportCount ?? 0)")
        }
        if let bundleProbe {
            logger?("NVST probe \(bundleProbe.snapshot.summary)")
        }
        if let sender = feedbackSender, let ssrc = receiver.stats.boundSSRC {
            sender.updateMediaSSRC(ssrc)
            sender.updateMediaState(highestExtendedSequence: receiver.stats.highestSequence,
                                    cumulativeLost: receiver.stats.lastCumulativeLost,
                                    fractionLost: receiver.stats.lastFractionLost,
                                    interarrivalJitter: receiver.stats.lastJitter)
        }
    }

    public func startRecording(configuration: WebRTCStreamRecordingConfiguration) async {
        recorder.start(configuration: configuration)
        logger?("NVST recording started \(configuration.width)x\(configuration.height)@\(configuration.fps)")
    }

    public func stopRecording() async {
        recorder.stop()
    }

    public func setRecordingStatusHandler(_ handler: (@MainActor @Sendable (WebRTCStreamRecordingStatus) -> Void)?) async {
        recorder.onStatusChanged = handler
    }

    public func disconnect() async {

        recorder.stop()

        remoteCoOpVideoRelay.removeAll()
        remoteCoOpAudioRelay.removeAll()
        await teardown(reason: "disconnect")
    }

    public func resetForRecovery() async {

        recorder.stop()
        await teardown(reason: "recovery")
    }

    public func terminalEvents() async -> AsyncStream<NativeNVSTTransportTermination> {
        terminationStream ?? AsyncStream { $0.finish() }
    }

    public func diagnosticMetadata() async -> [String: String] {
        let stats = receiver?.stats
        return [
            "transport": "nvst-bifrost-free",
            "nvidiaLibraries": "none",
            "rtspSession": session?.sessionIdentifier ?? "-",
            "rtspSteps": session?.steps.joined(separator: ",") ?? "-",
            "videoPeer": lastHandoff.map { "\($0.videoPeerIP):\($0.videoPeerPort)" } ?? "-",
            "mjolnirPort": lastHandoff.flatMap { $0.mjolnirUDPPort.map(String.init) } ?? "-",
            "srtpProfile": lastHandoff?.srtpProfile.rawValue ?? "-",
            "codec": lastHandoff?.codec.rawValue ?? "-",
            "authenticatedPackets": String(stats?.authenticatedPackets ?? 0),
            "fecPackets": String(stats?.fecPackets ?? 0),
            "droppedPackets": String(stats?.droppedPackets ?? 0),
            "framesAssembled": String(stats?.framesEmitted ?? 0),
            "keyframes": String(stats?.keyframesEmitted ?? 0),
            "recoveries": String(stats?.recoveries ?? 0),
            "framesDecoded": String(decoder?.decodedFrameCount ?? 0),
            "framesFailed": String(decoder?.failedFrameCount ?? 0),
            "mjolnirInbound": receiver?.inbound.summary ?? "-",
            "hapticEvents": String(hapticEventsReceived),
            "hdrMode": lastHdrMode?.summary ?? "-",
            "bundle": bundle?.diagnosticSummary ?? "-",
            "bundleProbe": bundleProbe?.snapshot.summary ?? "-",
        ]
    }

    public func sendRecoveryMode(enabled: Bool) async {
        guard let sender = feedbackSender else { return }
        if enabled {
            sender.requestKeyframe()
            try? sender.sendKeyframeRequestNow()
        }
    }

    var inputSendTotalMs = 0.0
    var inputSendPeakMs = 0.0
    var lastSnapshotAt: Date?
    var lastSnapshotFrames: UInt64 = 0
    var lastSnapshotBytes: UInt64 = 0
    var lastSnapshotPackets: UInt64 = 0
    var lastSnapshotLost: UInt64 = 0
    private var peakIntervalFps: Double = 0
    private var peakIntervalMbps: Double = 0
    private var lastSummaryFrames: UInt64 = 0
    private var lastSummaryMediaSeconds: Double = 0
    var negotiatedResolution: String?
    var negotiatedCodec: String?

    public internal(set) var remoteCursorVisible: Bool?
    var didDisableCursorCapture = false

    public internal(set) var onRemoteCursorVisibilityChanged: (@MainActor @Sendable (Bool) -> Void)?
    public internal(set) var onRemoteCursorChanged: (@MainActor @Sendable (NvstRemoteCursor) -> Void)?
    public internal(set) var onRemoteCursorCaptureChanged: (@MainActor @Sendable (Bool) -> Void)?
    var cursorCaptureWatchdogTask: Task<Void, Never>?

    static let cursorCaptureWatchdogDelay: Duration = .seconds(3)

    func startCursorCaptureWatchdog() {
        guard !isTornDown, cursorCaptureWatchdogTask == nil else { return }
        cursorCaptureWatchdogTask = Task { [weak self] in
            try? await Task.sleep(for: Self.cursorCaptureWatchdogDelay)
            guard !Task.isCancelled else { return }
            await self?.disableCursorCaptureAfterSilentSeat()
        }
    }

    func cancelCursorCaptureWatchdog() {
        cursorCaptureWatchdogTask?.cancel()
        cursorCaptureWatchdogTask = nil
    }

    func disableCursorCaptureAfterSilentSeat() {
        cancelCursorCaptureWatchdog()
        guard !isTornDown, !didDisableCursorCapture else { return }
        didDisableCursorCapture = true
        let sent = bundle?.sendControl(NvstInputActivation.mouseCursorCapture(isEnabled: false)) ?? false
        notifySeatCompositesCursor(false)
        let seconds = Self.cursorCaptureWatchdogDelay.components.seconds
        logger?("NVST no seat cursor notification in \(seconds)s; server-composited cursor disabled sent=\(sent)")
    }

    func notifySeatCompositesCursor(_ isCompositing: Bool) {
        guard let notify = onRemoteCursorCaptureChanged else { return }
        Task { @MainActor in notify(isCompositing) }
    }

    public internal(set) var onHapticEvents: (@MainActor @Sendable ([NvstHapticEvent]) -> Void)?
    var hapticEventsReceived: UInt64 = 0

    public internal(set) var onHdrModeChanged: (@MainActor @Sendable (NvstHdrModeNotification) -> Void)?
    public internal(set) var lastHdrMode: NvstHdrModeNotification?

    static func resolvedStreamProfile(allocation: NativeNVSTSessionAllocation,
                                              configuredFps: Int?,
                                              configuredMaxBitrateKbps: Int?) -> StreamProfile {
        var profile = Self.streamProfile(from: allocation)

        if let configuredFps, configuredFps > 0 { profile.fps = configuredFps }
        if let configuredMaxBitrateKbps, configuredMaxBitrateKbps > 0 {
            profile.maximumBitrateKbps = configuredMaxBitrateKbps

            profile.bitrateKbps = min(configuredMaxBitrateKbps, Self.maximumInitialBitrateKbps)
        }

        if let override = ProcessInfo.processInfo.environment["OPN_NVST_INITIAL_KBPS"].flatMap(Int.init),
           override > 0 {
            profile.bitrateKbps = override
        }
        return profile
    }

}

extension NVSTCoreTransport {

    func negotiationInput(sessionID: String, endpoints: [String], profile: StreamProfile) -> NvstRtspNegotiationInput {
        NvstRtspNegotiationInput(
            sessionID: sessionID,
            rtspsEndpoints: endpoints,
            resolution: profile.resolution,
            fps: profile.fps,
            codec: profile.codec,
            bitrateKbps: profile.bitrateKbps,
            maximumBitrateKbps: profile.maximumBitrateKbps,
            prefilterMode: configuredPrefilterMode,
            prefilterSharpness: configuredPrefilterSharpness,
            prefilterDenoise: configuredPrefilterDenoise,
            prefilterModel: configuredPrefilterModel,
            colorQuality: configuredColorQuality,
            audioChannels: configuredAudioChannels,
            timeout: controlTimeout,

            rtcpOnSctp: false,
            forcesLegacyPath: Self.forcesLegacyPath,
            disablesOwdCongestionControl: !Self.usesOwdCongestionControl,
            announcesExtendedSettings: Self.announcesExtendedSettings,
            echoesOfferedAttributes: Self.echoesOfferedAttributes,
            announceOverrides: Self.announceOverridesFromEnvironment(logger: logger)
        )
    }

    static func announceOverridesFromEnvironment(logger: (@Sendable (String) -> Void)?) -> [(String, String)] {
        guard let raw = ProcessInfo.processInfo.environment["OPN_NVST_ANNOUNCE_OVERRIDES"], !raw.isEmpty else { return [] }
        let pairs = raw.split(separator: ";").compactMap { entry -> (String, String)? in
            let parts = entry.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, !parts[0].isEmpty else { return nil }
            let name = parts[0].hasPrefix("x-nv-") ? parts[0] : "x-nv-" + parts[0]
            return (name, parts[1])
        }
        logger?("NVST announce overrides (harness): " + pairs.map { "\($0.0)=\($0.1)" }.joined(separator: " "))
        return pairs
    }

    func teardown(reason: String) async {
        isTornDown = true
        cancelCursorCaptureWatchdog()
        heartbeatTask?.cancel()
        heartbeatTask = nil
        invalidationFlushTask?.cancel()
        invalidationFlushTask = nil
        pendingInvalidationFirst = nil
        pendingInvalidationLast = nil

        didActivateInput = false
        didAnnounceClientState = false
        registeredGamepadBitmap = nil
        didDisableCursorCapture = false
        remoteCursorVisible = nil
        lastSnapshotAt = nil
        lastSnapshotFrames = 0
        lastSnapshotBytes = 0
        lastSnapshotPackets = 0
        lastSnapshotLost = 0
        lastAudioJitterSample = nil
        latestSeatStats = nil
        controlKeepAliveTask?.cancel()
        controlKeepAliveTask = nil
        qosFeedbackTask?.cancel()
        qosFeedbackTask = nil
        initialKeyframeTask?.cancel()
        initialKeyframeTask = nil
        logCountersSync()
        bundle?.refreshTransportStatistics()
        feedbackSender?.flush()
        feedbackSender?.stop()
        feedbackSender = nil

        receiver?.stop()
        receiver = nil

        videoPipeline?.stop()
        videoPipeline = nil
        bundle?.close()
        bundle = nil
        activeBundleHolder.set(nil)
        microphoneNegotiated = false
        microphoneSenderSsrc = nil
        microphoneOfferedOnBundle = false
        bundleProbe?.stop()
        bundleProbe = nil
        mediaFrameContinuation?.finish()
        mediaFrameContinuation = nil
        mediaForwardingTask?.cancel()
        mediaForwardingTask = nil
        decoder?.invalidate()
        decoder = nil
        if let session {
            await session.release(reason)
        }
        session = nil
        reserver?.release()
        reserver = nil
        connection = nil
        terminationContinuation?.finish()
        terminationContinuation = nil
        terminationStream = nil
    }
}

public typealias NvstBifrostFreeTransport = NVSTCoreTransport
