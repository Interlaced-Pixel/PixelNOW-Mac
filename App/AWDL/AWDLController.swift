import AppKit
import Foundation
import ServiceManagement

@objc private protocol PixelNOWAWDLHelperProtocol {
    func checkIn(withReply reply: @escaping (Bool) -> Void)
    func setAWDLEnabled(_ enabled: Bool, withReply reply: @escaping (Bool) -> Void)
}

@MainActor
final class AWDLController {
    private let helperService = SMAppService.daemon(plistName: "com.interlacedpixel.pixelnow.AWDLHelper.plist")
    private var helperConnection: NSXPCConnection?
    private var reconnectTimer: Timer?
    private var observerTokens: [NSObjectProtocol] = []
    private var isStopping = false
    private var hasCheckedIn = false

    func start() {
        guard !isStopping else { return }
        observerTokens = [
            NotificationCenter.default.addObserver(forName: NativeNVSTMediaStreamLifecycle.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.reevaluate() }
            },
            NotificationCenter.default.addObserver(forName: AWDLPreferences.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.reevaluate() }
            }
        ]
        reevaluate()
    }

    func stop() {
        guard !isStopping else { return }
        isStopping = true
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        removeObservers()
        disconnectAndRestore()
    }

    private func reevaluate() {
        guard !isStopping else { return }
        if AWDLPreferences.isEnabled && NativeNVSTMediaStreamLifecycle.hasActiveStream {
            registerAndConnect()
        } else {
            disconnectAndRestore()
        }
    }

    private func disconnectAndRestore() {
        guard let helperConnection else {
            hasCheckedIn = false
            return
        }
        let proxy = helperConnection.remoteObjectProxyWithErrorHandler { error in
            Log.warning(.app, "AWDL helper restore request failed: \(error.localizedDescription)")
        } as? PixelNOWAWDLHelperProtocol
        proxy?.setAWDLEnabled(true, withReply: Self.handleRestoreReply)
        helperConnection.invalidate()
        self.helperConnection = nil
        hasCheckedIn = false
    }

    nonisolated private static func handleRestoreReply(_ accepted: Bool) {
        guard !accepted else { return }
        Task { @MainActor in
            Log.warning(.app, "AWDL helper rejected restore request")
        }
    }

    private func registerAndConnect() {
        switch helperService.status {
        case .enabled:
            connect()
        case .requiresApproval:
            Log.warning(.app, "AWDL helper requires approval in System Settings Login Items")
            scheduleReconnect()
        case .notRegistered, .notFound:
            do {
                try helperService.register()
                connect()
            } catch {
                Log.error(.app, "Could not register AWDL helper: \(error.localizedDescription)")
                scheduleReconnect()
            }
        @unknown default:
            Log.warning(.app, "AWDL helper returned an unknown Service Management status")
            scheduleReconnect()
        }
    }

    private func connect() {
        guard helperConnection == nil else { return }

        let connection = NSXPCConnection(machServiceName: "com.interlacedpixel.pixelnow.AWDLHelper", options: [])
        connection.remoteObjectInterface = NSXPCInterface(with: PixelNOWAWDLHelperProtocol.self)
        connection.interruptionHandler = { [weak self] in
            Task { @MainActor in
                self?.handleHelperFailure("interrupted")
            }
        }
        connection.invalidationHandler = { [weak self] in
            Task { @MainActor in
                self?.handleHelperFailure("invalidated")
            }
        }
        helperConnection = connection
        hasCheckedIn = false
        connection.resume()

        let proxy = connection.remoteObjectProxyWithErrorHandler { [weak self] error in
            Task { @MainActor in
                self?.handleHelperFailure("request failed: \(error.localizedDescription)")
            }
        } as? PixelNOWAWDLHelperProtocol
        proxy?.checkIn { [weak self] accepted in
            Task { @MainActor in
                guard let self, accepted, self.helperConnection === connection else { return }
                self.hasCheckedIn = true
                self.setAWDLEnabled(false)
            }
        }
    }

    private func setAWDLEnabled(_ enabled: Bool) {
        guard hasCheckedIn, let helperConnection else { return }
        let proxy = helperConnection.remoteObjectProxyWithErrorHandler { error in
            Log.warning(.app, "AWDL helper state request failed: \(error.localizedDescription)")
        } as? PixelNOWAWDLHelperProtocol
        proxy?.setAWDLEnabled(enabled) { accepted in
            if !accepted {
                Log.warning(.app, "AWDL helper rejected state request")
            }
        }
    }

    private func handleHelperFailure(_ reason: String) {
        guard !isStopping else { return }
        Log.warning(.app, "AWDL helper \(reason); retrying")
        helperConnection = nil
        hasCheckedIn = false
        if AWDLPreferences.isEnabled && NativeNVSTMediaStreamLifecycle.hasActiveStream {
            scheduleReconnect()
        }
    }

    private func scheduleReconnect() {
        guard !isStopping, reconnectTimer == nil else { return }
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.reconnectTimer = nil
                self.registerAndConnect()
            }
        }
    }

    private func removeObservers() {
        let notificationCenter = NotificationCenter.default
        for token in observerTokens {
            notificationCenter.removeObserver(token)
        }
        observerTokens.removeAll()
    }
}
