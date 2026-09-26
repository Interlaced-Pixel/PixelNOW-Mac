import Foundation

public enum RemoteCoOpLatencyMode: String, CaseIterable, Codable, Equatable, Sendable {
    case quality
    case lowLatency

    public var label: String {
        switch self {
        case .quality: return "Quality"
        case .lowLatency: return "Low Latency"
        }
    }

    public var description: String {
        switch self {
        case .quality: return "Prioritizes image quality with higher bitrate targets. Best for watching or stable LAN sessions."
        case .lowLatency: return "Prioritizes responsiveness by reducing buffering and lowering quality before queueing frames."
        }
    }
}

public struct RemoteCoOpICEServer: Codable, Equatable, Sendable {
    public var urls: [String]
    public var username: String?
    public var credential: String?

    public init(urls: [String], username: String? = nil, credential: String? = nil) {
        self.urls = urls.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        self.username = username?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.credential = credential?.nilIfEmpty
    }
}

public struct RemoteCoOpNetworkConfiguration: Codable, Equatable, Sendable {
    public var latencyMode: RemoteCoOpLatencyMode
    public var iceServers: [RemoteCoOpICEServer]
    public var dataChannelInputEnabled: Bool
    public var websocketInputFallbackEnabled: Bool
    public var directPeerCandidateWarning: String

    public init(latencyMode: RemoteCoOpLatencyMode = .quality,
                iceServers: [RemoteCoOpICEServer] = [],
                dataChannelInputEnabled: Bool = true,
                websocketInputFallbackEnabled: Bool = false,
                directPeerCandidateWarning: String = "") {
        self.latencyMode = latencyMode
        self.iceServers = iceServers
        self.dataChannelInputEnabled = dataChannelInputEnabled
        self.websocketInputFallbackEnabled = false
        self.directPeerCandidateWarning = directPeerCandidateWarning.isEmpty ? Self.directConnectionWarning : directPeerCandidateWarning
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        latencyMode = try container.decodeIfPresent(RemoteCoOpLatencyMode.self, forKey: .latencyMode) ?? .quality
        iceServers = try container.decodeIfPresent([RemoteCoOpICEServer].self, forKey: .iceServers) ?? []
        dataChannelInputEnabled = try container.decodeIfPresent(Bool.self, forKey: .dataChannelInputEnabled) ?? true
        websocketInputFallbackEnabled = false
        let warning = try container.decodeIfPresent(String.self, forKey: .directPeerCandidateWarning) ?? ""
        directPeerCandidateWarning = warning.isEmpty ? Self.directConnectionWarning : warning
    }

    public static let directConnectionWarning = "Direct peer connections expose candidate network addresses and require compatible NAT or firewall rules."
}

public enum RemoteCoOpQualityPreset: String, CaseIterable, Codable, Equatable, Sendable {
    case p720f30
    case p720f60
    case p1080f60

    public var label: String {
        switch self {
        case .p720f30: return "720p 30 FPS"
        case .p720f60: return "720p 60 FPS"
        case .p1080f60: return "1080p 60 FPS"
        }
    }

    public var width: Int {
        switch self {
        case .p720f30, .p720f60: return 1280
        case .p1080f60: return 1920
        }
    }

    public var height: Int {
        switch self {
        case .p720f30, .p720f60: return 720
        case .p1080f60: return 1080
        }
    }

    public var fps: Int {
        switch self {
        case .p720f30: return 30
        case .p720f60, .p1080f60: return 60
        }
    }

    public var videoMaxBitrateBps: Int {
        switch self {
        case .p720f30: return 6_000_000
        case .p720f60: return 12_000_000
        case .p1080f60: return 20_000_000
        }
    }

    public var videoMinBitrateBps: Int {
        switch self {
        case .p720f30: return 2_500_000
        case .p720f60: return 5_000_000
        case .p1080f60: return 8_000_000
        }
    }

    public func videoMaxBitrateBps(for latencyMode: RemoteCoOpLatencyMode) -> Int {
        switch latencyMode {
        case .quality: return videoMaxBitrateBps
        case .lowLatency:
            switch self {
            case .p720f30: return 4_000_000
            case .p720f60: return 8_000_000
            case .p1080f60: return 12_000_000
            }
        }
    }

    public func videoMinBitrateBps(for latencyMode: RemoteCoOpLatencyMode) -> Int? {
        latencyMode == .quality ? videoMinBitrateBps : nil
    }
}

public struct RemoteCoOpPreferences: Codable, Equatable, Sendable {
    public static let launchMetadataAlphaOptedInKey = "remoteCoOpAlphaOptedIn"
    public static let launchMetadataEnabledKey = "remoteCoOpEnabled"
    public static let launchMetadataReservedGuestSlotsKey = "remoteCoOpReservedGuestSlots"
    public static let launchMetadataQualityPresetKey = "remoteCoOpQualityPreset"
    public static let launchMetadataLatencyModeKey = "remoteCoOpLatencyMode"
    public static let launchMetadataHideGuestInviteDetailsKey = "remoteCoOpHideGuestInviteDetails"

    public var isAlphaOptedIn: Bool
    public var isEnabled: Bool
    public var reservedGuestSlots: Int
    public var qualityPreset: RemoteCoOpQualityPreset
    public var latencyMode: RemoteCoOpLatencyMode
    public var hideGuestInviteDetails: Bool

    public init(isAlphaOptedIn: Bool = true,
                isEnabled: Bool = false,
                reservedGuestSlots: Int = 1,
                qualityPreset: RemoteCoOpQualityPreset = .p720f60,
                latencyMode: RemoteCoOpLatencyMode = .lowLatency,
                hideGuestInviteDetails: Bool = false) {
        self.isAlphaOptedIn = isAlphaOptedIn
        self.isEnabled = isEnabled
        self.reservedGuestSlots = Self.clampedGuestSlots(reservedGuestSlots)
        self.qualityPreset = qualityPreset
        self.latencyMode = latencyMode
        self.hideGuestInviteDetails = hideGuestInviteDetails
    }

    public var isAvailable: Bool { isAlphaOptedIn && isEnabled }

    public var effectiveReservedGuestSlots: Int {
        isAvailable ? Self.clampedGuestSlots(reservedGuestSlots) : 0
    }

    public static func clampedGuestSlots(_ value: Int) -> Int {
        min(3, max(0, value))
    }

    public var launchMetadata: [String: String] {
        guard isAlphaOptedIn else {
            return [
                Self.launchMetadataAlphaOptedInKey: String(false),
                Self.launchMetadataEnabledKey: String(false),
                Self.launchMetadataReservedGuestSlotsKey: String(0)
            ]
        }
        return [
            Self.launchMetadataAlphaOptedInKey: String(isAlphaOptedIn),
            Self.launchMetadataEnabledKey: String(isEnabled),
            Self.launchMetadataReservedGuestSlotsKey: String(Self.clampedGuestSlots(reservedGuestSlots)),
            Self.launchMetadataQualityPresetKey: qualityPreset.rawValue,
            Self.launchMetadataLatencyModeKey: latencyMode.rawValue,
            Self.launchMetadataHideGuestInviteDetailsKey: String(hideGuestInviteDetails)
        ]
    }

    public static func launchPreferences(from metadata: [String: String], fallback: RemoteCoOpPreferences) -> RemoteCoOpPreferences {
        RemoteCoOpPreferences(
            isAlphaOptedIn: bool(metadata[launchMetadataAlphaOptedInKey], defaultValue: fallback.isAlphaOptedIn),
            isEnabled: bool(metadata[launchMetadataEnabledKey], defaultValue: fallback.isEnabled),
            reservedGuestSlots: int(metadata[launchMetadataReservedGuestSlotsKey], defaultValue: fallback.reservedGuestSlots),
            qualityPreset: RemoteCoOpQualityPreset(rawValue: metadata[launchMetadataQualityPresetKey] ?? "") ?? fallback.qualityPreset,
            latencyMode: RemoteCoOpLatencyMode(rawValue: metadata[launchMetadataLatencyModeKey] ?? "") ?? fallback.latencyMode,
            hideGuestInviteDetails: bool(metadata[launchMetadataHideGuestInviteDetailsKey], defaultValue: fallback.hideGuestInviteDetails)
        )
    }

    private static func int(_ value: String?, defaultValue: Int) -> Int {
        guard let value, let parsed = Int(value) else { return defaultValue }
        return parsed
    }

    private static func bool(_ value: String?, defaultValue: Bool) -> Bool {
        guard let value else { return defaultValue }
        return value == "1" || value.caseInsensitiveCompare("true") == .orderedSame || value.caseInsensitiveCompare("yes") == .orderedSame
    }
}

public enum RemoteCoOpParticipantRole: String, Codable, Equatable, Sendable {
    case host
    case guest
    case spectator
}

public enum RemoteCoOpParticipantConnectionState: String, Codable, Equatable, Sendable {
    case connecting
    case connected
    case disconnected
    case failed
}

public struct RemoteCoOpParticipant: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var displayName: String
    public var role: RemoteCoOpParticipantRole
    public var connectionState: RemoteCoOpParticipantConnectionState
    public var inputEnabled: Bool
    public var playerIndex: Int?
    public var joinedAt: Date
    public var lastActivityAt: Date

    public init(id: UUID = UUID(),
                displayName: String,
                role: RemoteCoOpParticipantRole,
                connectionState: RemoteCoOpParticipantConnectionState,
                inputEnabled: Bool = false,
                playerIndex: Int? = nil,
                joinedAt: Date = Date(),
                lastActivityAt: Date = Date()) {
        self.id = id
        self.displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Guest" : displayName
        self.role = role
        self.connectionState = connectionState
        self.inputEnabled = inputEnabled
        self.playerIndex = playerIndex.map { min(3, max(1, $0)) }
        self.joinedAt = joinedAt
        self.lastActivityAt = lastActivityAt
    }
}

public struct RemoteCoOpInvite: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let code: String
    public let createdAt: Date
    public let expiresAt: Date
    public let token: String
    public let joinURL: URL?
    public let applicationID: String
    public let title: String
    public let hideGuestInviteDetails: Bool

    public init(id: UUID = UUID(),
                code: String,
                createdAt: Date = Date(),
                expiresAt: Date,
                token: String = "",
                joinURL: URL? = nil,
                applicationID: String = "",
                title: String = "",
                hideGuestInviteDetails: Bool = false) {
        self.id = id
        self.code = code
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.token = token.isEmpty ? code : token
        self.joinURL = joinURL
        self.applicationID = applicationID
        self.title = title
        self.hideGuestInviteDetails = hideGuestInviteDetails
    }

    public var isExpired: Bool { expiresAt <= Date() }
}

public struct RemoteCoOpInputPacket: Codable, Equatable, Sendable {
    public let participantID: UUID
    public let sequenceNumber: UInt64
    public let buttons: GamepadButtons
    public let leftTrigger: Float
    public let rightTrigger: Float
    public let leftStickX: Float
    public let leftStickY: Float
    public let rightStickX: Float
    public let rightStickY: Float
    public let sentAtNanoseconds: UInt64

    public init(participantID: UUID,
                sequenceNumber: UInt64,
                buttons: GamepadButtons = [],
                leftTrigger: Float = 0,
                rightTrigger: Float = 0,
                leftStickX: Float = 0,
                leftStickY: Float = 0,
                rightStickX: Float = 0,
                rightStickY: Float = 0,
                sentAtNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        self.participantID = participantID
        self.sequenceNumber = sequenceNumber
        self.buttons = buttons
        self.leftTrigger = Self.clampUnit(leftTrigger)
        self.rightTrigger = Self.clampUnit(rightTrigger)
        self.leftStickX = Self.clampSignedUnit(leftStickX)
        self.leftStickY = Self.clampSignedUnit(leftStickY)
        self.rightStickX = Self.clampSignedUnit(rightStickX)
        self.rightStickY = Self.clampSignedUnit(rightStickY)
        self.sentAtNanoseconds = sentAtNanoseconds
    }

    private static func clampUnit(_ value: Float) -> Float {
        min(1, max(0, value.isFinite ? value : 0))
    }

    private static func clampSignedUnit(_ value: Float) -> Float {
        min(1, max(-1, value.isFinite ? value : 0))
    }
}
