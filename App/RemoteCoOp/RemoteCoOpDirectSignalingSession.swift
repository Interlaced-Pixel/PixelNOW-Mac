import Foundation

public final class RemoteCoOpDirectSignalingSession: RemoteCoOpSignalingSession, @unchecked Sendable {
    private let port: UInt16
    private let urlSession: URLSession
    private let hostSession: RemoteCoOpHostSession
    private let lock = NSLock()
    private var eventContinuations: [UUID: AsyncStream<RemoteCoOpSignalingEvent>.Continuation] = [:]
    private var serverTask: Task<Void, Never>?
    private var connectedGuests: [UUID: GuestConnection] = [:]
    private var invite: RemoteCoOpInvite?
    private var isClosed = false
    private var pinAuthenticator = RemoteCoOpPINAuthenticator()
    private var roomID: UUID? { lock.withLock { invite?.id } }

    public init(port: UInt16 = 32189, urlSession: URLSession = .shared, hostSession: RemoteCoOpHostSession) {
        self.port = port
        self.urlSession = urlSession
        self.hostSession = hostSession
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
        let currentRoomID = lock.withLock { roomID }
        guard let message = RemoteCoOpWireMessage.message(for: command, roomID: currentRoomID) else { return }
        await sendToAllGuests(message)
    }

    public func close() async {
        let state = lock.withLock {
            isClosed = true
            let continuations = Array(eventContinuations.values)
            eventContinuations.removeAll()
            let serverTask = serverTask
            serverTask?.cancel()
            self.serverTask = nil
            let guests = connectedGuests
            connectedGuests.removeAll()
            return (continuations, guests)
        }
        for guest in state.1 { await guest.value.close() }
        for continuation in state.0 { continuation.finish() }
    }

    public func start() async throws {
        let serverURL = URL(string: "ws://0.0.0.0:\(port)")!
        let request = URLRequest(url: serverURL)
        let task = urlSession.webSocketTask(with: request)
        task.resume()
        lock.withLock {
            serverTask?.cancel()
            serverTask = Task { [weak self] in
                await self?.handleIncomingConnection(task: task)
            }
        }
    }

    private func handleIncomingConnection(task: URLSessionWebSocketTask) async {
        do {
            let message = try await task.receive()
            switch message {
            case .string(let text):
                guard let signalMessage = try? DirectSignalingCodec.decodeJSON(text) else { return }
                await handleDirectMessage(signalMessage, task: task)
            default:
                break
            }
        } catch {
            await close()
        }
    }

    private func handleDirectMessage(_ message: DirectSignalingMessage, task: URLSessionWebSocketTask) async {
        switch message.kind {
        case .guestJoinRequest:
            await handleGuestJoinRequest(message, task: task)
        case .sdpOffer, .sdpAnswer, .iceCandidate:
            await handlePeerSignal(message, task: task)
        case .ping:
            await sendPong(to: task)
        default:
            break
        }
    }

    private func handleGuestJoinRequest(_ message: DirectSignalingMessage, task: URLSessionWebSocketTask) async {
        guard let pin = message.pin else {
            await sendGuestJoinRejected(to: task, reason: "Missing PIN")
            return
        }
        guard let participantID = message.participantID else {
            await sendGuestJoinRejected(to: task, reason: "Missing participant ID")
            return
        }
        do {
            try await validatePIN(pin, from: task)
            await acceptGuestJoin(participantID: participantID, task: task, displayName: message.hostIP ?? "Guest")
        } catch {
            await sendGuestJoinRejected(to: task, reason: error.localizedDescription)
        }
    }

    private func validatePIN(_ pin: String, from task: URLSessionWebSocketTask) async throws {
        let ip = await getClientIP(for: task)
        let _ = try await pinAuthenticator.validate(pin, from: ip)
    }

    private func getClientIP(for task: URLSessionWebSocketTask) async -> String {
        "127.0.0.1"
    }

    private func acceptGuestJoin(participantID: UUID, task: URLSessionWebSocketTask, displayName: String) async {
        await sendGuestJoinAccepted(to: task)
        await createGuestConnection(participantID: participantID, task: task, displayName: displayName)
    }

    private func createGuestConnection(participantID: UUID, task: URLSessionWebSocketTask, displayName: String) async {
        let connection = GuestConnection(task: task, onDisconnect: { [weak self] id in
            self?.handleGuestDisconnected(id)
        })
        lock.withLock {
            connectedGuests[participantID] = connection
        }
        do {
            let _ = try await hostSession.registerGuest(displayName: displayName, inviteToken: "", participantID: participantID)
            lock.withLock {
                eventContinuations.values.forEach { $0.yield(.guestJoinRequested(participantID: participantID, inviteToken: "", displayName: displayName)) }
            }
        } catch {
            await sendGuestJoinRejected(to: task, reason: error.localizedDescription)
            await removeGuestConnection(participantID: participantID)
        }
    }

    private func handlePeerSignal(_ message: DirectSignalingMessage, task: URLSessionWebSocketTask) async {
        guard let signal = message.signal else { return }
        guard let participantID = message.participantID else { return }
        let wireSignal = await convertToWireSignal(signal, from: participantID)
        let wireMessage = RemoteCoOpWireMessage(
            kind: .peerSignal,
            participantID: participantID,
            peerSignal: wireSignal
        )
        await sendToGuest(participantID: participantID, message: wireMessage)
        lock.withLock {
            eventContinuations.values.forEach { $0.yield(.peerSignal(participantID: participantID, signal: wireSignal)) }
        }
    }

    private func convertToWireSignal(_ signal: DirectSignalingSignal, from participantID: UUID) async -> RemoteCoOpWirePeerSignal {
        switch signal {
        case .offer(let sdp):
            return RemoteCoOpWirePeerSignal(kind: .offer, sdp: sdp)
        case .answer(let sdp):
            return RemoteCoOpWirePeerSignal(kind: .answer, sdp: sdp)
        case .iceCandidate(let candidate, let sdpMid, let sdpMLineIndex):
            return RemoteCoOpWirePeerSignal(kind: .iceCandidate, candidate: candidate, sdpMid: sdpMid, sdpMLineIndex: sdpMLineIndex)
        }
    }

    private func handleGuestDisconnected(_ participantID: UUID) {
        lock.withLock {
            connectedGuests.removeValue(forKey: participantID)
            eventContinuations.values.forEach { $0.yield(.guestDisconnected(participantID)) }
        }
        Task {
            do {
                let _ = try await hostSession.removeParticipant(participantID)
            } catch {
            }
        }
    }

    private func removeGuestConnection(participantID: UUID) async {
        lock.withLock {
            connectedGuests.removeValue(forKey: participantID)
        }
    }

    private func sendToGuest(participantID: UUID, message: RemoteCoOpWireMessage) async {
        guard let connection = lock.withLock({ connectedGuests[participantID] }) else { return }
        let text = try? RemoteCoOpWireCodec.encode(message)
        await connection.send(string: text ?? "")
    }

    private func sendToAllGuests(_ message: RemoteCoOpWireMessage) async {
        let text = try? RemoteCoOpWireCodec.encode(message)
        guard let text else { return }
        let connections = lock.withLock { Array(connectedGuests.values) }
        for connection in connections { await connection.send(string: text) }
    }

    private func sendGuestJoinAccepted(to task: URLSessionWebSocketTask) async {
        let message = DirectSignalingMessage(kind: .guestJoinAccepted)
        await sendDirectMessage(message, to: task)
    }

    private func sendGuestJoinRejected(to task: URLSessionWebSocketTask, reason: String) async {
        let message = DirectSignalingMessage(kind: .guestJoinRejected, reason: reason)
        await sendDirectMessage(message, to: task)
    }

    private func sendPong(to task: URLSessionWebSocketTask) async {
        let message = DirectSignalingMessage(kind: .pong)
        await sendDirectMessage(message, to: task)
    }

    private func sendDirectMessage(_ message: DirectSignalingMessage, to task: URLSessionWebSocketTask) async {
        do {
            let text = try DirectSignalingCodec.encodeJSON(message)
            _ = try await task.send(.string(text))
        } catch {
        }
    }

    private class GuestConnection: @unchecked Sendable {
        private let task: URLSessionWebSocketTask
        private let onDisconnect: (@Sendable (UUID) -> Void)
        private var receiveTask: Task<Void, Never>?
        private let lock = NSLock()
        private var participantID: UUID?
        private var isClosed = false

        init(task: URLSessionWebSocketTask, onDisconnect: @escaping @Sendable (UUID) -> Void) {
            self.task = task
            self.onDisconnect = onDisconnect
            startReceiveLoop()
        }

        deinit {
            close()
        }

        func send(string: String) async {
            do {
                _ = try await task.send(.string(string))
            } catch {
            }
        }

        func close() {
            let state = lock.withLock {
                isClosed = true
                let receiveTask = receiveTask
                receiveTask?.cancel()
                self.receiveTask = nil
                let id = participantID
                return id
            }
            task.cancel(with: .normalClosure, reason: nil)
            if let id = state {
                onDisconnect(id)
            }
        }

        private func startReceiveLoop() {
            receiveTask = Task { [weak self] in
                guard let self else { return }
                for await message in task.receiveStream() {
                    switch message {
                    case .string(let text):
                        await self.handleTextMessage(text)
                    default:
                        break
                    }
                }
                self.close()
            }
        }

        private func handleTextMessage(_ text: String) async {
            guard let message = try? DirectSignalingCodec.decodeJSON(text) else { return }
            switch message.kind {
            case .guestJoinRequest:
                lock.withLock { participantID = message.participantID }
            default:
                break
            }
        }
    }
}

private extension URLSessionWebSocketTask {
    func receiveStream() -> AsyncStream<Message> {
        AsyncStream { continuation in
            Task { [weak self] in
                guard let self else { return }
                while !Task.isCancelled {
                    do {
                        let message = try await self.receive()
                        continuation.yield(message)
                    } catch {
                        continuation.finish()
                        return
                    }
                }
                continuation.finish()
            }
        }
    }
}
