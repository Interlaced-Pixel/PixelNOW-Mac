import AppKit
import Darwin
import SwiftUI
import SwiftData

enum UpdatePreferences {
    static let automaticUpdateChecksEnabledKey = "PixelNOWAutomaticUpdateChecksEnabled"
    static let defaultAutomaticUpdateChecksEnabled = true

    private static let remindAfterKey = "PixelNOWUpdateRemindAfter"

    static var automaticUpdateChecksEnabled: Bool {
        get {
            guard UserDefaults.standard.object(forKey: automaticUpdateChecksEnabledKey) != nil else {
                return defaultAutomaticUpdateChecksEnabled
            }
            return UserDefaults.standard.bool(forKey: automaticUpdateChecksEnabledKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: automaticUpdateChecksEnabledKey)
        }
    }

    static var updateChecksAreSuspendedForDebugging: Bool {
        #if DEBUG
        return true
        #else
        return isDebuggerAttached
        #endif
    }

    static var automaticUpdateChecksCanBeScheduled: Bool {
        automaticUpdateChecksEnabled && !updateChecksAreSuspendedForDebugging
    }

    static func shouldRunAutomaticUpdateCheck(now: Date = Date()) -> Bool {
        guard automaticUpdateChecksCanBeScheduled else { return false }
        guard let remindAfterDate else { return true }
        if remindAfterDate <= now {
            clearReminder()
            return true
        }
        return false
    }

    static func remindTomorrow(from date: Date = Date()) {
        let reminderDate = Calendar.current.date(byAdding: .day, value: 1, to: date) ?? date.addingTimeInterval(24 * 60 * 60)
        UserDefaults.standard.set(reminderDate.timeIntervalSince1970, forKey: remindAfterKey)
    }

    private static var remindAfterDate: Date? {
        guard UserDefaults.standard.object(forKey: remindAfterKey) != nil else { return nil }
        let timestamp = UserDefaults.standard.double(forKey: remindAfterKey)
        guard timestamp > 0 else { return nil }
        return Date(timeIntervalSince1970: timestamp)
    }

    private static func clearReminder() {
        UserDefaults.standard.removeObject(forKey: remindAfterKey)
    }

    private static var isDebuggerAttached: Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        let result = sysctl(&mib, u_int(mib.count), &info, &size, nil, 0)
        guard result == 0 else { return false }
        return (info.kp_proc.p_flag & P_TRACED) != 0
    }
}

@main
struct PixelNOWApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    let sharedModelContainer: ModelContainer

    init() {
        AppPreferenceStorage.standard.synchronize()
        Sentry.clearDiagnosticsLogForNewRun()
        Sentry.initializeSentry()
        Task.detached(priority: .userInitiated) { NVIDIAFont.prepare() }
        Log.info(.app, "PixelNOW application initializing")
        let container = Self.makeModelContainer()
        sharedModelContainer = container
        CatalogImageCache.shared.configure(container: container)
        Log.info(.app, "PixelNOW application initialization completed")
    }

    private static func makeModelContainer() -> ModelContainer {
        let schema = Schema([
            LoginAccount.self,
            LoginSession.self,
            LoginDeviceRegistration.self,
            CatalogImageCacheEntry.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            let container = try ModelContainer(for: schema, configurations: [modelConfiguration])
            Log.info(.app, "SwiftData model container created")
            return container
        } catch {
            Log.error(.app, "SwiftData container open failed: \(error.localizedDescription). Resetting the local login store after the userId unique-key migration.")
            removeStoreFiles(at: modelConfiguration.url)
            do {
                let container = try ModelContainer(for: schema, configurations: [modelConfiguration])
                Log.warning(.app, "SwiftData store was reset; remembered NVIDIA sessions will be rebuilt from the token vault if present.")
                return container
            } catch {
                Log.fatal(.app, "Could not create SwiftData model container: \(error.localizedDescription)")
                fatalError("Could not create ModelContainer: \(error)")
            }
        }
    }

    private static func removeStoreFiles(at url: URL) {
        let fileManager = FileManager.default
        let directory = url.deletingLastPathComponent()
        let prefix = url.deletingPathExtension().lastPathComponent
        guard let items = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            try? fileManager.removeItem(at: url)
            return
        }
        for item in items where item.lastPathComponent.hasPrefix(prefix) {
            try? fileManager.removeItem(at: item)
        }
    }

    var body: some Scene {
        Window("PixelNOW", id: "main") {
            ContentView()
        }
        .defaultSize(width: 1100, height: 720)
        .modelContainer(sharedModelContainer)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button("Check for Updates...") {
                    AppDelegate.requestApplicationUpdateCheck()
                }
            }
            CommandMenu("Stream") {
                Button("Toggle Microphone") {
                    AppDelegate.sendActiveStreamCommand(.toggleMicrophone)
                }
                .keyboardShortcut("m", modifiers: .command)
                Button("Toggle Recording") {
                    AppDelegate.sendActiveStreamCommand(.toggleRecording)
                }
                .keyboardShortcut("r", modifiers: .command)
                Button("Toggle Anti-AFK") {
                    AppDelegate.sendActiveStreamCommand(.toggleAntiAFK)
                }
                .keyboardShortcut("k", modifiers: .command)
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let githubUpdater = GitHubUpdater(owner: "Interlaced-Pixel", repository: "PixelNOW-Mac")
    private var applicationUpdateCheckTimer: Timer?
    private var updateCheckTask: Task<Void, Never>?
    private var updateInstallTask: Task<Void, Never>?
    private var updateProgressController: UpdateProgressController?
    private var streamShortcutMonitor: Any?
    private var isCompletingUserApprovedTermination = false

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        Log.info(.shortcut, "application(openFile:) received: \(filename)")
        postOpenedFile(URL(fileURLWithPath: filename))
        return true
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        Log.info(.shortcut, "application(openFiles:) received \(filenames.count) file(s)")
        for filename in filenames {
            postOpenedFile(URL(fileURLWithPath: filename))
        }
        sender.reply(toOpenOrPrint: .success)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.info(.app, "NSApplication did finish launching")
        installStreamShortcutMonitor()
        startApplicationUpdateChecks()
    }

    func applicationWillTerminate(_ notification: Notification) {
        Log.info(.app, "NSApplication will terminate")
        NativeNVSTMediaStreamLifecycle.drainForTermination()
        for window in NSApp.windows where window.isVisible && !window.styleMask.contains(.fullScreen) {
            window.saveFrame(usingName: "PixelNOWMainWindow")
        }
        removeStreamShortcutMonitor()
        stopApplicationUpdateChecks()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        Log.info(.app, "Application will terminate after last window closes")
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if isCompletingUserApprovedTermination {
            Log.info(.app, "Completing user-approved application termination")
            return .terminateNow
        }
        guard hasActiveStream else {
            Log.info(.app, "Application termination allowed with no active stream")
            return .terminateNow
        }
        Log.warning(.app, "Application termination requested while a stream is active")
        guard requestActiveStreamQuitDecision(completion: { [weak self, sender] shouldTerminateApplication in
            if shouldTerminateApplication {
                self?.isCompletingUserApprovedTermination = true
                Log.info(.app, "User approved application termination with active stream")
            } else {
                Log.info(.app, "User cancelled application termination with active stream")
            }
            sender.reply(toApplicationShouldTerminate: shouldTerminateApplication)
        }) else {
            Log.warning(.app, "Active stream quit decision unavailable; allowing termination")
            return .terminateNow
        }
        return .terminateLater
    }

    private func postOpenedFile(_ url: URL) {
        Task { @MainActor in
            FileOpenCoordinator.shared.enqueue(url)
        }
    }

    private func installStreamShortcutMonitor() {
        guard streamShortcutMonitor == nil else { return }
        streamShortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, NSApplication.shared.isActive, self.hasActiveStream else { return event }
            guard let command = Self.streamCommand(for: event) else { return event }
            guard self.dispatchActiveStreamCommand(command) else { return event }
            return nil
        }
    }

    private func removeStreamShortcutMonitor() {
        guard let streamShortcutMonitor else { return }
        NSEvent.removeMonitor(streamShortcutMonitor)
        self.streamShortcutMonitor = nil
    }

    private var hasActiveStream: Bool {
        NativeNVSTMediaStreamLifecycle.hasActiveStream
    }

    enum ActiveStreamShortcutCommand {
        case toggleMicrophone
        case toggleRecording
        case toggleAntiAFK
    }

    static func sendActiveStreamCommand(_ command: ActiveStreamShortcutCommand) -> Bool {
        guard let delegate = NSApp.delegate as? AppDelegate else { return false }
        return delegate.dispatchActiveStreamCommand(command)
    }

    private func dispatchActiveStreamCommand(_ command: ActiveStreamShortcutCommand) -> Bool {
        if NativeNVSTMediaStreamLifecycle.hasActiveStream {
            return NativeNVSTMediaStreamLifecycle.sendCommand(nvstCommand(for: command))
        }
        return false
    }

    private func requestActiveStreamQuitDecision(completion: @escaping NativeNVSTMediaStreamQuitDecisionHandler) -> Bool {
        if NativeNVSTMediaStreamLifecycle.hasActiveStream {
            return NativeNVSTMediaStreamLifecycle.requestApplicationQuitDecision(completion: completion)
        }
        return false
    }

    private func nvstCommand(for command: ActiveStreamShortcutCommand) -> NativeNVSTMediaStreamCommand {
        switch command {
        case .toggleMicrophone: return .toggleMicrophone
        case .toggleRecording: return .toggleRecording
        case .toggleAntiAFK: return .toggleAntiAFK
        }
    }

    private static func streamCommand(for event: NSEvent) -> ActiveStreamShortcutCommand? {
        if let command = NativeNVSTMediaStreamCommand.shortcutCommand(keyCode: UInt16(event.keyCode), modifierFlags: event.modifierFlags) {
            switch command {
            case .toggleMicrophone: return .toggleMicrophone
            case .toggleRecording: return .toggleRecording
            case .toggleAntiAFK: return .toggleAntiAFK
            default: return nil
            }
        }
        return nil
    }

    static func requestApplicationUpdateCheck() {
        (NSApp.delegate as? AppDelegate)?.checkForApplicationUpdates()
    }

    static func setAutomaticApplicationUpdateChecksEnabled(_ enabled: Bool) {
        UpdatePreferences.automaticUpdateChecksEnabled = enabled
        (NSApp.delegate as? AppDelegate)?.refreshApplicationUpdateCheckSchedule()
    }

    private func startApplicationUpdateChecks() {
        guard UpdatePreferences.automaticUpdateChecksCanBeScheduled else { return }
        guard applicationUpdateCheckTimer == nil else { return }
        checkForApplicationUpdates(showingCurrentStatus: false, automatic: true)
        applicationUpdateCheckTimer = Timer.scheduledTimer(timeInterval: 60 * 60, target: self, selector: #selector(applicationUpdateCheckTimerFired(_:)), userInfo: nil, repeats: true)
    }

    @objc private func applicationUpdateCheckTimerFired(_ timer: Timer) {
        checkForApplicationUpdates(showingCurrentStatus: false, automatic: true)
    }

    private func stopApplicationUpdateChecks() {
        stopAutomaticApplicationUpdateChecks(cancelActiveCheck: true)
        updateInstallTask?.cancel()
        updateInstallTask = nil
        updateProgressController?.dismiss()
        updateProgressController = nil
    }

    private func stopAutomaticApplicationUpdateChecks(cancelActiveCheck: Bool) {
        applicationUpdateCheckTimer?.invalidate()
        applicationUpdateCheckTimer = nil
        if cancelActiveCheck {
            updateCheckTask?.cancel()
            updateCheckTask = nil
        }
    }

    private func refreshApplicationUpdateCheckSchedule() {
        guard UpdatePreferences.automaticUpdateChecksCanBeScheduled else {
            stopAutomaticApplicationUpdateChecks(cancelActiveCheck: true)
            return
        }
        startApplicationUpdateChecks()
    }

    private func checkForApplicationUpdates() {
        checkForApplicationUpdates(showingCurrentStatus: true, automatic: false)
    }

    private func checkForApplicationUpdates(showingCurrentStatus: Bool, automatic: Bool) {
        if automatic, !UpdatePreferences.shouldRunAutomaticUpdateCheck() { return }
        guard updateCheckTask == nil, updateInstallTask == nil else { return }
        updateCheckTask = Task { @MainActor in
            defer { updateCheckTask = nil }
            do {
                let release = try await githubUpdater.checkForUpdate()
                guard let release else {
                    if showingCurrentStatus {
                        let currentVersion = githubUpdater.currentVersion
                        let alert = NSAlert()
                        alert.messageText = "PixelNOW is up to date"
                        alert.informativeText = "Version \(currentVersion) is the latest release available on GitHub."
                        alert.addButton(withTitle: "OK")
                        presentAlert(alert)
                    }
                    return
                }
                presentUpdateAlert(for: release)
            } catch is CancellationError {
            } catch {
                guard showingCurrentStatus else { return }
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Update check failed"
                alert.informativeText = error.localizedDescription
                alert.addButton(withTitle: "OK")
                presentAlert(alert)
            }
        }
    }

    private func presentUpdateAlert(for release: GitHubRelease) {
        updateInstallTask?.cancel()
        Task { @MainActor [weak self] in
            guard let self else { return }
            let currentVersion = githubUpdater.currentVersion
            var notes = release.releaseNotes.isEmpty ? "No release notes were provided." : release.releaseNotes
            if notes.count > 1400 {
                notes = String(notes.prefix(1400)) + "\n..."
            }

            let alert = NSAlert()
            alert.messageText = "PixelNOW \(release.version) is available"
            alert.informativeText = "Current version: \(currentVersion)\n\nA newer signed PixelNOW build is available.\n\n\(notes)"
            alert.addButton(withTitle: "Install and Relaunch")
            alert.addButton(withTitle: "Remind Me Tomorrow")
            alert.addButton(withTitle: "Cancel")
            presentAlert(alert) { [weak self] response in
                switch response {
                case .alertFirstButtonReturn:
                    self?.installUpdate(release)
                case .alertSecondButtonReturn:
                    UpdatePreferences.remindTomorrow()
                default:
                    break
                }
            }
        }
    }

    private func installUpdate(_ release: GitHubRelease) {
        guard updateInstallTask == nil else { return }

        let controller = UpdateProgressController()
        updateProgressController = controller

        controller.show(release: release) { [weak self] in
            self?.updateInstallTask?.cancel()
            self?.updateInstallTask = nil
            self?.updateProgressController = nil
        }

        updateInstallTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { updateInstallTask = nil }
            do {
                let launchedInstaller = try await githubUpdater.installRelease(release) { [weak controller] state in
                    Task { @MainActor in
                        controller?.updateProgress(state)
                    }
                }
                guard launchedInstaller else {
                    controller.showError("PixelNOW could not launch the update installer.")
                    return
                }
                try? await Task.sleep(nanoseconds: 600_000_000)
                NSApp.terminate(self)
            } catch is CancellationError {
                controller.dismiss()
                self.updateProgressController = nil
            } catch {
                controller.showError(error.localizedDescription.isEmpty ? "PixelNOW could not install the downloaded update." : error.localizedDescription)
            }
        }
    }

    private func showUpdateInstallFailed(message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Update install failed"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        presentAlert(alert)
    }

    private func presentAlert(_ alert: NSAlert, completion: ((NSApplication.ModalResponse) -> Void)? = nil) {
        if let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible }) {
            alert.beginSheetModal(for: window) { response in
                completion?(response)
            }
        } else {
            let response = alert.runModal()
            completion?(response)
        }
    }
}
