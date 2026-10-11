import Foundation

public enum NativeNVSTMediaLogLevel: String, Sendable {
    case debug
    case info
    case warning
    case error
}

public enum NativeNVSTMediaLog {
    private final class Sink: @unchecked Sendable {
        let lock = NSLock()
        var log: NvstDiagnosticLog?
    }

    private static let sink = Sink()

    @discardableResult
    public static func beginSessionLog() -> NvstDiagnosticLog {
        let log = NvstDiagnosticLog()
        sink.lock.lock()
        sink.log = log
        sink.lock.unlock()
        return log
    }

    public static func currentLogText(maximumLines: Int = 180) -> String {
        sink.lock.lock()
        let url = sink.log?.url
        sink.lock.unlock()
        guard let url else { return "" }
        return NvstDiagnosticLog.readTail(from: url, maximumLines: maximumLines)
    }

    public static func write(_ name: String, level: NativeNVSTMediaLogLevel, message: String, attributes: [String: String] = [:]) {
        let suffix = attributes.isEmpty ? "" : " " + attributes.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " ")
        let text = "\(name): \(message)\(suffix)"
        sink.lock.lock()
        let log = sink.log
        sink.lock.unlock()
        log?.append(text)
        switch level {
        case .debug: Log.debug(.stream, text)
        case .info: Log.info(.stream, text)
        case .warning: Log.warning(.stream, text)
        case .error: Log.error(.stream, text)
        }
    }
}
