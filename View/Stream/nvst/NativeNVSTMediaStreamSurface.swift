import Foundation
import GameController
import SwiftUI

public typealias NativeNVSTMediaStreamProgressCallback = @MainActor @Sendable (_ progress: StreamProgress) -> Void
public typealias NativeNVSTMediaStreamEndCallback = @MainActor @Sendable (_ success: Bool, _ message: String, _ report: StreamReport?) -> Void

enum NativeNVSTMediaStreamTheme {
    static let accent = Color(red: 0.08, green: 0.48, blue: 0.98)
    static let accentSoft = Color(red: 0.35, green: 0.68, blue: 1.0)
    static let appBar = Color(red: 45 / 255, green: 45 / 255, blue: 45 / 255)
    static let surface = Color(red: 25 / 255, green: 25 / 255, blue: 25 / 255)
    static let panel = Color(red: 23 / 255, green: 23 / 255, blue: 23 / 255)
    static let surfaceRaised = Color(red: 34 / 255, green: 34 / 255, blue: 34 / 255)
    static let divider = Color.white.opacity(0.10)
    static let textPrimary = Color.white.opacity(0.96)
    static let textSecondary = Color.white.opacity(0.72)
    static let textTertiary = Color.white.opacity(0.52)
    static let warning = Color.orange
    static let danger = Color.red

    static func dockWidth(for width: CGFloat) -> CGFloat {
        min(344, max(268, width * 0.72))
    }
}

extension Font {
    static func nativeNVSTStreamNvidia(size: CGFloat, weight: NVIDIAFont.Weight = .regular) -> Font {
        NVIDIAFont.font(size: size, weight: weight)
    }
}

struct NativeNVSTStreamHUDActionRow: View {
    let title: String
    let subtitle: String
    let systemName: String
    let isActive: Bool
    let isDisabled: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.nativeNVSTStreamNvidia(size: 15, weight: .bold))
                .foregroundStyle(iconColor)
                .frame(width: 42, height: 38)
                .background(rowBackground)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(isActive ? Color.pixelNowGreen.opacity(0.86) : NativeNVSTMediaStreamTheme.divider, lineWidth: 1)
                }
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.46 : 1)
        .onHover { isHovering = $0 }
        .accessibilityLabel(title)
        .accessibilityHint(subtitle)
        .help(subtitle.isEmpty ? title : "\(title): \(subtitle)")
    }

    private var rowBackground: Color {
        if isActive { return Color.pixelNowGreen }
        return Color.white.opacity(isHovering ? 0.14 : 0.075)
    }

    private var iconColor: Color {
        isActive ? .black : .white.opacity(isHovering ? 0.94 : 0.72)
    }
}

struct NativeNVSTStreamUnifiedSidebar<Content: View>: View {
    let title: String
    let closeAction: () -> Void
    let content: Content

    init(title: String, closeAction: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.title = title
        self.closeAction = closeAction
        self.content = content()
    }

    var body: some View {
        GeometryReader { proxy in
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Text(title)
                        .font(.nativeNVSTStreamNvidia(size: 12, weight: .bold))
                        .foregroundStyle(NativeNVSTMediaStreamTheme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                    Button(action: closeAction) {
                        Image(systemName: "xmark")
                            .font(.nativeNVSTStreamNvidia(size: 11, weight: .bold))
                            .foregroundStyle(.white.opacity(0.82))
                            .frame(width: 28, height: 28)
                            .background(Color.white.opacity(0.08), in: Circle())
                            .overlay { Circle().stroke(Color.white.opacity(0.14), lineWidth: 1) }
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel("Close stream HUD")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(NativeNVSTMediaStreamTheme.appBar)
                Rectangle().fill(NativeNVSTMediaStreamTheme.divider).frame(height: 1)
                ScrollView(.vertical, showsIndicators: false) {
                    content
                        .padding(.horizontal, 18)
                        .padding(.vertical, 14)
                }
                Rectangle().fill(NativeNVSTMediaStreamTheme.divider).frame(height: 1)
                Text(NativeNVSTMediaStreamCommand.shortcutGuide)
                    .font(.nativeNVSTStreamNvidia(size: 10, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(NativeNVSTMediaStreamTheme.textTertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 9)
            }
            .frame(width: NativeNVSTMediaStreamTheme.dockWidth(for: proxy.size.width), height: proxy.size.height, alignment: .topLeading)
            .background(NativeNVSTMediaStreamTheme.panel.opacity(0.96))
            .background(.ultraThinMaterial)
            .overlay(alignment: .trailing) { Rectangle().fill(NativeNVSTMediaStreamTheme.divider).frame(width: 1) }
            .shadow(color: .black.opacity(0.58), radius: 28, x: 14, y: 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .ignoresSafeArea(.container, edges: [.horizontal, .bottom])
    }
}

struct NativeNVSTStreamHUDSection<Content: View>: View {
    let label: String
    let spacing: CGFloat
    let content: Content

    init(label: String, spacing: CGFloat = 10, @ViewBuilder content: () -> Content) {
        self.label = label
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            Text(label)
                .font(.nativeNVSTStreamNvidia(size: 10, weight: .bold))
                .tracking(1.1)
                .foregroundStyle(NativeNVSTMediaStreamTheme.textTertiary)
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.055))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(NativeNVSTMediaStreamTheme.divider, lineWidth: 1)
        }
    }
}

struct NativeNVSTStreamHUDMetricCard: View {
    let title: String
    let value: String
    let positive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Circle().fill(positive ? Color.pixelNowGreen : NativeNVSTMediaStreamTheme.warning).frame(width: 6, height: 6)
                Text(title.uppercased())
                    .font(.nativeNVSTStreamNvidia(size: 9, weight: .bold))
                    .tracking(0.7)
                    .foregroundStyle(.white.opacity(0.46))
            }
            Text(value)
                .font(.nativeNVSTStreamNvidia(size: 12, weight: .bold))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
        .background(Color.white.opacity(0.055))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(NativeNVSTMediaStreamTheme.divider, lineWidth: 1)
        }
    }
}

struct NativeNVSTStreamSessionSidebarLimit: Equatable {
    let startedAt: Date
    let durationSeconds: Int

    init?(session: StreamSessionDescriptor, fallbackStartedAt: Date = Date()) {
        guard let duration = Int(session.metadata["sessionLimitSeconds"] ?? ""), duration > 0 else { return nil }
        let startedAtEpoch = Double(session.metadata["startedAtEpochSeconds"] ?? "")
        let startedAt = startedAtEpoch.map { Date(timeIntervalSince1970: $0) } ?? fallbackStartedAt
        self.startedAt = startedAt
        self.durationSeconds = duration
    }

    init?(update: StreamSessionLimitUpdate, receivedAt: Date = Date()) {
        let durationSeconds = max(3600, update.remainingSeconds)
        self.startedAt = receivedAt.addingTimeInterval(-Double(durationSeconds - update.remainingSeconds))
        self.durationSeconds = durationSeconds
    }

    func remainingSeconds(at now: Date) -> Int {
        max(0, durationSeconds - Int(now.timeIntervalSince(startedAt)))
    }
}

private final class NativeNVSTInputFailureReporter: @unchecked Sendable {
    private let lock = NSLock()
    private let minimumReportInterval: TimeInterval = 1
    private var lastReportedAt = Date.distantPast
    private var suppressedFailureCount = 0

    func report(operation: String, error: Error, applicationID: String) {
        let now = Date()
        let suppressedCount: Int? = lock.withLock {
            guard now.timeIntervalSince(lastReportedAt) >= minimumReportInterval else {
                suppressedFailureCount += 1
                return nil
            }
            let count = suppressedFailureCount
            suppressedFailureCount = 0
            lastReportedAt = now
            return count
        }
        guard let suppressedCount else { return }

        let nativeError = error as? NativeNVSTError
        let isExpectedDuringTeardown = nativeError == .notRunning
        var attributes = [
            "applicationID": applicationID,
            "operation": operation,
            "failurePhase": nativeError?.failurePhase ?? "unknown",
            "error": Self.sanitizedMessage(for: error),
            "expectedDuringTeardown": String(isExpectedDuringTeardown),
        ]
        if suppressedCount > 0 {
            attributes["suppressedCount"] = String(suppressedCount)
        }
        NativeNVSTMediaTelemetry.capture(
            "nvst.input.send_failed",
            level: isExpectedDuringTeardown ? .debug : .error,
            message: isExpectedDuringTeardown ? "Native NVST input arrived after teardown began." : "Native NVST input send failed.",
            attributes: attributes
        )
    }

    private static func sanitizedMessage(for error: Error) -> String {
        let message: String
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            message = description
        } else {
            message = error.localizedDescription
        }
        let sanitized = message
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sanitized.isEmpty else { return "Unknown native NVST input failure." }
        return String(sanitized.prefix(256))
    }
}

@MainActor
struct NativeNVSTMediaStreamSurface: View {
    private struct FailurePresentation: Identifiable {
        let id = UUID()
        let message: String
        let diagnostics: [String: String]
    }

    let configuration: PreparedLaunchConfiguration
    let sessionProvider: any NativeNVSTSessionProvider
    let preventDisplaySleep: Bool
    let onProgress: NativeNVSTMediaStreamProgressHandler?
    let onEnd: NativeNVSTMediaStreamCompletion
    private let sidebarCapabilities = NativeNVSTStreamSidebarCapabilities.standard
    @StateObject private var inputRouter = ControllerInputRouter()

    @State private var path: NativeNVSTStreamingPath?
    @State private var startTask: Task<Void, Never>?
    @State private var endEventTask: Task<Void, Never>?
    @State private var nativeView: NativeNVSTStreamView?
    @State private var loadingStepIndex = -1
    @State private var isConnected = false
    @State private var isEnding = false
    @State private var didEnd = false
    @State private var unifiedHUDVisible = false
    @State private var streamControlsVisible = false
    @State private var nativeStatsVisible = false
    @State private var latestNativeStats: NativeNVSTPerformanceSnapshot?
    @State private var nativeStatsTask: Task<Void, Never>?
    @State private var nativeStreamHealth = NativeNVSTStreamHealthMonitor()
    @State private var inputDispatcher: NativeNVSTInputDispatcher?
    @State private var microphoneAvailable = false
    @State private var microphoneEnabled = false
    @State private var microphoneDesiredEnabled = false
    @State private var microphoneStatus = NativeNVSTMicrophoneStatus.disabled
    @State private var microphoneMode = "disabled"
    @State private var microphonePendingStates: [Bool] = []
    @State private var microphoneUpdateTask: Task<Void, Never>?
    @State private var antiAFKMouseMovementEnabled = false
    @State private var antiAFKMouseMovementTask: Task<Void, Never>?
    @State private var lastAcceptedStreamInputAt = Date()
    @State private var transientStreamMessage = ""
    @State private var transientStreamMessageTask: Task<Void, Never>?
    @State private var pendingApplicationQuitCompletion: NativeNVSTMediaStreamQuitDecisionHandler?
    @State private var streamingPerformanceActivity: (any NSObjectProtocol)?
    @State private var sessionLimit: NativeNVSTStreamSessionSidebarLimit?
    @State private var remoteCoOpPreferences = RemoteCoOpPreferencesStore.load()
    @State private var networkGovernor: NativeNVSTNetworkGovernor?
    @State private var networkPathTask: Task<Void, Never>?
    @State private var networkPathAvailable = true
    @State private var nativeFailure: FailurePresentation?
    @State private var nativeAudioDeviceMonitor: NativeNVSTAudioDeviceMonitor?
    @State private var streamingFullScreenWindow: NSWindow?
    @State private var recordingStatus = WebRTCStreamRecordingStatus.idle
    @State private var recordingNotificationTask: Task<Void, Never>?
    @State private var desktopMacroEngine: DesktopMacroEngine?
    @State private var desktopMacroState: DesktopMacroState = .idle
    private let nativeInputFailureReporter = NativeNVSTInputFailureReporter()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea(.container, edges: [.horizontal, .bottom])
            NativeNVSTStreamHostView { view in
                nativeView = view
                configureNativeView(view)
                startIfNeeded()
            }
            .ignoresSafeArea(.container, edges: [.horizontal, .bottom])
            nativeWindowOverlay
            if let nativeFailure {
                nativeFailureOverlay(nativeFailure)
            } else if !isConnected {
                NativeNVSTStreamLaunchLoadingScreen(
                    title: configuration.title,
                    stage: NativeNVSTStreamLaunchLoadingStage.label(stepIndex: loadingStepIndex),
                    artworkURL: configuration.nativeNVSTLoadingArtworkURL
                ) { EmptyView() }
            }
        }
        .onAppear {
            NativeNVSTMediaTelemetry.configure(sink: NativeNVSTTelemetrySink())
            startIfNeeded()
        }
        .onDisappear { stopStream() }
    }

    private func startIfNeeded() {
        guard startTask == nil, path == nil, !didEnd else { return }
        guard let nativeView, nativeView.window != nil else {
            loadingStepIndex = StreamLaunchStep.checkNetworkRoute.rawValue
            return
        }
        enterStreamFullScreenIfNeeded(for: nativeView)
        nativeView.remoteInputEnabled = false
        nativeView.setNativeNVSTVideoVisible(false)
        let profile = StreamPreferences.launchProfile(forGame: configuration.applicationID, capabilities: StreamPreferences.loadDeviceCapabilities())
        microphoneMode = profile.microphoneMode.lowercased()
        let microphoneConfiguration = NativeNVSTMicrophoneConfiguration.settings(volume: profile.microphoneVolume, mode: microphoneMode)
        microphoneStatus = .disabled
        microphoneAvailable = false
        microphoneEnabled = false
        microphoneDesiredEnabled = false
        microphonePendingStates.removeAll()
        let initialMicrophoneEnabled = microphoneConfiguration.initiallyEnabled && profile.streamMicrophoneEnabled
        antiAFKMouseMovementEnabled = profile.antiAFKMouseMovementEnabled
        networkGovernor = NativeNVSTNetworkGovernor(maximumBitrateKbps: UInt32(max(1, profile.maxBitrateMbps) * 1_000), l4sEnabled: profile.enableL4S)
        nativeStreamHealth = NativeNVSTStreamHealthMonitor()
        lastAcceptedStreamInputAt = Date()
        beginStreamingPerformanceMode()
        startNetworkPathMonitoring()
        let audioDeviceMonitor = NativeNVSTAudioDeviceMonitor {
            NativeNVSTMediaTelemetry.capture(
                "nvst.audio.device_changed",
                level: .info,
                message: "Default audio device changed while native NVST was active.",
                attributes: ["applicationID": configuration.applicationID]
            )
        }
        audioDeviceMonitor.start()
        nativeAudioDeviceMonitor = audioDeviceMonitor
        let coreSink = nativeView.attachNVSTCoreRenderer(targetFps: Int32(max(30, profile.fps))).frameSink
        let diagnosticLog = NvstDiagnosticLog()
        let transport = NVSTCoreTransport(
            pixelBufferSink: { pixelBuffer, presentationTime, isKeyframe in
                coreSink.render(pixelBuffer: pixelBuffer, presentationTime: presentationTime, isKeyframe: isKeyframe)
            },
            configuredFps: profile.fps,
            configuredMaxBitrateKbps: profile.maxBitrateMbps * 1_000,
            logger: { message in
                NativeNVSTMediaTelemetry.capture("nvst.core", level: .info, message: message)
                diagnosticLog.append(message)
            }
        )
        Task {
            await transport.setRemoteCursorVisibilityHandler { [weak nativeView] isVisible in
                nativeView?.applyServerCursorVisibility(isVisible)
            }
            await transport.setHapticEventHandler { [weak nativeView] events in
                for event in events {
                    nativeView?.playHaptic(NativeNVSTHapticCommand(
                        playerIndex: Int(event.gamepadIndex),
                        lowFrequency: event.leftMotor,
                        highFrequency: event.rightMotor,
                        durationMilliseconds: event.effectiveDurationMilliseconds
                    ))
                }
            }
            await transport.setRecordingStatusHandler { status in
                handleRecordingStatusChanged(status)
            }
        }
        let path = NativeNVSTStreamingPath(sessionProvider: sessionProvider, transport: transport, automaticRecovery: .singleAttempt)
        let inputDispatcher = NativeNVSTInputDispatcher { input in
            switch input {
            case .event(let event):
                path.sendNow(event)
            case .absoluteMove(let event):
                path.sendAbsoluteMouseMoveNow(event)
            }
        }
        self.path = path
        self.inputDispatcher = inputDispatcher
        endEventTask = Task {
            let events = await path.endEvents()
            for await report in events {
                guard !Task.isCancelled else { return }
                await MainActor.run { finishOnce(report: report) }
                return
            }
        }
        configureInput(for: nativeView)
        NativeNVSTMediaStreamLifecycle.activate(
            configuration.id,
            quitRequestHandler: { completion in
                showStreamControls(completion: completion)
                return true
            },
            commandHandler: handleNativeCommand,
            terminationDrainHandler: { [path] in
                _ = try? await path.stopForApplicationTermination(reason: .userRequested, message: "Application terminating.")
            }
        )
        startTask = Task {
            do {
                try await path.setMicrophoneConfiguration(microphoneConfiguration)
                let session = try await path.start(configuration: configuration) { progress in
                    await MainActor.run {
                        loadingStepIndex = progress.currentStepIndex
                        onProgress?(progress)
                    }
                }
                let resolvedMicrophoneStatus = await path.microphoneStatus()
                await MainActor.run {
                    microphoneStatus = resolvedMicrophoneStatus
                    microphoneAvailable = resolvedMicrophoneStatus.isAvailable
                    microphoneEnabled = resolvedMicrophoneStatus.isAvailable && initialMicrophoneEnabled
                    microphoneDesiredEnabled = microphoneEnabled
                }
                let shouldPresentStream = await MainActor.run {
                    guard !Task.isCancelled, !didEnd, !isEnding else { return false }
                    isConnected = true
                    sessionLimit = NativeNVSTStreamSessionSidebarLimit(session: session)
                    nativeView.remoteInputEnabled = !unifiedHUDVisible && !streamControlsVisible
                    nativeView.setNativeNVSTVideoVisible(true)
                    nativeView.restoreInputFocus()
                    Task { try? await path.updateGamepadTopology(nativeView.gamepadTopology) }
                    loadingStepIndex = StreamLaunchStep.connected.rawValue
                    startNativeStatsPolling(path: path)
                    refreshAntiAFKMouseMovementTask()
                    if isDesktopLaunch {
                        startDesktopMacroExecution()
                    }
                    onProgress?(StreamProgress(configuration: configuration.progressConfiguration, step: .connected, message: "Connected over native NVST.", isReady: true))
                    NativeNVSTMediaTelemetry.capture("nvst.ui.connected", level: .info, message: "Native NVST stream connected.", attributes: ["sessionId": session.id])
                    return true
                }
                if !shouldPresentStream {
                    _ = try? await path.stop(reason: .userRequested, message: "Native NVST stream view closed during startup.")
                    await MainActor.run {
                        NativeNVSTMediaStreamLifecycle.deactivate(configuration.id)
                    }
                }
            } catch {
                let diagnostics = await path.diagnosticMetadata()
                await MainActor.run {
                    startTask = nil
                    handleStartFailure(error, diagnostics: diagnostics)
                }
            }
        }
    }

    private func handleStartFailure(_ error: Error, diagnostics: [String: String]) {
        guard !(error is CancellationError), !Task.isCancelled else {
            loadingStepIndex = -1
            endStreamingPerformanceMode()
            NativeNVSTMediaStreamLifecycle.deactivate(configuration.id)
            return
        }
        let message = Self.message(for: error)
        isConnected = false
        nativeView?.remoteInputEnabled = false
        nativeView?.stopHaptics()
        nativeView?.setPointerLocked(false)
        nativeView?.setNativeNVSTVideoVisible(false)
        inputDispatcher?.cancel()
        inputDispatcher = nil
        endStreamingPerformanceMode()
        var metadata = ["applicationID": configuration.applicationID, "transport": "nvst"]
        metadata.merge(diagnostics) { current, _ in current }
        if let sessionError = error as? StreamSessionError, case .activeSessionConflict(let conflict) = sessionError {
            metadata.merge(conflict.reportMetadata) { current, _ in current }
        }
        metadata["failurePhase"] = (error as? NativeNVSTError)?.failurePhase ?? "unknown"
        metadata["retryNativeAvailable"] = "true"
        metadata["switchToWebRTCAvailable"] = "true"
        nativeFailure = FailurePresentation(message: message, diagnostics: metadata)
        path = nil
        endEventTask?.cancel()
        endEventTask = nil
        NativeNVSTMediaStreamLifecycle.activate(
            configuration.id,
            quitRequestHandler: { completion in
                completion(true)
                return true
            }
        )
    }

    @ViewBuilder
    private func nativeFailureOverlay(_ failure: FailurePresentation) -> some View {
        ZStack {
            Color.black.opacity(0.88).ignoresSafeArea(.container, edges: [.horizontal, .bottom])
            VStack(alignment: .leading, spacing: 18) {
                Text("NATIVE NVST UNAVAILABLE")
                    .font(.nativeNVSTStreamNvidia(size: 16, weight: .bold))
                    .tracking(1.4)
                    .foregroundStyle(Color.pixelNowGreen)
                Text(failure.message)
                    .font(.nativeNVSTStreamNvidia(size: 13, weight: .medium))
                    .foregroundStyle(NativeNVSTMediaStreamTheme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Phase: \(failure.diagnostics["failurePhase"] ?? "unknown")")
                    .font(.nativeNVSTStreamNvidia(size: 11, weight: .medium))
                    .foregroundStyle(NativeNVSTMediaStreamTheme.textSecondary)
                HStack(spacing: 10) {
                    Button("Retry Native", action: retryNativeFailure)
                    Button("Switch to WebRTC", action: switchToWebRTCFromFailure)
                    Button("Copy Diagnostics", action: { copyNativeFailureDiagnostics(failure) })
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
            .padding(28)
            .frame(maxWidth: 620)
            .background(NativeNVSTMediaStreamTheme.panel.opacity(0.94))
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Color.pixelNowGreen.opacity(0.35), lineWidth: 1))
            .shadow(color: .black.opacity(0.6), radius: 24, y: 12)
        }
    }

    private func retryNativeFailure() {
        nativeFailure = nil
        didEnd = false
        isEnding = false
        isConnected = false
        nativeView?.setNativeNVSTVideoVisible(false)
        nativeView?.prepareNativeNVSTRendererForShutdown()
        startIfNeeded()
    }

    private func switchToWebRTCFromFailure() {
        StreamPreferences.saveNVSTTransportEnabled(false)
        nativeFailure = nil
        didEnd = true
        NativeNVSTMediaStreamLifecycle.deactivate(configuration.id)
        onEnd(false, "Native NVST failed; WebRTC transport selected.", nil)
    }

    private func copyNativeFailureDiagnostics(_ failure: FailurePresentation) {
        let lines: [String] = failure.diagnostics.keys.sorted().compactMap { key -> String? in
            guard let value = failure.diagnostics[key] else { return nil }
            return "\(key)=\(value)"
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
        showNativeTransientStreamMessage("Diagnostics copied")
    }

    private func stopStream() {
        let quitCompletion = pendingApplicationQuitCompletion
        pendingApplicationQuitCompletion = nil
        let pendingStartTask = startTask
        pendingStartTask?.cancel()
        startTask = nil
        endEventTask?.cancel()
        endEventTask = nil
        nativeStatsTask?.cancel()
        nativeStatsTask = nil
        latestNativeStats = nil
        nativeStreamHealth = NativeNVSTStreamHealthMonitor()
        sessionLimit = nil
        networkGovernor = nil
        networkPathTask?.cancel()
        networkPathTask = nil
        networkPathAvailable = true
        nativeAudioDeviceMonitor?.stop()
        nativeAudioDeviceMonitor = nil
        cancelNativeShortcutTasks()
        endStreamingPerformanceMode()
        nativeView?.remoteInputEnabled = false
        let inputDispatcher = self.inputDispatcher
        self.inputDispatcher = nil
        let shouldTerminateApplication = quitCompletion != nil
        isConnected = false
        unifiedHUDVisible = false
        streamControlsVisible = false
        nativeStatsVisible = false
        microphoneAvailable = false
        microphoneEnabled = false
        microphoneDesiredEnabled = false
        microphoneStatus = .disabled
        microphoneMode = "disabled"
        microphonePendingStates.removeAll()
        antiAFKMouseMovementEnabled = false
        recordingStatus = .idle
        nativeView?.stopHaptics()
        nativeView?.setNativeNVSTVideoVisible(false)
        nativeView?.detachNVSTCoreRenderer()
        nativeView?.prepareNativeNVSTRendererForShutdown()
        guard !didEnd else {
            inputDispatcher?.cancel()
            NativeNVSTMediaStreamLifecycle.deactivate(configuration.id)
            quitCompletion?(shouldTerminateApplication)
            return
        }
        didEnd = true
        nativeView?.onInputEvent = nil
        nativeView?.onAbsoluteMouseMove = nil
        nativeView?.onGamepadTopologyChanged = nil
        nativeView?.onPointerLockChanged = nil
        nativeView?.onCommand = nil
        nativeView?.shouldHandleCommand = nil
        let pendingPath = path
        Task {
            await pendingStartTask?.value
            await pendingPath?.cancelStart()
            inputDispatcher?.cancel()
            if let pendingPath {
                try? await pendingPath.setMicrophoneEnabled(false)
                _ = try? await pendingPath.stop(reason: .userRequested, message: "Native NVST stream view closed.")
            }
            await MainActor.run {
                NativeNVSTMediaStreamLifecycle.deactivate(configuration.id)
                quitCompletion?(shouldTerminateApplication)
            }
        }
    }

    private func finish(reason: StreamEndReason,
                        message: String,
                        forApplicationTermination: Bool = false) async -> Bool {
        guard !isEnding else { return false }
        let inputDispatcher = await MainActor.run {
            nativeView?.remoteInputEnabled = false
            nativeView?.setNativeNVSTVideoVisible(false)
            let dispatcher = self.inputDispatcher
            self.inputDispatcher = nil
            isEnding = true
            return dispatcher
        }
        if reason == .paused || reason == .userRequested {
            inputDispatcher?.cancel()
        } else {
            await inputDispatcher?.finish()
        }
        guard let path else {
            await MainActor.run {
                isEnding = false
                NativeNVSTMediaStreamLifecycle.deactivate(configuration.id)
                showStreamControls()
            }
            return false
        }
        do {
            do {
                try await path.setMicrophoneEnabled(false)
            } catch {
                NativeNVSTMediaTelemetry.capture(
                    "nvst.microphone.shutdown.failed",
                    level: .warning,
                    message: Self.message(for: error),
                    attributes: ["applicationID": configuration.applicationID, "reason": reason.rawValue]
                )
            }
            let report: StreamReport
            if forApplicationTermination {
                report = try await path.stopForApplicationTermination(reason: reason, message: message)
            } else {
                report = try await path.stop(reason: reason, message: message)
            }
            await MainActor.run { finishOnce(report: report) }
            return true
        } catch {
            let failureMessage = Self.message(for: error)
            if reason == .paused {
                await MainActor.run {
                    isEnding = false
                    self.inputDispatcher = NativeNVSTInputDispatcher { input in
                        switch input {
                        case .event(let event):
                            path.sendNow(event)
                        case .absoluteMove(let event):
                            path.sendAbsoluteMouseMoveNow(event)
                        }
                    }
                    streamControlsVisible = true
                    NativeNVSTMediaTelemetry.capture("nvst.ui.pause.failed", level: .error, message: failureMessage, attributes: ["applicationID": configuration.applicationID])
                }
                return false
            }
            let report = StreamReport(title: configuration.title, success: false, reason: .failed, message: failureMessage, durationSeconds: 0, metadata: ["applicationID": configuration.applicationID, "transport": "nvst"])
            await MainActor.run { finishOnce(report: report) }
            return false
        }
    }

    private func finishOnce(report: StreamReport) {
        guard !didEnd else { return }
        nativeView?.remoteInputEnabled = false
        inputDispatcher?.cancel()
        inputDispatcher = nil
        didEnd = true
        isConnected = false
        unifiedHUDVisible = false
        streamControlsVisible = false
        nativeStatsVisible = false
        microphoneAvailable = false
        microphoneEnabled = false
        microphoneDesiredEnabled = false
        microphoneStatus = .disabled
        microphoneMode = "disabled"
        microphonePendingStates.removeAll()
        antiAFKMouseMovementEnabled = false
        nativeStatsTask?.cancel()
        nativeStatsTask = nil
        latestNativeStats = nil
        nativeStreamHealth = NativeNVSTStreamHealthMonitor()
        sessionLimit = nil
        networkGovernor = nil
        networkPathTask?.cancel()
        networkPathTask = nil
        networkPathAvailable = true
        cancelNativeShortcutTasks()
        pendingApplicationQuitCompletion?(report.reason != .paused)
        pendingApplicationQuitCompletion = nil
        nativeView?.setPointerLocked(false)
        nativeView?.setNativeNVSTVideoVisible(false)
        exitStreamFullScreenIfNeeded()
        endEventTask?.cancel()
        endEventTask = nil
        nativeView?.onInputEvent = nil
        nativeView?.onAbsoluteMouseMove = nil
        nativeView?.onPointerLockChanged = nil
        nativeView?.onCommand = nil
        nativeView?.shouldHandleCommand = nil
        NativeNVSTMediaStreamLifecycle.deactivate(configuration.id)
        onEnd(report.success, report.message, report)
    }

    private func enterStreamFullScreenIfNeeded(for view: NativeNVSTStreamView) {
        guard streamingFullScreenWindow == nil, let window = view.window, !window.styleMask.contains(.fullScreen) else { return }
        streamingFullScreenWindow = window
        window.toggleFullScreen(nil)
    }

    private func exitStreamFullScreenIfNeeded() {
        guard let window = streamingFullScreenWindow else { return }
        streamingFullScreenWindow = nil
        guard window.styleMask.contains(.fullScreen) else { return }
        window.toggleFullScreen(nil)
    }

    private func configureNativeView(_ view: NativeNVSTStreamView) {
        guard !didEnd, !isEnding else {
            view.remoteInputEnabled = false
            view.setNativeNVSTVideoVisible(false)
            return
        }
        let profile = StreamPreferences.launchProfile(forGame: configuration.applicationID, capabilities: StreamPreferences.loadDeviceCapabilities())
        view.directMouseInputEnabled = profile.directMouseInput
        view.locksPointerWhenRelativeModeSelected = true
        view.hidesCursorWhilePointerLocked = true
        if path == nil { view.mouseInputMode = .absolute }
        view.setStreamContentSize(width: profile.resolution.width, height: profile.resolution.height)
        view.remoteInputEnabled = isConnected && !unifiedHUDVisible && !streamControlsVisible
        let pushToTalkEnabled = profile.microphoneMode.caseInsensitiveCompare("push-to-talk") == .orderedSame
        view.configurePushToTalk(
            keyCode: pushToTalkEnabled ? profile.microphonePushToTalkKeyCode : nil,
            modifierMask: profile.microphonePushToTalkModifierMask
        ) { enabled in
            requestNativeMicrophoneEnabled(enabled, source: "push-to-talk")
        }
        configureInput(for: view)
    }

    private func configureInput(for view: NativeNVSTStreamView) {
        view.onInputEvent = { [weak view] event in
            guard let view, isConnected, !unifiedHUDVisible, !streamControlsVisible, !isEnding, !didEnd else { return }
            if view.remoteInputEnabled && !NativeNVSTInputDispatcher.isNeutralizing(event) {
                guard NSApplication.shared.isActive, view.streamWindowHasInputFocus else {
                    NativeNVSTMediaTelemetry.capture(
                        "nvst.input.focus_lost",
                        level: .debug,
                        message: "Native NVST input was withheld because the stream window was not focused.",
                        attributes: ["applicationID": configuration.applicationID]
                    )
                    return
                }
            }
            lastAcceptedStreamInputAt = Date()
            if case .mouse = event {
                if view.mouseInputMode == .relative, !view.isPointerLocked { return }
                inputDispatcher?.enqueue(event)
                return
            }
            inputDispatcher?.enqueue(event)
        }
        view.shouldHandleCommand = { _ in
            isConnected
        }
        view.onCommand = { command in
            handleNativeCommand(command)
        }
        view.onAbsoluteMouseMove = { [weak view] event in
            guard let view, isConnected, !unifiedHUDVisible, !streamControlsVisible, !isEnding, !didEnd,
                  view.remoteInputEnabled, view.mouseInputMode == .absolute else { return }
            guard view.isEmittingNeutralizingAbsolutePosition ||
                    (NSApplication.shared.isActive && view.streamWindowHasInputFocus) else { return }
            lastAcceptedStreamInputAt = Date()
            inputDispatcher?.enqueueAbsoluteMove(event)
        }
        view.onGamepadTopologyChanged = { topology in
            guard let path, isConnected, !isEnding, !didEnd else { return }
            Task { try? await path.updateGamepadTopology(topology) }
        }
    }

    private func handleNativeCommand(_ command: NativeNVSTMediaStreamCommand) {
        switch command {
        case .toggleStatsHUD:
            toggleNativeStatsHUD()
        case .toggleUnifiedHUD:
            guard !streamControlsVisible else { return }
            setUnifiedHUDVisible(!unifiedHUDVisible)
        case .toggleMicrophone:
            let profile = StreamPreferences.launchProfile(forGame: configuration.applicationID, capabilities: StreamPreferences.loadDeviceCapabilities())
            guard profile.microphoneShortcutEnabled else { return }
            toggleNativeMicrophone()
        case .toggleRecording:
            toggleRecording()
        case .toggleAntiAFK:
            toggleNativeAntiAFKMouseMovement()
        case .showQuitMenu:
            if !streamControlsVisible { showStreamControls() }
        }
    }

    private func toggleNativeMicrophone() {
        guard isConnected, !isEnding, !didEnd else { return }
        guard microphoneAvailable else {
            microphoneEnabled = false
            microphoneDesiredEnabled = false
            showNativeTransientStreamMessage("Microphone is disabled in Settings.")
            return
        }
        guard microphoneMode != "push-to-talk" else {
            showNativeTransientStreamMessage("Hold the configured Push-to-Talk key to speak.")
            return
        }
        requestNativeMicrophoneEnabled(!microphoneDesiredEnabled, source: "toggle")
    }

    private func requestNativeMicrophoneEnabled(_ enabled: Bool, source: String) {
        guard microphoneAvailable, isConnected, !isEnding, !didEnd, let path else { return }
        microphoneDesiredEnabled = enabled
        let lastScheduledState = microphonePendingStates.last ?? microphoneEnabled
        if lastScheduledState != enabled { microphonePendingStates.append(enabled) }
        guard microphoneUpdateTask == nil else { return }
        microphoneUpdateTask = Task { @MainActor in
            defer { microphoneUpdateTask = nil }
            while !Task.isCancelled, !didEnd, !microphonePendingStates.isEmpty {
                let target = microphonePendingStates.removeFirst()
                do {
                    try await path.setMicrophoneEnabled(target)
                    guard !Task.isCancelled, !didEnd else { return }
                    microphoneEnabled = target
                    if source == "toggle" {
                        StreamPreferences.saveStreamMicrophoneEnabled(target)
                    }
                    let enabledMessage = microphoneMode == "voice-activity" ? "Voice Activity On" : "Microphone On"
                    showNativeTransientStreamMessage(target ? enabledMessage : "Microphone Muted")
                    NativeNVSTMediaTelemetry.capture("nvst.ui.microphone.update", level: .info, message: target ? "Native NVST microphone enabled." : "Native NVST microphone muted.", attributes: ["applicationID": configuration.applicationID, "enabled": String(target), "source": source])
                } catch {
                    guard !Task.isCancelled, !didEnd else { return }
                    microphoneDesiredEnabled = microphoneEnabled
                    microphonePendingStates.removeAll()
                    let message = Self.message(for: error)
                    showNativeTransientStreamMessage(message)
                    NativeNVSTMediaTelemetry.capture("nvst.ui.microphone.failed", level: .error, message: message, attributes: ["applicationID": configuration.applicationID, "source": source])
                }
            }
        }
    }

    private func toggleNativeAntiAFKMouseMovement() {
        guard isConnected, !isEnding, !didEnd else { return }
        antiAFKMouseMovementEnabled.toggle()
        StreamPreferences.saveAntiAFKMouseMovementEnabled(antiAFKMouseMovementEnabled)
        refreshAntiAFKMouseMovementTask()
        showNativeTransientStreamMessage(antiAFKMouseMovementEnabled ? "Anti-AFK On" : "Anti-AFK Off")
        NativeNVSTMediaTelemetry.capture("nvst.ui.anti_afk.toggle", level: .info, message: antiAFKMouseMovementEnabled ? "Native NVST Anti-AFK mouse movement enabled." : "Native NVST Anti-AFK mouse movement disabled.", attributes: ["applicationID": configuration.applicationID, "enabled": String(antiAFKMouseMovementEnabled)])
    }

    private func refreshAntiAFKMouseMovementTask() {
        guard isConnected, antiAFKMouseMovementEnabled else {
            antiAFKMouseMovementTask?.cancel()
            antiAFKMouseMovementTask = nil
            return
        }
        guard antiAFKMouseMovementTask == nil else { return }
        antiAFKMouseMovementTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: NativeNVSTAntiAFKInputPolicy.pollInterval)
                guard !Task.isCancelled else { return }
                sendNativeAntiAFKMouseMovement()
            }
        }
    }

    private func sendNativeAntiAFKMouseMovement() {
        guard isConnected, antiAFKMouseMovementEnabled, !isEnding, !didEnd, !unifiedHUDVisible, !streamControlsVisible, inputDispatcher != nil else { return }
        guard Date().timeIntervalSince(lastAcceptedStreamInputAt) >= NativeNVSTAntiAFKInputPolicy.idleThresholdSeconds else { return }
        let delta = NativeNVSTAntiAFKInputPolicy.randomMouseDelta()
        inputDispatcher?.enqueue(NativeNVSTAntiAFKInputPolicy.mouseMove(deltaX: delta.x, deltaY: delta.y))
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            guard isConnected, antiAFKMouseMovementEnabled, !isEnding, !didEnd, !unifiedHUDVisible, !streamControlsVisible else { return }
            guard Date().timeIntervalSince(lastAcceptedStreamInputAt) >= NativeNVSTAntiAFKInputPolicy.idleThresholdSeconds else { return }
            inputDispatcher?.enqueue(NativeNVSTAntiAFKInputPolicy.mouseMove(deltaX: -delta.x, deltaY: -delta.y))
        }
    }

    private func showNativeTransientStreamMessage(_ message: String) {
        transientStreamMessageTask?.cancel()
        transientStreamMessage = message
        transientStreamMessageTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            transientStreamMessage = ""
            transientStreamMessageTask = nil
        }
    }

    private func cancelNativeShortcutTasks() {
        microphoneUpdateTask?.cancel()
        microphoneUpdateTask = nil
        antiAFKMouseMovementTask?.cancel()
        antiAFKMouseMovementTask = nil
        recordingNotificationTask?.cancel()
        recordingNotificationTask = nil
        desktopMacroEngine?.cancel()
        desktopMacroEngine = nil
        transientStreamMessageTask?.cancel()
        transientStreamMessageTask = nil
        transientStreamMessage = ""
    }

    private var isDesktopLaunch: Bool {
        configuration.metadata["isDesktopLaunch"] == "true"
    }

    private func startDesktopMacroExecution() {
        guard isDesktopLaunch, isConnected, let dispatcher = inputDispatcher else { return }
        desktopMacroEngine?.cancel()
        let timings = DesktopMacroTimings(
            initialDelay: StreamPreferences.loadDesktopMacroInitialDelay(),
            keystrokeDelay: StreamPreferences.loadDesktopMacroKeystrokeDelay(),
            navigationDelay: StreamPreferences.loadDesktopMacroNavigationDelay(),
            downloadDelay: StreamPreferences.loadDesktopMacroDownloadDelay()
        )
        let engine = DesktopMacroEngine { event in
            dispatcher.enqueue(event)
        }
        desktopMacroEngine = engine
        engine.execute(timings: timings) { state in
            desktopMacroState = state
            showNativeTransientStreamMessage(state.displayMessage)
        }
    }

    private var recordingIsBusy: Bool {
        if case .finishing = recordingStatus { return true }
        return false
    }

    private var recordingCanStop: Bool {
        if case .starting = recordingStatus { return true }
        return recordingStatus.isRecording
    }

    private var recordingStatusText: String {
        switch recordingStatus {
        case .idle: return "Idle"
        case .starting: return "Starting"
        case .recording(_, let elapsedSeconds): return recordingElapsedText(elapsedSeconds)
        case .finishing: return "Saving"
        case .finished: return "Saved"
        case .failed: return "Failed"
        }
    }

    private func recordingElapsedText(_ elapsedSeconds: Double) -> String {
        let seconds = max(0, Int(elapsedSeconds.rounded(.down)))
        return String(format: "%02d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)
    }

    private func toggleRecording() {
        if recordingCanStop {
            Task { await path?.stopRecording() }
            NativeNVSTMediaTelemetry.capture("nvst.ui.recording.stop", level: .info, message: "Stream recording stop requested.", attributes: ["applicationID": configuration.applicationID])
            return
        }
        guard !recordingIsBusy, isConnected, !isEnding, !didEnd, let path else { return }
        let profile = StreamPreferences.launchProfile(forGame: configuration.applicationID, capabilities: StreamPreferences.loadDeviceCapabilities())
        let recordingConfiguration = WebRTCStreamRecordingConfiguration(
            title: configuration.title,
            applicationID: configuration.applicationID,
            width: profile.resolution.width,
            height: profile.resolution.height,
            fps: profile.fps,
            videoBitrateMbps: profile.recordingVideoBitrateMbps,
            audioBitrateKbps: profile.recordingAudioBitrateKbps,
            enhancedVideoEnabled: profile.recordingEnhancedVideoEnabled,
            microphoneDeviceId: profile.microphoneDeviceId,
            microphoneVolume: profile.microphoneVolume,
            microphoneEnabled: profile.microphoneMode != "disabled"
        )
        recordingStatus = .starting
        Task {
            do {
                try await path.startRecording(configuration: recordingConfiguration)
                NativeNVSTMediaTelemetry.capture("nvst.ui.recording.start", level: .info, message: "Stream recording start requested.", attributes: ["applicationID": configuration.applicationID])
            } catch {
                recordingStatus = .failed(error.localizedDescription)
                showNativeTransientStreamMessage("Recording failed: \(error.localizedDescription)")
            }
        }
    }

    private func handleRecordingStatusChanged(_ status: WebRTCStreamRecordingStatus) {
        recordingNotificationTask?.cancel()
        let previousStatus = recordingStatus
        recordingStatus = status
        logRecordingStatusChanged(status, previousStatus: previousStatus)
        if case .finished(let recording) = status {
            showNativeTransientStreamMessage("Recording saved: \(recording.title) (\(String(format: "%.1f", recording.durationSeconds))s)")
        } else if case .failed(let message) = status {
            showNativeTransientStreamMessage("Recording failed: \(message)")
        }
        guard status.isTerminal else { return }
        recordingNotificationTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard recordingStatus == status else { return }
            recordingStatus = .idle
            recordingNotificationTask = nil
        }
    }

    private func logRecordingStatusChanged(_ status: WebRTCStreamRecordingStatus, previousStatus: WebRTCStreamRecordingStatus) {
        switch status {
        case .idle:
            return
        case .starting:
            NativeNVSTMediaTelemetry.capture("nvst.ui.recording.starting", level: .info, message: "Stream recording accepted start request.", attributes: ["applicationID": configuration.applicationID])
        case .recording:
            guard !previousStatus.isRecording else { return }
            NativeNVSTMediaTelemetry.capture("nvst.ui.recording.active", level: .info, message: "Stream recording captured its first video frame.", attributes: ["applicationID": configuration.applicationID])
        case .finishing:
            guard previousStatus != .finishing else { return }
            NativeNVSTMediaTelemetry.capture("nvst.ui.recording.finishing", level: .info, message: "Stream recording is saving.", attributes: ["applicationID": configuration.applicationID])
        case .finished(let recording):
            NativeNVSTMediaTelemetry.capture("nvst.ui.recording.finished", level: .info, message: "Stream recording saved.", attributes: ["applicationID": configuration.applicationID, "file": recording.videoURL.lastPathComponent, "durationSeconds": String(format: "%.2f", recording.durationSeconds), "fileSizeBytes": String(recording.fileSizeBytes)])
        case .failed(let message):
            NativeNVSTMediaTelemetry.capture("nvst.ui.recording.failed", level: .warning, message: message, attributes: ["applicationID": configuration.applicationID])
        }
    }

    private func showStreamControls(completion: NativeNVSTMediaStreamQuitDecisionHandler? = nil) {
        guard isConnected else {
            let pendingStartTask = startTask
            let pendingPath = path
            pendingStartTask?.cancel()
            Task {
                await pendingStartTask?.value
                await pendingPath?.cancelStart()
                await MainActor.run {
                    NativeNVSTMediaStreamLifecycle.deactivate(configuration.id)
                    completion?(true)
                }
            }
            return
        }
        pendingApplicationQuitCompletion?(false)
        pendingApplicationQuitCompletion = completion
        unifiedHUDVisible = false
        nativeView?.remoteInputEnabled = false
        nativeView?.setNativeNVSTVideoVisible(isConnected)
        streamControlsVisible = true
        NativeNVSTMediaTelemetry.capture("nvst.ui.controls.show", level: .info, message: "Native NVST stream controls shown.", attributes: ["applicationID": configuration.applicationID])
    }

    private func dismissStreamControls() {
        guard !isEnding else { return }
        streamControlsVisible = false
        let completion = pendingApplicationQuitCompletion
        pendingApplicationQuitCompletion = nil
        nativeView?.remoteInputEnabled = isConnected && !unifiedHUDVisible
        nativeView?.setNativeNVSTVideoVisible(isConnected)
        nativeView?.restoreInputFocus()
        completion?(false)
        NativeNVSTMediaTelemetry.capture("nvst.ui.controls.dismiss", level: .info, message: "Native NVST stream controls dismissed.", attributes: ["applicationID": configuration.applicationID])
    }

    private func setUnifiedHUDVisible(_ visible: Bool) {
        guard isConnected, !streamControlsVisible else { return }
        if visible {
            nativeView?.remoteInputEnabled = false
            unifiedHUDVisible = true
        } else {
            unifiedHUDVisible = false
            nativeView?.remoteInputEnabled = true
            nativeView?.restoreInputFocus()
        }
        NativeNVSTMediaTelemetry.capture("nvst.ui.hud.toggle", level: .info, message: visible ? "Native NVST HUD shown." : "Native NVST HUD hidden.", attributes: ["applicationID": configuration.applicationID, "visible": String(visible)])
    }

    private func toggleNativeStatsHUD() {
        guard isConnected, !isEnding, !didEnd else { return }
        nativeStatsVisible.toggle()
        NativeNVSTMediaTelemetry.capture("nvst.ui.stats.toggle", level: .info, message: nativeStatsVisible ? "PixelNOW NVST stats shown." : "PixelNOW NVST stats hidden.", attributes: ["applicationID": configuration.applicationID, "visible": String(nativeStatsVisible)])
    }

    private func startNativeStatsPolling(path: NativeNVSTStreamingPath) {
        nativeStatsTask?.cancel()
        nativeStatsTask = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            while !Task.isCancelled {
                let snapshot = await path.performanceSnapshot()
                if snapshot == nil {
                    nativeStreamHealth = NativeNVSTStreamHealthMonitor()
                }
                if let snapshot, snapshot.available, isConnected, !isEnding, !didEnd {
                    latestNativeStats = snapshot
                    recordNativeNetworkTelemetry(snapshot)
                    let adjustments = networkGovernor?.evaluate(snapshot) ?? []
                    for adjustment in adjustments { await applyNativeNetworkAdjustment(adjustment, path: path) }
                }
                if isConnected, !isEnding, !didEnd,
                   let failure = nativeStreamHealth.observe(snapshot: snapshot, rendererReady: nativeView?.nativeNVSTRendererSurfaceReady == true) {
                    NativeNVSTMediaTelemetry.capture("nvst.stream.health.failed", level: .error, message: failure.message, attributes: ["applicationID": configuration.applicationID])
                    _ = await finish(reason: .failed, message: failure.message)
                    return
                }
                do {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                } catch {
                    return
                }
            }
        }
    }

    private func recordNativeNetworkTelemetry(_ snapshot: NativeNVSTPerformanceSnapshot) {
        let attributes = ["transport": "nvst", "applicationID": configuration.applicationID]
        if let droppedInputCount = inputDispatcher?.droppedInputCount, droppedInputCount > 0 {
            NativeNVSTMediaTelemetry.record("nvst.input.dropped", kind: .counter, value: Double(droppedInputCount), unit: "event", attributes: attributes)
        }
        if snapshot.latencyMilliseconds >= 0 { NativeNVSTMediaTelemetry.record("nvst.network.latency_ms", kind: .gauge, value: snapshot.latencyMilliseconds, unit: "millisecond", attributes: attributes) }
        if snapshot.jitterMilliseconds >= 0 { NativeNVSTMediaTelemetry.record("nvst.network.jitter_ms", kind: .gauge, value: snapshot.jitterMilliseconds, unit: "millisecond", attributes: attributes) }
        if snapshot.bitrateMegabitsPerSecond >= 0 { NativeNVSTMediaTelemetry.record("nvst.network.bitrate_mbps", kind: .gauge, value: snapshot.bitrateMegabitsPerSecond, unit: "megabit/second", attributes: attributes) }
        if snapshot.bandwidthUtilizationPercent >= 0 { NativeNVSTMediaTelemetry.record("nvst.network.bandwidth_utilization_percent", kind: .gauge, value: snapshot.bandwidthUtilizationPercent, unit: "percent", attributes: attributes) }
        NativeNVSTMediaTelemetry.record("nvst.network.packet_loss", kind: .gauge, value: Double(snapshot.packetLoss), unit: "packet", attributes: attributes)
        NativeNVSTMediaTelemetry.record("nvst.network.frame_loss", kind: .gauge, value: Double(snapshot.frameLoss), unit: "frame", attributes: attributes)
    }

    private func startNetworkPathMonitoring() {
        networkPathTask?.cancel()
        let monitor = NativeNVSTNetworkPathMonitor()
        networkPathTask = Task { @MainActor in
            for await networkPath in monitor.updates() {
                guard !Task.isCancelled, !didEnd else { return }
                if networkPath.isSatisfied {
                    networkPathAvailable = true
                    if isConnected, !unifiedHUDVisible, !streamControlsVisible { nativeView?.remoteInputEnabled = true }
                    NativeNVSTMediaTelemetry.capture("nvst.network.path.available", level: .info, message: "Native NVST network path is available.", attributes: ["wifi": String(networkPath.usesWiFi), "ethernet": String(networkPath.usesWiredEthernet), "expensive": String(networkPath.isExpensive), "constrained": String(networkPath.isConstrained)])
                } else {
                    networkPathAvailable = false
                    nativeView?.remoteInputEnabled = false
                    showNativeTransientStreamMessage("Network interrupted - waiting to reconnect")
                    NativeNVSTMediaTelemetry.capture("nvst.network.path.unavailable", level: .warning, message: "Native NVST network path is unavailable.")
                }
            }
        }
    }

    private func applyNativeNetworkAdjustment(_ adjustment: NativeNVSTNetworkAdjustment, path: NativeNVSTStreamingPath) async {
        do {
            switch adjustment {
            case .maximumBitrateKbps(let bitrate): try await path.setMaximumBitrateKbps(bitrate)
            case .dynamicStreamingMode(let mode): try await path.setDynamicStreamingMode(mode)
            case .l4sEnabled(let enabled): try await path.setL4SEnabled(enabled)
            }
            NativeNVSTMediaTelemetry.capture("nvst.network.adjustment", level: .info, message: "Applied native NVST network adjustment.", attributes: ["adjustment": String(describing: adjustment)])
        } catch {
            NativeNVSTMediaTelemetry.capture("nvst.network.adjustment.failed", level: .warning, message: Self.message(for: error), attributes: ["adjustment": String(describing: adjustment)])
        }
    }

    private func pauseFromStreamControls() {
        guard !isEnding else { return }
        let completion = pendingApplicationQuitCompletion
        pendingApplicationQuitCompletion = nil
        Task {
            _ = await finish(reason: .paused, message: "Native NVST stream paused.")
            completion?(false)
        }
    }

    private func endFromStreamControls() {
        guard !isEnding else { return }
        let completion = pendingApplicationQuitCompletion
        let shouldTerminateApplication = completion != nil
        pendingApplicationQuitCompletion = nil
        Task {
            let didFinish = await finish(
                reason: .userRequested,
                message: "Native NVST stream ended by user.",
                forApplicationTermination: shouldTerminateApplication
            )
            completion?(didFinish && shouldTerminateApplication)
        }
    }

    @ViewBuilder private var nativeWindowOverlay: some View {
        ZStack {
            if streamControlsVisible {
                nativeStreamControlsOverlay
                    .transition(.opacity)
            } else if !networkPathAvailable {
                nativeNetworkRecoveryOverlay
                    .transition(.opacity)
            } else {
                if unifiedHUDVisible {
                    ZStack(alignment: .leading) {
                        Color.black.opacity(0.001)
                            .ignoresSafeArea(.container, edges: [.horizontal, .bottom])
                            .onTapGesture {}
                        nativeUnifiedHUD
                    }
                    .transition(.move(edge: .leading).combined(with: .opacity))
                }

                VStack(alignment: .trailing, spacing: 10) {
                    if isConnected, inputRouter.isControllerConnected, let level = inputRouter.controllerBatteryLevel {
                        nativeBatteryPill(level: level, state: inputRouter.controllerBatteryState)
                            .transition(.scale(scale: 0.92).combined(with: .opacity))
                    }
                    if nativeStatsVisible {
                        nativeStatsHUDContent
                            .transition(.scale(scale: 0.96).combined(with: .opacity))
                    }
                }
                .padding(.top, 16)
                .padding(.trailing, 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .allowsHitTesting(false)
                .animation(.easeInOut(duration: 0.2), value: nativeStatsVisible)
                .animation(.easeInOut(duration: 0.2), value: inputRouter.isControllerConnected)

                if !transientStreamMessage.isEmpty {
                    VStack {
                        nativeTransientStreamMessageOverlay
                            .padding(.top, 20)
                            .transition(.move(edge: .top).combined(with: .opacity))
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .allowsHitTesting(false)
                    .animation(.spring(response: 0.35, dampingFraction: 0.8), value: transientStreamMessage)
                }
            }
        }
    }

    private func nativeBatteryPill(level: Float, state: GCDeviceBattery.State) -> some View {
        HStack(spacing: 8) {
            ControllerBatteryIndicator(level: level, state: state)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.black.opacity(0.72))
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.16), lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 10, x: 0, y: 4)
    }

    private var nativeNetworkRecoveryOverlay: some View {
        ZStack {
            Color.black.opacity(0.75).ignoresSafeArea(.container, edges: [.horizontal, .bottom])
            VStack(spacing: 16) {
                ProgressView().controlSize(.large).tint(Color.pixelNowGreen)
                Text("CONNECTION INTERRUPTED")
                    .font(.nativeNVSTStreamNvidia(size: 16, weight: .bold))
                    .tracking(1.4)
                    .foregroundStyle(Color.pixelNowGreen)
                Text("Waiting for a usable network path. PixelNOW will resume the same GeForce NOW session automatically.")
                    .font(.nativeNVSTStreamNvidia(size: 12, weight: .medium))
                    .foregroundStyle(NativeNVSTMediaStreamTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
                Button("End Stream", action: endFromStreamControls)
                    .buttonStyle(.plain)
                    .font(.nativeNVSTStreamNvidia(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 8)
                    .background(Color.white.opacity(0.08), in: Capsule())
                    .overlay(Capsule().stroke(Color.white.opacity(0.20), lineWidth: 1))
            }
            .padding(32)
            .background(NativeNVSTMediaStreamTheme.panel.opacity(0.92))
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Color.pixelNowGreen.opacity(0.35), lineWidth: 1))
            .shadow(color: .black.opacity(0.6), radius: 24, y: 12)
        }
    }

    private var nativeTransientStreamMessageOverlay: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.nativeNVSTStreamNvidia(size: 12, weight: .bold))
                .foregroundStyle(Color.pixelNowGreen)
            Text(transientStreamMessage)
                .font(.nativeNVSTStreamNvidia(size: 12, weight: .bold))
                .foregroundStyle(NativeNVSTMediaStreamTheme.textPrimary)
                .lineLimit(1)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.78))
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Color.pixelNowGreen.opacity(0.4), lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 14, y: 6)
        .frame(maxWidth: 440)
    }

    private var nativeStatsHUDContent: some View {
        let profile = StreamPreferences.launchProfile(forGame: configuration.applicationID, capabilities: StreamPreferences.loadDeviceCapabilities())
        let streamFramesPerSecond = latestNativeStats?.streamFramesPerSecond ?? Double(profile.fps)
        let resolution = nonEmptyNativeStat(latestNativeStats?.resolution, fallback: "\(profile.resolution.width)x\(profile.resolution.height)")
        let codec = nonEmptyNativeStat(latestNativeStats?.codec, fallback: profile.codec.value.uppercased())
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle()
                    .fill(Color.pixelNowGreen)
                    .frame(width: 6, height: 6)
                Text("STREAM METRICS")
                    .font(.nativeNVSTStreamNvidia(size: 9, weight: .bold))
                    .tracking(1.0)
                    .foregroundStyle(.white.opacity(0.64))
                Spacer()
            }
            .padding(.horizontal, 4)

            HStack(spacing: 6) {
                nativeStatsCompactBox(value: nativeLiveStatsWholeNumber(latestNativeStats?.gameFramesPerSecond), label: "GAME FPS", color: nativeGameFPSColor(target: streamFramesPerSecond))
                nativeStatsCompactBox(value: nativeStatsWholeNumber(streamFramesPerSecond), label: "STREAM FPS", color: NativeNVSTMediaStreamTheme.textPrimary)
                nativeStatsCompactBox(value: nativeLiveStatsWholeNumber(latestNativeStats?.latencyMilliseconds), label: "MS", color: nativeLatencyColor)
            }
            .frame(height: 50)

            VStack(alignment: .leading, spacing: 5) {
                nativeStatsStandardRow(label: "Frame Loss", value: nativeStatsCount(latestNativeStats?.frameLoss), detail: nativeStatsTotal(latestNativeStats?.totalFrameLoss), color: nativeFrameLossColor)
                nativeStatsStandardRow(label: "Packet Loss", value: nativeStatsCount(latestNativeStats?.packetLoss), detail: nativeStatsTotal(latestNativeStats?.totalPacketLoss), color: nativePacketLossColor)
                nativeStatsStandardRow(label: "Bandwidth", value: nativeStatsMegabits(latestNativeStats?.bitrateMegabitsPerSecond), detail: "Mbps", color: NativeNVSTMediaStreamTheme.textPrimary)
                nativeStatsStandardRow(label: "Resolution", value: resolution, detail: nil, color: NativeNVSTMediaStreamTheme.textPrimary)
                nativeStatsStandardRow(label: "Codec", value: codec, detail: nil, color: NativeNVSTMediaStreamTheme.textPrimary)
                nativeStatsStandardRow(label: "Server", value: nonEmptyNativeStat(latestNativeStats?.serverLocation, fallback: "--"), detail: nil, color: NativeNVSTMediaStreamTheme.textPrimary)
            }
            .padding(8)
            .background(Color.white.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .padding(12)
        .frame(width: 270, alignment: .topLeading)
        .background(Color.black.opacity(0.75))
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.14), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.52), radius: 18, x: 0, y: 8)
    }

    private func nativeStatsCompactBox(value: String, label: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.nativeNVSTStreamNvidia(size: 20, weight: .bold))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity)
            Text(label)
                .font(.nativeNVSTStreamNvidia(size: 8, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(NativeNVSTMediaStreamTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private func nativeStatsStandardRow(label: String, value: String, detail: String?, color: Color) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.nativeNVSTStreamNvidia(size: 10, weight: .medium))
                .foregroundStyle(NativeNVSTMediaStreamTheme.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            HStack(spacing: 4) {
                Text(value)
                    .font(.nativeNVSTStreamNvidia(size: 10, weight: .bold))
                    .foregroundStyle(color)
                    .lineLimit(1)
                if let detail {
                    Text(detail)
                        .font(.nativeNVSTStreamNvidia(size: 9, weight: .medium))
                        .foregroundStyle(NativeNVSTMediaStreamTheme.textTertiary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.white.opacity(0.05), in: Capsule())
        }
    }

    private func nativeGameFPSColor(target: Double) -> Color {
        guard let latestNativeStats, latestNativeStats.available, latestNativeStats.gameFramesPerSecond >= 0 else { return NativeNVSTMediaStreamTheme.textTertiary }
        return latestNativeStats.gameFramesPerSecond >= max(1, target * 0.9) ? NativeNVSTMediaStreamTheme.accent : NativeNVSTMediaStreamTheme.warning
    }

    private var nativeLatencyColor: Color {
        guard let latestNativeStats, latestNativeStats.available, latestNativeStats.latencyMilliseconds >= 0 else { return NativeNVSTMediaStreamTheme.textTertiary }
        if latestNativeStats.latencyMilliseconds >= 120 { return NativeNVSTMediaStreamTheme.danger }
        if latestNativeStats.latencyMilliseconds >= 90 { return NativeNVSTMediaStreamTheme.warning }
        return NativeNVSTMediaStreamTheme.accent
    }

    private var nativeFrameLossColor: Color {
        guard let latestNativeStats, latestNativeStats.available else { return NativeNVSTMediaStreamTheme.textTertiary }
        return latestNativeStats.frameLoss == 0 ? NativeNVSTMediaStreamTheme.accent : NativeNVSTMediaStreamTheme.warning
    }

    private var nativePacketLossColor: Color {
        guard let latestNativeStats, latestNativeStats.available else { return NativeNVSTMediaStreamTheme.textTertiary }
        return latestNativeStats.packetLoss == 0 ? NativeNVSTMediaStreamTheme.accent : NativeNVSTMediaStreamTheme.warning
    }

    private func nativeStatsWholeNumber(_ value: Double?) -> String {
        guard let value, value >= 0 else { return "--" }
        return String(format: "%.0f", value)
    }

    private func nativeLiveStatsWholeNumber(_ value: Double?) -> String {
        guard latestNativeStats?.available == true else { return "--" }
        return nativeStatsWholeNumber(value)
    }

    private func nativeStatsCount(_ value: UInt64?) -> String {
        guard latestNativeStats?.available == true, let value else { return "--" }
        return String(value)
    }

    private func nativeStatsTotal(_ value: UInt64?) -> String {
        guard latestNativeStats?.available == true, let value else { return "(-- Total)" }
        return "(\(value) Total)"
    }

    private func nativeStatsMegabits(_ value: Double?) -> String {
        guard latestNativeStats?.available == true, let value, value >= 0 else { return "--" }
        return String(format: "%.1f", value)
    }

    private func nonEmptyNativeStat(_ value: String?, fallback: String) -> String {
        guard let value, !value.isEmpty else { return fallback }
        return value
    }

    private var nativeMicrophoneStatusText: String {
        switch microphoneStatus {
        case .disabled:
            return "Disabled"
        case .permissionDenied:
            return "Permission Denied"
        case .capturerUnavailable:
            return "Unavailable"
        case .setupFailed:
            return "Setup Failed"
        case .available:
            break
        }
        if microphoneMode == "push-to-talk" { return microphoneEnabled ? "PTT Active" : "PTT Ready" }
        if microphoneMode == "voice-activity", microphoneEnabled { return "Voice Activity" }
        return microphoneEnabled ? "On" : "Muted"
    }

    private func nativeSessionLimitText(at date: Date) -> String {
        guard let sessionLimit else { return "Unlimited" }
        let remainingSeconds = sessionLimit.remainingSeconds(at: date)
        return String(format: "%d:%02d", remainingSeconds / 60, remainingSeconds % 60)
    }

    private func nativeSessionLimitIsHealthy(at date: Date) -> Bool {
        guard let sessionLimit else { return true }
        return sessionLimit.remainingSeconds(at: date) > 300
    }

    private var nativeNetworkHealthText: String {
        guard latestNativeStats?.available == true else { return "Waiting" }
        if (latestNativeStats?.packetLoss ?? 0) > 0 || (latestNativeStats?.jitterMilliseconds ?? 0) >= 35 || (latestNativeStats?.latencyMilliseconds ?? 0) >= 120 { return "Poor" }
        if (latestNativeStats?.jitterMilliseconds ?? 0) >= 20 || (latestNativeStats?.latencyMilliseconds ?? 0) >= 90 { return "Fair" }
        return "Good"
    }

    private var nativeNetworkHealthIsGood: Bool {
        nativeNetworkHealthText == "Good"
    }

    private var nativeLatencyText: String {
        guard latestNativeStats?.available == true, let latency = latestNativeStats?.latencyMilliseconds, latency >= 0 else { return "--" }
        return "\(Int(latency.rounded())) ms"
    }

    private var nativePacketLossText: String {
        guard latestNativeStats?.available == true, let packetLoss = latestNativeStats?.packetLoss else { return "--" }
        return String(packetLoss)
    }

    private var nativeNetworkWarningText: String {
        guard latestNativeStats?.available == true else { return "Waiting for native NVST network telemetry." }
        if (latestNativeStats?.packetLoss ?? 0) > 0 { return "Packet loss is active; image quality or input response may degrade." }
        if (latestNativeStats?.latencyMilliseconds ?? 0) >= 120 { return "Latency is high; input may feel delayed." }
        if (latestNativeStats?.jitterMilliseconds ?? 0) >= 35 { return "Network jitter is unstable; gameplay may stutter." }
        if let bitrate = latestNativeStats?.bitrateMegabitsPerSecond, bitrate >= 0, bitrate < 5 { return "Inbound bitrate is low for cloud gaming quality." }
        return ""
    }

    private var nativeUnifiedHUD: some View {
        NativeNVSTStreamUnifiedSidebar(title: configuration.title.isEmpty ? "GeForce NOW" : configuration.title, closeAction: { setUnifiedHUDVisible(false) }) {
            VStack(alignment: .leading, spacing: 14) {
                nativeHUDStatusPanel
                nativeHUDControlsPanel
                nativeHUDNetworkPanel
                if sidebarCapabilities.visibleFeatures.contains(.remoteCoOp), remoteCoOpPreferences.isAlphaOptedIn {
                    nativeHUDRemoteCoOpPanel
                }
                nativeHUDVideoPanel
            }
        }
    }

    private var nativeHUDStatusPanel: some View {
        HStack(spacing: 8) {
            NativeNVSTStreamHUDMetricCard(title: "Mic", value: nativeMicrophoneStatusText, positive: microphoneEnabled && microphoneAvailable)
            NativeNVSTStreamHUDMetricCard(title: "Rec", value: recordingStatusText, positive: recordingStatus.isRecording)
            NativeNVSTStreamHUDMetricCard(title: "AFK", value: antiAFKMouseMovementEnabled ? "On" : "Off", positive: antiAFKMouseMovementEnabled)
            if inputRouter.isControllerConnected, let level = inputRouter.controllerBatteryLevel {
                NativeNVSTStreamHUDMetricCard(title: "Battery", value: String(format: "%.0f%%", level * 100), positive: level > 0.2)
            }
            if sessionLimit != nil {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    NativeNVSTStreamHUDMetricCard(title: "Session", value: nativeSessionLimitText(at: context.date), positive: nativeSessionLimitIsHealthy(at: context.date))
                }
            }
            if remoteCoOpPreferences.isAlphaOptedIn {
                NativeNVSTStreamHUDMetricCard(title: "Co-Op", value: "Unavailable", positive: false)
            }
        }
    }

    private var nativeHUDControlsPanel: some View {
        NativeNVSTStreamHUDSection(label: "CONTROLS", spacing: 8) {
            HStack(spacing: 8) {
                NativeNVSTStreamHUDActionRow(
                    title: microphoneEnabled ? "Mute microphone" : "Unmute microphone",
                    subtitle: nativeMicrophoneStatusText,
                    systemName: microphoneEnabled ? "mic.slash.fill" : "mic.fill",
                    isActive: microphoneEnabled && microphoneAvailable,
                    isDisabled: !sidebarCapabilities.supports(.microphone) || !microphoneAvailable || microphoneUpdateTask != nil,
                    action: toggleNativeMicrophone
                )
                NativeNVSTStreamHUDActionRow(
                    title: recordingCanStop ? "Stop Recording" : "Record",
                    subtitle: recordingStatusText,
                    systemName: recordingStatus.isRecording ? "record.circle.fill" : "record.circle",
                    isActive: recordingStatus.isRecording,
                    isDisabled: !sidebarCapabilities.supports(.recording) || !isConnected || recordingIsBusy,
                    action: toggleRecording
                )
                NativeNVSTStreamHUDActionRow(
                    title: antiAFKMouseMovementEnabled ? "Disable Anti-AFK" : "Enable Anti-AFK",
                    subtitle: antiAFKMouseMovementEnabled ? "Active" : "Idle",
                    systemName: "cursorarrow.motionlines",
                    isActive: antiAFKMouseMovementEnabled,
                    isDisabled: !sidebarCapabilities.supports(.antiAFK) || !isConnected,
                    action: toggleNativeAntiAFKMouseMovement
                )
                if isDesktopLaunch {
                    NativeNVSTStreamHUDActionRow(
                        title: "Run Desktop Macro",
                        subtitle: desktopMacroState.displayMessage,
                        systemName: "desktopcomputer",
                        isActive: desktopMacroState != .idle && desktopMacroState != .completed,
                        isDisabled: !isConnected,
                        action: startDesktopMacroExecution
                    )
                }
                NativeNVSTStreamHUDActionRow(
                    title: nativeStatsVisible ? "Hide Floating Stats" : "Show Floating Stats",
                    subtitle: "Detailed overlay",
                    systemName: "chart.line.uptrend.xyaxis",
                    isActive: nativeStatsVisible,
                    isDisabled: !sidebarCapabilities.supports(.floatingStats),
                    action: toggleNativeStatsHUD
                )
            }
        }
    }

    private var nativeHUDNetworkPanel: some View {
        NativeNVSTStreamHUDSection(label: "NETWORK", spacing: 8) {
            HStack(spacing: 8) {
                NativeNVSTStreamHUDMetricCard(title: "Health", value: nativeNetworkHealthText, positive: nativeNetworkHealthIsGood)
                NativeNVSTStreamHUDMetricCard(title: "Latency", value: nativeLatencyText, positive: (latestNativeStats?.latencyMilliseconds ?? 0) < 90)
                NativeNVSTStreamHUDMetricCard(title: "Loss", value: nativePacketLossText, positive: (latestNativeStats?.packetLoss ?? 0) == 0)
            }
            if !nativeNetworkWarningText.isEmpty {
                Text(nativeNetworkWarningText)
                    .font(.nativeNVSTStreamNvidia(size: 11, weight: .medium))
                    .foregroundStyle(NativeNVSTMediaStreamTheme.warning)
                    .lineLimit(2)
            }
        }
    }

    private var nativeHUDRemoteCoOpPanel: some View {
        NativeNVSTStreamHUDSection(label: "CO-OP", spacing: 8) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Remote Co-Op")
                            .font(.nativeNVSTStreamNvidia(size: 14, weight: .bold))
                            .foregroundStyle(NativeNVSTMediaStreamTheme.textPrimary)
                        Text("Video and audio relay require WebRTC transport.")
                            .font(.nativeNVSTStreamNvidia(size: 11, weight: .medium))
                            .foregroundStyle(NativeNVSTMediaStreamTheme.textTertiary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 8)
                    Text("NVST")
                        .font(.nativeNVSTStreamNvidia(size: 9, weight: .bold))
                        .tracking(0.7)
                        .foregroundStyle(NativeNVSTMediaStreamTheme.warning)
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .background(Color.white.opacity(0.07))
                        .clipShape(Capsule())
                        .overlay { Capsule().stroke(NativeNVSTMediaStreamTheme.divider, lineWidth: 1) }
                }
                NativeNVSTStreamHUDActionRow(
                    title: "Create Invite",
                    subtitle: "Unavailable with native NVST",
                    systemName: "person.badge.plus",
                    isActive: false,
                    isDisabled: !sidebarCapabilities.supports(.remoteCoOp),
                    action: {}
                )
                nativeHUDDetailRow(label: "Slots", value: "\(remoteCoOpPreferences.effectiveReservedGuestSlots)")
                nativeHUDDetailRow(label: "Quality", value: remoteCoOpPreferences.qualityPreset.label)
                nativeHUDDetailRow(label: "Latency", value: remoteCoOpPreferences.latencyMode.label)
            }
        }
    }

    private var nativeHUDVideoPanel: some View {
        let profile = StreamPreferences.launchProfile(forGame: configuration.applicationID, capabilities: StreamPreferences.loadDeviceCapabilities())
        return NativeNVSTStreamHUDSection(label: "VIDEO") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("MetalFX Upscaling", selection: Binding.constant(0)) {
                    Text("Off").tag(0)
                    Text("MetalFX").tag(3)
                }
                .font(.nativeNVSTStreamNvidia(size: 12, weight: .medium))
                .pickerStyle(.segmented)
                .tint(Color.pixelNowGreen)
                .disabled(!sidebarCapabilities.supports(.videoEnhancement))
                nativeHUDDetailRow(label: "Active", value: "Native")
                nativeHUDDetailRow(label: "Target", value: "Native")
                nativeHUDDetailRow(label: "Resolution", value: "\(profile.resolution.width) x \(profile.resolution.height)")
                nativeHUDDetailRow(label: "Frame Rate", value: "\(profile.fps) FPS")
                nativeHUDDetailRow(label: "Codec", value: profile.codec.value.uppercased())
            }
        }
    }

    private func nativeHUDDetailRow(label: String, value: String) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.nativeNVSTStreamNvidia(size: 10, weight: .medium))
                .foregroundStyle(NativeNVSTMediaStreamTheme.textTertiary)
            Spacer(minLength: 8)
            Text(value)
                .font(.nativeNVSTStreamNvidia(size: 10, weight: .bold))
                .foregroundStyle(NativeNVSTMediaStreamTheme.textPrimary)
                .lineLimit(1)
        }
    }

    private var nativeStreamControlsOverlay: some View {
        ZStack {
            Color.black.opacity(0.85).ignoresSafeArea(.container, edges: [.horizontal, .bottom])
            VStack(spacing: 20) {
                Text("NATIVE NVST")
                    .font(NVIDIAFont.font(size: 12, weight: .bold))
                    .foregroundStyle(Color.pixelNowGreen)
                    .tracking(2.2)
                Text("STREAM CONTROLS")
                    .font(NVIDIAFont.font(size: 28, weight: .bold))
                    .foregroundStyle(.white)
                Text(configuration.title.isEmpty ? "GeForce NOW" : configuration.title)
                    .font(NVIDIAFont.font(size: 15, weight: .medium))
                    .foregroundStyle(.white.opacity(0.68))
                Text("Remote input is paused. Resume to return focus to the game.")
                    .font(NVIDIAFont.font(size: 13, weight: .regular))
                    .foregroundStyle(.white.opacity(0.54))
                    .multilineTextAlignment(.center)
                HStack(spacing: 12) {
                    Button("Resume", action: dismissStreamControls)
                        .keyboardShortcut(.cancelAction)
                        .buttonStyle(.borderedProminent)
                        .tint(Color.pixelNowGreen)
                    Button("Pause Stream", action: pauseFromStreamControls)
                        .buttonStyle(.bordered)
                    Button(pendingApplicationQuitCompletion == nil ? "End Stream" : "Quit PixelNOW", action: endFromStreamControls)
                        .buttonStyle(.bordered)
                }
                .controlSize(.large)
                .disabled(isEnding)
                Text("\(NativeNVSTMediaStreamCommand.shortcutGuide)   Esc Resume")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.50))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.06), in: Capsule())
                    .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 1))
            }
            .padding(36)
            .background(NativeNVSTMediaStreamTheme.panel.opacity(0.92))
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(Color.pixelNowGreen.opacity(0.35), lineWidth: 1))
            .shadow(color: .black.opacity(0.6), radius: 30, y: 16)
        }
    }

    private func beginStreamingPerformanceMode() {
        guard streamingPerformanceActivity == nil else { return }
        var options: ProcessInfo.ActivityOptions = [.userInitiated, .latencyCritical, .idleSystemSleepDisabled]
        if preventDisplaySleep { options.insert(.idleDisplaySleepDisabled) }
        streamingPerformanceActivity = ProcessInfo.processInfo.beginActivity(options: options, reason: "PixelNOW active native NVST stream")
        NativeNVSTMediaTelemetry.capture("nvst.stream.performance_mode.begin", level: .info, message: "Native NVST performance mode enabled.", attributes: ["applicationID": configuration.applicationID, "preventDisplaySleep": String(preventDisplaySleep)])
    }

    private func endStreamingPerformanceMode() {
        guard let streamingPerformanceActivity else { return }
        ProcessInfo.processInfo.endActivity(streamingPerformanceActivity)
        self.streamingPerformanceActivity = nil
        NativeNVSTMediaTelemetry.capture("nvst.stream.performance_mode.end", level: .info, message: "Native NVST performance mode disabled.", attributes: ["applicationID": configuration.applicationID])
    }

    private static func message(for error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription, !description.isEmpty { return description }
        return error.localizedDescription.isEmpty ? "Native NVST stream request failed." : error.localizedDescription
    }
}

struct NativeNVSTStreamHostView: NSViewRepresentable {
    let onResolve: @MainActor (NativeNVSTStreamView) -> Void

    func makeNSView(context: Context) -> NativeNVSTSurfaceContainerView {
        let view = NativeNVSTSurfaceContainerView(frame: .zero)
        view.onResolve = onResolve
        return view
    }

    func updateNSView(_ nsView: NativeNVSTSurfaceContainerView, context: Context) {
        nsView.onResolve = onResolve
        nsView.resolveIfReady()
    }

    static func dismantleNSView(_ nsView: NativeNVSTSurfaceContainerView, coordinator: ()) {
        nsView.streamView.remoteInputEnabled = false
        nsView.streamView.setPointerLocked(false)
        nsView.streamView.onInputEvent = nil
        nsView.streamView.onAbsoluteMouseMove = nil
        nsView.streamView.onGamepadTopologyChanged = nil
        nsView.streamView.onPointerLockChanged = nil
        nsView.streamView.onCommand = nil
        nsView.streamView.shouldHandleCommand = nil
        nsView.onResolve = nil
    }

    final class NativeNVSTSurfaceContainerView: NSView {
        let streamView = NativeNVSTStreamView(frame: .zero)
        var onResolve: (@MainActor (NativeNVSTStreamView) -> Void)?
        private var didResolve = false

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.backgroundColor = NSColor.black.cgColor
            addSubview(streamView)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            resolveIfReady()
        }

        override func layout() {
            super.layout()
            streamView.frame = bounds
            resolveIfReady()
        }

        func resolveIfReady() {
            streamView.frame = bounds
            guard !didResolve, window != nil, bounds.width >= 1, bounds.height >= 1, let onResolve else { return }
            didResolve = true
            onResolve(streamView)
        }
    }
}
