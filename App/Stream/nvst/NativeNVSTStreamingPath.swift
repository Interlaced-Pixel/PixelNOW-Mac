import CoreAudio
import Foundation

final class NativeNVSTAudioDeviceMonitor: @unchecked Sendable {
    private static let systemObject = AudioObjectID(kAudioObjectSystemObject)
    private let callback: @Sendable () -> Void
    private var context: UnsafeMutableRawPointer?
    private var isMonitoring = false

    init(callback: @escaping @Sendable () -> Void) {
        self.callback = callback
        context = nil
        context = Unmanaged.passUnretained(self).toOpaque()
    }

    func start() {
        guard !isMonitoring else { return }
        isMonitoring = true
        guard let context else { return }
        for selector in Self.monitoredSelectors {
            var address = Self.propertyAddress(selector)
            AudioObjectAddPropertyListener(Self.systemObject, &address, nativeNVSTAudioDeviceChangedCallback, context)
        }
    }

    func stop() {
        guard isMonitoring else { return }
        isMonitoring = false
        guard let context else { return }
        for selector in Self.monitoredSelectors {
            var address = Self.propertyAddress(selector)
            AudioObjectRemovePropertyListener(Self.systemObject, &address, nativeNVSTAudioDeviceChangedCallback, context)
        }
    }

    deinit {
        stop()
    }

    fileprivate func notifyChange() {
        callback()
    }

    private static let monitoredSelectors: [AudioObjectPropertySelector] = [
        kAudioHardwarePropertyDefaultInputDevice,
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioHardwarePropertyDevices
    ]

    private static func propertyAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }
}

private let nativeNVSTAudioDeviceChangedCallback: AudioObjectPropertyListenerProc = { _, _, _, clientData in
    guard let clientData else { return noErr }
    let monitor = Unmanaged<NativeNVSTAudioDeviceMonitor>.fromOpaque(clientData).takeUnretainedValue()
    monitor.notifyChange()
    return noErr
}

public enum NativeNVSTMicrophoneStatus: String, Equatable, Sendable {
    case disabled
    case permissionDenied = "permission-denied"
    case available
    case capturerUnavailable = "capturer-unavailable"
    case setupFailed = "setup-failed"

    public var isAvailable: Bool {
        self == .available
    }
}

public protocol NativeNVSTSessionProvider: Sendable {
    func startNativeNVSTSession(configuration: PreparedLaunchConfiguration) async throws -> NativeNVSTSessionAllocation
    func recoverNativeNVSTSession(configuration: PreparedLaunchConfiguration, session: StreamSessionDescriptor) async throws -> NativeNVSTSessionAllocation
    func finishSession(_ session: StreamSessionDescriptor, reason: StreamEndReason) async throws

    func lookupActiveSessionConflict(excludingSessionID sessionID: String, applicationID: String) async -> StreamSessionConflict?
}

extension StreamSessionCoordinator: NativeNVSTSessionProvider {}

public extension NativeNVSTSessionProvider {
    func recoverNativeNVSTSession(configuration: PreparedLaunchConfiguration, session: StreamSessionDescriptor) async throws -> NativeNVSTSessionAllocation {
        throw NativeNVSTError.transportFailed("Native NVST session recovery is unavailable.")
    }

    func lookupActiveSessionConflict(excludingSessionID sessionID: String, applicationID: String) async -> StreamSessionConflict? {
        nil
    }
}

public protocol NativeNVSTTransport: Sendable {
    func prepare() async throws -> NVSTNativeBridgeStatus
    func connect(allocation: NativeNVSTSessionAllocation, mediaReceiver: any NativeNVSTMediaReceiver) async throws -> NativeNVSTTransportConnection
    func send(_ event: UserInputEvent) async throws
    func sendNow(_ event: UserInputEvent)
    func sendAbsoluteMouseMove(_ event: NativeNVSTAbsoluteMouseEvent) async throws
    func sendAbsoluteMouseMoveNow(_ event: NativeNVSTAbsoluteMouseEvent)
    func setMicrophoneEnabled(_ enabled: Bool) async throws
    func setMicrophoneConfiguration(_ configuration: NativeNVSTMicrophoneConfiguration) async throws
    func microphoneStatus() async -> NativeNVSTMicrophoneStatus
    func setLocalAudioPlaybackMuted(_ muted: Bool) async throws
    func togglePerformanceOverlay() async throws
    func performanceSnapshot() async -> NativeNVSTPerformanceSnapshot?
    func setMaximumBitrateKbps(_ bitrateKbps: UInt32) async throws
    func setDynamicStreamingMode(_ mode: NativeNVSTDynamicStreamingMode) async throws
    func setL4SEnabled(_ enabled: Bool) async throws
    func updateGamepadTopology(_ topology: NativeNVSTGamepadTopology) async throws
    func startRecording(configuration: WebRTCStreamRecordingConfiguration) async
    func stopRecording() async
    func setRecordingStatusHandler(_ handler: (@MainActor @Sendable (WebRTCStreamRecordingStatus) -> Void)?) async
    func pause() async throws
    func disconnect() async
    func disconnectForApplicationTermination() async
    func resetForRecovery() async
    func terminalEvents() async -> AsyncStream<NativeNVSTTransportTermination>
    func diagnosticMetadata() async -> [String: String]
}

public extension NativeNVSTTransport {
    func sendNow(_ event: UserInputEvent) {
        Task { try? await send(event) }
    }

    func sendAbsoluteMouseMove(_ event: NativeNVSTAbsoluteMouseEvent) async throws {
        throw NativeNVSTError.notRunning
    }

    func sendAbsoluteMouseMoveNow(_ event: NativeNVSTAbsoluteMouseEvent) {
        Task { try? await sendAbsoluteMouseMove(event) }
    }

    func performanceSnapshot() async -> NativeNVSTPerformanceSnapshot? {
        nil
    }

    func setMaximumBitrateKbps(_ bitrateKbps: UInt32) async throws { throw NativeNVSTError.notRunning }
    func setDynamicStreamingMode(_ mode: NativeNVSTDynamicStreamingMode) async throws { throw NativeNVSTError.notRunning }
    func setL4SEnabled(_ enabled: Bool) async throws { throw NativeNVSTError.notRunning }
    func updateGamepadTopology(_ topology: NativeNVSTGamepadTopology) async throws { throw NativeNVSTError.notRunning }
    func setMicrophoneConfiguration(_ configuration: NativeNVSTMicrophoneConfiguration) async throws {}
    func microphoneStatus() async -> NativeNVSTMicrophoneStatus { .disabled }
    func setLocalAudioPlaybackMuted(_ muted: Bool) async throws { throw NativeNVSTError.notRunning }

    func startRecording(configuration: WebRTCStreamRecordingConfiguration) async {}
    func stopRecording() async {}
    func setRecordingStatusHandler(_ handler: (@MainActor @Sendable (WebRTCStreamRecordingStatus) -> Void)?) async {}

    func pause() async throws {
        throw NativeNVSTError.notRunning
    }

    func disconnectForApplicationTermination() async {
        await disconnect()
    }

    func terminalEvents() async -> AsyncStream<NativeNVSTTransportTermination> {
        AsyncStream { $0.finish() }
    }

    func resetForRecovery() async { await disconnect() }
    func diagnosticMetadata() async -> [String: String] { [:] }
}

public enum NativeNVSTError: LocalizedError, Equatable, Sendable {
    case alreadyRunning
    case notRunning
    case sessionLimitReached
    case invalidSession(String)
    case runtimeUnavailable(String)
    case privateABIUnavailable(String)
    case transportFailed(String)
    case unsupportedCodec(String)
    case mediaNotReady(String)

    public var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            "Native NVST stream is already running."
        case .notRunning:
            "Native NVST stream is not running."
        case .sessionLimitReached:
            "GeForce NOW reports that another session is already active."
        case .invalidSession(let message), .runtimeUnavailable(let message), .privateABIUnavailable(let message), .transportFailed(let message), .unsupportedCodec(let message), .mediaNotReady(let message):
            message
        }
    }

    public var failurePhase: String {
        switch self {
        case .runtimeUnavailable:
            "runtime-loading"
        case .invalidSession:
            "session-validation"
        case .unsupportedCodec:
            "codec-validation"
        case .privateABIUnavailable:
            "native-setup"
        case .mediaNotReady:
            "media-readiness"
        case .sessionLimitReached, .transportFailed:
            "transport"
        case .alreadyRunning, .notRunning:
            "lifecycle"
        }
    }
}

public actor NativeNVSTStreamingPath {
    let sessionProvider: any NativeNVSTSessionProvider
    nonisolated let transport: any NativeNVSTTransport
    private let mediaSession: NativeNVSTMediaSession
    private let automaticRecovery: NativeNVSTAutomaticRecovery
    private var state: StreamingPathState = .idle
    private var startOwner: UUID?
    private var activeSession: StreamSessionDescriptor?
    private var activeAllocation: NativeNVSTSessionAllocation?
    private var launchConfiguration: PreparedLaunchConfiguration?
    var startedAt: ContinuousClock.Instant?
    private var terminalTask: Task<Void, Never>?
    private var cancelStartTask: Task<Void, Never>?

    private var recoveryAttempts = 0
    private var recoveryWindowStartedAt: ContinuousClock.Instant?

    private var isRecovering = false
    private var reportContinuations: [UUID: AsyncStream<StreamReport>.Continuation] = [:]

    public static let maximumRecoveryAttempts = 4
    public static let recoveryAttemptWindow: Duration = .seconds(120)

    public static let recoveryAttemptDelays: [Duration] = [.zero, .seconds(2), .seconds(4), .seconds(6)]

    public init(sessionProvider: any NativeNVSTSessionProvider,
                transport: any NativeNVSTTransport,
                mediaSession: NativeNVSTMediaSession = NativeNVSTMediaSession(),
                automaticRecovery: NativeNVSTAutomaticRecovery = .disabled) {
        self.sessionProvider = sessionProvider
        self.transport = transport
        self.mediaSession = mediaSession
        self.automaticRecovery = automaticRecovery
    }

    public func currentState() -> StreamingPathState {
        state
    }

    public func videoFrames(bufferingPolicy: AsyncStream<NativeNVSTVideoFrame>.Continuation.BufferingPolicy = .bufferingNewest(120)) async -> AsyncStream<NativeNVSTVideoFrame> {
        await mediaSession.videoFrames(bufferingPolicy: bufferingPolicy)
    }

    public func audioFrames(bufferingPolicy: AsyncStream<NativeNVSTAudioFrame>.Continuation.BufferingPolicy = .bufferingNewest(240)) async -> AsyncStream<NativeNVSTAudioFrame> {
        await mediaSession.audioFrames(bufferingPolicy: bufferingPolicy)
    }

    public func endEvents() -> AsyncStream<StreamReport> {
        let id = UUID()
        let pair = AsyncStream<StreamReport>.makeStream(bufferingPolicy: .bufferingNewest(1))
        reportContinuations[id] = pair.continuation
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.removeReportContinuation(id) }
        }
        return pair.stream
    }

    public func start(configuration: PreparedLaunchConfiguration,
                      progress: (@Sendable (StreamProgress) async -> Void)? = nil) async throws -> StreamSessionDescriptor {
        guard activeSession == nil, startOwner == nil else { throw NativeNVSTError.alreadyRunning }
        let owner = UUID()
        startOwner = owner
        defer {
            if startOwner == owner { startOwner = nil }
        }
        return try await withTaskCancellationHandler {
            try await startStreaming(configuration: configuration, progress: progress)
        } onCancel: {
            Task { await self.cancelStart(owner: owner) }
        }
    }

    private func startStreaming(configuration: PreparedLaunchConfiguration,
                                progress: (@Sendable (StreamProgress) async -> Void)?) async throws -> StreamSessionDescriptor {
        NativeNVSTMediaTelemetry.capture("nvst.path.start", level: .info, message: "Starting native NVST streaming path.", attributes: ["configurationId": configuration.id.uuidString, "applicationID": configuration.applicationID])

        try Task.checkCancellation()
        try await publishProgress(configuration: configuration, step: .checkNetworkRoute, message: "Checking native NVST runtime...", progress: progress)
        do {
            _ = try await transport.prepare()
        } catch {
            NativeNVSTMediaTelemetry.capture("nvst.path.runtime.error", level: .error, message: Self.message(for: error), attributes: ["applicationID": configuration.applicationID])
            throw error
        }

        try Task.checkCancellation()
        NativeNVSTMediaTelemetry.capture("nvst.path.allocate", level: .info, message: "Allocating cloud session...", attributes: ["applicationID": configuration.applicationID])
        try await publishProgress(configuration: configuration, step: .allocateCloudSession, message: "Allocating native NVST cloud session...", progress: progress)
        let allocation: NativeNVSTSessionAllocation
        do {
            allocation = try await sessionProvider.startNativeNVSTSession(configuration: configuration)
        } catch {
            if error is CancellationError || Task.isCancelled { throw error }
            NativeNVSTMediaTelemetry.capture("nvst.path.session_provider.error", level: .error, message: Self.message(for: error), attributes: ["applicationID": configuration.applicationID])
            throw error
        }

        do {
            try await stopSessionIfCancelled(allocation.session, isResume: allocation.isResume)
            try await publishProgress(configuration: configuration, step: .receiveStreamOffer, message: "Preparing native NVST transport...", progress: progress)
            try validate(allocation: allocation)
            try await publishProgress(configuration: configuration, step: .negotiateWebRTC, message: "Connecting native NVST secure RTSP transport...", progress: progress)
            _ = try await transport.connect(allocation: allocation, mediaReceiver: mediaSession)
            try await stopSessionIfCancelled(allocation.session, isResume: allocation.isResume)
        } catch {
            await transport.disconnect()
            await mediaSession.finish()

            let releaseReason: StreamEndReason = allocation.isResume
                ? .paused
                : (Task.isCancelled ? .userRequested : .failed)
            if error as? NativeNVSTError == .sessionLimitReached {

                try? await sessionProvider.finishSession(allocation.session, reason: releaseReason)
                if let conflict = await sessionProvider.lookupActiveSessionConflict(
                    excludingSessionID: allocation.session.id,
                    applicationID: configuration.applicationID
                ) {
                    throw StreamSessionError.activeSessionConflict(conflict)
                }
                throw error
            }
            try? await sessionProvider.finishSession(allocation.session, reason: releaseReason)
            if error is CancellationError || Task.isCancelled { throw error }
            NativeNVSTMediaTelemetry.capture("nvst.path.transport.error", level: .error, message: Self.message(for: error), attributes: ["sessionId": allocation.session.id])
            throw error
        }

        activeSession = allocation.session
        activeAllocation = allocation
        launchConfiguration = configuration
        startedAt = .now
        recoveryAttempts = 0
        recoveryWindowStartedAt = nil
        state = .running(allocation.session)
        monitorTransportTermination()
        try await publishProgress(configuration: configuration, step: .connected, message: "Connected over native NVST.", isReady: true, progress: progress)
        NativeNVSTMediaTelemetry.capture("nvst.path.connected", level: .info, message: "Native NVST streaming path connected.", attributes: ["sessionId": allocation.session.id, "applicationID": allocation.session.applicationID])
        return allocation.session
    }

    public func send(_ event: UserInputEvent) async throws {
        guard activeSession != nil else { throw NativeNVSTError.notRunning }
        try await transport.send(event)
    }

    public nonisolated func sendNow(_ event: UserInputEvent) {
        transport.sendNow(event)
    }

    public func sendAbsoluteMouseMove(_ event: NativeNVSTAbsoluteMouseEvent) async throws {
        guard activeSession != nil else { throw NativeNVSTError.notRunning }
        try await transport.sendAbsoluteMouseMove(event)
    }

    public nonisolated func sendAbsoluteMouseMoveNow(_ event: NativeNVSTAbsoluteMouseEvent) {
        transport.sendAbsoluteMouseMoveNow(event)
    }

    public func togglePerformanceOverlay() async throws {
        guard activeSession != nil else { throw NativeNVSTError.notRunning }
        try await transport.togglePerformanceOverlay()
    }

    public func setMicrophoneEnabled(_ enabled: Bool) async throws {
        guard activeSession != nil else { throw NativeNVSTError.notRunning }
        try await transport.setMicrophoneEnabled(enabled)
    }

    public func setLocalAudioPlaybackMuted(_ muted: Bool) async throws {
        guard activeSession != nil else { throw NativeNVSTError.notRunning }
        try await transport.setLocalAudioPlaybackMuted(muted)
    }

    @discardableResult
    public func startRecording(configuration: WebRTCStreamRecordingConfiguration) async -> Bool {
        guard activeSession != nil else { return false }
        await transport.startRecording(configuration: configuration)
        return true
    }

    public func stopRecording() async {
        await transport.stopRecording()
    }

    public func setRecordingStatusHandler(_ handler: (@MainActor @Sendable (WebRTCStreamRecordingStatus) -> Void)?) async {
        await transport.setRecordingStatusHandler(handler)
    }

    public func setMicrophoneConfiguration(_ configuration: NativeNVSTMicrophoneConfiguration) async throws {
        try await transport.setMicrophoneConfiguration(configuration)
    }

    public func performanceSnapshot() async -> NativeNVSTPerformanceSnapshot? {
        guard activeSession != nil else { return nil }
        return await transport.performanceSnapshot()
    }

    public func diagnosticMetadata() async -> [String: String] {
        await transport.diagnosticMetadata()
    }

    public func setMaximumBitrateKbps(_ bitrateKbps: UInt32) async throws {
        guard activeSession != nil else { throw NativeNVSTError.notRunning }
        try await transport.setMaximumBitrateKbps(bitrateKbps)
    }

    public func setDynamicStreamingMode(_ mode: NativeNVSTDynamicStreamingMode) async throws {
        guard activeSession != nil else { throw NativeNVSTError.notRunning }
        try await transport.setDynamicStreamingMode(mode)
    }

    public func setL4SEnabled(_ enabled: Bool) async throws {
        guard activeSession != nil else { throw NativeNVSTError.notRunning }
        try await transport.setL4SEnabled(enabled)
    }

    public func microphoneStatus() async -> NativeNVSTMicrophoneStatus {
        guard activeSession != nil else { return .disabled }
        return await transport.microphoneStatus()
    }

    public func updateGamepadTopology(_ topology: NativeNVSTGamepadTopology) async throws {
        guard activeSession != nil else { throw NativeNVSTError.notRunning }
        try await transport.updateGamepadTopology(topology)
    }

    public func stop(reason: StreamEndReason = .userRequested, message: String = "Native NVST stream ended.") async throws -> StreamReport {
        try await stop(reason: reason, message: message, forApplicationTermination: false)
    }

    public func stopForApplicationTermination(reason: StreamEndReason = .userRequested,
                                              message: String = "Native NVST stream ended.") async throws -> StreamReport {
        try await stop(reason: reason, message: message, forApplicationTermination: true)
    }

    private func stop(reason: StreamEndReason,
                      message: String,
                      forApplicationTermination: Bool) async throws -> StreamReport {
        if reason == .paused { return try await pause(message: message) }
        guard let activeSession else { throw NativeNVSTError.notRunning }
        terminalTask?.cancel()
        terminalTask = nil
        let durationSeconds = streamDurationSeconds()
        self.activeSession = nil
        activeAllocation = nil
        launchConfiguration = nil
        startedAt = nil
        recoveryAttempts = 0
        recoveryWindowStartedAt = nil
        NativeNVSTMediaTelemetry.capture("nvst.path.stop", level: .info, message: message, attributes: ["sessionId": activeSession.id, "reason": reason.rawValue])
        if forApplicationTermination {
            await transport.disconnectForApplicationTermination()
        } else {
            await transport.disconnect()
        }
        let diagnostics = await transport.diagnosticMetadata()
        let finishError: Error?
        do {
            try await sessionProvider.finishSession(activeSession, reason: reason)
            finishError = nil
        } catch {
            finishError = error
        }
        await mediaSession.finish()
        var metadata = ["transport": "nvst"]
        metadata.merge(diagnostics) { current, _ in current }
        if let finishError {
            metadata["cloudFinishError"] = Self.message(for: finishError)
        }
        let report = StreamReport(title: activeSession.title, success: reason != .failed && finishError == nil, reason: reason, message: message, durationSeconds: durationSeconds, metadata: metadata)
        state = .ended(report)
        publish(report)
        return report
    }

    public func pause(message: String = "Native NVST stream paused.") async throws -> StreamReport {
        guard let activeSession else { throw NativeNVSTError.notRunning }
        terminalTask?.cancel()
        terminalTask = nil
        let originalStartedAt = startedAt
        let originalAllocation = activeAllocation
        let originalConfiguration = launchConfiguration
        let originalRecoveryAttempts = recoveryAttempts
        let originalRecoveryWindow = recoveryWindowStartedAt
        let durationSeconds = streamDurationSeconds()
        self.activeSession = nil
        activeAllocation = nil
        launchConfiguration = nil
        startedAt = nil
        recoveryAttempts = 0
        recoveryWindowStartedAt = nil
        NativeNVSTMediaTelemetry.capture("nvst.path.pause", level: .info, message: message, attributes: ["sessionId": activeSession.id])
        do {
            try await transport.pause()
            try? await sessionProvider.finishSession(activeSession, reason: .paused)
            await mediaSession.finish()
            var metadata = ["transport": "nvst"]
            metadata.merge(await transport.diagnosticMetadata()) { current, _ in current }
            let report = StreamReport(title: activeSession.title, success: true, reason: .paused, message: message, durationSeconds: durationSeconds, metadata: metadata)
            state = .ended(report)
            publish(report)
            return report
        } catch {
            self.activeSession = activeSession
            activeAllocation = originalAllocation
            launchConfiguration = originalConfiguration
            startedAt = originalStartedAt
            recoveryAttempts = originalRecoveryAttempts
            recoveryWindowStartedAt = originalRecoveryWindow
            state = .running(activeSession)
            monitorTransportTermination()
            throw error
        }
    }

    public func cancelStart() async {
        guard let startOwner else { return }
        await cancelStart(owner: startOwner)
    }

    private func cancelStart(owner: UUID) async {
        guard startOwner == owner else { return }
        if let cancelStartTask {
            await cancelStartTask.value
            return
        }
        let task = Task { [sessionProvider, transport] in
            await transport.disconnect()
            if let cancellable = sessionProvider as? any StreamSessionStartCancellable {
                await cancellable.cancelSessionStart()
            }
        }
        cancelStartTask = task
        await task.value
        cancelStartTask = nil
    }

    private func stopSessionIfCancelled(_ session: StreamSessionDescriptor, isResume: Bool) async throws {
        guard Task.isCancelled else { return }
        await transport.disconnect()

        try? await sessionProvider.finishSession(session, reason: isResume ? .paused : .userRequested)
        throw CancellationError()
    }

    private func publish(_ report: StreamReport) {
        for continuation in reportContinuations.values {
            continuation.yield(report)
        }
    }

    private func removeReportContinuation(_ id: UUID) {
        reportContinuations[id] = nil
    }

    private func publishProgress(configuration: PreparedLaunchConfiguration,
                                 step: StreamLaunchStep,
                                 message: String,
                                 isReady: Bool = false,
                                 progress: (@Sendable (StreamProgress) async -> Void)?) async throws {
        let value = StreamProgress(configuration: configuration.progressConfiguration, step: step, message: message, isReady: isReady)
        if isReady, let activeSession {
            state = .running(activeSession)
        } else {
            state = .starting(value)
        }
        await progress?(value)
    }

    private func validate(allocation: NativeNVSTSessionAllocation) throws {
        guard !allocation.session.id.isEmpty else { throw NativeNVSTError.invalidSession("Native NVST session is missing a session id.") }
        guard !allocation.session.serverAddress.isEmpty else { throw NativeNVSTError.invalidSession("Native NVST session is missing a server address.") }
        guard !allocation.signalingURL.isEmpty || !allocation.signalingServer.isEmpty else { throw NativeNVSTError.invalidSession("Native NVST session is missing signaling connection information.") }
    }

    private func streamDurationSeconds() -> Double {
        guard let startedAt else { return 0 }
        let duration = startedAt.duration(to: .now)
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }

    private static func message(for error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription, !description.isEmpty { return description }
        return error.localizedDescription.isEmpty ? "Native NVST stream failed." : error.localizedDescription
    }
}

extension NativeNVSTStreamingPath {

    private func monitorTransportTermination() {
        terminalTask?.cancel()
        terminalTask = Task { [weak self, transport] in
            let events = await transport.terminalEvents()
            for await event in events {
                guard !Task.isCancelled else { return }
                await self?.handleTransportTermination(event)
                return
            }
        }
    }

    private func handleTransportTermination(_ termination: NativeNVSTTransportTermination) async {
        guard let activeSession else { return }

        guard !isRecovering else { return }
        terminalTask = nil
        if automaticRecovery == .singleAttempt, NativeNVSTRecoveryPolicy.permitsRecovery(termination), activeAllocation != nil, launchConfiguration != nil {
            let reason: String = switch termination {
            case .sessionTerminated(let info): "seat: \(info.message)"
            case .transportFailed(let failure): "transport: \(failure.message)"
            }
            if await recoverInPlace(reason: reason) {
                return
            }
        }
        guard self.activeSession?.id == activeSession.id else { return }
        let durationSeconds = streamDurationSeconds()
        self.activeSession = nil
        activeAllocation = nil
        launchConfiguration = nil
        startedAt = nil
        recoveryAttempts = 0
        recoveryWindowStartedAt = nil
        let reason: StreamEndReason
        let message: String
        switch termination {
        case .sessionTerminated(let info):

            reason = info.isPause ? .paused : .remoteEnded
            message = info.message.isEmpty
                ? (info.isPause ? "Native NVST stream paused." : "Native NVST stream ended remotely.")
                : info.message
        case .transportFailed(let failure):
            reason = .failed
            message = failure.message.isEmpty ? "Native NVST transport failed." : failure.message
        }
        let diagnostics = await transport.diagnosticMetadata()
        await transport.disconnect()
        try? await sessionProvider.finishSession(activeSession, reason: reason)
        await mediaSession.finish()
        var metadata = ["transport": "nvst"]
        metadata.merge(diagnostics) { current, _ in current }
        let report = StreamReport(title: activeSession.title, success: reason != .failed, reason: reason, message: message, durationSeconds: durationSeconds, metadata: metadata)
        state = .ended(report)
        publish(report)
    }

    public func canRecoverInPlace() -> Bool {
        guard automaticRecovery == .singleAttempt, activeSession != nil, activeAllocation != nil, launchConfiguration != nil, !isRecovering else { return false }
        if let started = recoveryWindowStartedAt, started.duration(to: .now) > Self.recoveryAttemptWindow { return true }
        return recoveryAttempts < Self.maximumRecoveryAttempts
    }

    public var isRecoveringInPlace: Bool { isRecovering }

    public func recoverInPlace(reason: String) async -> Bool {
        guard canRecoverInPlace(), let session = activeSession, let configuration = launchConfiguration else { return false }
        isRecovering = true
        defer { isRecovering = false }
        terminalTask?.cancel()
        terminalTask = nil
        if let started = recoveryWindowStartedAt, started.duration(to: .now) > Self.recoveryAttemptWindow {
            recoveryAttempts = 0
            recoveryWindowStartedAt = nil
        }
        if recoveryWindowStartedAt == nil { recoveryWindowStartedAt = .now }
        while recoveryAttempts < Self.maximumRecoveryAttempts {
            let attempt = recoveryAttempts
            recoveryAttempts += 1
            let delay = Self.recoveryAttemptDelays[min(attempt, Self.recoveryAttemptDelays.count - 1)]
            if delay > .zero {
                try? await Task.sleep(for: delay)
            }
            guard activeSession?.id == session.id, !Task.isCancelled else { return false }
            NativeNVSTMediaTelemetry.capture("nvst.path.recovery.attempt", level: .info, message: "Reconnecting native NVST session in place.", attributes: ["sessionId": session.id, "attempt": String(attempt + 1), "reason": reason])
            if await recover(session: session, configuration: configuration, attempt: attempt + 1) {
                return true
            }
        }
        return false
    }

    private func recover(session: StreamSessionDescriptor, configuration: PreparedLaunchConfiguration, attempt: Int = 1) async -> Bool {
        await transport.resetForRecovery()
        guard activeSession?.id == session.id, !Task.isCancelled else { return false }
        do {
            let refreshed = try await sessionProvider.recoverNativeNVSTSession(configuration: configuration, session: session)
            guard refreshed.session.id == session.id, refreshed.session.applicationID == session.applicationID else {
                throw NativeNVSTError.invalidSession("Native NVST recovery returned a different cloud session.")
            }
            guard activeSession?.id == session.id, !Task.isCancelled else { return false }
            _ = try await transport.connect(allocation: refreshed, mediaReceiver: mediaSession)
            guard activeSession?.id == session.id, !Task.isCancelled else {
                await transport.resetForRecovery()
                return false
            }
            activeAllocation = refreshed
            monitorTransportTermination()
            NativeNVSTMediaTelemetry.capture("nvst.path.recovered", level: .info, message: "Native NVST session recovered.", attributes: ["sessionId": session.id, "attempt": String(attempt)])
            return true
        } catch {
            NativeNVSTMediaTelemetry.capture("nvst.path.recovery.failed", level: .warning, message: Self.message(for: error), attributes: ["sessionId": session.id, "attempt": String(attempt)])
            await transport.resetForRecovery()
        }
        return false
    }
}
