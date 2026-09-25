import Foundation

public enum RemoteCoOpWireMessageKind: String, Codable, Equatable, Sendable {
    case hostHello
    case inviteEnded
    case participantUpdated
    case participantRemoved
    case guestRejected
    case inputRejected
    case guestJoinRequested
    case guestInput
    case guestDisconnected
    case heartbeat
    case peerSignal
    case networkConfiguration
    case error
}

public enum RemoteCoOpWireInputRoutingRejection: String, Codable, Equatable, Sendable {
    case participantNotFound
    case inputDisabled
    case stalePacket
    case invalidPlayerSlot

    public init?(_ result: RemoteCoOpInputRoutingResult) {
        switch result {
        case .routed:
            return nil
        case .participantNotFound:
            self = .participantNotFound
        case .inputDisabled:
            self = .inputDisabled
        case .stalePacket:
            self = .stalePacket
        case .invalidPlayerSlot:
            self = .invalidPlayerSlot
        }
    }
}

public enum RemoteCoOpWirePeerSignalKind: String, Codable, Equatable, Sendable {
    case offer
    case answer
    case iceCandidate
}

public struct RemoteCoOpWirePeerSignal: Codable, Equatable, Sendable {
    public var kind: RemoteCoOpWirePeerSignalKind
    public var sdp: String?
    public var candidate: String?
    public var sdpMid: String?
    public var sdpMLineIndex: Int?

    public init(kind: RemoteCoOpWirePeerSignalKind,
                sdp: String? = nil,
                candidate: String? = nil,
                sdpMid: String? = nil,
                sdpMLineIndex: Int? = nil) {
        self.kind = kind
        self.sdp = sdp
        self.candidate = candidate
        self.sdpMid = sdpMid
        self.sdpMLineIndex = sdpMLineIndex
    }
}

public struct RemoteCoOpWireMessage: Codable, Equatable, Sendable {
    public var protocolVersion: Int
    public var kind: RemoteCoOpWireMessageKind
    public var roomID: UUID?
    public var participantID: UUID?
    public var inviteToken: String?
    public var displayName: String?
    public var invite: RemoteCoOpInvite?
    public var participant: RemoteCoOpParticipant?
    public var input: RemoteCoOpInputPacket?
    public var inputs: [RemoteCoOpInputPacket]?
    public var inputRejection: RemoteCoOpWireInputRoutingRejection?
    public var reason: String?
    public var peerSignal: RemoteCoOpWirePeerSignal?
    public var networkConfiguration: RemoteCoOpNetworkConfiguration?
    public var sentAtEpochMilliseconds: Int64

    public init(kind: RemoteCoOpWireMessageKind,
                roomID: UUID? = nil,
                participantID: UUID? = nil,
                inviteToken: String? = nil,
                displayName: String? = nil,
                invite: RemoteCoOpInvite? = nil,
                participant: RemoteCoOpParticipant? = nil,
                input: RemoteCoOpInputPacket? = nil,
                inputs: [RemoteCoOpInputPacket]? = nil,
                inputRejection: RemoteCoOpWireInputRoutingRejection? = nil,
                reason: String? = nil,
                peerSignal: RemoteCoOpWirePeerSignal? = nil,
                networkConfiguration: RemoteCoOpNetworkConfiguration? = nil,
                sentAt: Date = Date()) {
        self.protocolVersion = 1
        self.kind = kind
        self.roomID = roomID
        self.participantID = participantID
        self.inviteToken = inviteToken
        self.displayName = displayName
        self.invite = invite
        self.participant = participant
        self.input = input
        self.inputs = inputs
        self.inputRejection = inputRejection
        self.reason = reason
        self.peerSignal = peerSignal
        self.networkConfiguration = networkConfiguration
        self.sentAtEpochMilliseconds = Int64((sentAt.timeIntervalSince1970 * 1_000).rounded())
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try container.decodeIfPresent(Int.self, forKey: .protocolVersion) ?? 1
        kind = try container.decode(RemoteCoOpWireMessageKind.self, forKey: .kind)
        roomID = try container.decodeIfPresent(UUID.self, forKey: .roomID)
        participantID = try container.decodeIfPresent(UUID.self, forKey: .participantID)
        inviteToken = try container.decodeIfPresent(String.self, forKey: .inviteToken)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
        invite = try container.decodeIfPresent(RemoteCoOpInvite.self, forKey: .invite)
        participant = try container.decodeIfPresent(RemoteCoOpParticipant.self, forKey: .participant)
        input = try container.decodeIfPresent(RemoteCoOpInputPacket.self, forKey: .input)
        inputs = try container.decodeIfPresent([RemoteCoOpInputPacket].self, forKey: .inputs)
        inputRejection = try container.decodeIfPresent(RemoteCoOpWireInputRoutingRejection.self, forKey: .inputRejection)
        reason = try container.decodeIfPresent(String.self, forKey: .reason)
        peerSignal = try container.decodeIfPresent(RemoteCoOpWirePeerSignal.self, forKey: .peerSignal)
        networkConfiguration = try container.decodeIfPresent(RemoteCoOpNetworkConfiguration.self, forKey: .networkConfiguration)
        sentAtEpochMilliseconds = try container.decodeIfPresent(Int64.self, forKey: .sentAtEpochMilliseconds) ?? Int64((Date().timeIntervalSince1970 * 1_000).rounded())
    }

    public func signalingEvent() -> RemoteCoOpSignalingEvent? {
        switch kind {
        case .guestJoinRequested:
            guard let participantID, let inviteToken else { return nil }
            return .guestJoinRequested(participantID: participantID, inviteToken: inviteToken, displayName: displayName ?? "Guest")
        case .guestInput:
            guard let input = input ?? inputs?.last else { return nil }
            return .guestInput(input)
        case .guestDisconnected:
            guard let participantID else { return nil }
            return .guestDisconnected(participantID)
        case .peerSignal:
            guard let participantID, let peerSignal else { return nil }
            return .peerSignal(participantID: participantID, signal: peerSignal)
        case .networkConfiguration:
            guard let networkConfiguration else { return nil }
            return .networkConfiguration(networkConfiguration)
        case .hostHello, .inviteEnded, .participantUpdated, .participantRemoved, .guestRejected, .inputRejected, .heartbeat, .error:
            return nil
        }
    }

    public static func message(for command: RemoteCoOpSignalingCommand, roomID fallbackRoomID: UUID? = nil) -> RemoteCoOpWireMessage? {
        switch command {
        case .inviteCreated(let invite):
            return RemoteCoOpWireMessage(kind: .hostHello, roomID: invite.id, invite: invite)
        case .inviteEnded:
            return RemoteCoOpWireMessage(kind: .inviteEnded, roomID: fallbackRoomID)
        case .participantUpdated(let participant):
            return RemoteCoOpWireMessage(kind: .participantUpdated, roomID: fallbackRoomID, participantID: participant.id, participant: participant)
        case .participantRemoved(let participantID):
            return RemoteCoOpWireMessage(kind: .participantRemoved, roomID: fallbackRoomID, participantID: participantID)
        case .guestRejected(let participantID, let reason):
            return RemoteCoOpWireMessage(kind: .guestRejected, roomID: fallbackRoomID, participantID: participantID, reason: reason)
        case .inputRejected(let participantID, let result):
            guard let rejection = RemoteCoOpWireInputRoutingRejection(result) else { return nil }
            return RemoteCoOpWireMessage(kind: .inputRejected, roomID: fallbackRoomID, participantID: participantID, inputRejection: rejection)
        case .peerSignal(let participantID, let signal):
            return RemoteCoOpWireMessage(kind: .peerSignal, roomID: fallbackRoomID, participantID: participantID, peerSignal: signal)
        }
    }
}

public enum RemoteCoOpWireCodec {
    public static func encode(_ message: RemoteCoOpWireMessage) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(message)
        return String(decoding: data, as: UTF8.self)
    }

    public static func decode(_ text: String) throws -> RemoteCoOpWireMessage {
        let data = Data(text.utf8)
        return try JSONDecoder().decode(RemoteCoOpWireMessage.self, from: data)
    }
    
    public static func decode(_ data: Data) throws -> RemoteCoOpWireMessage {
        try JSONDecoder().decode(RemoteCoOpWireMessage.self, from: data)
    }
}

public enum DirectSignalingMessageKind: String, Codable, Equatable, Sendable {
    case hostWelcome
    case guestJoinRequest
    case guestJoinAccepted
    case guestJoinRejected
    case sdpOffer
    case sdpAnswer
    case iceCandidate
    case networkConfiguration
    case ping
    case pong
    case disconnect
}

public struct DirectSignalingMessage: Codable, Equatable, Sendable {
    public var protocolVersion: Int
    public var kind: DirectSignalingMessageKind
    public var participantID: UUID?
    public var pin: String?
    public var hostIP: String?
    public var signal: DirectSignalingSignal?
    public var networkConfiguration: RemoteCoOpNetworkConfiguration?
    public var reason: String?
    public var timestamp: Int64
    
    enum CodingKeys: String, CodingKey {
        case protocolVersion, kind, participantID, pin, hostIP, signal, networkConfiguration, reason, timestamp
    }
    
    public init(kind: DirectSignalingMessageKind,
                participantID: UUID? = nil,
                pin: String? = nil,
                hostIP: String? = nil,
                signal: DirectSignalingSignal? = nil,
                networkConfiguration: RemoteCoOpNetworkConfiguration? = nil,
                reason: String? = nil,
                timestamp: Int64 = Int64(Date().timeIntervalSince1970.rounded())) {
        self.protocolVersion = 1
        self.kind = kind
        self.participantID = participantID
        self.pin = pin
        self.hostIP = hostIP
        self.signal = signal
        self.networkConfiguration = networkConfiguration
        self.reason = reason
        self.timestamp = timestamp
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try container.decodeIfPresent(Int.self, forKey: .protocolVersion) ?? 1
        kind = try container.decode(DirectSignalingMessageKind.self, forKey: .kind)
        participantID = try container.decodeIfPresent(UUID.self, forKey: .participantID)
        pin = try container.decodeIfPresent(String.self, forKey: .pin)
        hostIP = try container.decodeIfPresent(String.self, forKey: .hostIP)
        signal = try container.decodeIfPresent(DirectSignalingSignal.self, forKey: .signal)
        networkConfiguration = try container.decodeIfPresent(RemoteCoOpNetworkConfiguration.self, forKey: .networkConfiguration)
        reason = try container.decodeIfPresent(String.self, forKey: .reason)
        timestamp = try container.decodeIfPresent(Int64.self, forKey: .timestamp) ?? Int64(Date().timeIntervalSince1970.rounded())
    }
}

public enum DirectSignalingSignal: Codable, Equatable, Sendable {
    case offer(sdp: String)
    case answer(sdp: String)
    case iceCandidate(candidate: String, sdpMid: String?, sdpMLineIndex: Int?)
    
    enum CodingKeys: String, CodingKey {
        case kind, sdp, candidate, sdpMid, sdpMLineIndex
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        
        switch kind {
        case "offer":
            let sdp = try container.decode(String.self, forKey: .sdp)
            self = .offer(sdp: sdp)
        case "answer":
            let sdp = try container.decode(String.self, forKey: .sdp)
            self = .answer(sdp: sdp)
        case "iceCandidate":
            let candidate = try container.decode(String.self, forKey: .candidate)
            let sdpMid = try container.decodeIfPresent(String.self, forKey: .sdpMid)
            let sdpMLineIndex = try container.decodeIfPresent(Int.self, forKey: .sdpMLineIndex)
            self = .iceCandidate(candidate: candidate, sdpMid: sdpMid, sdpMLineIndex: sdpMLineIndex)
        default:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: container, debugDescription: "Unknown signal kind")
        }
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        
        switch self {
        case .offer(let sdp):
            try container.encode("offer", forKey: .kind)
            try container.encode(sdp, forKey: .sdp)
        case .answer(let sdp):
            try container.encode("answer", forKey: .kind)
            try container.encode(sdp, forKey: .sdp)
        case .iceCandidate(let candidate, let sdpMid, let sdpMLineIndex):
            try container.encode("iceCandidate", forKey: .kind)
            try container.encode(candidate, forKey: .candidate)
            try container.encodeIfPresent(sdpMid, forKey: .sdpMid)
            try container.encodeIfPresent(sdpMLineIndex, forKey: .sdpMLineIndex)
        }
    }
}
