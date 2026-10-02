import Foundation

public enum NativeNVSTMediaLogLevel: String, Sendable {
    case debug
    case info
    case warning
    case error
}

public enum NativeNVSTMediaLog {
    public static func write(_ name: String, level: NativeNVSTMediaLogLevel, message: String, attributes: [String: String] = [:]) {
        let suffix = attributes.isEmpty ? "" : " " + attributes.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " ")
        let text = "\(name): \(message)\(suffix)"
        switch level {
        case .debug: Log.debug(.stream, text)
        case .info: Log.info(.stream, text)
        case .warning: Log.warning(.stream, text)
        case .error: Log.error(.stream, text)
        }
    }
}
