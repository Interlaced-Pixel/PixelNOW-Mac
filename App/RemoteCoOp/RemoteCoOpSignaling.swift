import Foundation

public enum RemoteCoOpSignalingEvent: Equatable, Sendable {
    case guestJoinRequested(participantID: UUID, inviteToken: String, displayName: String)
    case guestInput(RemoteCoOpInputPacket)
    case guestDisconnected(UUID)
    case peerSignal(participantID: UUID, signal: RemoteCoOpWirePeerSignal)
    case networkConfiguration(RemoteCoOpNetworkConfiguration)
}

public enum RemoteCoOpSignalingCommand: Equatable, Sendable {
    case inviteCreated(RemoteCoOpInvite)
    case inviteEnded
    case participantUpdated(RemoteCoOpParticipant)
    case participantRemoved(UUID)
    case guestRejected(participantID: UUID, reason: String)
    case inputRejected(participantID: UUID, result: RemoteCoOpInputRoutingResult)
    case peerSignal(participantID: UUID, signal: RemoteCoOpWirePeerSignal)
}

public protocol RemoteCoOpSignalingSession: Sendable {
    func events() -> AsyncStream<RemoteCoOpSignalingEvent>
    func send(_ command: RemoteCoOpSignalingCommand) async
    func close() async
}

public final class InProcessRemoteCoOpSignalingSession: RemoteCoOpSignalingSession, @unchecked Sendable {
    private let lock = NSLock()
    private var eventContinuations: [UUID: AsyncStream<RemoteCoOpSignalingEvent>.Continuation] = [:]
    private var commandContinuations: [UUID: AsyncStream<RemoteCoOpSignalingCommand>.Continuation] = [:]
    private var sentCommands: [RemoteCoOpSignalingCommand] = []
    private var isClosed = false

    public init() {}

    public func events() -> AsyncStream<RemoteCoOpSignalingEvent> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(240)) { continuation in
            lock.withLock {
                if isClosed {
                    continuation.finish()
                } else {
                    eventContinuations[id] = continuation
                }
            }
            continuation.onTermination = { [weak self] _ in
                self?.lock.withLock { self?.eventContinuations[id] = nil }
            }
        }
    }

    public func commands() -> AsyncStream<RemoteCoOpSignalingCommand> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(240)) { continuation in
            lock.withLock {
                if isClosed {
                    continuation.finish()
                } else {
                    commandContinuations[id] = continuation
                }
            }
            continuation.onTermination = { [weak self] _ in
                self?.lock.withLock { self?.commandContinuations[id] = nil }
            }
        }
    }

    public func publish(_ event: RemoteCoOpSignalingEvent) {
        let continuations = lock.withLock { isClosed ? [] : Array(eventContinuations.values) }
        for continuation in continuations { continuation.yield(event) }
    }

    public func commandHistory() -> [RemoteCoOpSignalingCommand] {
        lock.withLock { sentCommands }
    }

    public func send(_ command: RemoteCoOpSignalingCommand) async {
        let continuations: [AsyncStream<RemoteCoOpSignalingCommand>.Continuation] = lock.withLock {
            guard !isClosed else { return [] }
            sentCommands.append(command)
            return Array(commandContinuations.values)
        }
        for continuation in continuations { continuation.yield(command) }
    }

    public func close() async {
        let continuations = lock.withLock {
            isClosed = true
            let continuations = (Array(eventContinuations.values), Array(commandContinuations.values))
            eventContinuations.removeAll()
            commandContinuations.removeAll()
            sentCommands.removeAll()
            return continuations
        }
        for continuation in continuations.0 { continuation.finish() }
        for continuation in continuations.1 { continuation.finish() }
    }
}

public actor RemoteCoOpHostCoordinator {
    private let hostSession: RemoteCoOpHostSession
    private let signaling: any RemoteCoOpSignalingSession

    public init(hostSession: RemoteCoOpHostSession, signaling: any RemoteCoOpSignalingSession) {
        self.hostSession = hostSession
        self.signaling = signaling
    }

    public func snapshot() async -> RemoteCoOpHostSnapshot {
        await hostSession.snapshot()
    }

    public func startInvite(applicationID: String = "", title: String = "", lifetimeSeconds: TimeInterval = 3_600) async throws -> RemoteCoOpInvite {
        let invite = try await hostSession.startInvite(applicationID: applicationID, title: title, lifetimeSeconds: lifetimeSeconds)
        await signaling.send(.inviteCreated(invite))
        return invite
    }

    public func stopInvite() async -> [UserInputEvent] {
        let events = await hostSession.stopInvite()
        await signaling.send(.inviteEnded)
        return events
    }

    public func setInputEnabled(_ enabled: Bool, for id: UUID) async throws -> RemoteCoOpParticipant {
        let participant = try await hostSession.setInputEnabled(enabled, for: id)
        await signaling.send(.participantUpdated(participant))
        return participant
    }

    public func removeParticipant(_ id: UUID) async throws -> [UserInputEvent] {
        let events = try await hostSession.removeParticipant(id)
        await signaling.send(.participantRemoved(id))
        return events
    }

    public func handle(_ event: RemoteCoOpSignalingEvent) async -> [UserInputEvent] {
        switch event {
        case .guestJoinRequested(let participantID, let inviteToken, let displayName):
            do {
                let participant = try await hostSession.registerGuest(displayName: displayName, inviteToken: inviteToken, participantID: participantID)
                await signaling.send(.participantUpdated(participant))
            } catch {
                await signaling.send(.guestRejected(participantID: participantID, reason: Self.message(for: error)))
            }
            return []
        case .guestInput(let packet):
            let result = await hostSession.route(packet)
            if case .routed(let event) = result { return [event] }
            await signaling.send(.inputRejected(participantID: packet.participantID, result: result))
            return []
        case .guestDisconnected(let participantID):
            do {
                let events = try await hostSession.removeParticipant(participantID)
                await signaling.send(.participantRemoved(participantID))
                return events
            } catch {
                await signaling.send(.guestRejected(participantID: participantID, reason: Self.message(for: error)))
                return []
            }
        case .peerSignal, .networkConfiguration:
            return []
        }
    }

    public func listen(forwardInput: @escaping @Sendable (UserInputEvent) async -> Void) -> Task<Void, Never> {
        Task {
            for await event in signaling.events() {
                let routedEvents = await handle(event)
                for routedEvent in routedEvents { await forwardInput(routedEvent) }
            }
        }
    }

    private static func message(for error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription, !description.isEmpty { return description }
        return error.localizedDescription
    }
}
