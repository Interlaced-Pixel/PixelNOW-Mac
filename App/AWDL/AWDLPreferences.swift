import Foundation

enum AWDLPreferences {
    static let enabledKey = "PixelNOWAWDLControlEnabled"
    static let didChangeNotification = Notification.Name("PixelNOWAWDLControlPreferenceDidChange")

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    static func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: enabledKey)
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }
}
