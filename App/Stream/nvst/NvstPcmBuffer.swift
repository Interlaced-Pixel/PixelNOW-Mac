import AudioToolbox
import Foundation
import Synchronization

final class NvstPcmBuffer: @unchecked Sendable {
    private static let capacity = 8192
    private let storage = UnsafeMutablePointer<Float>.allocate(capacity: capacity * 8)
    private let written = Atomic<UInt64>(0)
    private let consumed = Atomic<UInt64>(0)
    private let gainBits = Atomic<UInt64>(Double(1).bitPattern)
    private let muted = Atomic<Bool>(false)
    private let dropped = Atomic<UInt64>(0)
    private let underruns = Atomic<UInt64>(0)
    private let discardRequested = Atomic<Bool>(false)

    init() { storage.initialize(repeating: 0, count: Self.capacity * 8) }
    deinit { storage.deinitialize(count: Self.capacity * 8); storage.deallocate() }

    var availableFrames: Int {
        let read = consumed.load(ordering: .acquiring)
        let write = written.load(ordering: .acquiring)
        return Int(min(UInt64(Self.capacity), write &- read))
    }
    var isMuted: Bool { muted.load(ordering: .acquiring) }
    var droppedFrames: UInt64 { dropped.load(ordering: .relaxed) }
    var underrunFrames: UInt64 { underruns.load(ordering: .relaxed) }
    func requestDiscard() { discardRequested.store(true, ordering: .releasing) }
    func setMuted(_ value: Bool) { muted.store(value, ordering: .releasing) }
    func setVolume(_ value: Double) {
        gainBits.store(min(max(value.isFinite ? value : 1, 0), 1).bitPattern, ordering: .releasing)
    }

    func write(_ samples: [Float], channels: Int) -> Bool {
        guard [1, 2, 6, 8].contains(channels), samples.count % channels == 0 else { return false }
        let frames = samples.count / channels
        let position = written.load(ordering: .relaxed)
        let read = consumed.load(ordering: .acquiring)
        guard frames <= Self.capacity - Int(position &- read) else {
            dropped.wrappingAdd(UInt64(frames), ordering: .relaxed)
            return false
        }
        for frame in 0..<frames {
            let destination = storage.advanced(by: Int((position &+ UInt64(frame)) & UInt64(Self.capacity - 1)) * 8)
            let storedChannels = max(2, channels)
            if storedChannels < 8 {
                destination.advanced(by: storedChannels).update(repeating: 0, count: 8 - storedChannels)
            }
            let source = frame * channels
            switch channels {
            case 1: destination[0] = samples[source]; destination[1] = samples[source]
            case 2: destination[0] = samples[source]; destination[1] = samples[source + 1]
            case 6:
                destination[0] = samples[source]; destination[1] = samples[source + 2]
                destination[2] = samples[source + 1]; destination[3] = samples[source + 5]
                destination[4] = samples[source + 3]; destination[5] = samples[source + 4]
            case 8:
                destination[0] = samples[source]; destination[1] = samples[source + 2]
                destination[2] = samples[source + 1]; destination[3] = samples[source + 7]
                destination[4] = samples[source + 3]; destination[5] = samples[source + 4]
                destination[6] = samples[source + 5]; destination[7] = samples[source + 6]
            default: break
            }
        }
        written.store(position &+ UInt64(frames), ordering: .releasing)
        return true
    }

    func writeCapture(_ samples: UnsafePointer<Int16>, frames: Int, channels: Int) {
        guard frames > 0, channels > 0, channels <= 8, !muted.load(ordering: .acquiring) else { return }
        let position = written.load(ordering: .relaxed)
        let read = consumed.load(ordering: .acquiring)
        guard frames <= Self.capacity - Int(position &- read) else {
            dropped.wrappingAdd(UInt64(frames), ordering: .relaxed)
            return
        }
        for frame in 0..<frames {
            let destination = storage.advanced(by: Int((position &+ UInt64(frame)) & UInt64(Self.capacity - 1)) * 8)
            var sample: Float = 0
            for channel in 0..<channels { sample += Float(samples[frame * channels + channel]) / 32768 }
            destination[0] = sample / Float(channels)
        }
        written.store(position &+ UInt64(frames), ordering: .releasing)
    }

    func readCapture(frames: Int) -> [Int16]? {
        var read = consumed.load(ordering: .relaxed)
        let write = written.load(ordering: .acquiring)
        if write &- read > 4800 {
            let skipped = write &- read &- 4800
            read = write &- 4800
            dropped.wrappingAdd(skipped, ordering: .relaxed)
            consumed.store(read, ordering: .releasing)
        }
        guard frames > 0, write &- read >= UInt64(frames) else { return nil }
        var result = [Int16](repeating: 0, count: frames)
        for frame in 0..<frames {
            let value = storage[Int((read &+ UInt64(frame)) & UInt64(Self.capacity - 1)) * 8]
            result[frame] = Self.integerSample(value)
        }
        consumed.store(read &+ UInt64(frames), ordering: .releasing)
        return result
    }

    func discardPending() { consumed.store(written.load(ordering: .acquiring), ordering: .releasing) }

    func render(_ buffers: UnsafeMutablePointer<AudioBufferList>, frames: Int, channels: Int) {
        var read = consumed.load(ordering: .relaxed)
        let write = written.load(ordering: .acquiring)
        if discardRequested.exchange(false, ordering: .acquiringAndReleasing) { read = write }
        if write &- read > 2880 {
            let skipped = write &- read &- 2880
            read = write &- 2880
            dropped.wrappingAdd(skipped, ordering: .relaxed)
        }
        let available = min(frames, Int(write &- read))
        for buffer in UnsafeMutableAudioBufferListPointer(buffers) {
            guard let data = buffer.mData else { continue }
            memset(data, 0, Int(buffer.mDataByteSize))
            guard Int(buffer.mNumberChannels) == channels,
                  Int(buffer.mDataByteSize) >= frames * channels * MemoryLayout<Int16>.size else { continue }
            let output = data.assumingMemoryBound(to: Int16.self)
            for frame in 0..<available {
                let input = storage.advanced(by: Int((read &+ UInt64(frame)) & UInt64(Self.capacity - 1)) * 8)
                let left = input[0] + 0.70710678 * (input[2] + input[4] + input[6]) + 0.5 * input[3]
                let right = input[1] + 0.70710678 * (input[2] + input[5] + input[7]) + 0.5 * input[3]
                if channels == 1 { output[frame] = Self.integerSample((left + right) * 0.5) }
                else if channels == 2 {
                    output[frame * 2] = Self.integerSample(left)
                    output[frame * 2 + 1] = Self.integerSample(right)
                } else {
                    for channel in 0..<channels {
                        var value = input[channel]
                        if channels == 6 && channel == 4 { value += input[6] * 0.70710678 }
                        if channels == 6 && channel == 5 { value += input[7] * 0.70710678 }
                        output[frame * channels + channel] = Self.integerSample(value)
                    }
                }
            }
        }
        consumed.store(read &+ UInt64(available), ordering: .releasing)
        if available < frames { underruns.wrappingAdd(UInt64(frames - available), ordering: .relaxed) }
    }

    func applyGain(_ buffers: UnsafeMutablePointer<AudioBufferList>) {
        let gain = muted.load(ordering: .acquiring) ? 0 : Double(bitPattern: gainBits.load(ordering: .acquiring))
        guard gain < 1 else { return }
        for buffer in UnsafeMutableAudioBufferListPointer(buffers) {
            guard let data = buffer.mData else { continue }
            let count = Int(buffer.mDataByteSize) / MemoryLayout<Int16>.size
            let samples = data.assumingMemoryBound(to: Int16.self)
            for index in 0..<count { samples[index] = Int16((Double(samples[index]) * gain).rounded()) }
        }
    }

    private static func integerSample(_ value: Float) -> Int16 {
        guard value.isFinite else { return 0 }
        return Int16(min(max((value * 32768).rounded(), -32768), 32767))
    }
}
