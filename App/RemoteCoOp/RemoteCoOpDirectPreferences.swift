import Foundation

public struct RemoteCoOpDirectPreferences: Codable, Equatable, Sendable {
    public var connectionMode: RemoteCoOpDirectConnectionMode
    public var enableUPnP: Bool
    public var enableBonjour: Bool
    public var pinAttempts: Int
    public var pinExpiration: TimeInterval
    public var signalingPort: UInt16
    
    public init(connectionMode: RemoteCoOpDirectConnectionMode = .autoDiscover,
                enableUPnP: Bool = true,
                enableBonjour: Bool = true,
                pinAttempts: Int = 3,
                pinExpiration: TimeInterval = 300,
                signalingPort: UInt16 = 32189) {
        self.connectionMode = connectionMode
        self.enableUPnP = enableUPnP
        self.enableBonjour = enableBonjour
        self.pinAttempts = pinAttempts
        self.pinExpiration = pinExpiration
        self.signalingPort = signalingPort
    }
}

public enum RemoteCoOpDirectConnectionMode: String, CaseIterable, Codable, Equatable, Sendable {
    case autoDiscover
    case directOnly
    case stunOnly
    
    public var label: String {
        switch self {
        case .autoDiscover: return "Auto Discover"
        case .directOnly: return "Direct Only"
        case .stunOnly: return "STUN Only"
        }
    }
}

public enum RemoteCoOpDirectPreferencesStore {
    private static let storage = AppPreferenceStorage.standard
    private static let connectionModeKey = "PixelNOW.RemoteCoOp.Direct.ConnectionMode"
    private static let enableUPnPKey = "PixelNOW.RemoteCoOp.Direct.EnableUPnP"
    private static let enableBonjourKey = "PixelNOW.RemoteCoOp.Direct.EnableBonjour"
    private static let pinAttemptsKey = "PixelNOW.RemoteCoOp.Direct.PinAttempts"
    private static let pinExpirationKey = "PixelNOW.RemoteCoOp.Direct.PinExpiration"
    private static let signalingPortKey = "PixelNOW.RemoteCoOp.Direct.SignalingPort"
    
    public static func load() -> RemoteCoOpDirectPreferences {
        RemoteCoOpDirectPreferences(
            connectionMode: RemoteCoOpDirectConnectionMode(rawValue: string(storage.object(forKey: connectionModeKey), defaultValue: "")) ?? .autoDiscover,
            enableUPnP: bool(storage.object(forKey: enableUPnPKey), defaultValue: true),
            enableBonjour: bool(storage.object(forKey: enableBonjourKey), defaultValue: true),
            pinAttempts: int(storage.object(forKey: pinAttemptsKey), defaultValue: 3),
            pinExpiration: double(storage.object(forKey: pinExpirationKey), defaultValue: 300),
            signalingPort: uint16(storage.object(forKey: signalingPortKey), defaultValue: 32189)
        )
    }
    
    public static func save(_ preferences: RemoteCoOpDirectPreferences) {
        storage.set(preferences.connectionMode.rawValue, forKey: connectionModeKey)
        storage.set(preferences.enableUPnP, forKey: enableUPnPKey)
        storage.set(preferences.enableBonjour, forKey: enableBonjourKey)
        storage.set(preferences.pinAttempts, forKey: pinAttemptsKey)
        storage.set(preferences.pinExpiration, forKey: pinExpirationKey)
        storage.set(preferences.signalingPort, forKey: signalingPortKey)
        storage.synchronize()
    }
    
    private static func string(_ value: Any?, defaultValue: String) -> String {
        if let value = value as? String { return value }
        if let value = value as? NSString { return value as String }
        if let value = value as? NSNumber { return value.stringValue }
        return defaultValue
    }
    
    private static func int(_ value: Any?, defaultValue: Int) -> Int {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String, let parsed = Int(value) { return parsed }
        return defaultValue
    }
    
    private static func double(_ value: Any?, defaultValue: Double) -> Double {
        if let value = value as? Double { return value }
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String, let parsed = Double(value) { return parsed }
        return defaultValue
    }
    
    private static func uint16(_ value: Any?, defaultValue: UInt16) -> UInt16 {
        if let value = value as? UInt16 { return value }
        if let value = value as? NSNumber { return UInt16(value.uintValue) }
        return defaultValue
    }
    
    private static func bool(_ value: Any?, defaultValue: Bool) -> Bool {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        if let value = value as? String {
            return value == "1" || value.caseInsensitiveCompare("true") == .orderedSame || value.caseInsensitiveCompare("yes") == .orderedSame
        }
        return defaultValue
    }
}
