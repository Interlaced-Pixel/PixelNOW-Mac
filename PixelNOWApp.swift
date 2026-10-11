import AppKit
import Sparkle
import SwiftUI
import SwiftData

enum UpdatePreferences {
    static let legacyAutomaticUpdateChecksEnabledKey = "PixelNOWAutomaticUpdateChecksEnabled"

    static var automaticUpdateChecksAreSuspendedForDebugging: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }
}

@main
struct PixelNOWApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    let sharedModelContainer: ModelContainer

    init() {
        AppPreferenceStorage.standard.synchronize()
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
                    _ = AppDelegate.sendActiveStreamCommand(.toggleMicrophone)
                }
                .keyboardShortcut("m", modifiers: .command)
                Button("Toggle Recording") {
                    _ = AppDelegate.sendActiveStreamCommand(.toggleRecording)
                }
                .keyboardShortcut("r", modifiers: .command)
                Button("Toggle Anti-AFK") {
                    _ = AppDelegate.sendActiveStreamCommand(.toggleAntiAFK)
                }
                .keyboardShortcut("k", modifiers: .command)
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let awdlController = AWDLController()
    private lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: false,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )
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
        awdlController.start()
        installStreamShortcutMonitor()
        startApplicationUpdateChecks()
    }

    func applicationWillTerminate(_ notification: Notification) {
        Log.info(.app, "NSApplication will terminate")
        awdlController.stop()
        NativeNVSTMediaStreamLifecycle.drainForTermination()
        for window in NSApp.windows where window.isVisible && !window.styleMask.contains(.fullScreen) {
            window.saveFrame(usingName: "PixelNOWMainWindow")
        }
        removeStreamShortcutMonitor()
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
        (NSApp.delegate as? AppDelegate)?.updaterController.checkForUpdates(nil)
    }

    static func setAutomaticApplicationUpdateChecksEnabled(_ enabled: Bool) {
        (NSApp.delegate as? AppDelegate)?.updaterController.updater.automaticallyChecksForUpdates = enabled
    }

    static var automaticApplicationUpdateChecksEnabled: Bool {
        (NSApp.delegate as? AppDelegate)?.updaterController.updater.automaticallyChecksForUpdates ?? false
    }

    private func startApplicationUpdateChecks() {
        migrateLegacyUpdatePreferenceIfNeeded()
#if DEBUG
        updaterController.updater.automaticallyChecksForUpdates = false
#endif
        updaterController.startUpdater()
    }

    private func migrateLegacyUpdatePreferenceIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: UpdatePreferences.legacyAutomaticUpdateChecksEnabledKey) != nil else { return }
        updaterController.updater.automaticallyChecksForUpdates = defaults.bool(forKey: UpdatePreferences.legacyAutomaticUpdateChecksEnabledKey)
        defaults.removeObject(forKey: UpdatePreferences.legacyAutomaticUpdateChecksEnabledKey)
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
