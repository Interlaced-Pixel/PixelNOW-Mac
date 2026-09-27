@preconcurrency import AVFoundation
import AppKit
import CoreGraphics
import CoreImage
import Foundation

public struct WebRTCStreamRecordingEditSegment: Equatable, Identifiable, Sendable {
    public let id: UUID
    public var recording: WebRTCStreamRecording
    public var startSeconds: Double
    public var endSeconds: Double
    public var audio: WebRTCStreamRecordingAudioEdit
    public var transitionBefore: WebRTCStreamRecordingTransitionStyle
    public var transitionDurationSeconds: Double

    public init(id: UUID = UUID(), recording: WebRTCStreamRecording, startSeconds: Double, endSeconds: Double, audio: WebRTCStreamRecordingAudioEdit = .original, transitionBefore: WebRTCStreamRecordingTransitionStyle = .cut, transitionDurationSeconds: Double = 0.5) {
        self.id = id
        self.recording = recording
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.audio = audio
        self.transitionBefore = transitionBefore
        self.transitionDurationSeconds = transitionDurationSeconds
    }

    public var durationSeconds: Double { max(0, endSeconds - startSeconds) }
}

public struct WebRTCStreamRecordingCrop: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public static let fullFrame = WebRTCStreamRecordingCrop(x: 0, y: 0, width: 1, height: 1)

    var isFullFrame: Bool {
        abs(x) <= 0.0001 && abs(y) <= 0.0001 && abs(width - 1) <= 0.0001 && abs(height - 1) <= 0.0001
    }
}

public enum WebRTCStreamRecordingRotation: Int, CaseIterable, Sendable {
    case degrees0 = 0
    case degrees90 = 90
    case degrees180 = 180
    case degrees270 = 270

    public var quarterTurns: Int { rawValue / 90 }
}

public enum WebRTCStreamRecordingExportPreset: String, CaseIterable, Sendable {
    case highestQuality
    case balanced
    case compact
}

public enum WebRTCStreamRecordingTransitionStyle: String, Codable, CaseIterable, Sendable {
    case cut
    case fadeThroughBlack
}

public enum WebRTCStreamRecordingOutputResolution: String, CaseIterable, Sendable {
    case source
    case p720
    case p1080
    case p4k

    public var maximumLongEdge: CGFloat? {
        switch self {
        case .source: nil
        case .p720: 1280
        case .p1080: 1920
        case .p4k: 3840
        }
    }
}

public struct WebRTCStreamRecordingAudioEdit: Equatable, Sendable {
    public var volume: Double
    public var isMuted: Bool
    public var fadeInSeconds: Double
    public var fadeOutSeconds: Double

    public init(volume: Double = 1, isMuted: Bool = false, fadeInSeconds: Double = 0, fadeOutSeconds: Double = 0) {
        self.volume = volume
        self.isMuted = isMuted
        self.fadeInSeconds = fadeInSeconds
        self.fadeOutSeconds = fadeOutSeconds
    }

    public static let original = WebRTCStreamRecordingAudioEdit()
}

public struct WebRTCStreamRecordingColorAdjustment: Equatable, Sendable {
    public var exposure: Double
    public var contrast: Double
    public var saturation: Double
    public var temperature: Double
    public var tint: Double
    public var vignette: Double

    public init(exposure: Double = 0, contrast: Double = 1, saturation: Double = 1, temperature: Double = 0, tint: Double = 0, vignette: Double = 0) {
        self.exposure = exposure
        self.contrast = contrast
        self.saturation = saturation
        self.temperature = temperature
        self.tint = tint
        self.vignette = vignette
    }

    public static let neutral = WebRTCStreamRecordingColorAdjustment()

    var isNeutral: Bool {
        abs(exposure) < 0.0001 && abs(contrast - 1) < 0.0001 && abs(saturation - 1) < 0.0001 && abs(temperature) < 0.0001 && abs(tint) < 0.0001 && abs(vignette) < 0.0001
    }
}

public struct WebRTCStreamRecordingPreview: @unchecked Sendable {
    public let asset: AVAsset
    public let audioMix: AVAudioMix?
    public let videoComposition: AVVideoComposition?
    public let durationSeconds: Double

    public init(asset: AVAsset, audioMix: AVAudioMix?, videoComposition: AVVideoComposition?, durationSeconds: Double) {
        self.asset = asset
        self.audioMix = audioMix
        self.videoComposition = videoComposition
        self.durationSeconds = durationSeconds
    }
}

public struct WebRTCStreamRecordingEditRequest: Sendable {
    public var title: String
    public var segments: [WebRTCStreamRecordingEditSegment]
    public var crop: WebRTCStreamRecordingCrop?
    public var rotation: WebRTCStreamRecordingRotation
    public var isFlippedHorizontally: Bool
    public var isFlippedVertically: Bool
    public var playbackRate: Double
    public var audio: WebRTCStreamRecordingAudioEdit
    public var exportPreset: WebRTCStreamRecordingExportPreset
    public var outputResolution: WebRTCStreamRecordingOutputResolution
    public var color: WebRTCStreamRecordingColorAdjustment
    public var captions: [RecordingEditorCaption]
    public var burnInCaptions: Bool
    public var overlays: [RecordingEditorOverlay]
    public var zoomKeyframes: [RecordingEditorZoomKeyframe]

    public init(title: String, segments: [WebRTCStreamRecordingEditSegment], crop: WebRTCStreamRecordingCrop? = nil, rotation: WebRTCStreamRecordingRotation = .degrees0, isFlippedHorizontally: Bool = false, isFlippedVertically: Bool = false, playbackRate: Double = 1, audio: WebRTCStreamRecordingAudioEdit = .original, exportPreset: WebRTCStreamRecordingExportPreset = .highestQuality, outputResolution: WebRTCStreamRecordingOutputResolution = .source, color: WebRTCStreamRecordingColorAdjustment = .neutral, captions: [RecordingEditorCaption] = [], burnInCaptions: Bool = false, overlays: [RecordingEditorOverlay] = [], zoomKeyframes: [RecordingEditorZoomKeyframe] = []) {
        self.title = title
        self.segments = segments
        self.crop = crop
        self.rotation = rotation
        self.isFlippedHorizontally = isFlippedHorizontally
        self.isFlippedVertically = isFlippedVertically
        self.playbackRate = playbackRate
        self.audio = audio
        self.exportPreset = exportPreset
        self.outputResolution = outputResolution
        self.color = color
        self.captions = captions
        self.burnInCaptions = burnInCaptions
        self.overlays = overlays
        self.zoomKeyframes = zoomKeyframes
    }
}

public struct RecordingEditorZoomKeyframe: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var timeSeconds: Double
    public var centerX: Double
    public var centerY: Double
    public var scale: Double

    public init(id: UUID = UUID(), timeSeconds: Double, centerX: Double, centerY: Double, scale: Double) {
        self.id = id
        self.timeSeconds = timeSeconds
        self.centerX = centerX
        self.centerY = centerY
        self.scale = scale
    }
}

public enum WebRTCStreamRecordingEditorError: LocalizedError, Equatable {
    case emptyTimeline
    case missingSourceFile(String)
    case invalidTimeRange(String)
    case invalidCrop
    case invalidPlaybackRate
    case noVideoTrack(String)
    case unableToCreateCompositionTrack
    case unableToCreateExportSession
    case unsupportedExportType
    case exportCancelled
    case exportFailed(String)
    case invalidExportedFile

    public var errorDescription: String? {
        switch self {
        case .emptyTimeline:
            return "Add at least one clip segment before exporting."
        case .missingSourceFile(let fileName):
            return "The source recording file is missing: \(fileName)."
        case .invalidTimeRange(let fileName):
            return "The edit range is outside the source recording: \(fileName)."
        case .invalidCrop:
            return "The crop area must stay inside the video frame."
        case .invalidPlaybackRate:
            return "Playback speed must be between 0.25x and 4x."
        case .noVideoTrack(let fileName):
            return "The source recording has no video track: \(fileName)."
        case .unableToCreateCompositionTrack:
            return "Unable to prepare the edited video timeline."
        case .unableToCreateExportSession:
            return "Unable to start the video export session."
        case .unsupportedExportType:
            return "The selected export preset cannot create an MP4 video."
        case .exportCancelled:
            return "Video export was cancelled."
        case .exportFailed(let message):
            return message.isEmpty ? "Video export failed." : message
        case .invalidExportedFile:
            return "The exported video file could not be validated."
        }
    }
}

private struct WebRTCStreamRecordingLoadedSegment {
    let segment: WebRTCStreamRecordingEditSegment
    let asset: AVURLAsset
    let duration: CMTime
    let videoTrack: AVAssetTrack
    let audioTrack: AVAssetTrack?
    let displaySize: CGSize
    let preferredTransform: CGAffineTransform
    let frameRate: Float
}

private struct WebRTCStreamRecordingTimelineBuildResult {
    let composition: AVMutableComposition
    let duration: CMTime
    let firstRecording: WebRTCStreamRecording
    let renderSize: CGSize
    let frameRate: Float
}

public final class WebRTCStreamRecordingExportSessionBox: @unchecked Sendable {
    let session: AVAssetExportSession

    init(session: AVAssetExportSession) {
        self.session = session
    }
}

public extension WebRTCStreamRecordingLibrary {
    static func previewEditedRecording(_ request: WebRTCStreamRecordingEditRequest) async throws -> WebRTCStreamRecordingPreview {
        let normalizedRequest = try validate(request)
        let loadedSegments = try await loadSegments(normalizedRequest.segments)
        let build = try buildTimeline(from: loadedSegments, request: normalizedRequest)
        let previewAudioMix = audioMix(for: build.composition, request: normalizedRequest, duration: build.duration)
        let previewVideoComposition = try await (needsVideoComposition(normalizedRequest, loadedSegments: loadedSegments)
            ? videoComposition(for: build.composition, request: normalizedRequest, renderSize: build.renderSize, frameRate: build.frameRate)
            : nil
        )
        return WebRTCStreamRecordingPreview(
            asset: build.composition,
            audioMix: previewAudioMix,
            videoComposition: previewVideoComposition,
            durationSeconds: max(0, build.duration.seconds)
        )
    }

    static func exportEditedRecording(_ request: WebRTCStreamRecordingEditRequest, sessionHandler: (@MainActor (WebRTCStreamRecordingExportSessionBox) -> Void)? = nil, progressHandler: (@MainActor @Sendable (Double) -> Void)? = nil) async throws -> WebRTCStreamRecording {
        let normalizedRequest = try validate(request)
        let outputID = UUID()
        let outputDirectory = try ensureDirectory(forGameTitle: normalizedRequest.title)
        let outputURL = outputDirectory.appendingPathComponent(outputID.uuidString).appendingPathExtension("mp4")
        let metadataURL = outputDirectory.appendingPathComponent(outputID.uuidString).appendingPathExtension("json")
        try removeIfExists(outputURL)
        try removeIfExists(metadataURL)
        do {
            let loadedSegments = try await loadSegments(normalizedRequest.segments)
            let build = try buildTimeline(from: loadedSegments, request: normalizedRequest)
            let presetName = await compatiblePreset(for: normalizedRequest.exportPreset, asset: build.composition)
            guard let exportSession = AVAssetExportSession(asset: build.composition, presetName: presetName) else { throw WebRTCStreamRecordingEditorError.unableToCreateExportSession }
            let outputFileType = try compatibleMP4FileType(for: exportSession)
            exportSession.shouldOptimizeForNetworkUse = false
            exportSession.timeRange = CMTimeRange(start: .zero, duration: build.duration)
            exportSession.audioMix = audioMix(for: build.composition, request: normalizedRequest, duration: build.duration)
            if needsVideoComposition(normalizedRequest, loadedSegments: loadedSegments) {
                exportSession.videoComposition = try await videoComposition(for: build.composition, request: normalizedRequest, renderSize: build.renderSize, frameRate: build.frameRate)
            }
            let sessionBox = WebRTCStreamRecordingExportSessionBox(session: exportSession)
            await sessionHandler?(sessionBox)
            await progressHandler?(0)
            try await runExportSession(exportSession, outputURL: outputURL, outputFileType: outputFileType, progressHandler: progressHandler)
            await progressHandler?(1)
            let attributes = try FileManager.default.attributesOfItem(atPath: outputURL.path)
            let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            guard fileSize > 0 else { throw WebRTCStreamRecordingEditorError.invalidExportedFile }
            let inspection = try await inspectExportedMedia(
                at: outputURL,
                expectedDuration: build.duration.seconds,
                expectedVideoSize: build.renderSize,
                requiresAudio: !normalizedRequest.audio.isMuted && loadedSegments.contains { $0.audioTrack != nil && !$0.segment.audio.isMuted }
            )
            let recording = WebRTCStreamRecording(
                id: outputID,
                title: normalizedRequest.title,
                applicationID: build.firstRecording.applicationID,
                createdAt: Date(),
                durationSeconds: inspection.durationSeconds,
                width: inspection.width,
                height: inspection.height,
                videoBitrateMbps: bitrateForExportPreset(normalizedRequest.exportPreset, source: build.firstRecording),
                audioBitrateKbps: normalizedRequest.audio.isMuted ? 0 : build.firstRecording.audioBitrateKbps,
                enhancedVideo: build.firstRecording.enhancedVideo,
                fileName: outputURL.lastPathComponent,
                fileSizeBytes: fileSize,
                storageDirectoryPath: outputDirectory.path
            )
            let data = try JSONEncoder.recordingEncoder.encode(recording)
            try data.write(to: metadataURL, options: .atomic)
            return recording
        } catch {
            try? removeIfExists(outputURL)
            try? removeIfExists(metadataURL)
            throw error
        }
    }

    static func exportEditedRecordingCopy(_ request: WebRTCStreamRecordingEditRequest, to destinationURL: URL, sessionHandler: (@MainActor (WebRTCStreamRecordingExportSessionBox) -> Void)? = nil, progressHandler: (@MainActor @Sendable (Double) -> Void)? = nil) async throws -> URL {
        let normalizedRequest = try validate(request)
        let outputURL = destinationURL.pathExtension.isEmpty ? destinationURL.appendingPathExtension("mp4") : destinationURL
        let fileManager = FileManager.default
        let destinationPath = outputURL.standardizedFileURL.path
        guard !normalizedRequest.segments.contains(where: { $0.recording.videoURL.standardizedFileURL.path == destinationPath }) else {
            throw WebRTCStreamRecordingEditorError.exportFailed("Choose a new file so the source recording stays unchanged.")
        }
        let parentDirectory = outputURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parentDirectory, withIntermediateDirectories: true)
        let temporaryURL = parentDirectory.appendingPathComponent(".pixelnow-export-\(UUID().uuidString)").appendingPathExtension("mp4")
        do {
            let loadedSegments = try await loadSegments(normalizedRequest.segments)
            let build = try buildTimeline(from: loadedSegments, request: normalizedRequest)
            let presetName = await compatiblePreset(for: normalizedRequest.exportPreset, asset: build.composition)
            guard let exportSession = AVAssetExportSession(asset: build.composition, presetName: presetName) else { throw WebRTCStreamRecordingEditorError.unableToCreateExportSession }
            let outputFileType = try compatibleMP4FileType(for: exportSession)
            exportSession.shouldOptimizeForNetworkUse = false
            exportSession.timeRange = CMTimeRange(start: .zero, duration: build.duration)
            exportSession.audioMix = audioMix(for: build.composition, request: normalizedRequest, duration: build.duration)
            if needsVideoComposition(normalizedRequest, loadedSegments: loadedSegments) {
                exportSession.videoComposition = try await videoComposition(for: build.composition, request: normalizedRequest, renderSize: build.renderSize, frameRate: build.frameRate)
            }
            await sessionHandler?(WebRTCStreamRecordingExportSessionBox(session: exportSession))
            await progressHandler?(0)
            try await runExportSession(exportSession, outputURL: temporaryURL, outputFileType: outputFileType, progressHandler: progressHandler)
            _ = try await inspectExportedMedia(
                at: temporaryURL,
                expectedDuration: build.duration.seconds,
                expectedVideoSize: build.renderSize,
                requiresAudio: !normalizedRequest.audio.isMuted && loadedSegments.contains { $0.audioTrack != nil && !$0.segment.audio.isMuted }
            )
            if fileManager.fileExists(atPath: outputURL.path) {
                _ = try fileManager.replaceItemAt(outputURL, withItemAt: temporaryURL)
            } else {
                try fileManager.moveItem(at: temporaryURL, to: outputURL)
            }
            await progressHandler?(1)
            return outputURL
        } catch {
            try? removeIfExists(temporaryURL)
            throw error
        }
    }

    private static func validate(_ request: WebRTCStreamRecordingEditRequest) throws -> WebRTCStreamRecordingEditRequest {
        guard !request.segments.isEmpty else { throw WebRTCStreamRecordingEditorError.emptyTimeline }
        guard request.playbackRate.isFinite, request.playbackRate >= 0.25, request.playbackRate <= 4 else { throw WebRTCStreamRecordingEditorError.invalidPlaybackRate }
        if let crop = request.crop, !crop.isFullFrame {
            guard crop.x.isFinite, crop.y.isFinite, crop.width.isFinite, crop.height.isFinite,
                  crop.x >= 0, crop.y >= 0, crop.width > 0, crop.height > 0,
                  crop.x + crop.width <= 1.0001, crop.y + crop.height <= 1.0001 else { throw WebRTCStreamRecordingEditorError.invalidCrop }
        }
        let cleanedTitle = request.title.trimmingCharacters(in: .whitespacesAndNewlines)
        var normalized = request
        normalized.title = cleanedTitle.isEmpty ? request.segments[0].recording.title + " Edited" : cleanedTitle
        normalized.playbackRate = min(max(request.playbackRate, 0.25), 4)
        normalized.audio.volume = min(max(request.audio.volume.isFinite ? request.audio.volume : 1, 0), 2)
        normalized.audio.fadeInSeconds = max(0, request.audio.fadeInSeconds.isFinite ? request.audio.fadeInSeconds : 0)
        normalized.audio.fadeOutSeconds = max(0, request.audio.fadeOutSeconds.isFinite ? request.audio.fadeOutSeconds : 0)
        for index in normalized.segments.indices {
            normalized.segments[index].audio.volume = min(max(normalized.segments[index].audio.volume.isFinite ? normalized.segments[index].audio.volume : 1, 0), 8)
            normalized.segments[index].transitionDurationSeconds = min(max(normalized.segments[index].transitionDurationSeconds.isFinite ? normalized.segments[index].transitionDurationSeconds : 0.5, 0.1), 2)
        }
        normalized.color.exposure = min(max(request.color.exposure.isFinite ? request.color.exposure : 0, -4), 4)
        normalized.color.contrast = min(max(request.color.contrast.isFinite ? request.color.contrast : 1, 0), 2)
        normalized.color.saturation = min(max(request.color.saturation.isFinite ? request.color.saturation : 1, 0), 2)
        normalized.color.temperature = min(max(request.color.temperature.isFinite ? request.color.temperature : 0, -1), 1)
        normalized.color.tint = min(max(request.color.tint.isFinite ? request.color.tint : 0, -1), 1)
        normalized.color.vignette = min(max(request.color.vignette.isFinite ? request.color.vignette : 0, 0), 1)
        normalized.overlays = request.overlays.compactMap { overlay in
            guard overlay.startSeconds.isFinite, overlay.endSeconds.isFinite, overlay.endSeconds > overlay.startSeconds,
                  overlay.x.isFinite, overlay.y.isFinite, overlay.width.isFinite, overlay.height.isFinite else { return nil }
            var safeOverlay = overlay
            safeOverlay.startSeconds = max(0, overlay.startSeconds)
            safeOverlay.endSeconds = max(safeOverlay.startSeconds + 0.05, overlay.endSeconds)
            safeOverlay.x = min(max(0, overlay.x), 0.95)
            safeOverlay.y = min(max(0, overlay.y), 0.95)
            safeOverlay.width = min(max(0.05, overlay.width), 1 - safeOverlay.x)
            safeOverlay.height = min(max(0.05, overlay.height), 1 - safeOverlay.y)
            return safeOverlay
        }
        return normalized
    }

    private static func loadSegments(_ segments: [WebRTCStreamRecordingEditSegment]) async throws -> [WebRTCStreamRecordingLoadedSegment] {
        var loadedSegments: [WebRTCStreamRecordingLoadedSegment] = []
        loadedSegments.reserveCapacity(segments.count)
        for segment in segments {
            let url = segment.recording.videoURL
            guard FileManager.default.fileExists(atPath: url.path) else { throw WebRTCStreamRecordingEditorError.missingSourceFile(url.lastPathComponent) }
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration)
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            guard let videoTrack = videoTracks.first else { throw WebRTCStreamRecordingEditorError.noVideoTrack(url.lastPathComponent) }
            let frameRate = try await videoTrack.load(.nominalFrameRate)
            let audioTrack = try await asset.loadTracks(withMediaType: .audio).first
            let naturalSize = try await videoTrack.load(.naturalSize)
            let preferredTransform = try await videoTrack.load(.preferredTransform)
            let displaySize = displaySize(naturalSize: naturalSize, preferredTransform: preferredTransform)
            guard segment.startSeconds.isFinite, segment.endSeconds.isFinite, segment.startSeconds >= 0, segment.endSeconds > segment.startSeconds else { throw WebRTCStreamRecordingEditorError.invalidTimeRange(url.lastPathComponent) }
            guard segment.endSeconds <= duration.seconds + 0.05 else { throw WebRTCStreamRecordingEditorError.invalidTimeRange(url.lastPathComponent) }
            loadedSegments.append(WebRTCStreamRecordingLoadedSegment(segment: segment, asset: asset, duration: duration, videoTrack: videoTrack, audioTrack: audioTrack, displaySize: displaySize, preferredTransform: preferredTransform, frameRate: frameRate))
        }
        return loadedSegments
    }

    private static func buildTimeline(from loadedSegments: [WebRTCStreamRecordingLoadedSegment], request: WebRTCStreamRecordingEditRequest) throws -> WebRTCStreamRecordingTimelineBuildResult {
        guard let firstSegment = loadedSegments.first else { throw WebRTCStreamRecordingEditorError.emptyTimeline }
        let composition = AVMutableComposition()
        guard let videoCompositionTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw WebRTCStreamRecordingEditorError.unableToCreateCompositionTrack }
        let audioCompositionTrack = loadedSegments.contains { $0.audioTrack != nil } ? composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) : nil
        videoCompositionTrack.preferredTransform = firstSegment.preferredTransform
        var cursor = CMTime.zero
        for loadedSegment in loadedSegments {
            let sourceStart = CMTime(seconds: loadedSegment.segment.startSeconds, preferredTimescale: 600)
            let sourceEnd = CMTime(seconds: loadedSegment.segment.endSeconds, preferredTimescale: 600)
            let sourceDuration = CMTimeSubtract(sourceEnd, sourceStart)
            let sourceRange = CMTimeRange(start: sourceStart, duration: sourceDuration)
            try videoCompositionTrack.insertTimeRange(sourceRange, of: loadedSegment.videoTrack, at: cursor)
            if let audioTrack = loadedSegment.audioTrack, let audioCompositionTrack {
                try audioCompositionTrack.insertTimeRange(sourceRange, of: audioTrack, at: cursor)
            }
            let insertedRange = CMTimeRange(start: cursor, duration: sourceDuration)
            let scaledDuration = CMTimeMultiplyByFloat64(sourceDuration, multiplier: 1 / request.playbackRate)
            if abs(request.playbackRate - 1) > 0.0001 {
                videoCompositionTrack.scaleTimeRange(insertedRange, toDuration: scaledDuration)
                audioCompositionTrack?.scaleTimeRange(insertedRange, toDuration: scaledDuration)
            }
            cursor = CMTimeAdd(cursor, scaledDuration)
        }
        let renderSize = renderSize(for: firstSegment.displaySize, request: request)
        return WebRTCStreamRecordingTimelineBuildResult(composition: composition, duration: cursor, firstRecording: firstSegment.segment.recording, renderSize: renderSize, frameRate: firstSegment.frameRate)
    }

    private static func videoComposition(for composition: AVMutableComposition, request: WebRTCStreamRecordingEditRequest, renderSize: CGSize, frameRate: Float) async throws -> AVMutableVideoComposition {
        let videoComposition = try await withCheckedThrowingContinuation { continuation in
            AVMutableVideoComposition.videoComposition(with: composition, applyingCIFiltersWithHandler: { filterRequest in
                applyVideoFilters(filterRequest, request: request, renderSize: renderSize)
            }) { videoComposition, error in
                if let videoComposition {
                    continuation.resume(returning: videoComposition)
                } else {
                    continuation.resume(throwing: WebRTCStreamRecordingEditorError.exportFailed(error?.localizedDescription ?? "Unable to create video composition."))
                }
            }
        }
        videoComposition.renderSize = normalizedRenderSize(renderSize)
        let sourceFrameRate = min(max(Int(frameRate.rounded()), 1), 60)
        videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(sourceFrameRate))
        return videoComposition
    }

    private static func applyVideoFilters(_ filterRequest: AVAsynchronousCIImageFilteringRequest, request: WebRTCStreamRecordingEditRequest, renderSize: CGSize) {
        let sourceExtent = filterRequest.sourceImage.extent
        let crop = request.crop ?? .fullFrame
        let cropRect = cropRect(for: sourceExtent, crop: crop)
        var image = filterRequest.sourceImage.cropped(to: cropRect).transformed(by: CGAffineTransform(translationX: -cropRect.minX, y: -cropRect.minY))
        image = applyColorAdjustments(image, adjustment: request.color)
        let croppedExtent = CGRect(origin: .zero, size: cropRect.size)
        if request.isFlippedHorizontally {
            image = image.transformed(by: CGAffineTransform(translationX: croppedExtent.width, y: 0).scaledBy(x: -1, y: 1))
        }
        if request.isFlippedVertically {
            image = image.transformed(by: CGAffineTransform(translationX: 0, y: croppedExtent.height).scaledBy(x: 1, y: -1))
        }
        image = rotatedImage(image, rotation: request.rotation, sourceSize: croppedExtent.size)
        let rotatedExtent = CGRect(origin: .zero, size: rotatedSize(croppedExtent.size, rotation: request.rotation))
        let scale = min(renderSize.width / max(rotatedExtent.width, 1), renderSize.height / max(rotatedExtent.height, 1))
        let scaledWidth = rotatedExtent.width * scale
        let scaledHeight = rotatedExtent.height * scale
        let x = (renderSize.width - scaledWidth) / 2
        let y = (renderSize.height - scaledHeight) / 2
        image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale).translatedBy(x: x / max(scale, 0.0001), y: y / max(scale, 0.0001)))
        let outputRect = CGRect(origin: .zero, size: renderSize)
        if let zoom = zoomValue(at: filterRequest.compositionTime.seconds, keyframes: request.zoomKeyframes) {
            let centerX = min(max(zoom.centerX, 0), 1) * renderSize.width
            let centerY = (1 - min(max(zoom.centerY, 0), 1)) * renderSize.height
            image = image.transformed(by: CGAffineTransform(translationX: -centerX, y: -centerY))
            image = image.transformed(by: CGAffineTransform(scaleX: zoom.scale, y: zoom.scale))
            image = image.transformed(by: CGAffineTransform(translationX: renderSize.width / 2, y: renderSize.height / 2))
        }
        image = image.cropped(to: outputRect)
        if request.burnInCaptions,
           let caption = request.captions.first(where: { filterRequest.compositionTime.seconds >= $0.startSeconds && filterRequest.compositionTime.seconds <= $0.endSeconds }),
           let textFilter = CIFilter(name: "CITextImageGenerator") {
            textFilter.setValue(caption.text, forKey: "inputText")
            textFilter.setValue("HelveticaNeue-Bold", forKey: "inputFontName")
            textFilter.setValue(max(22, renderSize.width * 0.035), forKey: "inputFontSize")
            textFilter.setValue(1, forKey: "inputScaleFactor")
            textFilter.setValue(8, forKey: "inputPadding")
            if let generatedText = textFilter.outputImage {
                let extent = generatedText.extent
                let positioned = generatedText.transformed(by: CGAffineTransform(translationX: (renderSize.width - extent.width) / 2 - extent.minX, y: renderSize.height * 0.06 - extent.minY))
                image = positioned.composited(over: image).cropped(to: outputRect)
            }
        }
        let transitionOpacity = transitionBlackOpacity(at: filterRequest.compositionTime.seconds, segments: request.segments, playbackRate: request.playbackRate)
        if transitionOpacity > 0 {
            let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: transitionOpacity)).cropped(to: outputRect)
            image = black.composited(over: image).cropped(to: outputRect)
        }
        image = applyOverlays(request.overlays, at: filterRequest.compositionTime.seconds, to: image, renderSize: renderSize)
        image = applyPointerTreatment(request.segments, at: filterRequest.compositionTime.seconds, playbackRate: request.playbackRate, to: image, renderSize: renderSize)
        filterRequest.finish(with: image, context: nil)
    }

    private static func zoomValue(at time: Double, keyframes: [RecordingEditorZoomKeyframe]) -> (centerX: Double, centerY: Double, scale: Double)? {
        let valid = keyframes.filter { $0.timeSeconds.isFinite && $0.centerX.isFinite && $0.centerY.isFinite && $0.scale.isFinite }
            .sorted { $0.timeSeconds < $1.timeSeconds }
        guard let first = valid.first, let last = valid.last, time >= first.timeSeconds, time <= last.timeSeconds else { return nil }
        guard let nextIndex = valid.firstIndex(where: { $0.timeSeconds >= time }) else { return (last.centerX, last.centerY, last.scale) }
        let next = valid[nextIndex]
        guard nextIndex > 0 else { return (next.centerX, next.centerY, next.scale) }
        let previous = valid[nextIndex - 1]
        let duration = next.timeSeconds - previous.timeSeconds
        let amount = duration > 0 ? min(max((time - previous.timeSeconds) / duration, 0), 1) : 1
        return (
            previous.centerX + (next.centerX - previous.centerX) * amount,
            previous.centerY + (next.centerY - previous.centerY) * amount,
            previous.scale + (next.scale - previous.scale) * amount
        )
    }

    private static func applyPointerTreatment(_ segments: [WebRTCStreamRecordingEditSegment], at timelineTime: Double, playbackRate: Double, to image: CIImage, renderSize: CGSize) -> CIImage {
        var cursor = 0.0
        for segment in segments {
            let duration = segment.durationSeconds / max(0.25, playbackRate)
            if timelineTime >= cursor, timelineTime < cursor + duration,
               let events = segment.recording.pointerEvents, !events.isEmpty {
                let sourceTime = segment.startSeconds + (timelineTime - cursor) * playbackRate
                let current = events.last { $0.timeSeconds <= sourceTime }
                let next = events.first { $0.timeSeconds >= sourceTime }
                guard let current, sourceTime - current.timeSeconds <= 0.25 else { return image }
                let fraction: Double
                if let next, next.timeSeconds > current.timeSeconds {
                    fraction = min(max((sourceTime - current.timeSeconds) / (next.timeSeconds - current.timeSeconds), 0), 1)
                } else {
                    fraction = 0
                }
                let x = current.x + ((next?.x ?? current.x) - current.x) * fraction
                let y = current.y + ((next?.y ?? current.y) - current.y) * fraction
                let click = events.last { $0.clickType != nil && $0.timeSeconds <= sourceTime && sourceTime - $0.timeSeconds <= 0.55 }
                guard let pointerImage = pointerImage(size: renderSize, x: x, y: y, clickAge: click.map { sourceTime - $0.timeSeconds }) else { return image }
                return pointerImage.composited(over: image).cropped(to: CGRect(origin: .zero, size: renderSize))
            }
            cursor += duration
        }
        return image
    }

    private static func pointerImage(size: CGSize, x: Double, y: Double, clickAge: Double?) -> CIImage? {
        let width = max(1, Int(size.width.rounded()))
        let height = max(1, Int(size.height.rounded()))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let point = CGPoint(x: x * Double(width), y: (1 - y) * Double(height))
        if let clickAge {
            let progress = min(max(clickAge / 0.55, 0), 1)
            let radius = CGFloat(10 + progress * 32)
            context.setStrokeColor(NSColor.systemBlue.withAlphaComponent(CGFloat(1 - progress)).cgColor)
            context.setLineWidth(3)
            context.strokeEllipse(in: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
        }
        let cursorPath = CGMutablePath()
        cursorPath.move(to: point)
        cursorPath.addLine(to: CGPoint(x: point.x + 2, y: point.y - 23))
        cursorPath.addLine(to: CGPoint(x: point.x + 8, y: point.y - 16))
        cursorPath.addLine(to: CGPoint(x: point.x + 15, y: point.y - 16))
        cursorPath.closeSubpath()
        context.addPath(cursorPath)
        context.setFillColor(NSColor.white.cgColor)
        context.setStrokeColor(NSColor.black.cgColor)
        context.setLineWidth(2)
        context.drawPath(using: .fillStroke)
        guard let cgImage = context.makeImage() else { return nil }
        return CIImage(cgImage: cgImage)
    }

    private static func transitionBlackOpacity(at time: Double, segments: [WebRTCStreamRecordingEditSegment], playbackRate: Double) -> CGFloat {
        var cursor = 0.0
        var opacity = 0.0
        for (index, segment) in segments.enumerated() {
            if index > 0, segment.transitionBefore == .fadeThroughBlack {
                let duration = segment.transitionDurationSeconds
                let boundary = cursor
                if time >= boundary - duration, time < boundary {
                    opacity = max(opacity, (time - (boundary - duration)) / duration)
                } else if time >= boundary, time < boundary + duration {
                    opacity = max(opacity, (boundary + duration - time) / duration)
                }
            }
            cursor += segment.durationSeconds / max(0.25, playbackRate)
        }
        return CGFloat(min(max(opacity, 0), 1))
    }

    private static func applyOverlays(_ overlays: [RecordingEditorOverlay], at time: Double, to sourceImage: CIImage, renderSize: CGSize) -> CIImage {
        let outputRect = CGRect(origin: .zero, size: renderSize)
        return overlays.reduce(sourceImage) { image, overlay in
            guard time >= overlay.startSeconds, time < overlay.endSeconds else { return image }
            let region = CGRect(
                x: CGFloat(overlay.x) * renderSize.width,
                y: CGFloat(1 - overlay.y - overlay.height) * renderSize.height,
                width: CGFloat(overlay.width) * renderSize.width,
                height: CGFloat(overlay.height) * renderSize.height
            ).intersection(outputRect)
            guard !region.isNull, !region.isEmpty else { return image }
            switch overlay.kind {
            case .redaction:
                let mask = CIImage(color: .black).cropped(to: region)
                return mask.composited(over: image).cropped(to: outputRect)
            case .blur:
                guard let blend = CIFilter(name: "CIBlendWithMask") else { return image }
                let blurred = image.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: max(8, min(region.width, region.height) * 0.12)]).cropped(to: outputRect)
                let blackMask = CIImage(color: .black).cropped(to: outputRect)
                let whiteRegion = CIImage(color: .white).cropped(to: region)
                let mask = whiteRegion.composited(over: blackMask).cropped(to: outputRect)
                blend.setValue(blurred, forKey: kCIInputImageKey)
                blend.setValue(image, forKey: kCIInputBackgroundImageKey)
                blend.setValue(mask, forKey: kCIInputMaskImageKey)
                return (blend.outputImage ?? image).cropped(to: outputRect)
            case .callout:
                let background = CIImage(color: CIColor(red: 0.07, green: 0.09, blue: 0.13, alpha: 0.94)).cropped(to: region)
                guard let textFilter = CIFilter(name: "CITextImageGenerator") else { return background.composited(over: image).cropped(to: outputRect) }
                textFilter.setValue(overlay.text, forKey: "inputText")
                textFilter.setValue("HelveticaNeue-Bold", forKey: "inputFontName")
                textFilter.setValue(max(14, min(renderSize.width * 0.035, region.height * 0.3)), forKey: "inputFontSize")
                textFilter.setValue(1, forKey: "inputScaleFactor")
                textFilter.setValue(4, forKey: "inputPadding")
                textFilter.setValue(CIColor.white, forKey: "inputColor")
                guard let generated = textFilter.outputImage else { return background.composited(over: image).cropped(to: outputRect) }
                let extent = generated.extent
                let scale = min(1, min((region.width - 16) / max(1, extent.width), (region.height - 12) / max(1, extent.height)))
                let text = generated.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                let textExtent = text.extent
                let positioned = text.transformed(by: CGAffineTransform(translationX: region.minX + (region.width - textExtent.width) / 2 - textExtent.minX, y: region.minY + (region.height - textExtent.height) / 2 - textExtent.minY))
                return positioned.composited(over: background).composited(over: image).cropped(to: outputRect)
            }
        }
    }

    private static func audioMix(for composition: AVMutableComposition, request: WebRTCStreamRecordingEditRequest, duration: CMTime) -> AVAudioMix? {
        guard let audioTrack = composition.tracks(withMediaType: .audio).first else { return nil }
        let parameters = AVMutableAudioMixInputParameters(track: audioTrack)
        let masterVolume = Float(request.audio.isMuted ? 0 : request.audio.volume)
        parameters.setVolume(masterVolume, at: .zero)
        var timelineCursor = CMTime.zero
        for segment in request.segments {
            let segmentDuration = CMTime(seconds: segment.durationSeconds / request.playbackRate, preferredTimescale: 600)
            let segmentVolume = Float(segment.audio.isMuted ? 0 : segment.audio.volume) * masterVolume
            let segmentRange = CMTimeRange(start: timelineCursor, duration: segmentDuration)
            parameters.setVolume(segmentVolume, at: timelineCursor)
            if !segment.audio.isMuted, !request.audio.isMuted, segment.audio.fadeInSeconds > 0 {
                let fadeDuration = CMTime(seconds: min(segment.audio.fadeInSeconds / request.playbackRate, segmentDuration.seconds), preferredTimescale: 600)
                parameters.setVolumeRamp(fromStartVolume: 0, toEndVolume: segmentVolume, timeRange: CMTimeRange(start: timelineCursor, duration: fadeDuration))
            }
            if !segment.audio.isMuted, !request.audio.isMuted, segment.audio.fadeOutSeconds > 0 {
                let fadeDuration = CMTime(seconds: min(segment.audio.fadeOutSeconds / request.playbackRate, segmentDuration.seconds), preferredTimescale: 600)
                let fadeStart = CMTimeAdd(timelineCursor, CMTimeSubtract(segmentDuration, fadeDuration))
                parameters.setVolumeRamp(fromStartVolume: segmentVolume, toEndVolume: 0, timeRange: CMTimeRange(start: fadeStart, duration: fadeDuration))
            }
            if segmentRange.duration.isValid { timelineCursor = CMTimeAdd(timelineCursor, segmentDuration) }
        }
        if !request.audio.isMuted, request.audio.fadeInSeconds > 0 {
            let fadeDuration = CMTime(seconds: min(request.audio.fadeInSeconds, max(0, duration.seconds)), preferredTimescale: 600)
            parameters.setVolumeRamp(fromStartVolume: 0, toEndVolume: masterVolume, timeRange: CMTimeRange(start: .zero, duration: fadeDuration))
        }
        if !request.audio.isMuted, request.audio.fadeOutSeconds > 0 {
            let fadeDurationSeconds = min(request.audio.fadeOutSeconds, max(0, duration.seconds))
            let fadeDuration = CMTime(seconds: fadeDurationSeconds, preferredTimescale: 600)
            let start = CMTimeMaximum(.zero, CMTimeSubtract(duration, fadeDuration))
            parameters.setVolumeRamp(fromStartVolume: masterVolume, toEndVolume: 0, timeRange: CMTimeRange(start: start, duration: fadeDuration))
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = [parameters]
        return mix
    }

    private static func runExportSession(_ exportSession: AVAssetExportSession, outputURL: URL, outputFileType: AVFileType, progressHandler: (@MainActor @Sendable (Double) -> Void)?) async throws {
        let box = WebRTCStreamRecordingExportSessionBox(session: exportSession)
        let progressTask = Task.detached(priority: .utility) {
            while !Task.isCancelled {
                await progressHandler?(Double(box.session.progress))
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
        defer { progressTask.cancel() }
        do {
            try await exportSession.export(to: outputURL, as: outputFileType)
        } catch is CancellationError {
            throw WebRTCStreamRecordingEditorError.exportCancelled
        } catch {
            throw WebRTCStreamRecordingEditorError.exportFailed(error.localizedDescription)
        }
    }

    private static func needsVideoComposition(_ request: WebRTCStreamRecordingEditRequest, loadedSegments: [WebRTCStreamRecordingLoadedSegment]) -> Bool {
        if let crop = request.crop, !crop.isFullFrame { return true }
        if request.rotation != .degrees0 || request.isFlippedHorizontally || request.isFlippedVertically { return true }
        if !request.color.isNeutral { return true }
        if request.burnInCaptions, !request.captions.isEmpty { return true }
        if !request.overlays.isEmpty { return true }
        if request.segments.contains(where: { $0.transitionBefore == .fadeThroughBlack }) { return true }
        let firstSize = renderSize(for: loadedSegments.first?.displaySize ?? .zero, request: request)
        if let sourceSize = loadedSegments.first?.displaySize,
           abs(firstSize.width - sourceSize.width) > 1 || abs(firstSize.height - sourceSize.height) > 1 { return true }
        return loadedSegments.contains { abs($0.displaySize.width - firstSize.width) > 1 || abs($0.displaySize.height - firstSize.height) > 1 }
    }

    private static func applyColorAdjustments(_ image: CIImage, adjustment: WebRTCStreamRecordingColorAdjustment) -> CIImage {
        var result = image
        if abs(adjustment.exposure) > 0.0001, let filter = CIFilter(name: "CIExposureAdjust") {
            filter.setValue(result, forKey: kCIInputImageKey)
            filter.setValue(adjustment.exposure, forKey: kCIInputEVKey)
            if let output = filter.outputImage { result = output }
        }
        if abs(adjustment.contrast - 1) > 0.0001 || abs(adjustment.saturation - 1) > 0.0001,
           let filter = CIFilter(name: "CIColorControls") {
            filter.setValue(result, forKey: kCIInputImageKey)
            filter.setValue(adjustment.contrast, forKey: kCIInputContrastKey)
            filter.setValue(adjustment.saturation, forKey: kCIInputSaturationKey)
            if let output = filter.outputImage { result = output }
        }
        if abs(adjustment.temperature) > 0.0001 || abs(adjustment.tint) > 0.0001,
           let filter = CIFilter(name: "CITemperatureAndTint") {
            filter.setValue(result, forKey: kCIInputImageKey)
            filter.setValue(CIVector(x: 6500, y: 0), forKey: "inputNeutral")
            filter.setValue(CIVector(x: 6500 + adjustment.temperature * 1800, y: adjustment.tint * 400), forKey: "inputTargetNeutral")
            if let output = filter.outputImage { result = output }
        }
        if adjustment.vignette > 0.0001, let filter = CIFilter(name: "CIVignette") {
            filter.setValue(result, forKey: kCIInputImageKey)
            filter.setValue(adjustment.vignette, forKey: kCIInputIntensityKey)
            filter.setValue(max(result.extent.width, result.extent.height) * 0.65, forKey: kCIInputRadiusKey)
            if let output = filter.outputImage { result = output }
        }
        return result
    }

    private static func compatiblePreset(for exportPreset: WebRTCStreamRecordingExportPreset, asset: AVAsset) async -> String {
        let preferred: [String]
        switch exportPreset {
        case .highestQuality:
            preferred = [AVAssetExportPresetHighestQuality, AVAssetExportPresetHEVCHighestQuality, AVAssetExportPreset1920x1080]
        case .balanced:
            preferred = [AVAssetExportPreset1920x1080, AVAssetExportPresetMediumQuality, AVAssetExportPresetHighestQuality]
        case .compact:
            preferred = [AVAssetExportPreset1280x720, AVAssetExportPreset960x540, AVAssetExportPresetLowQuality, AVAssetExportPresetMediumQuality]
        }
        for preset in preferred {
            if await isPresetCompatible(preset, asset: asset) { return preset }
        }
        return AVAssetExportPresetHighestQuality
    }

    private static func isPresetCompatible(_ preset: String, asset: AVAsset) async -> Bool {
        await withCheckedContinuation { continuation in
            AVAssetExportSession.determineCompatibility(ofExportPreset: preset, with: asset, outputFileType: .mp4) { compatible in
                continuation.resume(returning: compatible)
            }
        }
    }

    private static func compatibleMP4FileType(for exportSession: AVAssetExportSession) throws -> AVFileType {
        if exportSession.supportedFileTypes.contains(.mp4) { return .mp4 }
        if let fileType = exportSession.supportedFileTypes.first { return fileType }
        throw WebRTCStreamRecordingEditorError.unsupportedExportType
    }

    private struct ExportedMediaInspection {
        let width: Int
        let height: Int
        let durationSeconds: Double
    }

    private static func inspectExportedMedia(at url: URL, expectedDuration: Double, expectedVideoSize: CGSize, requiresAudio: Bool) async throws -> ExportedMediaInspection {
        guard url.pathExtension.lowercased() == "mp4" else { throw WebRTCStreamRecordingEditorError.invalidExportedFile }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard ((attributes[.size] as? NSNumber)?.int64Value ?? 0) > 0 else { throw WebRTCStreamRecordingEditorError.invalidExportedFile }
        let asset = AVURLAsset(url: url)
        guard try await asset.load(.isPlayable) else { throw WebRTCStreamRecordingEditorError.invalidExportedFile }
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let videoTrack = videoTracks.first else { throw WebRTCStreamRecordingEditorError.invalidExportedFile }
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard !requiresAudio || !audioTracks.isEmpty else { throw WebRTCStreamRecordingEditorError.invalidExportedFile }
        let duration = try await asset.load(.duration)
        let durationSeconds = duration.seconds
        guard durationSeconds.isFinite,
              durationSeconds > 0,
              expectedDuration.isFinite,
              expectedDuration > 0,
              abs(durationSeconds - expectedDuration) <= max(0.5, expectedDuration * 0.02) else {
            throw WebRTCStreamRecordingEditorError.invalidExportedFile
        }
        let naturalSize = try await videoTrack.load(.naturalSize)
        let preferredTransform = try await videoTrack.load(.preferredTransform)
        let size = displaySize(naturalSize: naturalSize, preferredTransform: preferredTransform)
        let width = max(1, Int(size.width.rounded()))
        let height = max(1, Int(size.height.rounded()))
        guard abs(CGFloat(width) - expectedVideoSize.width) <= 2,
              abs(CGFloat(height) - expectedVideoSize.height) <= 2 else {
            throw WebRTCStreamRecordingEditorError.invalidExportedFile
        }
        return ExportedMediaInspection(width: width, height: height, durationSeconds: durationSeconds)
    }

    private static func displaySize(naturalSize: CGSize, preferredTransform: CGAffineTransform) -> CGSize {
        let transformed = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        let width = abs(transformed.width)
        let height = abs(transformed.height)
        return CGSize(width: max(1, width), height: max(1, height))
    }

    private static func renderSize(for sourceSize: CGSize, request: WebRTCStreamRecordingEditRequest) -> CGSize {
        let crop = request.crop ?? .fullFrame
        let croppedSize = CGSize(width: sourceSize.width * max(0.01, crop.width), height: sourceSize.height * max(0.01, crop.height))
        let rotated = rotatedSize(croppedSize, rotation: request.rotation)
        guard let maximumLongEdge = request.outputResolution.maximumLongEdge else { return normalizedRenderSize(rotated) }
        let scale = min(1, maximumLongEdge / max(rotated.width, rotated.height))
        return normalizedRenderSize(CGSize(width: rotated.width * scale, height: rotated.height * scale))
    }

    private static func normalizedRenderSize(_ size: CGSize) -> CGSize {
        let width = max(16, Int(size.width.rounded(.toNearestOrAwayFromZero)))
        let height = max(16, Int(size.height.rounded(.toNearestOrAwayFromZero)))
        return CGSize(width: width + width % 2, height: height + height % 2)
    }

    private static func cropRect(for extent: CGRect, crop: WebRTCStreamRecordingCrop) -> CGRect {
        guard !crop.isFullFrame else { return extent }
        return CGRect(
            x: extent.minX + extent.width * crop.x,
            y: extent.minY + extent.height * crop.y,
            width: extent.width * crop.width,
            height: extent.height * crop.height
        )
    }

    private static func rotatedSize(_ size: CGSize, rotation: WebRTCStreamRecordingRotation) -> CGSize {
        rotation == .degrees90 || rotation == .degrees270 ? CGSize(width: size.height, height: size.width) : size
    }

    private static func rotatedImage(_ image: CIImage, rotation: WebRTCStreamRecordingRotation, sourceSize: CGSize) -> CIImage {
        switch rotation {
        case .degrees0:
            return image
        case .degrees90:
            return image.transformed(by: CGAffineTransform(translationX: sourceSize.height, y: 0).rotated(by: .pi / 2))
        case .degrees180:
            return image.transformed(by: CGAffineTransform(translationX: sourceSize.width, y: sourceSize.height).rotated(by: .pi))
        case .degrees270:
            return image.transformed(by: CGAffineTransform(translationX: 0, y: sourceSize.width).rotated(by: -.pi / 2))
        }
    }

    private static func bitrateForExportPreset(_ preset: WebRTCStreamRecordingExportPreset, source: WebRTCStreamRecording) -> Int {
        switch preset {
        case .highestQuality:
            return source.videoBitrateMbps
        case .balanced:
            return source.videoBitrateMbps == 0 ? 0 : max(4, min(source.videoBitrateMbps, 18))
        case .compact:
            return source.videoBitrateMbps == 0 ? 0 : max(2, min(source.videoBitrateMbps, 8))
        }
    }

    private static func removeIfExists(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}
