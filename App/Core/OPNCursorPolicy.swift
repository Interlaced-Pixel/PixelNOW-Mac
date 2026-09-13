import Foundation

@objc public enum OPNCursorPolicy: Int, CaseIterable, Sendable {
    case auto = 0
    case local = 1
    case stream = 2

    public var label: String {
        switch self {
        case .auto: return "Auto"
        case .local: return "Local"
        case .stream: return "Stream"
        }
    }

    public static func from(_ rawValue: Int) -> OPNCursorPolicy {
        OPNCursorPolicy(rawValue: rawValue) ?? .auto
    }
}
