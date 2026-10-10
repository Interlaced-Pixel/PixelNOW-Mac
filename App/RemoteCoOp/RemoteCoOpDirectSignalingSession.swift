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
        case connectionFailed(String)
        case connectionTimedOut
        case hostRejected(String)
        case registrationTimedOut

        var errorDescription: String? {
            switch self {
            case .invalidServerURL(let value):
                return "Invalid Remote Co-Op signaling URL: \(value)"
            case .connectionFailed(let message):
                return "Could not connect to the Remote Co-Op signaling service: \(message)"
            case .connectionTimedOut:
                return "The Remote Co-Op signaling service did not respond in time."
            case .hostRejected(let message):
                return "The Remote Co-Op signaling service rejected this invite: \(message)"
            case .registrationTimedOut:
                return "The Remote Co-Op signaling service did not confirm this invite in time."
            }
        }
    }

    private let serverURLString: String
    private let urlSession: URLSession
    private let lock = NSLock()
    private static let connectionTimeoutNanoseconds: UInt64 = 10_000_000_000
    private static let signalingMessageTimeoutNanoseconds: UInt64 = 10_000_000_000
    private static let registrationTimeoutNanoseconds: UInt64 = 8_000_000_000
    private var eventContinuations: [UUID: AsyncStream<RemoteCoOpSignalingEvent>.Continuation] = [:]
    private var webSocketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var hostRegistrationTimeoutTask: Task<Void, Never>?
    private var roomID: String?
    private var invite: RemoteCoOpInvite?
    private var networkConfiguration: RemoteCoOpNetworkConfiguration?
    private var isClosed = false
    private var hostRegistrationID: UUID?
    private var hostRegistrationResult: Result<Void, Error>?
    private var hostRegistrationWaiters: [UUID: ConnectionContinuationGate] = [:]
    private var pendingOperations: [UUID: ConnectionContinuationGate] = [:]

    public init(port: UInt16 = 38473,
                serverURL: String? = nil,
                urlSession: URLSession = .shared) {
        self.serverURLString = serverURL
            ?? ProcessInfo.processInfo.environment["PIXELNOW_REMOTE_COOP_DIRECT_URL"]
            ?? "wss://jayian.dev:\(port)/remote-coop-direct"
        self.urlSession = urlSession
    }

    public func latestNetworkConfiguration() -> RemoteCoOpNetworkConfiguration? {
        lock.withLock { networkConfiguration }
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
        guard !Task.isCancelled,
              let task = lock.withLock({ isClosed ? nil : webSocketTask }) else { return }
        switch command {
        case .inviteCreated(let invite):
            let previous = lock.withLock { () -> ([ConnectionContinuationGate], Task<Void, Never>?)? in
                guard !isClosed, webSocketTask === task else { return nil }
                let waiters = Array(hostRegistrationWaiters.values)
                hostRegistrationWaiters.removeAll()
                let timeoutTask = hostRegistrationTimeoutTask
                hostRegistrationTimeoutTask = nil
                hostRegistrationID = invite.id
                hostRegistrationResult = nil
                self.invite = invite
                roomID = invite.code
                return (waiters, timeoutTask)
            }
            guard let previous else { return }
            previous.1?.cancel()
            for waiter in previous.0 {
                waiter.resolve(error: SignalingError.connectionFailed("The invite was replaced before registration completed."))
            }
            await send(SignalingMessage(kind: "hostJoinRequested", roomID: invite.code), using: task)
        case .inviteEnded:
            let error = SignalingError.connectionFailed("The invite ended before registration completed.")
            let state = lock.withLock { () -> (String?, [ConnectionContinuationGate], Task<Void, Never>?)? in
                guard !isClosed, webSocketTask === task else { return nil }
                let currentRoomID = roomID
                let waiters = Array(hostRegistrationWaiters.values)
                hostRegistrationWaiters.removeAll()
                let timeoutTask = hostRegistrationTimeoutTask
                hostRegistrationTimeoutTask = nil
                hostRegistrationID = nil
                hostRegistrationResult = .failure(error)
                roomID = nil
                invite = nil
                networkConfiguration = nil
                return (currentRoomID, waiters, timeoutTask)
            }
            guard let state else { return }
            state.2?.cancel()
            for waiter in state.1 { waiter.resolve(error: error) }
            await send(SignalingMessage(kind: "hostLeaveRequested", roomID: state.0), using: task)
        case .participantUpdated(let participant):
            let currentRoomID = lock.withLock { roomID }
            await send(SignalingMessage(kind: "participantUpdated", roomID: currentRoomID, participantID: participant.id, participant: participant), using: task)
        case .participantRemoved(let participantID):
            let currentRoomID = lock.withLock { roomID }
            await send(SignalingMessage(kind: "participantRemoved", roomID: currentRoomID, participantID: participantID), using: task)
        case .guestRejected(let participantID, let reason):
            let currentRoomID = lock.withLock { roomID }
            await send(SignalingMessage(kind: "guestRejected", roomID: currentRoomID, participantID: participantID, reason: reason), using: task)
        case .inputRejected(let participantID, let result):
            let currentRoomID = lock.withLock { roomID }
            guard let rejection = RemoteCoOpWireInputRoutingRejection(result) else { return }
            await send(SignalingMessage(kind: "inputRejected", roomID: currentRoomID, participantID: participantID, inputRejection: rejection), using: task)
        case .peerSignal(let participantID, let signal):
            let currentRoomID = lock.withLock { roomID }
            await send(SignalingMessage(kind: "peerSignal", roomID: currentRoomID, toParticipantID: participantID, peerSignal: signal), using: task)
        }
    }

    public func close() async {
        closeConnection(error: SignalingError.connectionFailed("The signaling connection closed before invite registration completed."))
    }

    private struct ConnectionState {
        let socket: URLSessionWebSocketTask?
        let tasks: [Task<Void, Never>]
        let gates: [ConnectionContinuationGate]
        let continuations: [AsyncStream<RemoteCoOpSignalingEvent>.Continuation]

        func finish(error: Error) {
            for task in tasks { task.cancel() }
            socket?.cancel(with: .goingAway, reason: nil)
            for gate in gates { gate.resolve(error: error) }
            for continuation in continuations { continuation.finish() }
        }
    }

    private func takeConnectionStateLocked(error: Error, finishEvents: Bool = true) -> ConnectionState {
        let state = ConnectionState(
            socket: webSocketTask,
            tasks: [receiveTask, heartbeatTask, hostRegistrationTimeoutTask].compactMap { $0 },
            gates: Array(pendingOperations.values) + Array(hostRegistrationWaiters.values),
            continuations: finishEvents ? Array(eventContinuations.values) : []
        )
        isClosed = true
        webSocketTask = nil
        receiveTask = nil
        heartbeatTask = nil
        hostRegistrationTimeoutTask = nil
        hostRegistrationID = nil
        hostRegistrationResult = .failure(error)
        pendingOperations.removeAll()
        hostRegistrationWaiters.removeAll()
        if finishEvents { eventContinuations.removeAll() }
        roomID = nil
        invite = nil
        networkConfiguration = nil
        return state
    }

    private func closeConnection(matching task: URLSessionWebSocketTask? = nil,
                                 registrationID: UUID? = nil,
                                 error: Error) {
        let state = lock.withLock { () -> ConnectionState? in
            if let task, webSocketTask !== task { return nil }
            if let registrationID, hostRegistrationID != registrationID { return nil }
            return takeConnectionStateLocked(error: error)
        }
        state?.finish(error: error)
    }

    public func start() async throws {
        try Task.checkCancellation()
        guard let serverURL = URL(string: serverURLString),
              let scheme = serverURL.scheme?.lowercased(),
              scheme == "ws" || scheme == "wss",
              serverURL.host != nil else {
            throw SignalingError.invalidServerURL(serverURLString)
        }

        let task = urlSession.webSocketTask(with: serverURL)
        let operationID = UUID()
        let gate = ConnectionContinuationGate()
        let replacementError = SignalingError.connectionFailed("The signaling connection was replaced.")
        let previous = lock.withLock {
            let previous = takeConnectionStateLocked(error: replacementError, finishEvents: false)
            isClosed = false
            hostRegistrationResult = nil
            webSocketTask = task
            pendingOperations[operationID] = gate
            return previous
        }
        previous.finish(error: replacementError)
        defer { _ = lock.withLock { pendingOperations.removeValue(forKey: operationID) } }
        task.resume()
        do {
            try await Self.waitUntilConnected(task, gate: gate)
            try Task.checkCancellation()
            startReceiveLoop(task)
            startHeartbeatLoop(task)
            let isCurrent = lock.withLock { !isClosed && webSocketTask === task }
            guard isCurrent else { throw SignalingError.connectionFailed("The signaling connection closed while connecting.") }
        } catch {
            closeConnection(matching: task, error: error)
            task.cancel(with: .goingAway, reason: nil)
            if error is CancellationError { throw error }
            if let signalingError = error as? SignalingError {
                throw signalingError
            }
            throw SignalingError.connectionFailed(error.localizedDescription)
        }
    }

    private final class ConnectionContinuationGate: @unchecked Sendable {
        private var continuation: CheckedContinuation<Void, Error>?
        private let lock = NSLock()
        private var result: Result<Void, Error>?
        private var timeoutTask: Task<Void, Never>?

        func install(continuation: CheckedContinuation<Void, Error>) -> Bool {
            let result = lock.withLock { () -> Result<Void, Error>? in
                if let result = self.result { return result }
                self.continuation = continuation
                return nil
            }
            if let result {
                continuation.resume(with: result)
                return false
            }
            return true
        }

        func install(timeoutTask: Task<Void, Never>) {
            let shouldCancel = lock.withLock {
                guard result == nil else { return true }
                self.timeoutTask = timeoutTask
                return false
            }
            if shouldCancel { timeoutTask.cancel() }
        }

        @discardableResult
        func resolve(error: Error?) -> Bool {
            let resolution: Result<Void, Error> = error.map { .failure($0) } ?? .success(())
            let state = lock.withLock { () -> (Bool, CheckedContinuation<Void, Error>?, Task<Void, Never>?) in
                guard result == nil else { return (false, nil, nil) }
                result = resolution
                let continuation = self.continuation
                self.continuation = nil
                let timeoutTask = self.timeoutTask
                self.timeoutTask = nil
                return (true, continuation, timeoutTask)
            }
            guard state.0 else { return false }
            state.2?.cancel()
            state.1?.resume(with: resolution)
            return true
        }
    }

    private static func waitUntilConnected(_ task: URLSessionWebSocketTask, gate: ConnectionContinuationGate) async throws {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard gate.install(continuation: continuation) else { return }
                let timeoutTask = Task {
                    do {
                        try await Task.sleep(nanoseconds: Self.connectionTimeoutNanoseconds)
                        gate.resolve(error: SignalingError.connectionTimedOut)
                    } catch {}
                }
                gate.install(timeoutTask: timeoutTask)
                task.sendPing { error in
                    gate.resolve(error: error)
                }
            }
        }, onCancel: {
            if gate.resolve(error: CancellationError()) { task.cancel(with: .goingAway, reason: nil) }
        })
    }

    private static func send(_ data: Data, using task: URLSessionWebSocketTask, gate: ConnectionContinuationGate) async throws {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard gate.install(continuation: continuation) else { return }
                let timeoutTask = Task {
                    do {
                        try await Task.sleep(nanoseconds: Self.signalingMessageTimeoutNanoseconds)
                        gate.resolve(error: SignalingError.connectionTimedOut)
                    } catch {}
                }
                gate.install(timeoutTask: timeoutTask)
                task.send(.string(String(decoding: data, as: UTF8.self))) { error in
                    gate.resolve(error: error)
                }
            }
        }, onCancel: {
            if gate.resolve(error: CancellationError()) { task.cancel(with: .goingAway, reason: nil) }
        })
    }

    public func waitUntilHostRegistered() async throws {
        let waiterID = UUID()
        let gate = ConnectionContinuationGate()
        let registration = lock.withLock { (webSocketTask, hostRegistrationID) }
        defer { _ = lock.withLock { hostRegistrationWaiters.removeValue(forKey: waiterID) } }
        try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard gate.install(continuation: continuation) else { return }
                let result = lock.withLock { () -> Result<Void, Error>? in
                    guard !isClosed, let task = webSocketTask else {
                        if case .failure = hostRegistrationResult { return hostRegistrationResult }
                        return .failure(SignalingError.connectionFailed("The signaling connection is closed."))
                    }
                    guard task === registration.0, hostRegistrationID == registration.1 else {
                        return .failure(SignalingError.connectionFailed("The invite was replaced before registration completed."))
                    }
                    if let hostRegistrationResult { return hostRegistrationResult }
                    guard let registrationID = hostRegistrationID, invite != nil else {
                        return .failure(SignalingError.connectionFailed("No invite is awaiting registration."))
                    }
                    hostRegistrationWaiters[waiterID] = gate
                    if hostRegistrationTimeoutTask == nil {
                        hostRegistrationTimeoutTask = Task { [weak self] in
                            do {
                                try await Task.sleep(nanoseconds: Self.registrationTimeoutNanoseconds)
                                guard let self else { return }
                                let error = SignalingError.registrationTimedOut
                                if self.resolveHostRegistration(error: error, matching: task, registrationID: registrationID) {
                                    self.closeConnection(matching: task, registrationID: registrationID, error: error)
                                }
                            } catch {}
                        }
                    }
                    return nil
                }
                if let result {
                    switch result {
                    case .success: gate.resolve(error: nil)
                    case .failure(let error): gate.resolve(error: error)
                    }
                }
            }
            try Task.checkCancellation()
            let isCurrent = lock.withLock {
                !isClosed && webSocketTask === registration.0 && hostRegistrationID == registration.1
            }
            guard isCurrent else {
                throw SignalingError.connectionFailed("The invite closed before registration completed.")
            }
        }, onCancel: {
            gate.resolve(error: CancellationError())
        })
    }

    @discardableResult
    private func resolveHostRegistration(error: Error?,
                                         matching task: URLSessionWebSocketTask? = nil,
                                         registrationID: UUID? = nil,
                                         roomID: String? = nil,
                                         configuration: RemoteCoOpNetworkConfiguration? = nil) -> Bool {
        let result = lock.withLock { () -> (Bool, [ConnectionContinuationGate], Task<Void, Never>?) in
            if let task, webSocketTask !== task || isClosed { return (false, [], nil) }
            if let registrationID, hostRegistrationID != registrationID { return (false, [], nil) }
            if let roomID, self.roomID != roomID { return (false, [], nil) }
            guard hostRegistrationResult == nil, hostRegistrationID != nil else { return (false, [], nil) }
            hostRegistrationResult = error.map { .failure($0) } ?? .success(())
            if let configuration, error == nil { networkConfiguration = configuration }
            let waiters = Array(hostRegistrationWaiters.values)
            hostRegistrationWaiters.removeAll()
            let timeoutTask = hostRegistrationTimeoutTask
            hostRegistrationTimeoutTask = nil
            return (true, waiters, timeoutTask)
        }
        result.2?.cancel()
        for waiter in result.1 { waiter.resolve(error: error) }
        return result.0
    }

    private func startReceiveLoop(_ task: URLSessionWebSocketTask) {
        lock.withLock {
            guard !isClosed, webSocketTask === task else { return }
            receiveTask?.cancel()
            receiveTask = Task { [weak self, weak task] in
                while !Task.isCancelled {
                    guard let self, let task else { return }
                    do {
                        let message = try await task.receive()
                        guard !Task.isCancelled else { return }
                        await self.handle(message, from: task)
                    } catch {
                        self.handleDisconnect(task: task)
                        return
                    }
                }
            }
        }
    }

    private func startHeartbeatLoop(_ task: URLSessionWebSocketTask) {
        lock.withLock {
            guard !isClosed, webSocketTask === task else { return }
            heartbeatTask?.cancel()
            heartbeatTask = Task { [weak self, weak task] in
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(nanoseconds: 15_000_000_000)
                        guard let self, let task else { return }
                        let currentRoomID = self.lock.withLock { self.roomID }
                        await self.send(SignalingMessage(kind: "heartbeat", roomID: currentRoomID), using: task)
                    } catch {
                        return
                    }
                }
            }
        }
    }

    private func handleDisconnect(task: URLSessionWebSocketTask, error: Error? = nil) {
        closeConnection(matching: task, error: error ?? SignalingError.connectionFailed("The signaling connection disconnected."))
    }

    private func handle(_ message: URLSessionWebSocketTask.Message, from task: URLSessionWebSocketTask) async {
        let data: Data?
        switch message {
        case .string(let text): data = Data(text.utf8)
        case .data(let value): data = value
        @unknown default: data = nil
        }
        guard let data, let signalingMessage = try? JSONDecoder().decode(SignalingMessage.self, from: data) else { return }
        await handle(signalingMessage, from: task)
    }

    private func handle(_ message: SignalingMessage, from task: URLSessionWebSocketTask) async {
        guard lock.withLock({ !isClosed && webSocketTask === task }) else { return }
        switch message.kind {
        case "heartbeat":
            await send(SignalingMessage(kind: "heartbeat", roomID: message.roomID ?? lock.withLock { roomID }), using: task)
        case "guestConnected":
            guard let participantID = message.participantID else { return }
            let token = lock.withLock { invite?.code ?? roomID ?? "" }
            yield(.guestJoinRequested(participantID: participantID, inviteToken: token, displayName: message.displayName ?? "Guest"), from: task)
        case "guestDisconnected":
            if let participantID = message.participantID { yield(.guestDisconnected(participantID), from: task) }
        case "guestInput":
            let packets = message.inputs ?? (message.input.map { [$0] } ?? [])
            for packet in packets { yield(.guestInput(packet), from: task) }
        case "peerSignal":
            guard let signal = message.peerSignal,
                  let participantID = message.fromParticipantID ?? message.participantID else { return }
            yield(.peerSignal(participantID: participantID, signal: signal), from: task)
        case "networkConfiguration":
            if let configuration = message.networkConfiguration {
                lock.withLock {
                    if !isClosed, webSocketTask === task { networkConfiguration = configuration }
                }
                yield(.networkConfiguration(configuration), from: task)
            }
        case "hostJoinAccepted":
            guard let roomID = message.roomID else { return }
            resolveHostRegistration(error: nil, matching: task, roomID: roomID, configuration: message.networkConfiguration)
        case "hostJoinRejected":
            let error = SignalingError.hostRejected(message.reason ?? "Direct signaling rejected the host.")
            resolveHostRegistration(error: error, matching: task, roomID: message.roomID)
            WebRTCMediaLog.write("remote.coop.direct.signaling.rejected", level: .warning, message: message.reason ?? "Direct signaling rejected the host.")
        case "error":
            resolveHostRegistration(error: SignalingError.hostRejected(message.reason ?? "Direct signaling rejected the host."), matching: task, roomID: message.roomID)
            WebRTCMediaLog.write("remote.coop.direct.signaling.rejected", level: .warning, message: message.reason ?? "Direct signaling rejected the host.")
        default:
            break
        }
    }

    private func send(_ message: SignalingMessage, using expectedTask: URLSessionWebSocketTask? = nil) async {
        let operationID = UUID()
        let gate = ConnectionContinuationGate()
        guard let task = lock.withLock({ () -> URLSessionWebSocketTask? in
            guard !isClosed, let task = webSocketTask else { return nil }
            if let expectedTask, expectedTask !== task { return nil }
            pendingOperations[operationID] = gate
            return task
        }) else { return }
        defer { _ = lock.withLock { pendingOperations.removeValue(forKey: operationID) } }
        do {
            try Task.checkCancellation()
            let data = try JSONEncoder().encode(message)
            try await Self.send(data, using: task, gate: gate)
        } catch {
            WebRTCMediaLog.write("remote.coop.direct.signaling.send.failed", level: .warning, message: error.localizedDescription)
            handleDisconnect(task: task, error: error)
        }
    }

    private func yield(_ event: RemoteCoOpSignalingEvent, from task: URLSessionWebSocketTask) {
        let continuations = lock.withLock { isClosed || webSocketTask !== task ? [] : Array(eventContinuations.values) }
        for continuation in continuations { continuation.yield(event) }
    }
}
