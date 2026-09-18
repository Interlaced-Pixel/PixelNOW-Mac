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

    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.interlaced-pixel.PixelNOW"

    private static let logFileURL: URL? = {
        let fileManager = FileManager.default
        let projectDir = "/Users/jayian/Projects/PixelNOW"
        let logsDir = URL(fileURLWithPath: projectDir).appendingPathComponent("logs")
        if !fileManager.fileExists(atPath: logsDir.path) {
            try? fileManager.createDirectory(at: logsDir, withIntermediateDirectories: true)
        }
        return logsDir.appendingPathComponent("PixelNOW.log")
    }()

    private static func writeToFile(level: String, category: Category, message: String) {
        guard let url = logFileURL else { return }
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let logLine = "[\(timestamp)] [\(level.uppercased())] [\(category.rawValue)] \(message)\n"
        guard let data = logLine.data(using: .utf8) else { return }
        
        if FileManager.default.fileExists(atPath: url.path) {
            if let fileHandle = try? FileHandle(forWritingTo: url) {
                fileHandle.seekToEndOfFile()
                fileHandle.write(data)
                fileHandle.closeFile()
            }
        } else {
            try? data.write(to: url)
        }
    }

    public static func recentLogText(maxBytes: Int = 512 * 1024) -> String {
        guard let url = logFileURL,
              let fileHandle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? fileHandle.close() }
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        if fileSize <= maxBytes {
            guard let data = try? fileHandle.readToEnd() else { return "" }
            return String(decoding: data, as: UTF8.self)
        } else {
            _ = try? fileHandle.seek(toOffset: UInt64(max(0, fileSize - maxBytes)))
            guard let data = try? fileHandle.readToEnd() else { return "" }
            var text = String(decoding: data, as: UTF8.self)
            if let firstNewline = text.firstIndex(of: "\n") {
                text.removeSubrange(text.startIndex...firstNewline)
            }
            return text
        }
    }

    static func debug(_ category: Category, _ message: String) {
        let sanitized = Sentry.sanitizedLogMessage(message)
        Logger(subsystem: subsystem, category: category.rawValue).debug("\(sanitized, privacy: .public)")
        Sentry.logDebugMessage(formattedMessage(category: category, level: "debug", message: message))
        writeToFile(level: "debug", category: category, message: message)
    }

    static func info(_ category: Category, _ message: String) {
        let sanitized = Sentry.sanitizedLogMessage(message)
        Logger(subsystem: subsystem, category: category.rawValue).info("\(sanitized, privacy: .public)")
        Sentry.logInfoMessage(formattedMessage(category: category, level: "info", message: message))
        writeToFile(level: "info", category: category, message: message)
    }

    static func warning(_ category: Category, _ message: String) {
        let sanitized = Sentry.sanitizedLogMessage(message)
        Logger(subsystem: subsystem, category: category.rawValue).warning("\(sanitized, privacy: .public)")
        Sentry.logWarningMessage(formattedMessage(category: category, level: "warning", message: message))
        writeToFile(level: "warning", category: category, message: message)
    }

    static func error(_ category: Category, _ message: String) {
        let sanitized = Sentry.sanitizedLogMessage(message)
        Logger(subsystem: subsystem, category: category.rawValue).error("\(sanitized, privacy: .public)")
        Sentry.logErrorMessage(formattedMessage(category: category, level: "error", message: message))
        writeToFile(level: "error", category: category, message: message)
    }

    static func fatal(_ category: Category, _ message: String) {
        let sanitized = Sentry.sanitizedLogMessage(message)
        Logger(subsystem: subsystem, category: category.rawValue).fault("\(sanitized, privacy: .public)")
        Sentry.logFatalMessage(formattedMessage(category: category, level: "fatal", message: message))
        writeToFile(level: "fatal", category: category, message: message)
    }

    private static func formattedMessage(category: Category, level: String, message: String) -> String {
        Sentry.formattedLogMessage(level: level, area: category.rawValue, message: message)
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
