import Darwin
import Foundation

enum NativeNVSTInput: Equatable, Sendable {
    case event(UserInputEvent)
    case absoluteMove(NativeNVSTAbsoluteMouseEvent)
}

final class NativeNVSTInputDispatcher: @unchecked Sendable {
    static let defaultCapacity = 256

    private let buffer: NativeNVSTInputBuffer
    private let queue = DispatchQueue(label: "nvst.input.dispatcher", qos: .userInteractive)
    private let sendAction: @Sendable (NativeNVSTInput) -> Void
    private var isCancelled = false
    private var isDraining = false
    private let lock = NSLock()

    init(capacity: Int = defaultCapacity, send: @escaping @Sendable (NativeNVSTInput) -> Void) {
        self.buffer = NativeNVSTInputBuffer(capacity: capacity)
        self.sendAction = send
    }

    func enqueue(_ event: UserInputEvent) {
        enqueue(.event(event))
    }

    func enqueueAbsoluteMove(_ event: NativeNVSTAbsoluteMouseEvent) {
        enqueue(.absoluteMove(event))
    }

    var pendingInputCount: Int {
        buffer.count
    }

    static func isNeutralizing(_ event: UserInputEvent) -> Bool {
        switch event {
        case .keyboard(let keyboard):
            return !keyboard.isPressed
        case .mouse(.button(_, _, let isPressed, _)):
            return !isPressed
        case .gamepad(let state):
            return state.buttons.isEmpty && state.leftTrigger == 0 && state.rightTrigger == 0 &&
                state.leftStickX == 0 && state.leftStickY == 0 && state.rightStickX == 0 && state.rightStickY == 0
        case .mouse, .text, .hidReport:
            return false
        }
    }

    func finish() async {
        buffer.finish(discardingStaleInput: true)
        scheduleDrain()
        let _: Void = await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: ())
            }
        }
        lock.withLock {
            isCancelled = true
        }
    }

    func cancel() {
        buffer.finish(discardingStaleInput: false)
        lock.withLock {
            isCancelled = true
        }
    }

    deinit {
        cancel()
    }

    private func enqueue(_ input: NativeNVSTInput) {
        guard buffer.append(input) else { return }
        scheduleDrain()
    }

    private func scheduleDrain() {
        let shouldReturn = lock.withLock { () -> Bool in
            if isCancelled || isDraining {
                return true
            }
            isDraining = true
            return false
        }
        if shouldReturn { return }

        queue.async { [weak self] in
            self?.drain()
        }
    }

    private func drain() {
        while let input = buffer.removeFirst() {
            let cancelled = lock.withLock { isCancelled }
            if cancelled { return }
            sendAction(input)
        }
        
        lock.withLock {
            isDraining = false
        }
        
        if !buffer.isFinished && buffer.count > 0 {
            scheduleDrain()
        }
    }
}

private final class NativeNVSTInputBuffer: @unchecked Sendable {
    private let capacity: Int
    private let protectedCapacity: Int
    private let ordinaryCapacity: Int
    private var lock = os_unfair_lock_s()
    private var inputs: [NativeNVSTInput] = []
    private var headIndex = 0
    private var finished = false

    init(capacity: Int) {
        let normalizedCapacity = max(1, capacity)
        self.capacity = normalizedCapacity
        protectedCapacity = normalizedCapacity > Int.max - 96 ? Int.max : normalizedCapacity + 96
        ordinaryCapacity = max(normalizedCapacity, protectedCapacity - 32)
        inputs.reserveCapacity(min(normalizedCapacity, NativeNVSTInputDispatcher.defaultCapacity))
    }

    var isFinished: Bool {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return finished && pendingCount == 0
    }

    var count: Int {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return pendingCount
    }

    func append(_ input: NativeNVSTInput) -> Bool {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        guard !finished else { return false }
        if coalesce(input) { return true }
        makeReservedCapacityIfNeeded(for: input)
        if pendingCount >= capacity {
            if let staleIndex = (headIndex..<inputs.count).first(where: {
                Self.isLossy(inputs[$0]) && !isProtectedAbsoluteMove(at: $0) && !isProspectiveAbsoluteButtonPair(at: $0, incoming: input)
            }) {
                inputs.remove(at: staleIndex)
            } else if Self.isNeutralizing(input), let pressIndex = (headIndex..<inputs.count).first(where: { Self.isNonNeutralButtonOrKeyPress(inputs[$0]) }) {
                inputs.remove(at: pressIndex)
            } else if Self.isNeutralizing(input) {
                removePendingFirst()
            } else if (!Self.isLossy(input) || Self.isAbsoluteMove(input)),
                      pendingCount < capacityLimit(for: input) {
                inputs.append(input)
                return true
            } else {
                return false
            }
        }
        inputs.append(input)
        return true
    }

    func removeFirst() -> NativeNVSTInput? {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return removePendingFirst()
    }

    func finish(discardingStaleInput: Bool) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        guard !finished else { return }
        finished = true
        if discardingStaleInput {
            let staleIndices = (headIndex..<inputs.count).filter { Self.isLossy(inputs[$0]) && !isProtectedAbsoluteMove(at: $0) }
            for index in staleIndices.reversed() { inputs.remove(at: index) }
            compactIfNeeded()
        } else {
            inputs.removeAll(keepingCapacity: false)
            headIndex = 0
        }
    }

    private func coalesce(_ input: NativeNVSTInput) -> Bool {
        guard let last = lastInput else { return false }
        let lastIndex = inputs.count - 1
        switch (last, input) {
        case (.absoluteMove, .absoluteMove):
            inputs[lastIndex] = input
            return true
        case (.event(.mouse(.moved(let oldDeviceID, let oldX, let oldY, _))),
              .event(.mouse(.moved(let newDeviceID, let newX, let newY, let timestamp)))) where oldDeviceID == newDeviceID:
            guard let deltaX = Self.sum(oldX, newX), let deltaY = Self.sum(oldY, newY) else { return false }
            inputs[lastIndex] = .event(.mouse(.moved(
                deviceID: newDeviceID,
                deltaX: deltaX,
                deltaY: deltaY,
                timestamp: timestamp
            )))
            return true
        case (.event(.mouse(.wheel(let oldDeviceID, let oldDelta, _))),
              .event(.mouse(.wheel(let newDeviceID, let newDelta, let timestamp))))
            where oldDeviceID == newDeviceID && (oldDelta > 0) == (newDelta > 0):
            guard let delta = Self.sum(oldDelta, newDelta) else { return false }
            inputs[lastIndex] = .event(.mouse(.wheel(deviceID: newDeviceID, delta: delta, timestamp: timestamp)))
            return true
        case (.event(.gamepad(let oldState)), .event(.gamepad(let newState)))
            where oldState.playerIndex == newState.playerIndex && oldState.deviceID == newState.deviceID &&
                oldState.buttons == newState.buttons &&
                !Self.isNeutralizing(last) && !Self.isNeutralizing(input):
            inputs[lastIndex] = input
            return true
        default:
            return false
        }
    }

    private static func isLossy(_ input: NativeNVSTInput) -> Bool {
        switch input {
        case .absoluteMove, .event(.mouse(.moved)):
            return true
        case .event(.gamepad(let state)):
            return state.buttons.isEmpty && !isNeutralizing(input)
        case .event:
            return false
        }
    }

    private static func isAbsoluteMove(_ input: NativeNVSTInput) -> Bool {
        if case .absoluteMove = input { return true }
        return false
    }

    private func capacityLimit(for input: NativeNVSTInput) -> Int {
        if Self.isAbsoluteMove(input) { return protectedCapacity }
        if case .event(.mouse(.wheel)) = input { return max(ordinaryCapacity, protectedCapacity - 10) }
        if case .event(.mouse(.button)) = input, lastInput.map(Self.isAbsoluteMove) == true { return protectedCapacity }
        return ordinaryCapacity
    }

    private func makeReservedCapacityIfNeeded(for input: NativeNVSTInput) {
        guard pendingCount >= capacityLimit(for: input) else { return }
        let needsAbsoluteSlot = Self.isAbsoluteMove(input)
        let needsButtonSlot = lastInput.map(Self.isAbsoluteMove) == true && {
            if case .event(.mouse(.button)) = input { return true }
            return false
        }()
        guard needsAbsoluteSlot || needsButtonSlot else { return }
        let pairEnd = inputs.count - (needsButtonSlot ? 2 : 1)
        guard pairEnd > headIndex,
              let pairStart = (headIndex..<pairEnd).first(where: { isEvictableAbsolutePressPair(at: $0) }) else { return }
        inputs.remove(at: pairStart + 1)
        inputs.remove(at: pairStart)
    }

    private func isEvictableAbsolutePressPair(at index: Int) -> Bool {
        guard isProtectedAbsoluteMove(at: index) else { return false }
        guard case .event(.mouse(.button(_, _, let isPressed, _))) = inputs[index + 1] else { return false }
        return isPressed
    }

    private static func isNeutralizing(_ input: NativeNVSTInput) -> Bool {
        guard case .event(let event) = input else { return false }
        return NativeNVSTInputDispatcher.isNeutralizing(event)
    }

    private static func isNonNeutralButtonOrKeyPress(_ input: NativeNVSTInput) -> Bool {
        switch input {
        case .event(.keyboard(let event)):
            return event.isPressed
        case .event(.mouse(.button(_, _, let isPressed, _))):
            return isPressed
        case .event(.gamepad(let state)):
            return !state.buttons.isEmpty
        default:
            return false
        }
    }

    private func isProtectedAbsoluteMove(at index: Int) -> Bool {
        guard index >= headIndex, inputs.indices.contains(index + 1), case .absoluteMove = inputs[index] else { return false }
        guard case .event(.mouse(.button)) = inputs[index + 1] else { return false }
        return true
    }

    private func isProspectiveAbsoluteButtonPair(at index: Int, incoming: NativeNVSTInput) -> Bool {
        guard index >= headIndex, index == inputs.count - 1, case .absoluteMove = inputs[index] else { return false }
        guard case .event(.mouse(.button)) = incoming else { return false }
        return true
    }

    private var pendingCount: Int { inputs.count - headIndex }

    private var lastInput: NativeNVSTInput? {
        pendingCount > 0 ? inputs[inputs.count - 1] : nil
    }

    @discardableResult
    private func removePendingFirst() -> NativeNVSTInput? {
        guard pendingCount > 0 else { return nil }
        let input = inputs[headIndex]
        headIndex += 1
        compactIfNeeded()
        return input
    }

    private func compactIfNeeded() {
        if pendingCount == 0 {
            inputs.removeAll(keepingCapacity: true)
            headIndex = 0
        } else if headIndex >= 64 && headIndex >= pendingCount {
            inputs.removeFirst(headIndex)
            headIndex = 0
        }
    }

    private static func sum(_ lhs: Int16, _ rhs: Int16) -> Int16? {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? nil : sum
    }
}
