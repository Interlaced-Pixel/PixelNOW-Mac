import AppKit
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

    let sharedModelContainer: ModelContainer?

    init() {
        AppPreferenceStorage.standard.synchronize()
        Task.detached(priority: .userInitiated) { NVIDIAFont.prepare() }
        Log.info(.app, "PixelNOW application initializing")
        let container = Self.makeModelContainer()
        sharedModelContainer = container
        if let container { CatalogImageCache.shared.configure(container: container) }
        Log.info(.app, "PixelNOW application initialization completed")
    }

    private static func makeModelContainer() -> ModelContainer? {
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
            Log.error(.app, "SwiftData persistent container unavailable: \(error.localizedDescription). Falling back to in-memory storage; local account and cache data remain untouched.")
            let inMemoryConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            do {
                let container = try ModelContainer(for: schema, configurations: [inMemoryConfiguration])
                Log.warning(.app, "SwiftData is using in-memory storage for this session")
                return container
            } catch {
                Log.fatal(.app, "Could not create in-memory SwiftData container: \(error.localizedDescription)")
                return nil
            }
        }
    }

    var body: some Scene {
        Window("PixelNOW", id: "main") {
            if let sharedModelContainer {
                ContentView()
                    .modelContainer(sharedModelContainer)
            } else {
                PersistenceUnavailableView()
            }
        }
        .defaultSize(width: 1100, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button("Check for Updates...") {
                    UpdateCenter.shared.checkForUpdates()
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

private struct PersistenceUnavailableView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("PixelNOW could not open local storage")
                .font(.title3.weight(.semibold))
            Text("Your saved accounts and cache were left untouched. Restart PixelNOW after resolving the storage issue.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
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
        UpdateCenter.shared.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        Log.info(.app, "NSApplication will terminate")
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
