import CoreMedia
import Foundation
public final class NvstSessionClock: @unchecked Sendable {
    let lock = NSLock()
    var startedAt: Date?
    private var originNanoseconds: UInt64?

    public init() {}
    public func start(at date: Date = Date()) {
        lock.lock()
        if startedAt == nil {
            startedAt = date
            originNanoseconds = DispatchTime.now().uptimeNanoseconds
        }
        lock.unlock()
    }

    public var startDate: Date? {
        lock.lock()
        defer { lock.unlock() }
        return startedAt
    }

    public func elapsedMicroseconds() -> UInt64 {
        lock.lock()
        let origin = originNanoseconds
        lock.unlock()
        guard let origin else { return 0 }
        let now = DispatchTime.now().uptimeNanoseconds
        return now >= origin ? (now - origin) / 1_000 : 0
    }

    public func milliseconds(at timestamp: UInt64) -> Double {
        lock.lock()
        let origin = originNanoseconds
        lock.unlock()
        guard let origin else { return 0 }
        return timestamp >= origin ? Double(timestamp - origin) / 1_000_000 : 0
    }
}
public final class NvstVideoPipeline: @unchecked Sendable {
    public struct StageTimings: Sendable, Equatable {
        public var hop = 0.0
        public var decode = 0.0
        public var ack = 0.0

        public var total: Double { hop + decode + ack }

        mutating func raise(to other: StageTimings) {
            hop = max(hop, other.hop)
            decode = max(decode, other.decode)
            ack = max(ack, other.ack)
        }

        mutating func add(_ other: StageTimings) {
            hop += other.hop
            decode += other.decode
            ack += other.ack
        }
    }

    public struct Counters: Sendable {
        public var framesHandled: UInt64 = 0
        public var frameAcksSent = 0
        public var frameAckFailures = 0
        public var frameAckQueueDrops = 0
        public var pacingReportsSent = 0
        public var pacingReportFailures = 0
        public var missingParameterSetFrames = 0
        public var slowFrames = 0
        public var lastDecodeLatencyMilliseconds = 0.0
        public var recentDecodeMilliseconds = -1.0
        public var peak = StageTimings()
        public var total = StageTimings()
        public var inFlightHistogram: [Int: Int] = [:]
        public var timingSummary: String {
            let frames = Double(max(1, framesHandled))
            let inFlight = inFlightHistogram.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: ",")
            return String(format: "peak[hop=%.1f decode=%.1f ack=%.1f] mean[hop=%.2f decode=%.2f ack=%.2f]ms inFlight=%@",
                          peak.hop, peak.decode, peak.ack,
                          total.hop / frames, total.decode / frames, total.ack / frames, inFlight)
        }
    }
    public static let slowFrameMilliseconds = 50.0
    public static let maximumLoggedSlowFrames = 60
    public static let fatalDecodeFailureCount = 30
    let decoder: NvstVideoToolboxDecoder
    private let clock: NvstSessionClock
    private var displayIntervalMicroseconds: UInt32
    var displayVsyncMicroseconds: UInt32 {
        lock.lock()
        defer { lock.unlock() }
        return displayIntervalMicroseconds
    }
    let logger: (@Sendable (String) -> Void)?
    private let mediaSink: (@Sendable (NvstAccessUnit) -> Void)?
    private let onKeyframeNeeded: @Sendable () -> Void
    private let onFatalDecodeError: @Sendable (String) -> Void
    private let qosManager: NvstQosManager?
    let queue = DispatchQueue(label: "com.interlacedpixel.pixelnow.nvst.decode", qos: .userInitiated)
    let lock = NSLock()
    var bundle: NvstWebRtcBundle?
    private var counters = Counters()
    private var loggedSlowFrames = 0
    private var consecutiveDecodeFailures = 0
    private var isStopped = false
    private var pendingFrames = 0
    private var recentDecodeDurations: [Double] = []

    private struct PendingCompletion {
        let unit: NvstAccessUnit
        let hopMilliseconds: Double
        let startedAt: UInt64
    }
    private var pendingCompletions: [UInt64: PendingCompletion] = [:]
    private var pendingLifecycles: [UInt64: NvstVideoFrameLifecycle] = [:]
    private var terminalStatistics: [UInt32: NvstVideoFrameLifecycle.Snapshot] = [:]
    private var lastStatisticsFrame: UInt32?
    private var pendingFrameAcknowledgements: [NvstFrameAck] = []
    private var signalStrength: Int32 = 0
    private var networkSpeedKbps: UInt32 = 0
    private let queueKey = DispatchSpecificKey<Bool>()
    private var nextOperationID: UInt64 = 0
    private let feedbackConfiguration: NvstFeedbackConfiguration
    private let framePacingConfiguration: NvstFramePacingConfiguration
    private let frameTiming = NvstFrameTiming()
    private var presentationConfiguration = NvstClientDJBConfig()

    public init(decoder: NvstVideoToolboxDecoder,
                clock: NvstSessionClock,
                frameTimeMicroseconds: UInt32,
                displayVsyncMicroseconds: UInt32,
                feedbackConfiguration: NvstFeedbackConfiguration,
                framePacingConfiguration: NvstFramePacingConfiguration,
                logger: (@Sendable (String) -> Void)?,
                mediaSink: (@Sendable (NvstAccessUnit) -> Void)?,
                onKeyframeNeeded: @escaping @Sendable () -> Void,
                onFatalDecodeError: @escaping @Sendable (String) -> Void,
                qosManager: NvstQosManager? = nil) {
        self.decoder = decoder
        self.clock = clock
        self.displayIntervalMicroseconds = displayVsyncMicroseconds
        self.feedbackConfiguration = feedbackConfiguration
        self.framePacingConfiguration = framePacingConfiguration
        self.logger = logger
        self.mediaSink = mediaSink
        self.onKeyframeNeeded = onKeyframeNeeded
        self.onFatalDecodeError = onFatalDecodeError
        self.qosManager = qosManager
        queue.setSpecific(key: queueKey, value: true)
    }
    public func attach(bundle: NvstWebRtcBundle?) {
        lock.lock()
        self.bundle = bundle
        lock.unlock()
    }

    public func updateDisplayInterval(microseconds: UInt32) {
        lock.lock()
        displayIntervalMicroseconds = microseconds
        lock.unlock()
    }

    public func updateNetworkLink(signalStrength: Int32, networkSpeedKbps: UInt32) {
        lock.lock()
        self.signalStrength = signalStrength
        self.networkSpeedKbps = networkSpeedKbps
        lock.unlock()
    }

    public func configurePresentation(_ configuration: NvstClientDJBConfig) {
        queue.async { [weak self] in
            guard let self else { return }
            lock.lock()
            presentationConfiguration = configuration
            frameTiming.configure(configuration)
            lock.unlock()
            qosManager?.handleDJBConfigResponse(config: configuration)
        }
    }

    public func requestPresentation(_ request: NvstClientDJBConfig) {
        queue.async { [weak self] in
            guard let self else { return }
            lock.lock()
            let stopped = isStopped
            lock.unlock()
            guard !stopped else { return }
            var response = request.pinned ? request : presentationConfiguration
            response.reason = request.reason
            response.mode = request.mode == .unchanged ? presentationConfiguration.mode : request.mode
            response.maximumDepthMicroseconds = max(response.minimumDepthMicroseconds, response.maximumDepthMicroseconds)
            lock.lock()
            frameTiming.configure(response)
            lock.unlock()
            qosManager?.handleDJBConfigResponse(config: response)
            logger?("NVST DJB applied reason=\(response.reason.rawValue) mode=\(response.mode.rawValue) minUs=\(response.minimumDepthMicroseconds) maxUs=\(response.maximumDepthMicroseconds) pinned=\(response.pinned)")
        }
    }

    public var snapshot: Counters {
        lock.lock()
        defer { lock.unlock() }
        return counters
    }
    public func submit(_ unit: NvstAccessUnit) {
        let enqueued = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        guard !isStopped else { lock.unlock(); return }
        pendingFrames += 1
        lock.unlock()
        queue.async { [weak self] in self?.process(unit, enqueuedAt: enqueued) }
    }

    public func submitFrameStatistics(frameIndex: UInt32, statistics: NvstFrameReceiveStatistics.Snapshot) {
        queue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let channel = self.isStopped ? nil : self.bundle
            let lifecycle = self.terminalStatistics.removeValue(forKey: frameIndex)
                ?? self.pendingLifecycles.values.first(where: { $0.unit.frameIndex == frameIndex })?.statisticsSnapshot
            self.lastStatisticsFrame = frameIndex
            self.terminalStatistics = self.terminalStatistics.filter { frameIndex &- $0.key >= 0x8000_0000 }
            self.lock.unlock()
            guard self.feedbackConfiguration.frameStatsVersion >= 4, let channel else { return }
            let ack = self.makeFrameAck(frameIndex: frameIndex, receive: statistics, lifecycle: lifecycle)
            self.lock.lock()
            guard !self.isStopped else { self.lock.unlock(); return }
            if self.pendingFrameAcknowledgements.count < 256 {
                self.pendingFrameAcknowledgements.append(ack)
            } else {
                self.counters.frameAckQueueDrops += 1
            }
            self.lock.unlock()
            self.flushFrameStatistics(on: channel)
        }
    }

    public func retryFrameStatistics() {
        queue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let channel = self.isStopped ? nil : self.bundle
            self.lock.unlock()
            if let channel { self.flushFrameStatistics(on: channel) }
        }
    }

    private func flushFrameStatistics(on channel: NvstWebRtcBundle) {
        for _ in 0..<256 {
            lock.lock()
            let ack = isStopped ? nil : pendingFrameAcknowledgements.first
            lock.unlock()
            guard let ack else { return }
            let accepted = channel.sendPartiallyReliableControl(ack.command)
            lock.lock()
            if accepted {
                if pendingFrameAcknowledgements.first?.frameNumber == ack.frameNumber {
                    pendingFrameAcknowledgements.removeFirst()
                }
                counters.frameAcksSent += 1
            } else {
                counters.frameAckFailures += 1
            }
            lock.unlock()
            if !accepted { return }
        }
    }

    public func stop() {
        lock.lock()
        isStopped = true
        let lifecycles = Array(pendingLifecycles.values)
        pendingLifecycles.removeAll()
        pendingCompletions.removeAll()
        terminalStatistics.removeAll()
        pendingFrameAcknowledgements.removeAll()
        lastStatisticsFrame = nil
        lock.unlock()
        for lifecycle in lifecycles { lifecycle.discard(decoded: false) }
    }

    private func process(_ unit: NvstAccessUnit, enqueuedAt: UInt64) {
        lock.lock()
        pendingFrames = max(0, pendingFrames - 1)
        let stopped = isStopped
        lock.unlock()
        guard !stopped else { return }

        let started = DispatchTime.now().uptimeNanoseconds
        var timings = StageTimings()
        timings.hop = Self.milliseconds(from: enqueuedAt, to: started)
        mediaSink?(unit)

        lock.lock()
        guard !isStopped else { lock.unlock(); return }
        counters.inFlightHistogram[pendingCompletions.count, default: 0] += 1
        nextOperationID &+= 1
        let operationID = nextOperationID
        let lifecycle = NvstVideoFrameLifecycle(unit: unit, decoderPresentAt: enqueuedAt,
            maximumQueuedFrames: Int(framePacingConfiguration.maximumQueuedFrames),
            maximumPresentationCaptureSpanMicroseconds: qosManager?.maximumPresentationCaptureSpanMicroseconds) { [weak self] snapshot in
            self?.queue.async { [weak self] in self?.handleFrameTerminal(operationID: operationID, snapshot: snapshot) }
        }
        pendingLifecycles[operationID] = lifecycle
        pendingCompletions[operationID] = PendingCompletion(unit: unit, hopMilliseconds: timings.hop, startedAt: started)
        lock.unlock()
        do {
            try decoder.decode(unit, lifecycle: lifecycle) { [weak self] success, completedAt in
                guard let self else { return }
                if success {
                    self.lock.lock()
                    let schedule = self.frameTiming.nextSchedule(
                        captureMicroseconds: unit.captureTimestampMicroseconds,
                        arrivalNanoseconds: completedAt)
                    self.lock.unlock()
                    lifecycle.notePresentationSchedule(schedule)
                }
                lifecycle.noteDecoded(at: completedAt, success: success)
                if success, let duration = lifecycle.decodeDurationMicroseconds(completedAt: completedAt) {
                    self.qosManager?.recordDecodeDuration(microseconds: duration)
                }
                if let duration = lifecycle.decodeQueueDurationMicroseconds {
                    self.qosManager?.recordDecodeQueueDuration(microseconds: duration)
                }
                if DispatchQueue.getSpecific(key: self.queueKey) == true {
                    self.handleDecodeCompleted(operationID: operationID, success: success, completedAt: completedAt)
                } else {
                    self.queue.async { [weak self] in
                        self?.handleDecodeCompleted(operationID: operationID, success: success, completedAt: completedAt)
                    }
                }
            }
        } catch NvstVideoToolboxDecoder.DecoderError.missingParameterSets {
            lock.lock()
            let removed = pendingCompletions.removeValue(forKey: operationID)
            if removed != nil { counters.missingParameterSetFrames += 1 }
            lock.unlock()
            guard removed != nil else { return }
            requestKeyframeThrottled()
            lifecycle.noteDecoded(at: DispatchTime.now().uptimeNanoseconds, success: false)
            let failedAt = DispatchTime.now().uptimeNanoseconds
            timings.decode = Self.milliseconds(from: started, to: failedAt)

            record(timings, frameNumber: unit.frameIndex, unit: unit)
            return
        } catch {
            lock.lock()
            let removed = pendingCompletions.removeValue(forKey: operationID)
            lock.unlock()
            guard removed != nil else { return }
            lifecycle.noteDecoded(at: DispatchTime.now().uptimeNanoseconds, success: false)
            consecutiveDecodeFailures += 1
            logger?("NVST decode error: \(error.localizedDescription)")
            requestKeyframeThrottled()
            if consecutiveDecodeFailures >= Self.fatalDecodeFailureCount {
                consecutiveDecodeFailures = 0
                onFatalDecodeError(error.localizedDescription)
            }
            let failedAt = DispatchTime.now().uptimeNanoseconds
            timings.decode = Self.milliseconds(from: started, to: failedAt)

            record(timings, frameNumber: unit.frameIndex, unit: unit)
            return
        }
    }
    private func handleDecodeCompleted(operationID: UInt64, success: Bool, completedAt: UInt64) {
        lock.lock()
        guard !isStopped, let entry = pendingCompletions.removeValue(forKey: operationID) else { lock.unlock(); return }
        counters.lastDecodeLatencyMilliseconds = Self.milliseconds(from: entry.unit.receivedAtNanoseconds, to: completedAt)
        lock.unlock()
        if success {
            consecutiveDecodeFailures = 0
        } else {
            consecutiveDecodeFailures += 1
            if consecutiveDecodeFailures >= Self.fatalDecodeFailureCount {
                consecutiveDecodeFailures = 0
                onFatalDecodeError("VideoToolbox repeatedly failed to output a decoded frame.")
            }
        }
        let decodedAt = completedAt
        var timings = StageTimings()
        timings.hop = entry.hopMilliseconds
        timings.decode = Self.milliseconds(from: entry.startedAt, to: decodedAt)

        record(timings, frameNumber: entry.unit.frameIndex, unit: entry.unit)
    }

    private func handleFrameTerminal(operationID: UInt64, snapshot: NvstVideoFrameLifecycle.Snapshot) {
        lock.lock()
        guard pendingLifecycles.removeValue(forKey: operationID) != nil, !isStopped else {
            lock.unlock()
            return
        }
        let frameIndex = snapshot.unit.frameIndex
        if feedbackConfiguration.frameStatsVersion >= 4,
           lastStatisticsFrame.map({ let distance = frameIndex &- $0; return distance > 0 && distance < 0x8000_0000 }) ?? true {
            if let overwritten = terminalStatistics.keys.first(where: { ($0 & 255) == (frameIndex & 255) }) {
                terminalStatistics.removeValue(forKey: overwritten)
            }
            terminalStatistics[frameIndex] = snapshot
        }
        lock.unlock()
        let unit = snapshot.unit
        if let started = snapshot.renderStartedAt, let finished = snapshot.renderCompletedAt, finished > started {
            qosManager?.recordRenderDuration(microseconds: (finished - started) / 1000)
        }
        if let renderPresent = snapshot.renderPresentAt, let presented = snapshot.presentedAt,
           let renderStarted = snapshot.renderStartedAt, let renderCompleted = snapshot.renderCompletedAt,
           presented >= renderPresent, renderCompleted >= renderStarted {
            qosManager?.recordPresentation(frameNumber: unit.frameIndex,
                processingMicroseconds: (presented - renderPresent) / 1000,
                renderMicroseconds: (renderCompleted - renderStarted) / 1000,
                renderPresentNanoseconds: renderPresent,
                captureTimestampMicroseconds: unit.captureTimestampMicroseconds)
        }
    }

    private func makeFrameAck(frameIndex: UInt32, receive: NvstFrameReceiveStatistics.Snapshot,
                              lifecycle snapshot: NvstVideoFrameLifecycle.Snapshot?) -> NvstFrameAck {
        lock.lock()
        let signalStrength = self.signalStrength
        let networkSpeedKbps = self.networkSpeedKbps
        lock.unlock()
        let receivedAt = receive.firstReceivedAtNanoseconds ?? snapshot?.unit.receivedAtNanoseconds ?? 0
        let delta: (UInt64?) -> Float = { timestamp in
            guard let timestamp else { return -1 }
            return Float(Self.milliseconds(from: receivedAt, to: timestamp))
        }
        return NvstFrameAck(frameNumber: frameIndex,
            version: receive.firstReceivedAtNanoseconds == nil && snapshot == nil ? 3 : feedbackConfiguration.frameStatsVersion,
            lostPackets: receive.lostPackets,
            firstPacketReceivedMilliseconds: clock.milliseconds(at: receivedAt),
            decoderPresentMilliseconds: delta(snapshot?.decoderPresentAt),
            decodeStartMilliseconds: delta(snapshot?.decodeStartedAt),
            predecodeCompletedMilliseconds: delta(snapshot?.predecodeCompletedAt),
            renderPresentMilliseconds: delta(snapshot?.renderPresentAt),
            renderStartMilliseconds: delta(snapshot?.renderStartedAt),
            renderCompletedMilliseconds: delta(snapshot?.renderCompletedAt),
            presentCompletedMilliseconds: delta(snapshot?.presentedAt),
            gpuDurationMilliseconds: Float(snapshot?.gpuDurationMilliseconds ?? -1),
            rtpQueueMilliseconds: receive.rtpQueueMilliseconds,
            fecDecodeMilliseconds: receive.fecDecodeMilliseconds,
            receiveDurationMilliseconds: receive.firstReceivedAtNanoseconds == nil ? 0
                : delta(receive.lastReceivedAtNanoseconds ?? snapshot?.unit.lastPacketReceivedAtNanoseconds),
            oneWayDelayMilliseconds: receive.oneWayDelayMilliseconds,
            transmitGapMilliseconds: receive.transmitGapMilliseconds,
            frameBytes: snapshot.map { UInt32(clamping: $0.unit.bytes.count) } ?? receive.frameBytes,
            statusFlags: (snapshot?.statusFlags ?? 0) | receive.statusFlags,
            recoveredNackPackets: receive.recoveredNackPackets,
            rtpInactivityMilliseconds: receive.rtpInactivityMilliseconds,
            transportInactivityMilliseconds: receive.transportInactivityMilliseconds,
            signalStrength: signalStrength, networkSpeedKbps: networkSpeedKbps)
    }

    private func requestKeyframeThrottled() {
        onKeyframeNeeded()
    }

    private func record(_ timings: StageTimings, frameNumber: UInt32, unit: NvstAccessUnit) {
        lock.lock()
        counters.framesHandled &+= 1
        counters.peak.raise(to: timings)
        counters.total.add(timings)
        recentDecodeDurations.append(timings.decode)
        if recentDecodeDurations.count > 60 { recentDecodeDurations.removeFirst() }
        counters.recentDecodeMilliseconds = recentDecodeDurations.reduce(0, +) / Double(recentDecodeDurations.count)
        let isSlow = timings.total >= Self.slowFrameMilliseconds
        if isSlow { counters.slowFrames += 1 }
        let shouldLog = isSlow && loggedSlowFrames < Self.maximumLoggedSlowFrames
        if shouldLog { loggedSlowFrames += 1 }
        lock.unlock()
        guard shouldLog else { return }
        logger?(String(format: "NVST SLOW FRAME #%u total=%.1fms hop=%.1f decode=%.1f ack=%.1f bytes=%d key=%@",
                       frameNumber, timings.total, timings.hop, timings.decode, timings.ack,
                       unit.bytes.count, unit.isKeyframe ? "y" : "n"))
    }

    public func noteProcessingReport(accepted: Bool) {
        lock.lock()
        if accepted { counters.pacingReportsSent += 1 } else { counters.pacingReportFailures += 1 }
        lock.unlock()
    }

    private static func milliseconds(from start: UInt64, to end: UInt64) -> Double {
        end > start ? Double(end - start) / 1_000_000 : 0
    }

}
