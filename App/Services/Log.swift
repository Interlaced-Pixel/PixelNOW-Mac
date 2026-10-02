import Foundation
import OSLog

enum Log {
    enum Category: String {
        case app = "App"
        case auth = "Auth"
        case cache = "Cache"
        case catalog = "Catalog"
        case launch = "Launch"
        case shortcut = "GFNShortcut"
        case stream = "WebRTC"
    }

    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.interlacedpixel.pixelnow"

    static func debug(_ category: Category, _ message: String) {
        Logger(subsystem: subsystem, category: category.rawValue).debug("\(sanitizedMessage(message), privacy: .public)")
    }

    static func info(_ category: Category, _ message: String) {
        Logger(subsystem: subsystem, category: category.rawValue).info("\(sanitizedMessage(message), privacy: .public)")
    }

    static func warning(_ category: Category, _ message: String) {
        Logger(subsystem: subsystem, category: category.rawValue).warning("\(sanitizedMessage(message), privacy: .public)")
    }

    static func error(_ category: Category, _ message: String) {
        Logger(subsystem: subsystem, category: category.rawValue).error("\(sanitizedMessage(message), privacy: .public)")
    }

    static func fatal(_ category: Category, _ message: String) {
        Logger(subsystem: subsystem, category: category.rawValue).fault("\(sanitizedMessage(message), privacy: .public)")
    }

    static func sanitizedMessage(_ message: String) -> String {
        message
            .replacingOccurrences(of: #"\b(?:\d{1,3}\.){3}\d{1,3}\b"#, with: "[redacted-ip]", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)\b(?:[0-9a-f]{1,4}:){2,}[0-9a-f:]*\b"#, with: "[redacted-ip]", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)\bbearer\s+[^\s\"',;]+"#, with: "Bearer [redacted-secret]", options: .regularExpression)
    }
}

@MainActor
final class FileOpenCoordinator {
    static let shared = FileOpenCoordinator()

    private var pendingFileURLs: [URL] = []

    private init() {}

    func enqueue(_ url: URL) {
        pendingFileURLs.append(url)
        Log.info(.shortcut, "Queued opened file: \(url.path)")
        NotificationCenter.default.post(name: .didOpenFile, object: url)
    }

    func drainPendingFileURLs() -> [URL] {
        let urls = pendingFileURLs
        pendingFileURLs.removeAll()
        if !urls.isEmpty {
            Log.info(.shortcut, "Draining \(urls.count) pending opened file(s)")
        }
        return urls
    }
}
