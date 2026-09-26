import Foundation

public enum RemoteCoOpHostSessionError: LocalizedError, Equatable, Sendable {
    case disabled
    case inviteExpired
    case invalidInviteCode
    case participantNotFound
    case noAvailablePlayerSlots

    public var errorDescription: String? {
        switch self {
        case .disabled: return "Remote Co-Op is disabled."
        case .inviteExpired: return "Remote Co-Op invite has expired."
        case .invalidInviteCode: return "Remote Co-Op invite code is invalid."
        case .participantNotFound: return "Remote Co-Op participant was not found."
        case .noAvailablePlayerSlots: return "No Remote Co-Op player slots are available."
        }
    }
}

public struct RemoteCoOpHostSnapshot: Equatable, Sendable {
    public var preferences: RemoteCoOpPreferences
    public var invite: RemoteCoOpInvite?
    public var participants: [RemoteCoOpParticipant]

    public init(preferences: RemoteCoOpPreferences,
                invite: RemoteCoOpInvite?,
                participants: [RemoteCoOpParticipant]) {
        self.preferences = preferences
        self.invite = invite
        self.participants = participants
    }

    public var statusText: String {
        guard preferences.isEnabled else { return "Off" }
        if let invite, invite.isExpired { return "Expired" }
        if invite != nil { return participants.isEmpty ? "Inviting" : "Active" }
        return "Ready"
    }

    public var connectedParticipantCount: Int {
        participants.filter { $0.connectionState == .connected }.count
    }
}

public actor RemoteCoOpHostSession {
    private var preferences: RemoteCoOpPreferences
    private var invite: RemoteCoOpInvite?
    private var participants: [RemoteCoOpParticipant] = []
    private let inputRouter = RemoteCoOpInputRouter()

    public init(preferences: RemoteCoOpPreferences = RemoteCoOpPreferencesStore.load()) {
        self.preferences = preferences
    }

    public func updatePreferences(_ preferences: RemoteCoOpPreferences) async {
        self.preferences = preferences
        await inputRouter.replaceParticipants(participants)
    }

    public func snapshot() -> RemoteCoOpHostSnapshot {
        RemoteCoOpHostSnapshot(preferences: preferences, invite: invite, participants: participants.sorted { $0.joinedAt < $1.joinedAt })
    }

    public func startInvite(applicationID: String = "", title: String = "", lifetimeSeconds: TimeInterval = 3_600) throws -> RemoteCoOpInvite {
        guard preferences.isAvailable else { throw RemoteCoOpHostSessionError.disabled }
        guard preferences.effectiveReservedGuestSlots > 0 else { throw RemoteCoOpHostSessionError.noAvailablePlayerSlots }
        let now = Date()
        let invite = RemoteCoOpInvite(
            code: Self.makeInviteCode(),
            createdAt: now,
            expiresAt: now.addingTimeInterval(max(60, lifetimeSeconds)),
            applicationID: preferences.hideGuestInviteDetails ? "" : applicationID,
            title: preferences.hideGuestInviteDetails ? "" : title,
            hideGuestInviteDetails: preferences.hideGuestInviteDetails
        )
        self.invite = invite
        return invite
    }

    public func stopInvite() async -> [UserInputEvent] {
        let neutralEvents = await inputRouter.neutralInputEventsForDisconnectedParticipants()
        invite = nil
        participants.removeAll()
        await inputRouter.replaceParticipants([])
        return neutralEvents
    }

    public func registerGuest(displayName: String, inviteToken: String, participantID: UUID = UUID(), now: Date = Date()) async throws -> RemoteCoOpParticipant {
        guard preferences.isAvailable else { throw RemoteCoOpHostSessionError.disabled }
        guard let invite, invite.expiresAt > now else { throw RemoteCoOpHostSessionError.inviteExpired }
        guard inviteToken.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(invite.code) == .orderedSame else {
            throw RemoteCoOpHostSessionError.invalidInviteCode
        }
        if let existing = participants.first(where: { $0.id == participantID }) { return existing }
        guard participants.count < preferences.effectiveReservedGuestSlots else { throw RemoteCoOpHostSessionError.noAvailablePlayerSlots }
        let participant = RemoteCoOpParticipant(
            id: participantID,
            displayName: displayName,
            role: .guest,
            connectionState: .connected,
            inputEnabled: true,
            playerIndex: try nextAvailablePlayerIndex(),
            joinedAt: now,
            lastActivityAt: now
        )
        participants.append(participant)
        await inputRouter.upsertParticipant(participant)
        return participant
    }

    public func setInputEnabled(_ enabled: Bool, for id: UUID) async throws -> RemoteCoOpParticipant {
        guard let index = participants.firstIndex(where: { $0.id == id }) else { throw RemoteCoOpHostSessionError.participantNotFound }
        participants[index].inputEnabled = enabled
        participants[index].lastActivityAt = Date()
        let participant = participants[index]
        await inputRouter.upsertParticipant(participant)
        return participant
    }

    public func removeParticipant(_ id: UUID) async throws -> [UserInputEvent] {
        guard let index = participants.firstIndex(where: { $0.id == id }) else { throw RemoteCoOpHostSessionError.participantNotFound }
        let removed = participants.remove(at: index)
        await inputRouter.removeParticipant(id)
        guard let playerIndex = removed.playerIndex else { return [] }
        return [.gamepad(GamepadState(
            deviceID: InputDeviceID("remote-coop-\(removed.id.uuidString)"),
            playerIndex: playerIndex,
            timestamp: MediaTimestamp(nanoseconds: DispatchTime.now().uptimeNanoseconds)
        ))]
    }

    public func route(_ packet: RemoteCoOpInputPacket, receivedAtNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds) async -> RemoteCoOpInputRoutingResult {
        await inputRouter.route(packet, receivedAtNanoseconds: receivedAtNanoseconds)
    }

    private func nextAvailablePlayerIndex() throws -> Int {
        let maximumGuestSlots = preferences.effectiveReservedGuestSlots
        guard maximumGuestSlots > 0 else { throw RemoteCoOpHostSessionError.noAvailablePlayerSlots }
        let used = Set(participants.compactMap(\.playerIndex))
        for playerIndex in 1...min(3, maximumGuestSlots) where !used.contains(playerIndex) {
            return playerIndex
        }
        throw RemoteCoOpHostSessionError.noAvailablePlayerSlots
    }

    private static func makeInviteCode() -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        var generator = SystemRandomNumberGenerator()
        return String((0..<6).map { _ in alphabet.randomElement(using: &generator) ?? "X" })
    }
}
