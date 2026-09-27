@preconcurrency import Speech
@preconcurrency import AVFoundation
import Foundation

struct RecordingEditorTranscript: Codable, Equatable, Identifiable, Sendable {
    struct Segment: Codable, Equatable, Identifiable, Sendable {
        let id: UUID
        var startSeconds: Double
        var durationSeconds: Double
        var confidence: Double
        var text: String

        init(id: UUID = UUID(), startSeconds: Double, durationSeconds: Double, confidence: Double, text: String) {
            self.id = id
            self.startSeconds = startSeconds
            self.durationSeconds = durationSeconds
            self.confidence = confidence
            self.text = text
        }
    }

    let id: UUID
    var sourceRecordingID: UUID
    var language: String
    var segments: [Segment]

    init(id: UUID = UUID(), sourceRecordingID: UUID, language: String, segments: [Segment]) {
        self.id = id
        self.sourceRecordingID = sourceRecordingID
        self.language = language
        self.segments = segments
    }
}

public struct RecordingEditorCaption: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var startSeconds: Double
    public var endSeconds: Double
    public var text: String
    public var language: String

    public init(id: UUID = UUID(), startSeconds: Double, endSeconds: Double, text: String, language: String) {
        self.id = id
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.text = text
        self.language = language
    }
}

enum RecordingEditorTranscriptionService {
    static func transcribe(recording: WebRTCStreamRecording) async throws -> RecordingEditorTranscript {
        let authorization = await authorizationStatus()
        guard authorization == .authorized else {
            throw RecordingEditorTranscriptionError.permissionRequired
        }
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else {
            throw RecordingEditorTranscriptionError.recognizerUnavailable
        }
        let audioURL = FileManager.default.temporaryDirectory.appendingPathComponent("pixelnow-transcript-\(UUID().uuidString).m4a")
        let asset = AVURLAsset(url: recording.videoURL)
        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw RecordingEditorTranscriptionError.audioExtractionUnavailable
        }
        try await exportSession.export(to: audioURL, as: .m4a)
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let request = SFSpeechURLRecognitionRequest(url: audioURL)
        request.shouldReportPartialResults = false
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        return try await withCheckedThrowingContinuation { continuation in
            var didResume = false
            recognizer.recognitionTask(with: request) { result, error in
                guard !didResume else { return }
                if let result, result.isFinal {
                    didResume = true
                    let segments = result.bestTranscription.segments.map {
                        RecordingEditorTranscript.Segment(startSeconds: $0.timestamp, durationSeconds: $0.duration, confidence: Double($0.confidence), text: $0.substring)
                    }
                    continuation.resume(returning: RecordingEditorTranscript(sourceRecordingID: recording.id, language: recognizer.locale.identifier, segments: segments))
                } else if let error {
                    didResume = true
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func authorizationStatus() async -> SFSpeechRecognizerAuthorizationStatus {
        let current = SFSpeechRecognizer.authorizationStatus()
        guard current == .notDetermined else { return current }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
    }
}

private enum RecordingEditorTranscriptionError: LocalizedError {
    case permissionRequired
    case recognizerUnavailable
    case audioExtractionUnavailable

    var errorDescription: String? {
        switch self {
        case .permissionRequired: "Allow speech recognition in System Settings to create a transcript."
        case .recognizerUnavailable: "Speech recognition is unavailable for this language or while offline."
        case .audioExtractionUnavailable: "PixelNOW could not prepare this recording's audio for transcription."
        }
    }
}
