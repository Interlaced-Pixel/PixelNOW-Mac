import Foundation

public final class NvstVideoFrameLifecycle: @unchecked Sendable {
    public struct Snapshot: Sendable {
        public let unit: NvstAccessUnit
        public let decoderPresentAt: UInt64
        public let predecodeCompletedAt: UInt64?
        public let decodeStartedAt: UInt64?
        public let decodeCompletedAt: UInt64?
        public let renderPresentAt: UInt64?
        public let renderStartedAt: UInt64?
        public let renderCompletedAt: UInt64?
        public let presentedAt: UInt64?
        public let gpuDurationMilliseconds: Double?
        public let statusFlags: UInt32
    }

    public let unit: NvstAccessUnit
    var presentationSchedule: NvstFrameTiming.Schedule {
        lock.lock()
        defer { lock.unlock() }
        return schedule
    }
    public var presentationDeadlineNanoseconds: UInt64 { presentationSchedule.deadlineNanoseconds }
    public let maximumQueuedFrames: Int
    public let maximumPresentationCaptureSpanMicroseconds: UInt64?
    private let lock = NSLock()
    private let decoderPresentAt: UInt64
    private var schedule: NvstFrameTiming.Schedule
    private var predecodeCompletedAt: UInt64?
    private var decodeStartedAt: UInt64?
    private var decodeCompletedAt: UInt64?
    private var renderPresentAt: UInt64?
    private var renderStartedAt: UInt64?
    private var renderCompletedAt: UInt64?
    private var presentedAt: UInt64?
    private var gpuDurationMilliseconds: Double?
    private var statusFlags: UInt32 = 0
    private var isFinished = false
    private let terminalHandler: @Sendable (Snapshot) -> Void

    public init(unit: NvstAccessUnit, decoderPresentAt: UInt64,
                maximumQueuedFrames: Int, maximumPresentationCaptureSpanMicroseconds: UInt64?,
                terminalHandler: @escaping @Sendable (Snapshot) -> Void) {
        self.unit = unit
        self.schedule = NvstFrameTiming.Schedule(deadlineNanoseconds: decoderPresentAt,
            frameDurationSeconds: 1 / 60, variableRefreshDurationSeconds: 1 / 60,
            arrivalJitterSeconds: 0, pinnedQueue: false)
        self.maximumQueuedFrames = max(1, maximumQueuedFrames)
        self.maximumPresentationCaptureSpanMicroseconds = maximumPresentationCaptureSpanMicroseconds
        self.decoderPresentAt = decoderPresentAt
        self.terminalHandler = terminalHandler
    }

    func notePresentationSchedule(_ schedule: NvstFrameTiming.Schedule) {
        lock.lock()
        if !isFinished { self.schedule = schedule }
        lock.unlock()
    }

    var presentationQueueDurationMicroseconds: UInt64? {
        lock.lock()
        defer { lock.unlock() }
        guard let renderPresentAt, let presentedAt, presentedAt >= renderPresentAt else { return nil }
        return (presentedAt - renderPresentAt) / 1000
    }

    public func notePredecodeCompleted(at timestamp: UInt64) {
        lock.lock()
        if !isFinished { predecodeCompletedAt = timestamp }
        lock.unlock()
    }

    public var isTerminal: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isFinished
    }

    public func noteDecodeStarted(at timestamp: UInt64) {
        lock.lock()
        if !isFinished { decodeStartedAt = timestamp }
        lock.unlock()
    }

    public func decodeDurationMicroseconds(completedAt: UInt64) -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        guard let decodeStartedAt, completedAt >= decodeStartedAt else { return nil }
        return (completedAt - decodeStartedAt) / 1000
    }

    public var decodeQueueDurationMicroseconds: UInt64? {
        lock.lock()
        defer { lock.unlock() }
        guard let predecodeCompletedAt, predecodeCompletedAt >= decoderPresentAt else { return nil }
        return (predecodeCompletedAt - decoderPresentAt) / 1000
    }

    public var renderQueueDurationMilliseconds: Double? {
        lock.lock()
        defer { lock.unlock() }
        guard let renderPresentAt, let renderStartedAt, renderStartedAt >= renderPresentAt else { return nil }
        return Double(renderStartedAt - renderPresentAt) / 1_000_000
    }

    public func noteDecoded(at timestamp: UInt64, success: Bool) {
        lock.lock()
        guard !isFinished else { lock.unlock(); return }
        decodeCompletedAt = timestamp
        if !success { statusFlags |= 1 << 2 }
        let snapshot = !success ? finishLocked() : nil
        lock.unlock()
        if let snapshot { terminalHandler(snapshot) }
    }

    public func noteRenderPresent(at timestamp: UInt64) {
        lock.lock()
        if !isFinished { renderPresentAt = timestamp }
        lock.unlock()
    }

    public func noteRenderStarted(at timestamp: UInt64) {
        lock.lock()
        if !isFinished, renderStartedAt == nil { renderStartedAt = timestamp }
        lock.unlock()
    }

    public func noteGpuCompleted(at timestamp: UInt64, durationMilliseconds: Double?, success: Bool) {
        lock.lock()
        guard !isFinished else { lock.unlock(); return }
        renderCompletedAt = timestamp
        gpuDurationMilliseconds = durationMilliseconds
        if !success { statusFlags |= 1 << 3 }
        let snapshot = !success || presentedAt != nil ? finishLocked() : nil
        lock.unlock()
        if let snapshot { terminalHandler(snapshot) }
    }

    @discardableResult
    public func notePresented(at timestamp: UInt64) -> Bool {
        lock.lock()
        guard !isFinished, presentedAt == nil else { lock.unlock(); return false }
        presentedAt = timestamp
        let snapshot = renderCompletedAt != nil ? finishLocked() : nil
        lock.unlock()
        if let snapshot { terminalHandler(snapshot) }
        return true
    }

    public func discard(decoded: Bool) {
        lock.lock()
        guard !isFinished else { lock.unlock(); return }
        statusFlags |= decoded ? 1 << 3 : 1 << 8
        let snapshot = finishLocked()
        lock.unlock()
        if let snapshot { terminalHandler(snapshot) }
    }

    private func finishLocked() -> Snapshot? {
        guard !isFinished else { return nil }
        isFinished = true
        return snapshotLocked()
    }

    var statisticsSnapshot: Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return snapshotLocked()
    }

    private func snapshotLocked() -> Snapshot {
        return Snapshot(unit: unit, decoderPresentAt: decoderPresentAt,
            predecodeCompletedAt: predecodeCompletedAt, decodeStartedAt: decodeStartedAt,
            decodeCompletedAt: decodeCompletedAt, renderPresentAt: renderPresentAt,
            renderStartedAt: renderStartedAt, renderCompletedAt: renderCompletedAt,
            presentedAt: presentedAt, gpuDurationMilliseconds: gpuDurationMilliseconds,
            statusFlags: statusFlags)
    }
}
