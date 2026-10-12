import AppKit
import Combine
import Foundation
import Sparkle

@MainActor
final class UpdateCenter: NSObject, ObservableObject, SPUUpdaterDelegate {
    static let shared = UpdateCenter()

    enum Status: Equatable {
        case ready
        case checking
        case updateAvailable(String)
        case upToDate
        case downloading(String)
        case downloaded(String)
        case installing(String)
        case failed(String)

        var title: String {
            switch self {
            case .ready: "Ready to check"
            case .checking: "Checking for updates…"
            case .updateAvailable(let version): "Version \(version) is available"
            case .upToDate: "PixelNOW is up to date"
            case .downloading(let version): "Downloading version \(version)…"
            case .downloaded(let version): "Version \(version) downloaded"
            case .installing(let version): "Installing version \(version)…"
            case .failed: "Update check failed"
            }
        }

        var symbol: String {
            switch self {
            case .ready, .upToDate: "checkmark.circle"
            case .checking, .downloading, .installing: "arrow.triangle.2.circlepath"
            case .updateAvailable, .downloaded: "arrow.down.circle"
            case .failed: "exclamationmark.triangle"
            }
        }

        var isWorking: Bool {
            switch self {
            case .checking, .downloading, .installing: true
            default: false
            }
        }
    }

    @Published private(set) var status: Status = .ready
    @Published private(set) var lastNotice = "Updates are delivered through Sparkle's signed release feed."
    @Published private(set) var lastCheckedAt: Date?
    @Published private(set) var automaticChecksEnabled = false

    private lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: false,
        updaterDelegate: self,
        userDriverDelegate: nil
    )
    private var didStart = false

    private override init() {}

    func start() {
        guard !didStart else { return }
        didStart = true
        migrateLegacyPreferenceIfNeeded()
        #if DEBUG
        updaterController.updater.automaticallyChecksForUpdates = false
        #endif
        automaticChecksEnabled = updaterController.updater.automaticallyChecksForUpdates
        updaterController.startUpdater()
    }

    func checkForUpdates() {
        start()
        status = .checking
        lastNotice = "Contacting the PixelNOW release feed."
        updaterController.checkForUpdates(nil)
    }

    func setAutomaticChecksEnabled(_ enabled: Bool) {
        start()
        updaterController.updater.automaticallyChecksForUpdates = enabled
        automaticChecksEnabled = updaterController.updater.automaticallyChecksForUpdates
        lastNotice = enabled
            ? "Automatic update checks are enabled."
            : "Automatic update checks are disabled."
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        status = .updateAvailable(version)
        lastNotice = "Sparkle found version \(version). Review the update prompt to install it."
        lastCheckedAt = Date()
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        status = .upToDate
        lastNotice = "No newer compatible release was found."
        lastCheckedAt = Date()
    }

    func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with request: NSMutableURLRequest) {
        let version = item.displayVersionString
        status = .downloading(version)
        lastNotice = "Downloading the signed PixelNOW update."
    }

    func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        status = .downloaded(version)
        lastNotice = "Version \(version) is downloaded and ready for installation."
    }

    func userDidCancelDownload(_ updater: SPUUpdater) {
        status = .ready
        lastNotice = "The update download was canceled. You can check again at any time."
    }

    func updater(_ updater: SPUUpdater, failedToDownloadUpdate item: SUAppcastItem, error: any Error) {
        let detail = error.localizedDescription
        status = .failed(detail)
        lastNotice = "The update download failed: \(detail)"
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        status = .installing(version)
        lastNotice = "PixelNOW will restart to finish installing version \(version)."
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        let detail = error.localizedDescription
        status = .failed(detail)
        lastNotice = "Sparkle could not complete the update: \(detail)"
        lastCheckedAt = Date()
    }

    private func migrateLegacyPreferenceIfNeeded() {
        let defaults = UserDefaults.standard
        let key = UpdatePreferences.legacyAutomaticUpdateChecksEnabledKey
        guard defaults.object(forKey: key) != nil else { return }
        updaterController.updater.automaticallyChecksForUpdates = defaults.bool(forKey: key)
        defaults.removeObject(forKey: key)
    }
}
