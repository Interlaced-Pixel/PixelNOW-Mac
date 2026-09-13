import CoreGraphics
import CoreVideo
import Foundation
import AppKit

public enum DesktopAutomationStep: Int, CaseIterable, Sendable, Identifiable {
    case detectSteamAndDismissFriends = 0
    case installGameIfPrompted = 1
    case ensureOnStorePage = 2
    case rightClickCenterAndOpenTab = 3
    case selectAndHighlightAddressBar = 4
    case enterSalsaNowURL = 5
    case saveUpdaterOverExecutable = 6
    case finalizeDesktopEnvironment = 7

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .detectSteamAndDismissFriends: return "Detect Steam & Dismiss Friends"
        case .installGameIfPrompted: return "Install Game if Prompted"
        case .ensureOnStorePage: return "Ensure on Steam Store Page"
        case .rightClickCenterAndOpenTab: return "Right-Click Center & Open Tab"
        case .selectAndHighlightAddressBar: return "Locate & Highlight Address Bar"
        case .enterSalsaNowURL: return "Paste Updater URL (Manual)"
        case .saveUpdaterOverExecutable: return "Overwrite Steam Executable (Manual)"
        case .finalizeDesktopEnvironment: return "Desktop Ready for Manual Steps"
        }
    }
}

public enum DesktopStepStatus: Sendable, Equatable {
    case pending
    case inProgress
    case completed
    case failed(String)
}

public struct DesktopAutomationSnapshot: Sendable, Equatable {
    public var currentStep: DesktopAutomationStep
    public var statuses: [DesktopAutomationStep: DesktopStepStatus]
    public var detailMessage: String
    public var isComplete: Bool
    public var isCancelled: Bool
    public var error: String?

    public static var initial: DesktopAutomationSnapshot {
        var map: [DesktopAutomationStep: DesktopStepStatus] = [:]
        for step in DesktopAutomationStep.allCases {
            map[step] = .pending
        }
        return DesktopAutomationSnapshot(
            currentStep: .detectSteamAndDismissFriends,
            statuses: map,
            detailMessage: "Waiting for Steam to launch...",
            isComplete: false,
            isCancelled: false,
            error: nil
        )
    }

    public mutating func update(step: DesktopAutomationStep, status: DesktopStepStatus, message: String) {
        currentStep = step
        statuses[step] = status
        detailMessage = message
        if case .failed(let err) = status {
            error = err
        }
    }
}

public struct DesktopMacroTimings: Equatable, Sendable {
    public var initialDelay: TimeInterval
    public var keystrokeDelay: TimeInterval
    public var navigationDelay: TimeInterval
    public var downloadDelay: TimeInterval
    public var visionScanInterval: TimeInterval
    public var maxWaitTimeout: TimeInterval

    public init(
        initialDelay: TimeInterval = StreamPreferences.defaultDesktopMacroInitialDelay,
        keystrokeDelay: TimeInterval = StreamPreferences.defaultDesktopMacroKeystrokeDelay,
        navigationDelay: TimeInterval = StreamPreferences.defaultDesktopMacroNavigationDelay,
        downloadDelay: TimeInterval = StreamPreferences.defaultDesktopMacroDownloadDelay,
        visionScanInterval: TimeInterval = 0.35,
        maxWaitTimeout: TimeInterval = 25.0
    ) {
        self.initialDelay = initialDelay
        self.keystrokeDelay = keystrokeDelay
        self.navigationDelay = navigationDelay
        self.downloadDelay = downloadDelay
        self.visionScanInterval = visionScanInterval
        self.maxWaitTimeout = maxWaitTimeout
    }
}

public enum DesktopMacroState: Equatable, Sendable {
    case idle
    case waitingForSteam(remainingSeconds: Int)
    case dismissingFriends
    case installingGame
    case navigatingToStore
    case waitingForStoreToLoad
    case openingContextMenu
    case verifyingContextMenu
    case clickingOpenInNewTab
    case waitingForBrowser
    case locatingAddressBar
    case enteringURL
    case submittingURL
    case waitingForSaveDialog
    case browsingToExecutable
    case confirmingSave
    case verifyingOverwrite
    case completed
    case cancelled
    case failed(String)

    public var displayMessage: String {
        switch self {
        case .idle: return "Desktop Setup: Ready"
        case .waitingForSteam(let s): return "Waiting for Steam (\(s)s)..."
        case .dismissingFriends: return "Dismissing Friends Window..."
        case .installingGame: return "Confirming Game Install..."
        case .navigatingToStore: return "Navigating to Steam Store..."
        case .waitingForStoreToLoad: return "Waiting for Store Page to Load..."
        case .openingContextMenu: return "Right-clicking Center of Store Page..."
        case .verifyingContextMenu: return "Verifying Context Menu..."
        case .clickingOpenInNewTab: return "Clicking Open Link in New Tab..."
        case .waitingForBrowser: return "Waiting for Browser Tab to Open..."
        case .locatingAddressBar: return "Locating & Highlighting Address Bar..."
        case .enteringURL: return "Entering SalsaNOW Updater URL..."
        case .submittingURL: return "Submitting Updater Download..."
        case .waitingForSaveDialog: return "Waiting for Save As Dialog..."
        case .browsingToExecutable: return "Navigating to Game Executable..."
        case .confirmingSave: return "Saving SalsaNOW Updater..."
        case .verifyingOverwrite: return "Confirming Overwrite..."
        case .completed: return "SalsaNOW Desktop Configured!"
        case .cancelled: return "Desktop Setup Cancelled"
        case .failed(let msg): return "Desktop Setup Error: \(msg)"
        }
    }
}

public final class DesktopMacroEngine: @unchecked Sendable {
    public static let salsaDownloadURL = "https://salsanowfiles.work/SalsaNOW/SalsaNOWUpdater.exe"
    public static let steamAppsCommonPath = "C:\\Program Files (x86)\\Steam\\steamapps\\common"

    private let sendEvent: @Sendable (UserInputEvent) -> Void
    private let sendAbsoluteMove: (@Sendable (NativeNVSTAbsoluteMouseEvent) -> Void)?
    private let frameProvider: (@Sendable () -> CVPixelBuffer?)?
    private let carrierGameExecutableHint: String?
    private var viewportWidth: Int32
    private var viewportHeight: Int32

    private var executionTask: Task<Void, Never>?
    private var isRunning = false
    private var currentSnapshot = DesktopAutomationSnapshot.initial
    private var progressCallback: (@MainActor (DesktopAutomationSnapshot) -> Void)?

    public init(
        sendEvent: @escaping @Sendable (UserInputEvent) -> Void,
        sendAbsoluteMove: (@Sendable (NativeNVSTAbsoluteMouseEvent) -> Void)? = nil,
        frameProvider: (@Sendable () -> CVPixelBuffer?)? = nil,
        carrierGameExecutableHint: String? = nil,
        viewportWidth: Int32 = 1920,
        viewportHeight: Int32 = 1080
    ) {
        self.sendEvent = sendEvent
        self.sendAbsoluteMove = sendAbsoluteMove
        self.frameProvider = frameProvider
        self.carrierGameExecutableHint = carrierGameExecutableHint
        self.viewportWidth = viewportWidth
        self.viewportHeight = viewportHeight
    }

    deinit { cancel() }

    public func cancel() {
        executionTask?.cancel()
        executionTask = nil
        isRunning = false
        if !currentSnapshot.isComplete && !currentSnapshot.isCancelled {
            currentSnapshot.isCancelled = true
            currentSnapshot.detailMessage = "Automation cancelled by user."
            currentSnapshot.statuses[currentSnapshot.currentStep] = .failed("Cancelled by user")
            let snap = currentSnapshot
            let cb = progressCallback
            Task { @MainActor in cb?(snap) }
        }
    }

    public func execute(
        timings: DesktopMacroTimings,
        progressHandler: @escaping @MainActor (DesktopAutomationSnapshot) -> Void
    ) {
        cancel()
        isRunning = true
        progressCallback = progressHandler
        currentSnapshot = DesktopAutomationSnapshot.initial
        let initialSnap = currentSnapshot
        Task { @MainActor in
            progressHandler(initialSnap)
        }

        executionTask = Task { [weak self] in
            guard let self else { return }
            await self.run(timings: timings, progressHandler: progressHandler)
        }
    }

    // MARK: - Reactive Perception-Action State Machine

    private func run(
        timings: DesktopMacroTimings,
        progressHandler: @escaping @MainActor (DesktopAutomationSnapshot) -> Void
    ) async {
        Log.info(.stream, "DesktopMacroEngine: Starting context-aware execution")

        // Helper to publish snapshot updates
        let notify = { [weak self] (step: DesktopAutomationStep, status: DesktopStepStatus, msg: String) in
            guard let self else { return }
            self.currentSnapshot.update(step: step, status: status, message: msg)
            let snap = self.currentSnapshot
            Task { @MainActor in progressHandler(snap) }
        }

        // ══════════════════════════════════════════════════════════════════════════
        // Step 1: Detect Steam & Dismiss Friends Window (if visible)
        // ══════════════════════════════════════════════════════════════════════════
        notify(.detectSteamAndDismissFriends, .inProgress, "Detecting Steam on remote desktop...")

        let totalWaitSeconds = max(1, Int(timings.initialDelay))
        var initialFrameReady = false
        for second in (1...totalWaitSeconds).reversed() {
            guard !Task.isCancelled else {
                currentSnapshot.isCancelled = true
                notify(.detectSteamAndDismissFriends, .failed("Cancelled"), "Setup cancelled.")
                return
            }
            notify(.detectSteamAndDismissFriends, .inProgress, "Waiting for Steam (\(second)s)...")
            if let frame = frameProvider?() {
                updateViewportDimensions(from: frame)
                let elements = DesktopMacroVisionScanner.shared.recognizeText(in: frame)
                if !elements.isEmpty {
                    initialFrameReady = true
                    Log.info(.stream, "DesktopMacroEngine: Frame received with \(elements.count) elements")
                    break
                }
            }
            try? await Task.sleep(for: .seconds(1))
        }

        guard initialFrameReady else {
            notify(.detectSteamAndDismissFriends, .failed("No video stream"), "No video stream received.")
            return
        }
        guard !Task.isCancelled else { return }

        // Check for Friends window and dismiss it if visible
        if let friends = await scanCurrentFrame(for: { [self] elements in
            DesktopMacroVisionScanner.shared.detectFriendsWindow(in: elements, viewportWidth: viewportWidth, viewportHeight: viewportHeight)
        }) {
            notify(.detectSteamAndDismissFriends, .inProgress, "Dismissing Steam Friends & Chat window...")
            Log.info(.stream, "DesktopMacroEngine: Clicking Friends close button at (\(friends.closePoint.x), \(friends.closePoint.y))")
            await sendAbsoluteMouseEvent(x: friends.closePoint.x, y: friends.closePoint.y)
            await sendMouseClick(button: .left)

            // Confirm Friends window is dismissed
            _ = await waitUntil(timeout: 3.0, interval: 0.3) { [self] elements in
                DesktopMacroVisionScanner.shared.detectFriendsWindow(in: elements, viewportWidth: viewportWidth, viewportHeight: viewportHeight) == nil ? true : nil
            }
        }

        notify(.detectSteamAndDismissFriends, .completed, "Steam detected. Friends window clear.")
        guard !Task.isCancelled else { return }

        // ══════════════════════════════════════════════════════════════════════════
        // Step 2: Install the Game if Prompted by Steam
        // ══════════════════════════════════════════════════════════════════════════
        notify(.installGameIfPrompted, .inProgress, "Checking for Steam install prompts...")

        let maxInstallPromptChecks = 3
        for _ in 1...maxInstallPromptChecks {
            guard let installButton = await scanCurrentFrame(for: { [self] elements in
                DesktopMacroVisionScanner.shared.detectInstallPrompt(in: elements, viewportWidth: viewportWidth, viewportHeight: viewportHeight)
            }) else {
                break
            }

            notify(.installGameIfPrompted, .inProgress, "Confirming install prompt: '\(installButton.label)'...")
            Log.info(.stream, "DesktopMacroEngine: Clicking install prompt button '\(installButton.label)' at (\(installButton.buttonPoint.x), \(installButton.buttonPoint.y))")
            await sendAbsoluteMouseEvent(x: installButton.buttonPoint.x, y: installButton.buttonPoint.y)
            await sendMouseClick(button: .left)

            // Wait for dialog step to advance
            try? await Task.sleep(for: .milliseconds(700))
        }

        notify(.installGameIfPrompted, .completed, "Install prompts handled.")
        guard !Task.isCancelled else { return }

        // ══════════════════════════════════════════════════════════════════════════
        // Step 3: Ensure User is on the Steam Store Page
        // ══════════════════════════════════════════════════════════════════════════
        notify(.ensureOnStorePage, .inProgress, "Verifying Steam Store page...")

        var onStorePage = await scanCurrentFrame(for: { elements in
            DesktopMacroVisionScanner.shared.isSteamStorePageLoaded(in: elements)
        }) ?? false

        if !onStorePage {
            notify(.ensureOnStorePage, .inProgress, "Navigating to Steam Store...")
            Log.info(.stream, "DesktopMacroEngine: Store not loaded yet. Locating top STORE tab.")

            let storeButton = await waitUntil(timeout: 8.0, interval: timings.visionScanInterval) { [self] elements in
                DesktopMacroVisionScanner.shared.findSteamTopStoreButton(in: elements, viewportWidth: viewportWidth, viewportHeight: viewportHeight)
            }

            if let storeBtn = storeButton {
                Log.info(.stream, "DesktopMacroEngine: Left-clicking STORE tab at (\(storeBtn.point.x), \(storeBtn.point.y))")
                await sendAbsoluteMouseEvent(x: storeBtn.point.x, y: storeBtn.point.y)
                await sendMouseClick(button: .left)
            }

            // Confirm store page loaded
            notify(.ensureOnStorePage, .inProgress, "Waiting for Store content to render...")
            onStorePage = await waitUntilTrue(timeout: timings.maxWaitTimeout, interval: timings.visionScanInterval) { elements in
                DesktopMacroVisionScanner.shared.isSteamStorePageLoaded(in: elements)
            }
        }

        guard onStorePage else {
            notify(.ensureOnStorePage, .failed("Store failed to load"), "Steam Store page failed to load.")
            return
        }

        notify(.ensureOnStorePage, .completed, "Steam Store page confirmed.")
        guard !Task.isCancelled else { return }

        // ══════════════════════════════════════════════════════════════════════════
        // Step 4: Right-Click Dead Center & Open Link in New Tab
        // ══════════════════════════════════════════════════════════════════════════
        notify(.rightClickCenterAndOpenTab, .inProgress, "Right-clicking center of Store page...")

        let centerX = viewportWidth / 2
        let centerY = viewportHeight / 2
        Log.info(.stream, "DesktopMacroEngine: Right-clicking dead center of screen at (\(centerX), \(centerY))")
        await sendAbsoluteMouseEvent(x: centerX, y: centerY)
        await sendMouseClick(button: .right)

        // Locate 'Open link in new tab' in context menu
        notify(.rightClickCenterAndOpenTab, .inProgress, "Locating 'Open link in new tab'...")
        var contextMenuOption = await waitUntil(timeout: 5.0, interval: 0.25) { [self] elements in
            DesktopMacroVisionScanner.shared.findContextMenuOption(in: elements, viewportWidth: viewportWidth, viewportHeight: viewportHeight)
        }

        // Retry dead-center click once if menu didn't immediately register
        if contextMenuOption == nil {
            Log.info(.stream, "DesktopMacroEngine: Retrying right-click dead center")
            await sendAbsoluteMouseEvent(x: centerX, y: centerY)
            await sendMouseClick(button: .right)
            contextMenuOption = await waitUntil(timeout: 5.0, interval: 0.25) { [self] elements in
                DesktopMacroVisionScanner.shared.findContextMenuOption(in: elements, viewportWidth: viewportWidth, viewportHeight: viewportHeight)
            }
        }

        guard let menuOption = contextMenuOption else {
            notify(.rightClickCenterAndOpenTab, .failed("Context menu not found"), "Could not locate 'Open link in new tab' context menu.")
            return
        }

        Log.info(.stream, "DesktopMacroEngine: Clicking context menu option '\(menuOption.label)' at (\(menuOption.point.x), \(menuOption.point.y))")
        await sendAbsoluteMouseEvent(x: menuOption.point.x, y: menuOption.point.y)
        await sendMouseClick(button: .left)

        // Confirm browser tab / window opens
        _ = await waitUntilTrue(timeout: 6.0, interval: timings.visionScanInterval) { elements in
            DesktopMacroVisionScanner.shared.detectBrowserWindow(in: elements)
        }
        try? await Task.sleep(for: .milliseconds(400))

        notify(.rightClickCenterAndOpenTab, .completed, "New browser tab opened.")
        guard !Task.isCancelled else { return }

        // ══════════════════════════════════════════════════════════════════════════
        // Step 5: Locate Address Bar & Highlight Contents
        // ══════════════════════════════════════════════════════════════════════════
        notify(.selectAndHighlightAddressBar, .inProgress, "Locating new tab and address bar...")

        // If a new tab header is detected in the upper tab strip, click it to guarantee tab focus
        if let newTab = await scanCurrentFrame(for: { [self] elements in
            DesktopMacroVisionScanner.shared.findNewTabHeader(in: elements, hint: carrierGameExecutableHint, viewportWidth: viewportWidth, viewportHeight: viewportHeight)
        }) {
            Log.info(.stream, "DesktopMacroEngine: Clicking new tab '\(newTab.label)' at (\(newTab.point.x), \(newTab.point.y))")
            await sendAbsoluteMouseEvent(x: newTab.point.x, y: newTab.point.y)
            await sendMouseClick(button: .left)
            try? await Task.sleep(for: .milliseconds(120))
        }

        // Visually locate address bar
        let detectedAddressBar = await waitUntil(timeout: 5.0, interval: timings.visionScanInterval) { [self] elements in
            DesktopMacroVisionScanner.shared.findAddressBar(in: elements, viewportWidth: viewportWidth, viewportHeight: viewportHeight)
        }

        let addressBarPoint: (x: Int32, y: Int32)
        if let bar = detectedAddressBar {
            Log.info(.stream, "DesktopMacroEngine: Located address bar at (\(bar.point.x), \(bar.point.y)) with label '\(bar.label)'")
            addressBarPoint = bar.point
        } else {
            // Steam client canonical address bar location (x ~ 28% of width, y ~ 7.6% of height)
            let defaultX = Int32(Double(viewportWidth) * 0.28)
            let defaultY = Int32(Double(viewportHeight) * 0.076)
            Log.info(.stream, "DesktopMacroEngine: Address bar text not explicit in OCR; targeting canonical bar location at (\(defaultX), \(defaultY))")
            addressBarPoint = (defaultX, defaultY)
        }

        // Focus address bar via mouse click
        notify(.selectAndHighlightAddressBar, .inProgress, "Focusing address bar...")
        await sendAbsoluteMouseEvent(x: addressBarPoint.x, y: addressBarPoint.y)
        await sendMouseClick(button: .left)
        try? await Task.sleep(for: .milliseconds(80))

        // Focus address bar via standard shortcuts (Ctrl+L and Alt+D) with genuine modifiers
        await sendCtrlKey(key: (37, 0x26)) // Ctrl+L
        try? await Task.sleep(for: .milliseconds(60))
        await sendAltKey(key: (2, 0x20)) // Alt+D
        try? await Task.sleep(for: .milliseconds(60))

        // Highlight contents: Triple-click the address bar field AND send Ctrl+A
        notify(.selectAndHighlightAddressBar, .inProgress, "Highlighting address bar contents (Ctrl+A)...")
        Log.info(.stream, "DesktopMacroEngine: Triple-clicking address bar and pressing Ctrl+A")
        await sendTripleClick(at: addressBarPoint)
        try? await Task.sleep(for: .milliseconds(60))
        await sendCtrlKey(key: (0, 0x1e)) // Ctrl+A
        try? await Task.sleep(for: .milliseconds(80))

        notify(.selectAndHighlightAddressBar, .completed, "Address bar selected & highlighted.")
        guard !Task.isCancelled else {
            currentSnapshot.isCancelled = true
            return
        }

        // ══════════════════════════════════════════════════════════════════════════
        // Step 6: Overwrite with SalsaNOW Updater URL & Submit
        // ══════════════════════════════════════════════════════════════════════════
        notify(.enterSalsaNowURL, .inProgress, "Overwriting address bar with SalsaNOW URL...")

        // Copy to clipboard
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.salsaDownloadURL, forType: .string)

        notify(.enterSalsaNowURL, .completed, "URL copied! Paste into address bar and press Enter.")
        guard !Task.isCancelled else { return }

        // ══════════════════════════════════════════════════════════════════════════
        // Step 7: Wait for Dialog Box, Navigate to & Overwrite Executable
        // ══════════════════════════════════════════════════════════════════════════
        notify(.saveUpdaterOverExecutable, .completed, "Locate and overwrite the Steam executable manually.")
        guard !Task.isCancelled else { return }

        // ══════════════════════════════════════════════════════════════════════════
        // Step 8: Desktop Mode Ready
        // ══════════════════════════════════════════════════════════════════════════
        currentSnapshot.isComplete = true
        notify(.finalizeDesktopEnvironment, .completed, "SalsaNOW Desktop environment ready for manual steps.")
        Log.info(.stream, "DesktopMacroEngine: Automated portion finished, delegated manual steps to user.")
        isRunning = false
    }

    // MARK: - Frame & Dimension Helpers

    private func updateViewportDimensions(from pixelBuffer: CVPixelBuffer) {
        let width = Int32(CVPixelBufferGetWidth(pixelBuffer))
        let height = Int32(CVPixelBufferGetHeight(pixelBuffer))
        if width > 0 && height > 0 {
            viewportWidth = width
            viewportHeight = height
        }
    }

    private func scanCurrentFrame<T>(for extract: ([DetectedTextElement]) -> T?) async -> T? {
        guard let frame = frameProvider?() else { return nil }
        updateViewportDimensions(from: frame)
        let elements = DesktopMacroVisionScanner.shared.recognizeText(in: frame)
        return extract(elements)
    }

    private func waitUntil<T>(
        timeout: TimeInterval,
        interval: TimeInterval,
        discriminator: @escaping ([DetectedTextElement]) -> T?
    ) async -> T? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard !Task.isCancelled else { return nil }
            if let frame = frameProvider?() {
                updateViewportDimensions(from: frame)
                let elements = DesktopMacroVisionScanner.shared.recognizeText(in: frame)
                if let result = discriminator(elements) { return result }
            }
            try? await Task.sleep(for: .milliseconds(Int(interval * 1000)))
        }
        return nil
    }

    private func waitUntilTrue(
        timeout: TimeInterval,
        interval: TimeInterval,
        predicate: @escaping ([DetectedTextElement]) -> Bool
    ) async -> Bool {
        let result = await waitUntil(timeout: timeout, interval: interval) { elements -> Bool? in
            predicate(elements) ? true : nil
        }
        return result == true
    }

    // MARK: - Low-Level Verified Input Primitives

    private static func timestamp() -> MediaTimestamp {
        MediaTimestamp(nanoseconds: DispatchTime.now().uptimeNanoseconds)
    }

    private func sendAbsoluteMouseEvent(x: Int32, y: Int32) async {
        sendAbsoluteMove?(NativeNVSTAbsoluteMouseEvent(
            x: x,
            y: y,
            viewportWidth: viewportWidth,
            viewportHeight: viewportHeight,
            timestamp: Self.timestamp()
        ))
        try? await Task.sleep(for: .milliseconds(50))
    }

    private func sendMouseClick(button: MouseButton) async {
        await sendMouseButtonEvent(button: button, isPressed: true)
        try? await Task.sleep(for: .milliseconds(40))
        await sendMouseButtonEvent(button: button, isPressed: false)
        try? await Task.sleep(for: .milliseconds(40))
    }

    private func clickOrEnterItem(point: (x: Int32, y: Int32), isExecutable: Bool) async {
        await sendAbsoluteMouseEvent(x: point.x, y: point.y)
        try? await Task.sleep(for: .milliseconds(60))
        await sendMouseButtonEvent(button: .left, isPressed: true)
        try? await Task.sleep(for: .milliseconds(40))
        await sendMouseButtonEvent(button: .left, isPressed: false)
        if !isExecutable {
            try? await Task.sleep(for: .milliseconds(50))
            await sendMouseButtonEvent(button: .left, isPressed: true)
            try? await Task.sleep(for: .milliseconds(40))
            await sendMouseButtonEvent(button: .left, isPressed: false)
        }
    }

    private func sendMouseButtonEvent(button: MouseButton, isPressed: Bool) async {
        let event = MouseEvent.button(deviceID: "mouse", button: button, isPressed: isPressed, timestamp: Self.timestamp())
        sendEvent(.mouse(event))
        try? await Task.sleep(for: .milliseconds(30))
    }

    private func sendTripleClick(at point: (x: Int32, y: Int32)) async {
        await sendAbsoluteMouseEvent(x: point.x, y: point.y)
        try? await Task.sleep(for: .milliseconds(40))
        for _ in 0..<3 {
            await sendMouseButtonEvent(button: .left, isPressed: true)
            try? await Task.sleep(for: .milliseconds(40))
            await sendMouseButtonEvent(button: .left, isPressed: false)
            try? await Task.sleep(for: .milliseconds(40))
        }
    }

    private func sendKeyEvent(keyCode: UInt16, scanCode: UInt16, modifiers: KeyboardModifiers = [], isPressed: Bool) async {
        let event = KeyboardEvent(
            deviceID: "keyboard",
            keyCode: keyCode,
            scanCode: scanCode,
            modifiers: modifiers,
            isPressed: isPressed,
            timestamp: Self.timestamp()
        )
        sendEvent(.keyboard(event))
        try? await Task.sleep(for: .milliseconds(25))
    }

    private func sendShortcut(modifierKeyCode: UInt16, modifierScanCode: UInt16, modifier: KeyboardModifiers, key: (keyCode: UInt16, scanCode: UInt16)) async {
        // Press modifier key down with modifier flag
        await sendKeyEvent(keyCode: modifierKeyCode, scanCode: modifierScanCode, modifiers: modifier, isPressed: true)
        try? await Task.sleep(for: .milliseconds(40))
        // Press target key with modifier flag
        await sendKeyEvent(keyCode: key.keyCode, scanCode: key.scanCode, modifiers: modifier, isPressed: true)
        try? await Task.sleep(for: .milliseconds(50))
        // Release target key with modifier flag
        await sendKeyEvent(keyCode: key.keyCode, scanCode: key.scanCode, modifiers: modifier, isPressed: false)
        try? await Task.sleep(for: .milliseconds(30))
        // Release modifier key
        await sendKeyEvent(keyCode: modifierKeyCode, scanCode: modifierScanCode, modifiers: [], isPressed: false)
        try? await Task.sleep(for: .milliseconds(40))
    }

    private func sendCtrlKey(key: (keyCode: UInt16, scanCode: UInt16)) async {
        await sendShortcut(modifierKeyCode: 59, modifierScanCode: 0x1d, modifier: .control, key: key)
    }

    private func sendAltKey(key: (keyCode: UInt16, scanCode: UInt16)) async {
        await sendShortcut(modifierKeyCode: 58, modifierScanCode: 0x38, modifier: .option, key: key)
    }

    private func sendCharacter(_ character: Character) async {
        guard let entry = Self.characterKeyMap[character] else { return }
        if entry.shift {
            await sendKeyEvent(keyCode: 56, scanCode: 0x2a, modifiers: .shift, isPressed: true)
            try? await Task.sleep(for: .milliseconds(20))
        }
        let mods: KeyboardModifiers = entry.shift ? .shift : []
        await sendKeyEvent(keyCode: entry.keyCode, scanCode: entry.scanCode, modifiers: mods, isPressed: true)
        try? await Task.sleep(for: .milliseconds(25))
        await sendKeyEvent(keyCode: entry.keyCode, scanCode: entry.scanCode, modifiers: mods, isPressed: false)
        try? await Task.sleep(for: .milliseconds(20))
        if entry.shift {
            await sendKeyEvent(keyCode: 56, scanCode: 0x2a, modifiers: [], isPressed: false)
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    // MARK: - Key map

    private struct KeyEntry {
        let keyCode: UInt16
        let scanCode: UInt16
        let shift: Bool
        init(_ keyCode: UInt16, _ scanCode: UInt16, shift: Bool = false) {
            self.keyCode = keyCode
            self.scanCode = scanCode
            self.shift = shift
        }
    }

    private static let characterKeyMap: [Character: KeyEntry] = {
        var map: [Character: KeyEntry] = [:]
        let digits: [(Character, UInt16, UInt16)] = [
            ("0", 29, 0x0b), ("1", 18, 0x02), ("2", 19, 0x03), ("3", 20, 0x04),
            ("4", 21, 0x05), ("5", 23, 0x06), ("6", 22, 0x07), ("7", 26, 0x08),
            ("8", 28, 0x09), ("9", 25, 0x0a)
        ]
        for (char, kc, sc) in digits { map[char] = KeyEntry(kc, sc) }
        let letters: [(Character, UInt16, UInt16)] = [
            ("a", 0, 0x1e), ("b", 11, 0x30), ("c", 8, 0x2e), ("d", 2, 0x20),
            ("e", 14, 0x12), ("f", 3, 0x21), ("g", 5, 0x22), ("h", 4, 0x23),
            ("i", 34, 0x17), ("j", 38, 0x24), ("k", 40, 0x25), ("l", 37, 0x26),
            ("m", 46, 0x32), ("n", 45, 0x31), ("o", 31, 0x18), ("p", 35, 0x19),
            ("q", 12, 0x10), ("r", 15, 0x13), ("s", 1, 0x1f), ("t", 17, 0x14),
            ("u", 32, 0x16), ("v", 9, 0x2f), ("w", 13, 0x11), ("x", 7, 0x2d),
            ("y", 16, 0x15), ("z", 6, 0x2c)
        ]
        for (char, kc, sc) in letters {
            map[char] = KeyEntry(kc, sc)
            map[Character(char.uppercased())] = KeyEntry(kc, sc, shift: true)
        }
        map[":"] = KeyEntry(41, 0x27, shift: true)
        map["/"] = KeyEntry(44, 0x35)
        map["\\"] = KeyEntry(42, 0x2b)
        map["."] = KeyEntry(47, 0x34)
        map["-"] = KeyEntry(27, 0x0c)
        map["_"] = KeyEntry(27, 0x0c, shift: true)
        map["?"] = KeyEntry(44, 0x35, shift: true)
        map["="] = KeyEntry(24, 0x0d)
        map["&"] = KeyEntry(26, 0x08, shift: true)
        map["%"] = KeyEntry(23, 0x06, shift: true)
        map["+"] = KeyEntry(24, 0x0d, shift: true)
        map["#"] = KeyEntry(20, 0x04, shift: true)
        map["("] = KeyEntry(25, 0x0a, shift: true)
        map[")"] = KeyEntry(29, 0x0b, shift: true)
        map[" "] = KeyEntry(49, 0x39)
        return map
    }()
}
