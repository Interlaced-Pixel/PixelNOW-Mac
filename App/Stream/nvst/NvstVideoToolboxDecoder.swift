import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

public final class NvstVideoToolboxDecoder: @unchecked Sendable {
    public enum DecoderError: LocalizedError, Equatable, Sendable {
        case unsupportedCodec(String)
        case missingParameterSets
        case formatDescriptionFailed(OSStatus)
        case sessionCreationFailed(OSStatus)
        case blockBufferFailed(OSStatus)
        case sampleBufferFailed(OSStatus)
        case decodeFailed(OSStatus)
        case emptySample
        case missingOutput

        public var errorDescription: String? {
            switch self {
            case .unsupportedCodec(let codec): "NVST video codec \(codec) has no VideoToolbox decode path yet."
            case .missingParameterSets: "NVST video stream has not delivered a keyframe with parameter sets yet."
            case .formatDescriptionFailed(let status): "NVST decoder could not build a format description (OSStatus \(status))."
            case .sessionCreationFailed(let status): "NVST decoder could not create a decompression session (OSStatus \(status))."
            case .blockBufferFailed(let status): "NVST decoder could not wrap the access unit (OSStatus \(status))."
            case .sampleBufferFailed(let status): "NVST decoder could not build a sample buffer (OSStatus \(status))."
            case .decodeFailed(let status): "NVST decoder rejected a frame (OSStatus \(status))."
            case .emptySample: "NVST access unit contains no decodable sample."
            case .missingOutput: "NVST decoder completed without an image."
            }
        }
    }

    public static let clockRate: Int32 = 90_000

    private let stateLock = NSLock()
    private let operationLock = NSLock()
    let statsLock = NSLock()
    let codec: NVSTVideoCodec
    private var parameterSets = NvstElementaryStream.ParameterSets()
    private var formatDescription: CMVideoFormatDescription?
    var session: VTDecompressionSession?
    private var decodedFrames: UInt64 = 0
    private var failedFrames: UInt64 = 0
    private var firstFailureStatus: OSStatus = noErr
    private var lastFailureStatus: OSStatus = noErr
    private var loggedFailures = 0
    private var loggedAccepted = 0
    private var lastLoggedFailureAt: UInt64?
    private var suppressedFailureCount = 0
    static let maxLoggedAccepted = 6

    static func describeOSStatus(_ status: OSStatus) -> String {
        switch status {
        case -12909: return "-12909 (kVTVideoDecoderBadDataErr)"
        case -12911: return "-12911 (kVTVideoDecoderConfigurationErr)"
        case -12903: return "-12903 (kVTVideoDecoderReferenceMissingErr)"
        case -12913: return "-12913 (kVTVideoDecoderNotAvailableNowErr)"
        case -12905: return "-12905 (kVTVideoDecoderUnsupportedDataFormatErr)"
        case -12906: return "-12906 (kVTVideoDecoderMalfunctionErr)"
        default: return "\(status)"
        }
    }

    public func prewarm(parameterSets sets: NvstElementaryStream.ParameterSets) {
        guard sets.isComplete else { return }
        operationLock.lock()
        defer { operationLock.unlock() }
        _ = try? prepareSession(for: sets)
    }

    private var hasSeenKeyframe = false
    private var generation: UInt64 = 0

    private final class DecodeOperation: @unchecked Sendable {
        private let lock = NSLock()
        private var completed = false

        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !completed else { return false }
            completed = true
            return true
        }
    }

    public var onDecodeFailure: (@Sendable (UInt32) -> Void)?
    public var onDecoderLog: (@Sendable (String) -> Void)?

    static func accessUnitShape(_ bytes: Data, codec: NVSTVideoCodec) -> String {
        let buffer = [UInt8](bytes)
        let units = NvstAnnexB.nalUnits(bytes)
        let described = units.prefix(12).map { unit -> String in
            guard unit.offset < buffer.count else { return "?" }
            let header = buffer[unit.offset]
            let type: Int = switch codec {
            case .h264: Int(header & 0x1f)
            case .hevc: Int((header >> 1) & 0x3f)
            case .av1: Int(header)
            }
            let head = buffer[unit.offset..<min(unit.offset + 4, buffer.count)]
                .map { String(format: "%02x", $0) }.joined()
            return "\(type):\(unit.length):\(head)"
        }
        return "bytes=\(bytes.count) nals=[\(described.joined(separator: ", "))]"
    }

    public var onPixelBuffer: (@Sendable (CVPixelBuffer, CMTime, Bool, NvstVideoFrameLifecycle) -> Void)?

    public init(codec: NVSTVideoCodec) throws {
        guard codec == .h264 || codec == .hevc || codec == .av1 else {
            throw DecoderError.unsupportedCodec(codec.rawValue)
        }
        self.codec = codec
    }

    public var decodedFrameCount: UInt64 { statsLock.lock(); defer { statsLock.unlock() }; return decodedFrames }

    public var decodedResolution: String? {
        statsLock.lock()
        defer { statsLock.unlock() }
        guard decodedWidth > 0, decodedHeight > 0 else { return nil }
        return "\(decodedWidth)x\(decodedHeight)"
    }
    private var decodedWidth = 0
    private var decodedHeight = 0

    public var bitstreamFormat: BitstreamFormat? {
        statsLock.lock()
        defer { statsLock.unlock() }
        return currentBitstreamFormat
    }
    var currentBitstreamFormat: BitstreamFormat?

    public var outputPixelFormatName: String {
        statsLock.lock()
        defer { statsLock.unlock() }
        return Self.pixelFormatName(outputPixelFormat)
    }
    private var outputPixelFormat: OSType = 0
    public var failedFrameCount: UInt64 { statsLock.lock(); defer { statsLock.unlock() }; return failedFrames }

    public var failureStatusSummary: String {
        statsLock.lock()
        defer { statsLock.unlock() }
        guard firstFailureStatus != noErr || lastFailureStatus != noErr else { return "-" }
        return firstFailureStatus == lastFailureStatus ? "\(firstFailureStatus)" : "\(firstFailureStatus)/\(lastFailureStatus)"
    }

    public func invalidate() {
        operationLock.lock()
        defer { operationLock.unlock() }
        stateLock.lock()
        let expiring = session
        session = nil
        formatDescription = nil
        parameterSets = NvstElementaryStream.ParameterSets()
        hasSeenKeyframe = false
        generation &+= 1
        stateLock.unlock()
        Self.tearDown(expiring)
    }

    public func decode(_ unit: NvstAccessUnit, lifecycle: NvstVideoFrameLifecycle, completion: @escaping @Sendable (Bool, UInt64) -> Void) throws {
        operationLock.lock()
        defer { operationLock.unlock() }
        let decodeStart = DispatchTime.now().uptimeNanoseconds

        stateLock.lock()
        let decodeGeneration = generation
        let awaitingFirstKeyframe = !hasSeenKeyframe
        stateLock.unlock()
        guard !awaitingFirstKeyframe || unit.isKeyframe else { throw DecoderError.missingParameterSets }

        let prepared = NvstElementaryStream.prepare(unit.bytes, codec: codec)

        let (session, description) = try prepareSession(for: prepared.parameterSets)

        let buildStart = DispatchTime.now().uptimeNanoseconds
        let sample = prepared.sample
        guard !sample.isEmpty else { throw DecoderError.emptySample }
        let sampleBuffer = try makeSampleBuffer(
            sample: sample,
            formatDescription: description,
            presentationTime: unit.captureTimestampMicroseconds.map { CMTime(value: $0, timescale: 1_000_000) }
                ?? CMTime(value: CMTimeValue(unit.rtpTimestamp), timescale: Self.clockRate)
        )
        let submitStart = DispatchTime.now().uptimeNanoseconds
        lifecycle.notePredecodeCompleted(at: submitStart)
        lifecycle.noteDecodeStarted(at: submitStart)
        let operation = DecodeOperation()

        var flagsOut = VTDecodeInfoFlags()
        let isKeyframe = unit.isKeyframe

        let bytes = unit.bytes
        let codec = codec
        let shape: @Sendable () -> String = { Self.accessUnitShape(bytes, codec: codec) }
        let logFailure = onDecoderLog
        let frameIndex = unit.frameIndex
        let status = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,

            flags: [],
            infoFlagsOut: &flagsOut,
            outputHandler: { [weak self] status, _, imageBuffer, presentationTime, _ in
                guard let self, operation.claim() else { return }
                stateLock.lock()
                let isCurrent = generation == decodeGeneration
                stateLock.unlock()
                guard isCurrent else {
                    completion(false, DispatchTime.now().uptimeNanoseconds)
                    return
                }
                if status == noErr, imageBuffer != nil, isKeyframe {
                    stateLock.lock()
                    hasSeenKeyframe = true
                    stateLock.unlock()
                }
                handleDecodedFrame(status: status,
                                   imageBuffer: imageBuffer,
                                   presentationTime: presentationTime,
                                   frameIndex: frameIndex,
                                   isKeyframe: isKeyframe,
                                   shape: shape,
                                   logFailure: logFailure,
                                   lifecycle: lifecycle, completion: completion)
            }
        )
        noteStageTimings(prepare: decodeStart, build: buildStart, submit: submitStart)
        guard status == noErr else {
            statsLock.lock()
            if operation.claim() { failedFrames &+= 1 }
            statsLock.unlock()

            stateLock.lock()
            let broken = self.session
            self.session = nil
            hasSeenKeyframe = false
            generation &+= 1
            stateLock.unlock()
            Self.tearDown(broken)
            throw DecoderError.decodeFailed(status)
        }
        if operation.claim() {
            statsLock.lock()
            failedFrames &+= 1
            statsLock.unlock()
            onDecodeFailure?(frameIndex)
            completion(false, DispatchTime.now().uptimeNanoseconds)
            throw DecoderError.missingOutput
        }
    }

    private func prepareSession(for incoming: NvstElementaryStream.ParameterSets) throws -> (VTDecompressionSession, CMFormatDescription) {
        stateLock.lock()
        let isComplete = incoming.isComplete || parameterSets.isComplete
        guard isComplete else {
            stateLock.unlock()
            throw DecoderError.missingParameterSets
        }

        let setsToUse = incoming.isComplete ? incoming : parameterSets
        let isNewSets = incoming.isComplete && incoming != parameterSets
        let currentDescription = formatDescription
        stateLock.unlock()

        if isNewSets || currentDescription == nil {
            let newDescription = try makeFormatDescription(setsToUse)

            stateLock.lock()
            if let active = session, isNewSets, VTDecompressionSessionCanAcceptFormatDescription(active, formatDescription: newDescription) {
                parameterSets = setsToUse
                formatDescription = newDescription
                stateLock.unlock()
                return (active, newDescription)
            }

            let expiring = session
            session = nil
            parameterSets = setsToUse
            formatDescription = newDescription
            stateLock.unlock()
            Self.tearDown(expiring)
        }

        stateLock.lock()
        guard let description = formatDescription else {
            stateLock.unlock()
            throw DecoderError.missingParameterSets
        }
        var active = session
        stateLock.unlock()

        if active == nil {
            active = try makeSession(formatDescription: description)
            stateLock.lock()

            if let existing = session {
                let redundant = active
                active = existing
                stateLock.unlock()
                Self.tearDown(redundant)
            } else {
                session = active
                stateLock.unlock()
            }
        }
        guard let active else { throw DecoderError.sessionCreationFailed(-1) }
        return (active, description)
    }

    private func handleDecodedFrame(status: OSStatus,
                                    imageBuffer: CVImageBuffer?,
                                    presentationTime: CMTime,
                                    frameIndex: UInt32,
                                    isKeyframe: Bool,
                                    shape: @escaping @Sendable () -> String,
                                    logFailure: ((String) -> Void)?,
                                    lifecycle: NvstVideoFrameLifecycle,
                                    completion: @Sendable (Bool, UInt64) -> Void) {
        guard status == noErr, let imageBuffer else {
            statsLock.lock()
            failedFrames &+= 1
            if firstFailureStatus == noErr { firstFailureStatus = status }
            lastFailureStatus = status
            let now = DispatchTime.now().uptimeNanoseconds
            let shouldReport: Bool
            let suppressed: Int
            if loggedFailures < 25 {
                loggedFailures += 1
                shouldReport = true
                suppressed = 0
                lastLoggedFailureAt = now
            } else if let last = lastLoggedFailureAt, now >= last, now - last >= 1_000_000_000 {
                shouldReport = true
                suppressed = suppressedFailureCount
                suppressedFailureCount = 0
                lastLoggedFailureAt = now
            } else {
                shouldReport = false
                suppressedFailureCount += 1
                suppressed = 0
            }
            statsLock.unlock()

            onDecodeFailure?(frameIndex)

            if shouldReport {
                let suppressedNote = suppressed > 0 ? " (+\(suppressed) suppressed in past 1s)" : ""
                let statusStr = Self.describeOSStatus(status)
                logFailure?("NVST decode rejected OSStatus \(statusStr) frame=\(frameIndex) keyframe=\(isKeyframe)\(suppressedNote) \(shape())")
            }
            completion(false, DispatchTime.now().uptimeNanoseconds)
            return
        }
        completion(true, DispatchTime.now().uptimeNanoseconds)
        statsLock.lock()
        decodedFrames &+= 1

        decodedWidth = CVPixelBufferGetWidth(imageBuffer)
        decodedHeight = CVPixelBufferGetHeight(imageBuffer)
        let handler = onPixelBuffer
        let shouldReportAccepted = loggedAccepted < Self.maxLoggedAccepted
        if shouldReportAccepted { loggedAccepted += 1 }
        statsLock.unlock()

        if shouldReportAccepted {
            logFailure?("NVST decode accepted frame=\(frameIndex) keyframe=\(isKeyframe) \(shape())")
        }
        if let handler {
            handler(imageBuffer, presentationTime, isKeyframe, lifecycle)
        } else {
            lifecycle.discard(decoded: true)
        }
    }

    public struct StageTimings: Sendable, Equatable {
        public var prepareMilliseconds = 0.0
        public var buildMilliseconds = 0.0
        public var submitMilliseconds = 0.0
    }

    public var stageTimingSummary: String {
        statsLock.lock()
        defer { statsLock.unlock() }
        let frames = max(1, timedFrames)
        return String(format: "peak[prepare=%.1f build=%.1f submit=%.1f] mean[prepare=%.2f build=%.2f submit=%.2f]ms",
                      peakStages.prepareMilliseconds, peakStages.buildMilliseconds, peakStages.submitMilliseconds,
                      totalStages.prepareMilliseconds / Double(frames),
                      totalStages.buildMilliseconds / Double(frames),
                      totalStages.submitMilliseconds / Double(frames))
    }

    public var peakStageTimings: StageTimings { statsLock.lock(); defer { statsLock.unlock() }; return peakStages }
    private var peakStages = StageTimings()
    private var totalStages = StageTimings()
    private var timedFrames: UInt64 = 0

    private func noteStageTimings(prepare: UInt64, build: UInt64, submit: UInt64) {
        let now = DispatchTime.now().uptimeNanoseconds
        let prepareMs = Self.milliseconds(from: prepare, to: build)
        let buildMs = Self.milliseconds(from: build, to: submit)
        let submitMs = Self.milliseconds(from: submit, to: now)
        statsLock.lock()
        peakStages.prepareMilliseconds = max(peakStages.prepareMilliseconds, prepareMs)
        peakStages.buildMilliseconds = max(peakStages.buildMilliseconds, buildMs)
        peakStages.submitMilliseconds = max(peakStages.submitMilliseconds, submitMs)
        totalStages.prepareMilliseconds += prepareMs
        totalStages.buildMilliseconds += buildMs
        totalStages.submitMilliseconds += submitMs
        timedFrames &+= 1
        statsLock.unlock()
    }

    public func drain() {
        stateLock.lock()
        let active = session
        stateLock.unlock()
        guard let active else { return }
        VTDecompressionSessionWaitForAsynchronousFrames(active)
    }

    private func makeSession(formatDescription: CMVideoFormatDescription) throws -> VTDecompressionSession {

        statsLock.lock()
        let bitstream = currentBitstreamFormat ?? BitstreamFormat()
        statsLock.unlock()

        let specification: [CFString: Any] = [
            kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true,
        ]
        var created: VTDecompressionSession?
        var status: OSStatus = noErr
        var chosenFormat: OSType = 0
        for candidate in Self.preferredOutputPixelFormats(for: bitstream) {
            let attributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: NSNumber(value: candidate),
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                kCVPixelBufferMetalCompatibilityKey: true,
            ]
            var attempt: VTDecompressionSession?
            status = VTDecompressionSessionCreate(
                allocator: kCFAllocatorDefault,
                formatDescription: formatDescription,
                decoderSpecification: specification as CFDictionary,
                imageBufferAttributes: attributes as CFDictionary,
                outputCallback: nil,
                decompressionSessionOut: &attempt
            )
            if status == noErr, let attempt {
                created = attempt
                chosenFormat = candidate
                break
            }
            onDecoderLog?("NVST decoder declined output \(Self.pixelFormatName(candidate)) for \(bitstream.summary) (OSStatus \(status)); trying the next format")
        }
        guard status == noErr, let created else { throw DecoderError.sessionCreationFailed(status) }
        statsLock.lock()
        outputPixelFormat = chosenFormat
        statsLock.unlock()
        VTSessionSetProperty(created, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)

        var usingHardware: Unmanaged<CFTypeRef>?
        VTSessionCopyProperty(created,
                              key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,
                              allocator: kCFAllocatorDefault,
                              valueOut: &usingHardware)
        let isHardware = (usingHardware?.takeRetainedValue() as? NSNumber)?.boolValue ?? false
        statsLock.lock()
        usesHardwareDecoder = isHardware
        statsLock.unlock()
        onDecoderLog?("NVST decoder session created codec=\(codec.rawValue) hardware=\(isHardware) bitstream=\(bitstream.summary) output=\(Self.pixelFormatName(chosenFormat))")

        statsLock.lock()
        sessionsCreated &+= 1
        statsLock.unlock()
        return created
    }

    public var sessionCreationCount: UInt64 { statsLock.lock(); defer { statsLock.unlock() }; return sessionsCreated }

    public var isHardwareAccelerated: Bool { statsLock.lock(); defer { statsLock.unlock() }; return usesHardwareDecoder }
    private var usesHardwareDecoder = false
    private var sessionsCreated: UInt64 = 0

}
