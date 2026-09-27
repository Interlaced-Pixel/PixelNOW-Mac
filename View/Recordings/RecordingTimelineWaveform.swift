import AVFoundation
import CoreMedia
import Foundation

@MainActor
enum RecordingTimelineWaveformCache {
    private static var cache: [String: [Float]] = [:]

    static func waveform(recordingID: UUID, url: URL, startSeconds: Double, endSeconds: Double, bucketCount: Int) async -> [Float] {
        let key = "\(recordingID.uuidString):\(Int(startSeconds * 10)):\(Int(endSeconds * 10)):\(bucketCount)"
        if let cached = cache[key] { return cached }
        let worker = Task.detached(priority: .utility) {
            await readWaveform(url: url, startSeconds: startSeconds, endSeconds: endSeconds, bucketCount: bucketCount)
        }
        let values = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
        if cache.count >= 128 { cache.removeAll(keepingCapacity: true) }
        cache[key] = values
        return values
    }

    nonisolated private static func readWaveform(url: URL, startSeconds: Double, endSeconds: Double, bucketCount: Int) async -> [Float] {
        let emptyWaveform = Array(repeating: Float.zero, count: bucketCount)
        guard bucketCount > 0, startSeconds.isFinite, endSeconds.isFinite, endSeconds > startSeconds else { return emptyWaveform }
        let asset = AVURLAsset(url: url)
        guard let tracks = try? await asset.loadTracks(withMediaType: .audio),
              let track = tracks.first,
              let reader = try? AVAssetReader(asset: asset) else { return emptyWaveform }
        reader.timeRange = CMTimeRange(start: CMTime(seconds: startSeconds, preferredTimescale: 600), duration: CMTime(seconds: endSeconds - startSeconds, preferredTimescale: 600))
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        guard reader.canAdd(output) else { return emptyWaveform }
        reader.add(output)
        guard reader.startReading() else { return emptyWaveform }
        let duration = endSeconds - startSeconds
        let descriptions = (try? await track.load(.formatDescriptions)) ?? []
        let streamDescription = descriptions.first.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
        let sampleRate = max(1, streamDescription?.mSampleRate ?? 48_000)
        let channelCount = max(1, Int(streamDescription?.mChannelsPerFrame ?? 2))
        var peaks = emptyWaveform
        var absoluteSampleIndex = 0
        while reader.status == .reading, let sampleBuffer = output.copyNextSampleBuffer() {
            if Task.isCancelled { reader.cancelReading(); return emptyWaveform }
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            var bytesAtOffset = 0
            var totalBytes = 0
            var bytePointer: UnsafeMutablePointer<Int8>?
            guard CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: &bytesAtOffset, totalLengthOut: &totalBytes, dataPointerOut: &bytePointer) == kCMBlockBufferNoErr,
                  let bytePointer else { continue }
            let samples = bytePointer.withMemoryRebound(to: Int16.self, capacity: totalBytes / MemoryLayout<Int16>.size) { pointer in
                Array(UnsafeBufferPointer(start: pointer, count: totalBytes / MemoryLayout<Int16>.size))
            }
            for sample in samples {
                let sampleTime = Double(absoluteSampleIndex / channelCount) / sampleRate
                let bucket = min(bucketCount - 1, max(0, Int(sampleTime / duration * Double(bucketCount))))
                peaks[bucket] = max(peaks[bucket], Float(min(32_768, abs(Int(sample)))) / 32_768)
                absoluteSampleIndex += 1
            }
        }
        if reader.status == .failed { return emptyWaveform }
        return peaks
    }
}
