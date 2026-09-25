import Foundation

public struct RemoteCoOpDirectPreferences: Codable, Equatable, Sendable {
    public var connectionMode: RemoteCoOpDirectConnectionMode
    public var enableUPnP: Bool
    public var enableBonjour: Bool
    public var pinAttempts: Int
    public var pinExpiration: Double
    public var signalingPort: UInt16
    public var nvstEnabled: Bool
    public var nvstLocalPort: UInt16
    public var nvstHandoffConfig: RemoteCoOpNVSTHandoffConfig
    
    public var effectiveReservedGuestSlots: Int { 3 }
    public var qualityPreset: RemoteCoOpQualityPreset { .p720f60 }
    public var latencyMode: RemoteCoOpLatencyMode { .lowLatency }
    public var signalingServerURL: String { "wss://localhost:\(signalingPort)/remote-coop-direct" }
    public var guestJoinBaseURL: String { "https://localhost:\(signalingPort)" }
    
    public init(connectionMode: RemoteCoOpDirectConnectionMode = .autoDiscover,
                enableUPnP: Bool = true,
                enableBonjour: Bool = true,
                pinAttempts: Int = 3,
                pinExpiration: Double = 300,
                signalingPort: UInt16 = 32189,
                nvstEnabled: Bool = true,
                nvstLocalPort: UInt16 = 32190,
                nvstHandoffConfig: RemoteCoOpNVSTHandoffConfig = RemoteCoOpNVSTHandoffConfig()) {
        self.connectionMode = connectionMode
        self.enableUPnP = enableUPnP
        self.enableBonjour = enableBonjour
        self.pinAttempts = pinAttempts
        self.pinExpiration = pinExpiration
        self.signalingPort = signalingPort
        self.nvstEnabled = nvstEnabled
        self.nvstLocalPort = nvstLocalPort
        self.nvstHandoffConfig = nvstHandoffConfig
    }
}

public struct RemoteCoOpNVSTHandoffConfig: Codable, Equatable, Sendable {
    public var videoPeerIP: String
    public var videoPeerPort: UInt16
    public var codec: RemoteCoOpNVSTVideoCodec
    public var rtpPayloadType: UInt8
    public var rtpSSRC: UInt32
    public var maxAccessUnitBytes: UInt32
    public var timeoutMilliseconds: UInt32
    public var pingVersion: UInt8
    public var pingPayload: String
    public var iceCredentials: RemoteCoOpNVSTHandoffIceCredentials
    public var srtpProfile: RemoteCoOpNVSTSRTPProfile
    public var srtpAESKey: Data
    public var srtpSalt: Data
    
    public init(videoPeerIP: String = "127.0.0.1",
                videoPeerPort: UInt16 = 32190,
                codec: RemoteCoOpNVSTVideoCodec = .h264,
                rtpPayloadType: UInt8 = 96,
                rtpSSRC: UInt32 = 0,
                maxAccessUnitBytes: UInt32 = 1024,
                timeoutMilliseconds: UInt32 = 5000,
                pingVersion: UInt8 = 6,
                pingPayload: String = "PING",
                iceCredentials: RemoteCoOpNVSTHandoffIceCredentials = RemoteCoOpNVSTHandoffIceCredentials(),
                srtpProfile: RemoteCoOpNVSTSRTPProfile = .aes256Gcm,
                srtpAESKey: Data = Data(repeating: 0xab, count: 32),
                srtpSalt: Data = Data(repeating: 0x9e, count: 12)) {
        self.videoPeerIP = videoPeerIP
        self.videoPeerPort = videoPeerPort
        self.codec = codec
        self.rtpPayloadType = rtpPayloadType
        self.rtpSSRC = rtpSSRC
        self.maxAccessUnitBytes = maxAccessUnitBytes
        self.timeoutMilliseconds = timeoutMilliseconds
        self.pingVersion = pingVersion
        self.pingPayload = pingPayload
        self.iceCredentials = iceCredentials
        self.srtpProfile = srtpProfile
        self.srtpAESKey = srtpAESKey
        self.srtpSalt = srtpSalt
    }
}

public enum RemoteCoOpNVSTVideoCodec: String, Codable, Equatable, Sendable {
    case h264
    case h265
    case av1
}

public enum RemoteCoOpNVSTSRTPProfile: String, Codable, Equatable, Sendable {
    case aes128Gcm = "aead_aes_128_gcm"
    case aes256Gcm = "aead_aes_256_gcm"
}

public struct RemoteCoOpNVSTHandoffIceCredentials: Codable, Equatable, Sendable {
    public var localUsernameFragment: String
    public var localPassword: String
    public var remoteUsernameFragment: String
    public var remotePassword: String
    public var remoteDTLSFingerprint: String
    
    public init(localUsernameFragment: String = "open",
                localPassword: String = "1234567890",
                remoteUsernameFragment: String = "remote",
                remotePassword: String = "0987654321",
                remoteDTLSFingerprint: String = "SHA-256 00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF") {
        self.localUsernameFragment = localUsernameFragment
        self.localPassword = localPassword
        self.remoteUsernameFragment = remoteUsernameFragment
        self.remotePassword = remotePassword
        self.remoteDTLSFingerprint = remoteDTLSFingerprint
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
    private static let nvstEnabledKey = "PixelNOW.RemoteCoOp.Direct.NVSTEnabled"
    private static let nvstLocalPortKey = "PixelNOW.RemoteCoOp.Direct.NVSTLocalPort"
    private static let nvstHandoffVideoPeerIPKey = "PixelNOW.RemoteCoOp.Direct.NVSTHandoff.VideoPeerIP"
    private static let nvstHandoffVideoPeerPortKey = "PixelNOW.RemoteCoOp.Direct.NVSTHandoff.VideoPeerPort"
    private static let nvstHandoffCodecKey = "PixelNOW.RemoteCoOp.Direct.NVSTHandoff.Codec"
    private static let nvstHandoffRTPPayloadTypeKey = "PixelNOW.RemoteCoOp.Direct.NVSTHandoff.RTPPayloadType"
    private static let nvstHandoffRTPSSRCKey = "PixelNOW.RemoteCoOp.Direct.NVSTHandoff.RTPSSRC"
    private static let nvstHandoffMaxAccessUnitKey = "PixelNOW.RemoteCoOp.Direct.NVSTHandoff.MaxAccessUnitBytes"
    private static let nvstHandoffTimeoutMsKey = "PixelNOW.RemoteCoOp.Direct.NVSTHandoff.TimeoutMilliseconds"
    private static let nvstHandoffPingVersionKey = "PixelNOW.RemoteCoOp.Direct.NVSTHandoff.PingVersion"
    private static let nvstHandoffPingPayloadKey = "PixelNOW.RemoteCoOp.Direct.NVSTHandoff.PingPayload"
    private static let nvstHandoffLocalUserKey = "PixelNOW.RemoteCoOp.Direct.NVSTHandoff.LocalUsernameFragment"
    private static let nvstHandoffLocalPassKey = "PixelNOW.RemoteCoOp.Direct.NVSTHandoff.LocalPassword"
    private static let nvstHandoffRemoteUserKey = "PixelNOW.RemoteCoOp.Direct.NVSTHandoff.RemoteUsernameFragment"
    private static let nvstHandoffRemotePassKey = "PixelNOW.RemoteCoOp.Direct.NVSTHandoff.RemotePassword"
    private static let nvstHandoffDTLSFingerprintKey = "PixelNOW.RemoteCoOp.Direct.NVSTHandoff.DTLSFingerprint"
    private static let nvstHandoffSRTPProfileKey = "PixelNOW.RemoteCoOp.Direct.NVSTHandoff.SRTPProfile"
    private static let nvstHandoffSRTPKeyKey = "PixelNOW.RemoteCoOp.Direct.NVSTHandoff.SRTPKey"
    private static let nvstHandoffSRTPSaltKey = "PixelNOW.RemoteCoOp.Direct.NVSTHandoff.SRTPSalt"
    
    public static func load() -> RemoteCoOpDirectPreferences {
        RemoteCoOpDirectPreferences(
            connectionMode: RemoteCoOpDirectConnectionMode(rawValue: string(storage.object(forKey: connectionModeKey), defaultValue: "")) ?? .autoDiscover,
            enableUPnP: bool(storage.object(forKey: enableUPnPKey), defaultValue: true),
            enableBonjour: bool(storage.object(forKey: enableBonjourKey), defaultValue: true),
            pinAttempts: int(storage.object(forKey: pinAttemptsKey), defaultValue: 3),
            pinExpiration: double(storage.object(forKey: pinExpirationKey), defaultValue: 300),
            signalingPort: uint16(storage.object(forKey: signalingPortKey), defaultValue: 32189),
            nvstEnabled: bool(storage.object(forKey: nvstEnabledKey), defaultValue: true),
            nvstLocalPort: uint16(storage.object(forKey: nvstLocalPortKey), defaultValue: 32190),
            nvstHandoffConfig: RemoteCoOpNVSTHandoffConfig(
                videoPeerIP: string(storage.object(forKey: nvstHandoffVideoPeerIPKey), defaultValue: "127.0.0.1"),
                videoPeerPort: uint16(storage.object(forKey: nvstHandoffVideoPeerPortKey), defaultValue: 32190),
                codec: RemoteCoOpNVSTVideoCodec(rawValue: string(storage.object(forKey: nvstHandoffCodecKey), defaultValue: "h264")) ?? .h264,
                rtpPayloadType: uint8(storage.object(forKey: nvstHandoffRTPPayloadTypeKey), defaultValue: 96),
                rtpSSRC: uint32(storage.object(forKey: nvstHandoffRTPSSRCKey), defaultValue: 0),
                maxAccessUnitBytes: uint32(storage.object(forKey: nvstHandoffMaxAccessUnitKey), defaultValue: 1024),
                timeoutMilliseconds: uint32(storage.object(forKey: nvstHandoffTimeoutMsKey), defaultValue: 5000),
                pingVersion: uint8(storage.object(forKey: nvstHandoffPingVersionKey), defaultValue: 6),
                pingPayload: string(storage.object(forKey: nvstHandoffPingPayloadKey), defaultValue: "PING"),
                iceCredentials: RemoteCoOpNVSTHandoffIceCredentials(
                    localUsernameFragment: string(storage.object(forKey: nvstHandoffLocalUserKey), defaultValue: "open"),
                    localPassword: string(storage.object(forKey: nvstHandoffLocalPassKey), defaultValue: "1234567890"),
                    remoteUsernameFragment: string(storage.object(forKey: nvstHandoffRemoteUserKey), defaultValue: "remote"),
                    remotePassword: string(storage.object(forKey: nvstHandoffRemotePassKey), defaultValue: "0987654321"),
                    remoteDTLSFingerprint: string(storage.object(forKey: nvstHandoffDTLSFingerprintKey), defaultValue: "SHA-256 00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF")
                ),
                srtpProfile: RemoteCoOpNVSTSRTPProfile(rawValue: string(storage.object(forKey: nvstHandoffSRTPProfileKey), defaultValue: "aead_aes_256_gcm")) ?? .aes256Gcm,
                srtpAESKey: data(storage.object(forKey: nvstHandoffSRTPKeyKey), defaultValue: Data(repeating: 0xab, count: 32)),
                srtpSalt: data(storage.object(forKey: nvstHandoffSRTPSaltKey), defaultValue: Data(repeating: 0x9e, count: 12))
            )
        )
    }
    
    public static func save(_ preferences: RemoteCoOpDirectPreferences) {
        storage.set(preferences.connectionMode.rawValue, forKey: connectionModeKey)
        storage.set(preferences.enableUPnP, forKey: enableUPnPKey)
        storage.set(preferences.enableBonjour, forKey: enableBonjourKey)
        storage.set(preferences.pinAttempts, forKey: pinAttemptsKey)
        storage.set(preferences.pinExpiration, forKey: pinExpirationKey)
        storage.set(preferences.signalingPort, forKey: signalingPortKey)
        storage.set(preferences.nvstEnabled, forKey: nvstEnabledKey)
        storage.set(preferences.nvstLocalPort, forKey: nvstLocalPortKey)
        storage.set(preferences.nvstHandoffConfig.videoPeerIP, forKey: nvstHandoffVideoPeerIPKey)
        storage.set(preferences.nvstHandoffConfig.videoPeerPort, forKey: nvstHandoffVideoPeerPortKey)
        storage.set(preferences.nvstHandoffConfig.codec.rawValue, forKey: nvstHandoffCodecKey)
        storage.set(preferences.nvstHandoffConfig.rtpPayloadType, forKey: nvstHandoffRTPPayloadTypeKey)
        storage.set(preferences.nvstHandoffConfig.rtpSSRC, forKey: nvstHandoffRTPSSRCKey)
        storage.set(preferences.nvstHandoffConfig.maxAccessUnitBytes, forKey: nvstHandoffMaxAccessUnitKey)
        storage.set(preferences.nvstHandoffConfig.timeoutMilliseconds, forKey: nvstHandoffTimeoutMsKey)
        storage.set(preferences.nvstHandoffConfig.pingVersion, forKey: nvstHandoffPingVersionKey)
        storage.set(preferences.nvstHandoffConfig.pingPayload, forKey: nvstHandoffPingPayloadKey)
        storage.set(preferences.nvstHandoffConfig.iceCredentials.localUsernameFragment, forKey: nvstHandoffLocalUserKey)
        storage.set(preferences.nvstHandoffConfig.iceCredentials.localPassword, forKey: nvstHandoffLocalPassKey)
        storage.set(preferences.nvstHandoffConfig.iceCredentials.remoteUsernameFragment, forKey: nvstHandoffRemoteUserKey)
        storage.set(preferences.nvstHandoffConfig.iceCredentials.remotePassword, forKey: nvstHandoffRemotePassKey)
        storage.set(preferences.nvstHandoffConfig.iceCredentials.remoteDTLSFingerprint, forKey: nvstHandoffDTLSFingerprintKey)
        storage.set(preferences.nvstHandoffConfig.srtpProfile.rawValue, forKey: nvstHandoffSRTPProfileKey)
        storage.set(preferences.nvstHandoffConfig.srtpAESKey.base64EncodedString(), forKey: nvstHandoffSRTPKeyKey)
        storage.set(preferences.nvstHandoffConfig.srtpSalt.base64EncodedString(), forKey: nvstHandoffSRTPSaltKey)
        storage.synchronize()
    }
    
    private static func string(_ value: Any?, defaultValue: String) -> String {
        if let value = value as? String { return value }
        if let value = value as? NSString { return value as String }
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
    
    private static func uint8(_ value: Any?, defaultValue: UInt8) -> UInt8 {
        if let value = value as? UInt8 { return value }
        if let value = value as? NSNumber { return UInt8(value.uintValue) }
        if let value = value as? String, let parsed = UInt8(value) { return parsed }
        return defaultValue
    }
    
    private static func uint16(_ value: Any?, defaultValue: UInt16) -> UInt16 {
        if let value = value as? UInt16 { return value }
        if let value = value as? NSNumber { return UInt16(value.uintValue) }
        if let value = value as? String, let parsed = UInt16(value) { return parsed }
        return defaultValue
    }
    
    private static func uint32(_ value: Any?, defaultValue: UInt32) -> UInt32 {
        if let value = value as? UInt32 { return value }
        if let value = value as? NSNumber { return UInt32(value.uintValue) }
        if let value = value as? String, let parsed = UInt32(value) { return parsed }
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
    
    private static func data(_ value: Any?, defaultValue: Data) -> Data {
        if let value = value as? Data { return value }
        if let value = value as? String {
            return Data(base64Encoded: value) ?? defaultValue
        }
        return defaultValue
    }
}
