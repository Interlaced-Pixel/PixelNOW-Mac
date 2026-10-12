import CxxStdlib
import Foundation
import NVSTNative

extension NvstBundle: NvstCoreAudioDeviceOwner {
    func handleGameAudioFrame(_ buffers: UnsafeRawPointer?, frameCount: UInt32, sampleRate: Double, channels: UInt32) {
        onGameAudioFrame?(buffers, frameCount, sampleRate, channels)
    }
    func handleMicrophoneAudioFrame(_ buffers: UnsafeRawPointer?, frameCount: UInt32, sampleRate: Double, channels: UInt32) {
        onMicrophoneAudioFrame?(buffers, frameCount, sampleRate, channels)
    }
    func handleCapturedMicrophoneLevel(_ level: Double) { onMicrophoneLevel?(level) }
    func microphoneSamplesAvailable() { microphoneSignal?.add(data: 1) }
    func handleAudioDeviceFailure(_ message: String) {
        queue.async { [weak self] in self?.fail(message) }
    }
    func handleRenderReference(_ samples: UnsafePointer<Int16>, frames: Int, channels: Int) {
        guard microphoneProcessor != nil, !capture.isMuted else { return }
        renderReference.writeCapture(samples, frames: frames, channels: channels)
        microphoneSignal?.add(data: 1)
    }

    func drainMicrophone() {
        guard !closed, microphoneCaptureEnabled, dtls?.connected() == true,
              microphoneEncoder != nil, microphoneProcessor != nil else {
            capture.discardPending()
            renderReference.discardPending()
            previousMicrophonePayloads.removeAll(keepingCapacity: true)
            return
        }
        var referenceFrames = 0
        while referenceFrames < 64, let samples = renderReference.readCapture(frames: 480) {
            let processed = samples.withUnsafeBufferPointer { microphoneProcessor?.processRender($0.baseAddress, $0.count) == true }
            guard processed else {
                if !closed { fail("Microphone render-reference processing failed") }
                return
            }
            referenceFrames += 1
        }
        var drained = 0
        while drained < 32, var samples = capture.readCapture(frames: 480) {
            let now = DispatchTime.now().uptimeNanoseconds
            if microphoneClockNanoseconds == nil {
                microphoneClockNanoseconds = now
                microphoneClockTimestamp = microphoneTimestamp
            }
            if let origin = microphoneClockNanoseconds {
                let elapsed = (now &- origin) / 1_000_000 * 48
                let clockTimestamp = microphoneClockTimestamp &+ UInt32(truncatingIfNeeded: elapsed)
                if Int32(bitPattern: clockTimestamp &- microphoneTimestamp) > 4_800 {
                    microphoneTimestamp = clockTimestamp
                    previousMicrophonePayloads.removeAll(keepingCapacity: true)
                }
            }
            let delay = UInt32(min(max((audioDevice?.echoPathLatencySeconds ?? 0) * 1000 + Double(capture.availableFrames) / 48, 0), 500))
            let processed = samples.withUnsafeMutableBufferPointer { microphoneProcessor?.processCapture($0.baseAddress, $0.count, delay) == true }
            guard processed else { fail("Microphone audio processing failed"); return }
            for index in samples.indices {
                samples[index] = Int16(min(max(Double(samples[index]) * microphoneVolume, Double(Int16.min)), Double(Int16.max)))
            }
            let encoded = samples.withUnsafeBufferPointer { microphoneEncoder?.encode($0.baseAddress, $0.count, 480) }
            guard let encoded, !encoded.empty() else {
                fail("Microphone Opus encoding failed: \(String(microphoneEncoder?.errorDescription() ?? std.string()))")
                return
            }
            let payload = Data(encoded)
            let redundant = previousMicrophonePayloads.filter {
                $0.payload.count <= 1023 && microphoneTimestamp &- $0.timestamp <= 16_383
            }
            var writer = NvstByteWriter(capacity: 13 + payload.count + redundant.reduce(0) { $0 + $1.payload.count + 4 })
            writer.u8(0x80)
            writer.u8(previousMicrophonePayloads.isEmpty ? 0xbf : 63)
            writer.u16BE(microphoneSequence)
            writer.u32BE(microphoneTimestamp)
            writer.u32BE(microphoneSenderSsrc ?? 1)
            for block in redundant {
                let age = microphoneTimestamp &- block.timestamp
                writer.u8(0xef)
                writer.u8(UInt8(age >> 6))
                writer.u8(UInt8((age & 63) << 2) | UInt8(block.payload.count >> 8))
                writer.u8(UInt8(truncatingIfNeeded: block.payload.count))
            }
            writer.u8(111)
            for block in redundant { writer.bytes(block.payload) }
            writer.bytes(payload)
            guard sendProtectedMedia(writer.data, rtcp: false) else { return }
            if microphoneInitialSequence == nil { microphoneInitialSequence = microphoneSequence }
            microphoneSentDataBytes &+= UInt64(writer.data.count)
            microphonePacketCount &+= 1
            microphonePayloadBytes &+= UInt32(clamping: writer.data.count - 12)
            microphoneSequence &+= 1
            previousMicrophonePayloads.append((microphoneTimestamp, payload))
            if previousMicrophonePayloads.count > Int(handoff.microphoneRedundancyPackets) {
                previousMicrophonePayloads.removeFirst(previousMicrophonePayloads.count - Int(handoff.microphoneRedundancyPackets))
            }
            microphoneTimestamp &+= 480
            drained += 1
        }
        if capture.availableFrames >= 480 { microphoneSignal?.add(data: 1) }
    }

    @discardableResult
    func sendProtectedMedia(_ packet: Data, rtcp: Bool) -> Bool {
        guard dtls?.connected() == true else { return false }
        let protected = packet.withUnsafeBytes { dtls?.protect($0.bindMemory(to: UInt8.self).baseAddress, $0.count, rtcp) }
        guard let protected, !protected.empty() else { fail("SRTP protection failed"); return false }
        enqueueDatagram(Data(protected))
        return !closed
    }

    func receiveRtcp(_ packet: Data) {
        let bytes = [UInt8](packet)
        var offset = 0
        while offset + 4 <= bytes.count {
            guard bytes[offset] >> 6 == 2 else { return }
            let count = Int(bytes[offset] & 31)
            let size = ((Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])) + 1) * 4
            guard size >= 4, offset + size <= bytes.count else { return }
            var contentSize = size
            if bytes[offset] & 0x20 != 0 {
                let padding = Int(bytes[offset + size - 1])
                guard offset + size == bytes.count, padding > 0, padding <= size - 4 else { return }
                contentSize -= padding
            }
            let type = bytes[offset + 1]
            let blockOffset: Int
            if type == 200 {
                guard contentSize >= 28 + count * 24 else { return }
                if readRtcp32(bytes, offset + 4) == audio?.reception.ssrc {
                    lastAudioSenderReport = (readRtcp32(bytes, offset + 8) << 16) | (readRtcp32(bytes, offset + 12) >> 16)
                    lastAudioSenderReportNanoseconds = DispatchTime.now().uptimeNanoseconds
                }
                blockOffset = offset + 28
            } else if type == 201 {
                guard contentSize >= 8 + count * 24 else { return }
                blockOffset = offset + 8
            } else { offset += size; continue }
            for index in 0..<count {
                let block = blockOffset + index * 24
                guard readRtcp32(bytes, block) == microphoneSenderSsrc else { continue }
                let loss = UInt32(bytes[block + 4]) * 100 / 256
                _ = microphoneEncoder?.setExpectedPacketLoss(loss)
                let cumulative = Int32(bitPattern: readRtcp32(bytes, block + 4) << 8) >> 8
                let highest = readRtcp32(bytes, block + 8)
                if let initial = microphoneInitialSequence {
                    let expected = Int64(highest) - Int64(initial) + 1
                    microphoneSeatReportedPackets = min(UInt64(max(expected - Int64(cumulative), 0)), UInt64(microphonePacketCount))
                }
            }
            offset += size
        }
    }

    func sendAudioReports(at now: UInt64) {
        let sender = microphoneSenderSsrc ?? 1
        let delay = lastAudioSenderReportNanoseconds == 0 ? 0 : UInt32(clamping: (now &- lastAudioSenderReportNanoseconds) / 1_000_000 * 65_536 / 1000)
        let blocks = audio?.receiverReport(lastSenderReport: lastAudioSenderReport, delay: delay).map { [$0] } ?? []
        var report: Data
        if microphonePacketCount > 0 {
            let unix = Date().timeIntervalSince1970
            let ntp = unix + 2_208_988_800
            let seconds = ntp.rounded(.down)
            var writer = NvstByteWriter(capacity: 28)
            writer.u8(0x80)
            writer.u8(200)
            writer.u16BE(6)
            writer.u32BE(sender)
            writer.u32BE(UInt32(truncatingIfNeeded: UInt64(seconds)))
            writer.u32BE(UInt32(min((ntp - seconds) * 4_294_967_296, Double(UInt32.max))))
            let elapsed = microphoneClockNanoseconds.map { (now &- $0) / 1_000_000 * 48 } ?? 0
            writer.u32BE(microphoneClockTimestamp &+ UInt32(truncatingIfNeeded: elapsed))
            writer.u32BE(microphonePacketCount)
            writer.u32BE(microphonePayloadBytes)
            report = writer.data
            if !blocks.isEmpty { report.append(NvstRtcp.receiverReport(ssrc: sender, blocks: blocks)) }
        } else { report = NvstRtcp.receiverReport(ssrc: sender, blocks: blocks) }
        let name = Data("PixelNOW".utf8)
        var description = NvstByteWriter(capacity: 20)
        description.u8(0x81)
        description.u8(202)
        description.u16BE(4)
        description.u32BE(sender)
        description.u8(1)
        description.u8(UInt8(name.count))
        description.bytes(name)
        description.u8(0)
        description.u8(0)
        report.append(description.data)
        sendProtectedMedia(report, rtcp: true)
        lastMicrophoneReportNanoseconds = now
    }

    private func readRtcp32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16 | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
    }
}
