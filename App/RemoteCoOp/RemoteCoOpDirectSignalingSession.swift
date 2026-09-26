import Foundation

public final class RemoteCoOpDirectSignalingSession: RemoteCoOpSignalingSession, @unchecked Sendable {
    private struct SignalingMessage: Codable, Sendable {
        var protocolVersion: Int?
        var kind: String
        var roomID: String?
        var participantID: UUID?
        var fromParticipantID: UUID?
        var toParticipantID: UUID?
        var displayName: String?
        var participant: RemoteCoOpParticipant?
        var input: RemoteCoOpInputPacket?
        var inputs: [RemoteCoOpInputPacket]?
        var inputRejection: RemoteCoOpWireInputRoutingRejection?
        var peerSignal: RemoteCoOpWirePeerSignal?
        var networkConfiguration: RemoteCoOpNetworkConfiguration?
        var reason: String?

        init(kind: String,
             roomID: String? = nil,
             participantID: UUID? = nil,
             toParticipantID: UUID? = nil,
             displayName: String? = nil,
             participant: RemoteCoOpParticipant? = nil,
             input: RemoteCoOpInputPacket? = nil,
             inputs: [RemoteCoOpInputPacket]? = nil,
             inputRejection: RemoteCoOpWireInputRoutingRejection? = nil,
             peerSignal: RemoteCoOpWirePeerSignal? = nil,
             networkConfiguration: RemoteCoOpNetworkConfiguration? = nil,
             reason: String? = nil) {
            self.protocolVersion = 1
            self.kind = kind
            self.roomID = roomID
            self.participantID = participantID
            self.fromParticipantID = nil
            self.toParticipantID = toParticipantID
            self.displayName = displayName
            self.participant = participant
            self.input = input
            self.inputs = inputs
            self.inputRejection = inputRejection
            self.peerSignal = peerSignal
            self.networkConfiguration = networkConfiguration
            self.reason = reason
        }
    }

    private enum SignalingError: LocalizedError {
        case invalidServerURL(String)

        var errorDescription: String? {
            switch self {
            case .invalidServerURL(let value):
                return "Invalid Remote Co-Op signaling URL: \(value)"
            }
        }
    }

    private let serverURLString: String
    private let urlSession: URLSession
    private let lock = NSLock()
    private var eventContinuations: [UUID: AsyncStream<RemoteCoOpSignalingEvent>.Continuation] = [:]
    private var webSocketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var roomID: String?
    private var invite: RemoteCoOpInvite?
    private var isClosed = false

    public init(port: UInt16 = 32189,
                serverURL: String? = nil,
                urlSession: URLSession = .shared) {
        self.serverURLString = serverURL ?? "ws://127.0.0.1:\(port)/remote-coop-direct"
        self.urlSession = urlSession
    }

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

    public func send(_ command: RemoteCoOpSignalingCommand) async {
        switch command {
        case .inviteCreated(let invite):
            lock.withLock {
                self.invite = invite
                roomID = invite.code
            }
            await send(SignalingMessage(kind: "hostJoinRequested", roomID: invite.code))
        case .inviteEnded:
            let currentRoomID = lock.withLock { roomID }
            await send(SignalingMessage(kind: "hostLeaveRequested", roomID: currentRoomID))
        case .participantUpdated(let participant):
            let currentRoomID = lock.withLock { roomID }
            await send(SignalingMessage(kind: "participantUpdated", roomID: currentRoomID, participantID: participant.id, participant: participant))
        case .participantRemoved(let participantID):
            let currentRoomID = lock.withLock { roomID }
            await send(SignalingMessage(kind: "participantRemoved", roomID: currentRoomID, participantID: participantID))
        case .guestRejected(let participantID, let reason):
            let currentRoomID = lock.withLock { roomID }
            await send(SignalingMessage(kind: "guestRejected", roomID: currentRoomID, participantID: participantID, reason: reason))
        case .inputRejected(let participantID, let result):
            let currentRoomID = lock.withLock { roomID }
            guard let rejection = RemoteCoOpWireInputRoutingRejection(result) else { return }
            await send(SignalingMessage(kind: "inputRejected", roomID: currentRoomID, participantID: participantID, inputRejection: rejection))
        case .peerSignal(let participantID, let signal):
            let currentRoomID = lock.withLock { roomID }
            await send(SignalingMessage(kind: "peerSignal", roomID: currentRoomID, toParticipantID: participantID, peerSignal: signal))
        }
    }

    public func close() async {
        let state = lock.withLock {
            isClosed = true
            let continuations = Array(eventContinuations.values)
            eventContinuations.removeAll()
            let socket = webSocketTask
            webSocketTask = nil
            let receiveTask = receiveTask
            self.receiveTask = nil
            let heartbeatTask = heartbeatTask
            self.heartbeatTask = nil
            roomID = nil
            invite = nil
            return (continuations, socket, receiveTask, heartbeatTask)
        }
        state.2?.cancel()
        state.3?.cancel()
        state.1?.cancel(with: .normalClosure, reason: nil)
        for continuation in state.0 { continuation.finish() }
    }

    public func start() async throws {
        guard let serverURL = URL(string: serverURLString),
              let scheme = serverURL.scheme?.lowercased(),
              scheme == "ws" || scheme == "wss",
              serverURL.host != nil else {
            throw SignalingError.invalidServerURL(serverURLString)
        }

        let task = urlSession.webSocketTask(with: serverURL)
        lock.withLock {
            isClosed = false
            webSocketTask?.cancel(with: .goingAway, reason: nil)
            webSocketTask = task
        }
        task.resume()
        startReceiveLoop(task)
        startHeartbeatLoop()
    }

    private func startReceiveLoop(_ task: URLSessionWebSocketTask) {
        let loop = Task { [weak self, weak task] in
            while !Task.isCancelled {
                guard let self, let task else { return }
                do {
                    let message = try await task.receive()
                    await self.handle(message)
                } catch {
                    await self.handleDisconnect(task: task)
                    return
                }
            }
        }
        lock.withLock {
            receiveTask?.cancel()
            receiveTask = loop
        }
    }

    private func startHeartbeatLoop() {
        let task = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 15_000_000_000)
                    guard let self else { return }
                    let currentRoomID = self.lock.withLock { self.roomID }
                    await self.send(SignalingMessage(kind: "heartbeat", roomID: currentRoomID))
                } catch {
                    return
                }
            }
        }
        lock.withLock {
            heartbeatTask?.cancel()
            heartbeatTask = task
        }
    }

    private func handleDisconnect(task: URLSessionWebSocketTask) async {
        let shouldClose = lock.withLock { webSocketTask === task && !isClosed }
        if shouldClose { await close() }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) async {
        let data: Data?
        switch message {
        case .string(let text): data = Data(text.utf8)
        case .data(let value): data = value
        @unknown default: data = nil
        }
        guard let data, let signalingMessage = try? JSONDecoder().decode(SignalingMessage.self, from: data) else { return }
        await handle(signalingMessage)
    }

    private func handle(_ message: SignalingMessage) async {
        switch message.kind {
        case "heartbeat":
            await send(SignalingMessage(kind: "heartbeat", roomID: message.roomID ?? lock.withLock { roomID }))
        case "guestConnected":
            guard let participantID = message.participantID else { return }
            let token = lock.withLock { invite?.code ?? roomID ?? "" }
            yield(.guestJoinRequested(participantID: participantID, inviteToken: token, displayName: message.displayName ?? "Guest"))
        case "guestDisconnected":
            if let participantID = message.participantID { yield(.guestDisconnected(participantID)) }
        case "guestInput":
            let packets = message.inputs ?? (message.input.map { [$0] } ?? [])
            for packet in packets { yield(.guestInput(packet)) }
        case "peerSignal":
            guard let signal = message.peerSignal,
                  let participantID = message.fromParticipantID ?? message.participantID else { return }
            yield(.peerSignal(participantID: participantID, signal: signal))
        case "networkConfiguration":
            if let configuration = message.networkConfiguration { yield(.networkConfiguration(configuration)) }
        case "hostJoinRejected", "error":
            WebRTCMediaTelemetry.capture("remote.coop.direct.signaling.rejected", level: .warning, message: message.reason ?? "Direct signaling rejected the host.")
        default:
            break
        }
    }

    private func send(_ message: SignalingMessage) async {
        guard let task = lock.withLock({ webSocketTask }) else { return }
        do {
            let data = try JSONEncoder().encode(message)
            try await task.send(.data(data))
        } catch {
            await handleDisconnect(task: task)
        }
    }

    private func yield(_ event: RemoteCoOpSignalingEvent) {
        let continuations = lock.withLock { isClosed ? [] : Array(eventContinuations.values) }
        for continuation in continuations { continuation.yield(event) }
    }
}
