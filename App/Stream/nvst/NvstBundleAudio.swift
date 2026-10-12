import Foundation
import NVSTNative

final class NvstBundleAudio: @unchecked Sendable {
    private struct Packet {
        let timestamp: Int64
        let payload: Data
        let receivedAt: UInt64
        let redundant: Bool
    }

    private static let bufferConfiguration = NvstClientAudioBufferConfig()
    private static let minimumBufferNanoseconds = UInt64(bufferConfiguration.minBufferSizeMs) * 1_000_000
    private static let defaultBufferNanoseconds = UInt64(bufferConfiguration.bufferSizeMs) * 1_000_000
    private static let maximumBufferNanoseconds = UInt64(bufferConfiguration.maxBufferSizeMs) * 1_000_000
    private static let maximumBufferedPackets = 256
    private static let audioClockRate: Double = 48_000
    private static let maximumBufferedTicks = Int64(maximumBufferNanoseconds * 48_000 / 1_000_000_000)

    private let processingQueue = DispatchQueue(label: "com.interlacedpixel.pixelnow.nvst.audio-playout", qos: .userInitiated)
    private let processingQueueKey = DispatchSpecificKey<UInt8>()
    private var decoder: NvstOpusDecoder
    private let playout: NvstPcmBuffer
    private var packets: [Int64: Packet] = [:]
    private var latestTimestamp: UInt32?
    private var extendedTimestamp: Int64 = 0
    private var highestSequence: Int64?
    private var firstSequence: Int64?
    private var previousExpected: Int64 = 0
    private var previousReceived: UInt64 = 0
    private var seenSequences = Set<Int64>()
    private var expectedTimestamp: Int64?
    private var deadline: UInt64?
    private var deadlineTimer: DispatchSourceTimer?
    private var isRunning = false
    private var lastArrival: UInt64?
    private var lastArrivalTimestamp: Int64?
    private var jitterTicks = 0.0
    private var targetDelayNanoseconds = NvstBundleAudio.defaultBufferNanoseconds
    private var frameCount = 240
    private var consecutiveConcealments = 0
    private var receptionState = NvstBundle.AudioReception()
    private var recoveredRed = 0
    private var fecAttempts = 0
    private var decodeFailures = 0
    private var malformed = 0
    private var discontinuities = 0
    private var boundedResyncs = 0
    var onFailure: (@Sendable (String) -> Void)?

    init(channels: Int, playout: NvstPcmBuffer) throws {
        self.playout = playout
        decoder = try Self.makeDecoder(channels: channels)
        processingQueue.setSpecific(key: processingQueueKey, value: 1)
    }

    deinit { stop() }

    private static func makeDecoder(channels: Int) throws -> NvstOpusDecoder {
        switch channels {
        case 1: try NvstOpusDecoder(channels: 1, streams: 1, coupledStreams: 0, mapping: [0])
        case 2: try NvstOpusDecoder()
        case 6: try NvstOpusDecoder(channels: 6, streams: 4, coupledStreams: 2, mapping: [0, 4, 1, 2, 3, 5])
        case 8: try NvstOpusDecoder(channels: 8, streams: 5, coupledStreams: 3, mapping: [0, 6, 1, 2, 3, 4, 5, 7])
        default: throw NvstOpusDecoder.DecoderError.invalidConfiguration
        }
    }

    func configure(_ info: NvstAudioSurroundInfo) throws {
        try synchronized {
            guard [1, 2, 6, 8].contains(Int(info.channels)) else { throw NvstOpusDecoder.DecoderError.invalidConfiguration }
            let replacement: NvstOpusDecoder
            if info.useMultiMappingMode {
                replacement = try NvstOpusDecoder(channels: UInt32(info.channels), streams: Int32(info.streams),
                    coupledStreams: Int32(info.coupledStreams), mapping: Array(info.channelMapping.prefix(Int(info.channels))))
            } else {
                replacement = try Self.makeDecoder(channels: Int(info.channels))
            }
            decoder = replacement
            playout.requestDiscard()
            packets.removeAll(keepingCapacity: true)
            expectedTimestamp = nil
            deadline = nil
            consecutiveConcealments = 0
            discontinuities += 1
            scheduleDeadlineLocked()
        }
    }

    func receive(_ datagram: Data, at now: UInt64) {
        processingQueue.async { [weak self] in
            guard let self, isRunning else { return }
            receiveLocked(datagram, at: now)
            scheduleDeadlineLocked()
        }
    }

    func start() {
        synchronized {
            guard !isRunning else { return }
            isRunning = true
            let timer = DispatchSource.makeTimerSource(queue: processingQueue)
            timer.setEventHandler { [weak self] in self?.processDeadline() }
            timer.schedule(deadline: .distantFuture)
            timer.resume()
            deadlineTimer = timer
        }
    }

    func stop() {
        synchronized {
            guard isRunning || deadlineTimer != nil else { return }
            isRunning = false
            deadlineTimer?.setEventHandler {}
            deadlineTimer?.cancel()
            deadlineTimer = nil
            packets.removeAll(keepingCapacity: false)
            expectedTimestamp = nil
            deadline = nil
        }
    }

    private func synchronized<T>(_ operation: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: processingQueueKey) != nil { return try operation() }
        return try processingQueue.sync(execute: operation)
    }

    private func receiveLocked(_ datagram: Data, at now: UInt64) {
        let bytes = [UInt8](datagram)
        guard bytes.count >= 12, bytes[0] >> 6 == 2 else { malformed += 1; return }
        var offset = 12 + Int(bytes[0] & 15) * 4
        guard offset <= bytes.count else { malformed += 1; return }
        if bytes[0] & 0x10 != 0 {
            guard offset + 4 <= bytes.count else { malformed += 1; return }
            let extensionLength = (Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])) * 4
            offset += 4 + extensionLength
        }
        var end = bytes.count
        if bytes[0] & 0x20 != 0 {
            let padding = Int(bytes[bytes.count - 1])
            guard padding > 0, padding <= end - offset else { malformed += 1; return }
            end -= padding
        }
        guard offset < end else { malformed += 1; return }
        let sequence = UInt16(bytes[2]) << 8 | UInt16(bytes[3])
        let timestamp = Self.read32(bytes, 4)
        let ssrc = Self.read32(bytes, 8)
        if let bound = receptionState.ssrc, bound != ssrc { receptionState.discarded &+= 1; return }
        let extendedSequence: Int64
        if let highestSequence {
            extendedSequence = highestSequence + Int64(Int16(bitPattern: sequence &- UInt16(truncatingIfNeeded: highestSequence)))
        } else { extendedSequence = Int64(sequence) }
        guard !seenSequences.contains(extendedSequence),
              highestSequence == nil || extendedSequence >= (highestSequence ?? 0) - 1024 else {
            receptionState.discarded &+= 1
            return
        }
        let payloadType = bytes[1] & 0x7f
        guard payloadType == 63 || payloadType == 111 else { receptionState.discarded &+= 1; return }
        let packetTimestamp: Int64
        if let latestTimestamp {
            packetTimestamp = extendedTimestamp + Int64(Int32(bitPattern: timestamp &- latestTimestamp))
        } else { packetTimestamp = Int64(timestamp) }
        var parsed: [Packet] = []
        if payloadType == 111 {
            parsed.append(Packet(timestamp: packetTimestamp, payload: Data(bytes[offset..<end]), receivedAt: now, redundant: false))
        } else {
            var blocks: [(Int64, Int)] = []
            while offset < end && bytes[offset] & 0x80 != 0 {
                guard offset + 4 < end, bytes[offset] & 0x7f == 111, blocks.count < 8 else { malformed += 1; return }
                let age = Int64(bytes[offset + 1]) << 6 | Int64(bytes[offset + 2] >> 2)
                let length = Int(bytes[offset + 2] & 3) << 8 | Int(bytes[offset + 3])
                guard length > 0 else { malformed += 1; return }
                blocks.append((packetTimestamp - age, length))
                offset += 4
            }
            guard offset < end, bytes[offset] == 111 else { malformed += 1; return }
            offset += 1
            for (blockTimestamp, length) in blocks {
                guard offset + length < end else { malformed += 1; return }
                parsed.append(Packet(timestamp: blockTimestamp, payload: Data(bytes[offset..<(offset + length)]), receivedAt: now, redundant: true))
                offset += length
            }
            guard offset < end else { malformed += 1; return }
            parsed.append(Packet(timestamp: packetTimestamp, payload: Data(bytes[offset..<end]), receivedAt: now, redundant: false))
        }
        guard parsed.allSatisfy({ $0.payload.count <= 10_240 }) else { malformed += 1; return }
        receptionState.ssrc = ssrc
        receptionState.packets &+= 1
        receptionState.bytes &+= UInt64(datagram.count)
        seenSequences.insert(extendedSequence)
        if firstSequence == nil { firstSequence = extendedSequence }
        highestSequence = max(highestSequence ?? extendedSequence, extendedSequence)
        if seenSequences.count > 2048, let highestSequence { seenSequences = seenSequences.filter { $0 >= highestSequence - 1024 } }
        if latestTimestamp == nil || packetTimestamp > extendedTimestamp {
            latestTimestamp = timestamp
            extendedTimestamp = packetTimestamp
        }
        if let lastArrival, let lastArrivalTimestamp, packetTimestamp > lastArrivalTimestamp {
            let arrivalDelta = Double(now &- lastArrival) * Self.audioClockRate / 1_000_000_000
            let variation = abs(arrivalDelta - Double(packetTimestamp - lastArrivalTimestamp))
            jitterTicks += (variation - jitterTicks) / 16
            let target = UInt64(min(max(5_000_000 + jitterTicks / Self.audioClockRate * 3_000_000_000,
                                        Double(Self.minimumBufferNanoseconds)),
                                    Double(Self.maximumBufferNanoseconds)))
            let change = Int64(target) - Int64(targetDelayNanoseconds)
            let step = min(max(change, -1_000_000), 1_000_000)
            targetDelayNanoseconds = UInt64(Int64(targetDelayNanoseconds) + step)
            if let deadline { self.deadline = UInt64(max(Int64(now), Int64(deadline) + step)) }
        }
        if lastArrivalTimestamp == nil || packetTimestamp > (lastArrivalTimestamp ?? packetTimestamp) {
            lastArrival = now
            lastArrivalTimestamp = packetTimestamp
        }
        if let expectedTimestamp, packetTimestamp - expectedTimestamp > Self.maximumBufferedTicks {
            packets.removeAll(keepingCapacity: true)
            self.expectedTimestamp = nil
            deadline = nil
            discontinuities += 1
            boundedResyncs += 1
        }
        for packet in parsed {
            if let expectedTimestamp, packet.timestamp < expectedTimestamp { continue }
            if let existing = packets[packet.timestamp], !existing.redundant { continue }
            guard packets.count < Self.maximumBufferedPackets || packets[packet.timestamp] != nil else { receptionState.discarded &+= 1; continue }
            packets[packet.timestamp] = packet
        }
        if expectedTimestamp == nil {
            expectedTimestamp = packetTimestamp
            deadline = now &+ targetDelayNanoseconds
        }
        if let expectedTimestamp { packets = packets.filter { $0.key >= expectedTimestamp } }
    }

    private func processDeadline() {
        guard isRunning else { return }
        do {
            try processLocked(at: DispatchTime.now().uptimeNanoseconds)
            scheduleDeadlineLocked()
        } catch {
            isRunning = false
            deadlineTimer?.schedule(deadline: .distantFuture)
            onFailure?(error.localizedDescription)
        }
    }

    private func processLocked(at now: UInt64) throws {
        var emitted = 0
        while let due = deadline, due <= now, let timestamp = expectedTimestamp, emitted < 24 {
            let samples: [Float]
            if let packet = packets.removeValue(forKey: timestamp) {
                do { samples = try decoder.decode(packet.payload) ?? [] }
                catch { decodeFailures += 1; samples = try decoder.conceal(frames: frameCount); receptionState.concealed &+= UInt64(frameCount) }
                if packet.redundant { recoveredRed += 1 }
                let decodedFrames = samples.count / Int(decoder.channels)
                if decodedFrames > 0 { frameCount = decodedFrames }
                consecutiveConcealments = 0
                receptionState.jitterBufferDelaySeconds += Double(now &- packet.receivedAt) / 1_000_000_000 * Double(frameCount)
                receptionState.jitterBufferEmitted &+= UInt64(frameCount)
            } else {
                if let next = packets[timestamp + Int64(frameCount)], !next.redundant {
                    do { samples = try decoder.recoverPrevious(from: next.payload, frames: frameCount) }
                    catch { decodeFailures += 1; samples = try decoder.conceal(frames: frameCount) }
                    fecAttempts += 1
                } else { samples = try decoder.conceal(frames: frameCount) }
                receptionState.concealed &+= UInt64(samples.count / Int(decoder.channels))
                consecutiveConcealments += 1
            }
            if !playout.write(samples, channels: Int(decoder.channels)) { receptionState.discarded &+= 1 }
            receptionState.samples &+= UInt64(samples.count / Int(decoder.channels))
            expectedTimestamp = timestamp + Int64(frameCount)
            deadline = due &+ UInt64(frameCount) * 1_000_000_000 / 48_000
            emitted += 1
            if consecutiveConcealments >= 20 {
                packets.removeAll(keepingCapacity: true)
                expectedTimestamp = nil
                deadline = nil
                discontinuities += 1
                break
            }
        }
        if emitted == 24, let deadline, deadline <= now {
            self.deadline = now &+ UInt64(frameCount) * 1_000_000_000 / 48_000
            discontinuities += 1
        }
        if let expectedTimestamp { packets = packets.filter { $0.key >= expectedTimestamp } }
    }

    private func scheduleDeadlineLocked() {
        guard isRunning, let deadlineTimer else { return }
        guard let deadline else {
            deadlineTimer.schedule(deadline: .distantFuture)
            return
        }
        let now = DispatchTime.now().uptimeNanoseconds
        deadlineTimer.schedule(deadline: DispatchTime(uptimeNanoseconds: max(now &+ 100_000, deadline)), leeway: .microseconds(100))
    }

    var reception: NvstBundle.AudioReception { synchronized { receptionState } }

    var summary: String {
        synchronized {
            "packets=\(receptionState.packets) discarded=\(receptionState.discarded) malformed=\(malformed) decodeFailures=\(decodeFailures) redRecovered=\(recoveredRed) fecAttempts=\(fecAttempts) concealed=\(receptionState.concealed) jitterMs=\(jitterTicks / 48) targetMs=\(Double(targetDelayNanoseconds) / 1_000_000) queued=\(packets.count) playoutFrames=\(playout.availableFrames) underrunFrames=\(playout.underrunFrames) overflowFrames=\(playout.droppedFrames) discontinuities=\(discontinuities) boundedResyncs=\(boundedResyncs)"
        }
    }

    func receiverReport(lastSenderReport: UInt32, delay: UInt32) -> NvstRtcpReportBlock? {
        synchronized {
            guard let firstSequence, let highestSequence, let ssrc = receptionState.ssrc else { return nil }
            let expected = highestSequence - firstSequence + 1
            let expectedInterval = expected - previousExpected
            let receivedInterval = receptionState.packets &- previousReceived
            let lostInterval = expectedInterval - Int64(clamping: receivedInterval)
            let fraction = expectedInterval > 0 && lostInterval > 0 ? UInt8(clamping: lostInterval * 256 / expectedInterval) : 0
            previousExpected = expected
            previousReceived = receptionState.packets
            let lost = min(max(expected - Int64(clamping: receptionState.packets), -8_388_608), 8_388_607)
            return NvstRtcpReportBlock(sourceSSRC: ssrc, fractionLost: fraction,
                cumulativeLost: UInt32(truncatingIfNeeded: lost), extendedHighestSequence: UInt32(truncatingIfNeeded: highestSequence),
                interarrivalJitter: UInt32(clamping: Int64(jitterTicks)), lastSenderReportTimestamp: lastSenderReport,
                delaySinceLastSenderReport: delay)
        }
    }
    private static func read32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16 | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
    }
}
