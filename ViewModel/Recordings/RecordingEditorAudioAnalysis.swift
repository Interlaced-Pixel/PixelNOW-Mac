@preconcurrency import AVFoundation
import Foundation

struct RecordingEditorAudioRange: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var startSeconds: Double
    var endSeconds: Double

    init(id: UUID = UUID(), startSeconds: Double, endSeconds: Double) {
        self.id = id
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
    }
}

struct RecordingEditorAudioAnalysisResult: Sendable {
    var peakAmplitude: Double
    var normalizationGain: Double
    var silenceRanges: [RecordingEditorAudioRange]
}

enum RecordingEditorAudioAnalysisService {
    static func analyze(recordingURL: URL, startSeconds: Double, endSeconds: Double) async throws -> RecordingEditorAudioAnalysisResult {
        try await Task.detached(priority: .userInitiated) {
            let asset = AVURLAsset(url: recordingURL)
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            guard let track = audioTracks.first else { throw RecordingEditorAudioAnalysisError.noAudio }
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ])
            guard reader.canAdd(output) else { throw RecordingEditorAudioAnalysisError.cannotReadAudio }
            reader.add(output)
            reader.timeRange = CMTimeRange(start: CMTime(seconds: startSeconds, preferredTimescale: 600), duration: CMTime(seconds: endSeconds - startSeconds, preferredTimescale: 600))
            guard reader.startReading() else { throw reader.error ?? RecordingEditorAudioAnalysisError.cannotReadAudio }

            var peak = 0.0
            var activeSilenceStart: Double?
            var silenceRanges: [RecordingEditorAudioRange] = []
            let silenceThreshold = 0.003_981_071_7
            let minimumSilenceDuration = 0.5
            while let sampleBuffer = output.copyNextSampleBuffer() {
                try Task.checkCancellation()
                defer { CMSampleBufferInvalidate(sampleBuffer) }
                guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
                var bytes = [UInt8](repeating: 0, count: CMBlockBufferGetDataLength(blockBuffer))
                let copyStatus = bytes.withUnsafeMutableBytes { buffer in
                    guard let baseAddress = buffer.baseAddress else { return kCMBlockBufferBadCustomBlockSourceErr }
                    return CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: buffer.count, destination: baseAddress)
                }
                guard copyStatus == kCMBlockBufferNoErr, bytes.count >= 2 else { continue }
                var squaredSum = 0.0
                var sampleCount = 0
                var index = 0
                while index + 1 < bytes.count {
                    let bits = UInt16(bytes[index]) | (UInt16(bytes[index + 1]) << 8)
                    let sample = Double(Int16(bitPattern: bits)) / 32_768
                    let magnitude = abs(sample)
                    peak = max(peak, magnitude)
                    squaredSum += sample * sample
                    sampleCount += 1
                    index += 2
                }
                guard sampleCount > 0 else { continue }
                let start = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
                let duration = Double(sampleCount) / 16_000
                let end = start + duration
                let rms = sqrt(squaredSum / Double(sampleCount))
                if rms < silenceThreshold {
                    if activeSilenceStart == nil { activeSilenceStart = start }
                } else if let silenceStart = activeSilenceStart {
                    if end - silenceStart >= minimumSilenceDuration {
                        silenceRanges.append(RecordingEditorAudioRange(startSeconds: silenceStart, endSeconds: start))
                    }
                    activeSilenceStart = nil
                }
            }
            if let silenceStart = activeSilenceStart, endSeconds - silenceStart >= minimumSilenceDuration {
                silenceRanges.append(RecordingEditorAudioRange(startSeconds: silenceStart, endSeconds: endSeconds))
            }
            guard reader.status == .completed || reader.status == .reading else {
                throw reader.error ?? RecordingEditorAudioAnalysisError.cannotReadAudio
            }
            let targetPeak = pow(10.0, -1.0 / 20.0)
            let gain = peak > 0 ? min(targetPeak / peak, 8) : 1
            return RecordingEditorAudioAnalysisResult(peakAmplitude: peak, normalizationGain: gain, silenceRanges: silenceRanges)
        }.value
    }
}

private enum RecordingEditorAudioAnalysisError: LocalizedError {
    case noAudio
    case cannotReadAudio

    var errorDescription: String? {
        switch self {
        case .noAudio: "This recording has no audio track to analyze."
        case .cannotReadAudio: "PixelNOW could not analyze this recording's audio."
        }
    }
}
