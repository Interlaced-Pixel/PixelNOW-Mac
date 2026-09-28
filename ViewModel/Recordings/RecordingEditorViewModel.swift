import AVFoundation
import Combine
import Foundation
import Vision

enum RecordingEditorDragPayload: Equatable {
    case recording(UUID)
    case segment(UUID)

    private static let recordingPrefix = "pixelnow-recording:"
    private static let segmentPrefix = "pixelnow-segment:"

    var stringValue: String {
        switch self {
        case .recording(let id): return Self.recordingPrefix + id.uuidString
        case .segment(let id): return Self.segmentPrefix + id.uuidString
        }
    }

    init?(stringValue: String) {
        if let value = Self.payloadValue(in: stringValue, prefixes: [Self.recordingPrefix]) {
            guard let id = UUID(uuidString: value) else { return nil }
            self = .recording(id)
            return
        }
        if let value = Self.payloadValue(in: stringValue, prefixes: [Self.segmentPrefix]) {
            guard let id = UUID(uuidString: value) else { return nil }
            self = .segment(id)
            return
        }
        return nil
    }

    private static func payloadValue(in string: String, prefixes: [String]) -> String? {
        guard let prefix = prefixes.first(where: string.hasPrefix) else { return nil }
        return String(string.dropFirst(prefix.count))
    }
}

struct RecordingEditorSegment: Equatable, Identifiable {
    let id: UUID
    var recording: WebRTCStreamRecording
    var startSeconds: Double
    var endSeconds: Double
    var audioGain: Double
    var isAudioMuted: Bool
    var fadeInSeconds: Double
    var fadeOutSeconds: Double
    var transitionBefore: WebRTCStreamRecordingTransitionStyle
    var transitionDurationSeconds: Double

    init(id: UUID = UUID(), recording: WebRTCStreamRecording, startSeconds: Double, endSeconds: Double, audioGain: Double = 1, isAudioMuted: Bool = false, fadeInSeconds: Double = 0, fadeOutSeconds: Double = 0, transitionBefore: WebRTCStreamRecordingTransitionStyle = .cut, transitionDurationSeconds: Double = 0.5) {
        self.id = id
        self.recording = recording
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.audioGain = audioGain
        self.isAudioMuted = isAudioMuted
        self.fadeInSeconds = fadeInSeconds
        self.fadeOutSeconds = fadeOutSeconds
        self.transitionBefore = transitionBefore
        self.transitionDurationSeconds = transitionDurationSeconds
    }

    var durationSeconds: Double { max(0, endSeconds - startSeconds) }
}

struct RecordingEditorMarker: Codable, Equatable, Identifiable {
    let id: UUID
    var timeSeconds: Double
    var name: String

    init(id: UUID = UUID(), timeSeconds: Double, name: String = "") {
        self.id = id
        self.timeSeconds = timeSeconds
        self.name = name
    }
}

enum RecordingEditorAspectPreset: String, CaseIterable, Identifiable {
    case source
    case landscape16x9
    case vertical9x16
    case square
    case portrait4x5
    case classic4x3

    var id: String { rawValue }

    var title: String {
        switch self {
        case .source: "Source"
        case .landscape16x9: "16:9"
        case .vertical9x16: "9:16"
        case .square: "1:1"
        case .portrait4x5: "4:5"
        case .classic4x3: "4:3"
        }
    }

    var aspectRatio: Double? {
        switch self {
        case .source: nil
        case .landscape16x9: 16.0 / 9.0
        case .vertical9x16: 9.0 / 16.0
        case .square: 1
        case .portrait4x5: 4.0 / 5.0
        case .classic4x3: 4.0 / 3.0
        }
    }
}

enum RecordingEditorExportQuality: String, CaseIterable, Identifiable {
    case highest
    case balanced
    case compact

    var id: String { rawValue }

    var title: String {
        switch self {
        case .highest: return "Highest"
        case .balanced: return "Balanced"
        case .compact: return "Compact"
        }
    }

    var preset: WebRTCStreamRecordingExportPreset {
        switch self {
        case .highest: return .highestQuality
        case .balanced: return .balanced
        case .compact: return .compact
        }
    }
}

struct RecordingEditorAudioAnalysis: Sendable {
    var segmentID: UUID
    var recordingID: UUID
    var result: RecordingEditorAudioAnalysisResult
}

private struct RecordingEditorSnapshot {
    var outputTitle: String
    var segments: [RecordingEditorSegment]
    var selectedSegmentID: UUID?
    var markInSeconds: Double?
    var markOutSeconds: Double?
    var cropX: Double
    var cropY: Double
    var cropWidth: Double
    var cropHeight: Double
    var cropEnabled: Bool
    var cropAspectPreset: RecordingEditorAspectPreset
    var rotation: WebRTCStreamRecordingRotation
    var isFlippedHorizontally: Bool
    var isFlippedVertically: Bool
    var playbackRate: Double
    var isMuted: Bool
    var volume: Double
    var fadeInSeconds: Double
    var fadeOutSeconds: Double
    var exportQuality: RecordingEditorExportQuality
    var markers: [RecordingEditorMarker]
    var outputResolution: WebRTCStreamRecordingOutputResolution
    var colorAdjustment: WebRTCStreamRecordingColorAdjustment
    var transcript: RecordingEditorTranscript?
    var captions: [RecordingEditorCaption]
    var burnInCaptions: Bool
    var overlays: [RecordingEditorOverlay]
    var zoomKeyframes: [RecordingEditorZoomKeyframe]
}

private struct RecordingEditorTimeRange {
    var startSeconds: Double
    var endSeconds: Double

    var durationSeconds: Double { max(0, endSeconds - startSeconds) }
}

@MainActor
final class RecordingEditorViewModel: ObservableObject {
    private static let sectionJoinTolerance = 0.05

    let primaryRecording: WebRTCStreamRecording
    @Published var library: [WebRTCStreamRecording]
    @Published var outputTitle: String
    @Published var segments: [RecordingEditorSegment]
    @Published var selectedSegmentID: UUID?
    @Published var markInSeconds: Double?
    @Published var markOutSeconds: Double?
    @Published var cropX: Double = 0
    @Published var cropY: Double = 0
    @Published var cropWidth: Double = 1
    @Published var cropHeight: Double = 1
    @Published var cropEnabled = false
    @Published var cropAspectPreset: RecordingEditorAspectPreset = .source
    @Published var isCropOverlayEditing = false
    @Published var showsSafeAreaGuides = false
    @Published var rotation: WebRTCStreamRecordingRotation = .degrees0
    @Published var isFlippedHorizontally = false
    @Published var isFlippedVertically = false
    @Published var playbackRate = 1.0
    @Published var isMuted = false
    @Published var volume = 1.0
    @Published var fadeInSeconds = 0.0
    @Published var fadeOutSeconds = 0.0
    @Published var exportQuality: RecordingEditorExportQuality = .highest
    @Published var outputResolution: WebRTCStreamRecordingOutputResolution = .source
    @Published var markers: [RecordingEditorMarker] = []
    @Published var snappingEnabled = true
    @Published var timelineZoomScale = 1.0
    @Published var timelineVisibleStartSeconds = 0.0
    @Published var colorAdjustment = WebRTCStreamRecordingColorAdjustment.neutral
    @Published private(set) var transcript: RecordingEditorTranscript?
    @Published private(set) var draftTranscript: RecordingEditorTranscript?
    @Published var captions: [RecordingEditorCaption] = []
    @Published var burnInCaptions = false
    @Published var overlays: [RecordingEditorOverlay] = []
    @Published var zoomKeyframes: [RecordingEditorZoomKeyframe] = []
    @Published private(set) var isTranscribing = false
    @Published private(set) var audioAnalysis: RecordingEditorAudioAnalysis?
    @Published private(set) var isAnalyzingAudio = false
    @Published var selectedSilenceRangeIDs: Set<UUID> = []
    @Published private(set) var missingProjectRecordingIDs: [UUID] = []
    @Published private(set) var isExporting = false
    @Published private(set) var exportProgress = 0.0
    @Published var errorMessage: String?

    private var activeExportSession: AVAssetExportSession?
    private var hasRecordedOutputTitleEdit = false
    private var editorProjectID = UUID()
    private var pendingProject: RecordingEditorProject?
    private var relinkedRecordings: [UUID: WebRTCStreamRecording] = [:]

    private var undoStack: [RecordingEditorSnapshot] = []
    private var redoStack: [RecordingEditorSnapshot] = []

    init(recording: WebRTCStreamRecording, library: [WebRTCStreamRecording]) {
        primaryRecording = recording
        self.library = library
        outputTitle = Self.uniqueOutputTitle(for: recording.title, recordingID: recording.id, library: library)
        let segment = RecordingEditorSegment(recording: recording, startSeconds: 0, endSeconds: max(0, recording.durationSeconds))
        segments = [segment]
        selectedSegmentID = segment.id
    }

    private static func uniqueOutputTitle(for sourceTitle: String, recordingID: UUID, library: [WebRTCStreamRecording]) -> String {
        var base = sourceTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        for suffix in [" - Edited", " Edited", " - Edit", " Edit"] where base.lowercased().hasSuffix(suffix.lowercased()) {
            base = String(base.dropLast(suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }
        if base.isEmpty { base = "Video" }
        let usedTitles = Set(library.filter { $0.id != recordingID }.map { $0.title.localizedLowercase })
        let proposedTitle = "\(base) Edited"
        guard usedTitles.contains(proposedTitle.localizedLowercase) else { return proposedTitle }
        var version = 2
        while usedTitles.contains("\(proposedTitle) \(version)".localizedLowercase) { version += 1 }
        return "\(proposedTitle) \(version)"
    }

    var selectedSegment: RecordingEditorSegment? {
        guard let selectedSegmentID else { return segments.first }
        return segments.first { $0.id == selectedSegmentID }
    }

    var selectedSegmentIndex: Int? {
        guard let selectedSegmentID else { return segments.indices.first }
        return segments.firstIndex { $0.id == selectedSegmentID }
    }

    var totalSourceDurationSeconds: Double {
        segments.reduce(0) { $0 + $1.durationSeconds }
    }

    var outputDurationSeconds: Double {
        totalSourceDurationSeconds / max(0.25, playbackRate)
    }

    var predictedOutputDimensions: (width: Int, height: Int) {
        let segment = segments.first
        let sourceWidth = Double(segment?.recording.width ?? primaryRecording.width)
        let sourceHeight = Double(segment?.recording.height ?? primaryRecording.height)
        let cropWidth = cropEnabled ? cropWidth : 1
        let cropHeight = cropEnabled ? cropHeight : 1
        var width = sourceWidth * cropWidth
        var height = sourceHeight * cropHeight
        if rotation == .degrees90 || rotation == .degrees270 { swap(&width, &height) }
        if let cap = outputResolution.maximumLongEdge {
            let scale = min(1, Double(cap) / max(width, height))
            width *= scale
            height *= scale
        }
        let evenWidth = max(16, Int(width.rounded())) & ~1
        let evenHeight = max(16, Int(height.rounded())) & ~1
        return (evenWidth, evenHeight)
    }

    var supports4KOutput: Bool {
        max(primaryRecording.width, primaryRecording.height) >= 3840
    }

    var normalizedCropAspectRatio: Double? {
        guard let targetAspect = cropAspectPreset.aspectRatio else { return nil }
        let finalAspect = rotation == .degrees90 || rotation == .degrees270 ? 1 / targetAspect : targetAspect
        let sourceAspect = Double(primaryRecording.width) / Double(max(1, primaryRecording.height))
        return finalAspect / sourceAspect
    }

    var estimatedFileSizeRange: ClosedRange<Int64> {
        let dimensions = predictedOutputDimensions
        let sourcePixels = max(1, primaryRecording.width * primaryRecording.height)
        let outputPixels = max(1, dimensions.width * dimensions.height)
        let qualityFactor: Double = switch exportQuality {
        case .highest: 1
        case .balanced: 0.72
        case .compact: 0.42
        }
        let sourceVideoBitsPerSecond = Double(max(primaryRecording.videoBitrateMbps, 1)) * 1_000_000
        let estimatedBitsPerSecond = sourceVideoBitsPerSecond * Double(outputPixels) / Double(sourcePixels) * qualityFactor + Double(max(primaryRecording.audioBitrateKbps, 128)) * 1_000
        let bytes = max(0, outputDurationSeconds * estimatedBitsPerSecond / 8)
        return (Int64(bytes * 0.65))...Int64(bytes * 1.45)
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var canExport: Bool { !isExporting && missingProjectRecordingIDs.isEmpty && !segments.isEmpty && outputDurationSeconds > 0.05 }
    var canJoinSelectedSection: Bool { joinablePairContainingSelectedSegment() != nil }
    var canCutMarkedRange: Bool {
        guard let markInSeconds, let markOutSeconds else { return false }
        return abs(markOutSeconds - markInSeconds) > 0.05
    }
    var previewSignature: String {
        let segmentSignature = segments
            .map { segment in
                [
                    segment.id.uuidString,
                    segment.recording.id.uuidString,
                    String(format: "%.4f", segment.startSeconds),
                String(format: "%.4f", segment.endSeconds),
                    String(format: "%.4f", segment.audioGain),
                    segment.isAudioMuted ? "1" : "0",
                    String(format: "%.3f", segment.fadeInSeconds),
                    String(format: "%.3f", segment.fadeOutSeconds),
                    segment.transitionBefore.rawValue,
                    String(format: "%.3f", segment.transitionDurationSeconds),
                ].joined(separator: ":")
            }
            .joined(separator: "|")
        let cropSignature = isCropOverlayEditing
            ? "crop-overlay-preview"
            : [cropEnabled ? "1" : "0", String(format: "%.4f", cropX), String(format: "%.4f", cropY), String(format: "%.4f", cropWidth), String(format: "%.4f", cropHeight)].joined(separator: ":")
        let transformSignature = [String(rotation.rawValue), isFlippedHorizontally ? "1" : "0", isFlippedVertically ? "1" : "0"].joined(separator: ":")
        let audioSignature = [
            String(format: "%.4f", playbackRate),
            isMuted ? "1" : "0",
            String(format: "%.4f", volume),
            String(format: "%.4f", fadeInSeconds),
            String(format: "%.4f", fadeOutSeconds),
        ].joined(separator: ":")
        let outputSignature = outputResolution.rawValue
        let colorSignature = [colorAdjustment.exposure, colorAdjustment.contrast, colorAdjustment.saturation, colorAdjustment.temperature, colorAdjustment.tint, colorAdjustment.vignette].map { String(format: "%.4f", $0) }.joined(separator: ":")
        let captionSignature = captions.map { "\($0.id):\($0.startSeconds):\($0.endSeconds):\($0.text)" }.joined(separator: "|") + (burnInCaptions ? "#burn" : "#sidecar")
        let overlaySignature = overlays.map { "\($0.id):\($0.kind.rawValue):\($0.startSeconds):\($0.endSeconds):\($0.x):\($0.y):\($0.width):\($0.height):\($0.text)" }.joined(separator: "|")
        return [segmentSignature, cropSignature, transformSignature, audioSignature, outputSignature, colorSignature, captionSignature, overlaySignature, isCropOverlayEditing ? "crop-overlay" : "crop-final"].joined(separator: "#")
    }

    func sourceTime(forOutputSeconds outputSeconds: Double) -> (segment: RecordingEditorSegment, seconds: Double)? {
        var cursor = 0.0
        let rate = max(0.25, playbackRate)
        let target = min(max(0, outputSeconds), outputDurationSeconds)
        for segment in segments {
            let outputDuration = segment.durationSeconds / rate
            let nextCursor = cursor + outputDuration
            if target < nextCursor || segment.id == segments.last?.id {
                let sourceOffset = (target - cursor) * rate
                return (segment, min(max(segment.startSeconds, segment.startSeconds + sourceOffset), segment.endSeconds))
            }
            cursor = nextCursor
        }
        return nil
    }

    func editPointTime(from outputSeconds: Double, direction: Int) -> Double? {
        guard direction != 0 else { return nil }
        var cursor = 0.0
        var editPoints: [Double] = [0]
        for segment in segments {
            cursor += segment.durationSeconds / max(0.25, playbackRate)
            editPoints.append(cursor)
        }
        return direction < 0
            ? editPoints.filter { $0 < outputSeconds - 0.04 }.max()
            : editPoints.filter { $0 > outputSeconds + 0.04 }.min()
    }

    func selectSegment(_ segment: RecordingEditorSegment) {
        selectedSegmentID = segment.id
        markInSeconds = nil
        markOutSeconds = nil
    }

    func selectPreviewSegment(_ segment: RecordingEditorSegment) {
        if selectedSegmentID != segment.id { selectedSegmentID = segment.id }
    }

    func updateSelectedStart(_ value: Double) {
        guard let index = selectedSegmentIndex else { return }
        let segment = segments[index]
        let next = min(max(0, value), max(0, segment.endSeconds - 0.05))
        segments[index].startSeconds = next
    }

    func updateSelectedEnd(_ value: Double) {
        guard let index = selectedSegmentIndex else { return }
        let segment = segments[index]
        let next = max(min(segment.recording.durationSeconds, value), segment.startSeconds + 0.05)
        segments[index].endSeconds = next
    }

    func updateSegmentStart(_ segment: RecordingEditorSegment, seconds: Double) {
        selectedSegmentID = segment.id
        updateSelectedStart(seconds)
    }

    func updateSegmentEnd(_ segment: RecordingEditorSegment, seconds: Double) {
        selectedSegmentID = segment.id
        updateSelectedEnd(seconds)
    }

    func beginInteractiveEdit() {
        recordUndo()
    }

    func setCropEnabled(_ enabled: Bool) {
        guard cropEnabled != enabled else { return }
        recordUndo()
        cropEnabled = enabled
    }

    func setMuted(_ muted: Bool) {
        guard isMuted != muted else { return }
        recordUndo()
        isMuted = muted
    }

    func beginOutputTitleEdit() {
        hasRecordedOutputTitleEdit = false
    }

    func updateOutputTitle(_ title: String) {
        guard outputTitle != title else { return }
        if !hasRecordedOutputTitleEdit {
            recordUndo()
            hasRecordedOutputTitleEdit = true
        }
        outputTitle = title
    }

    func endOutputTitleEdit() {
        hasRecordedOutputTitleEdit = false
    }

    func setExportQuality(_ quality: RecordingEditorExportQuality) {
        guard exportQuality != quality else { return }
        recordUndo()
        exportQuality = quality
    }

    func setOutputResolution(_ resolution: WebRTCStreamRecordingOutputResolution) {
        guard outputResolution != resolution else { return }
        recordUndo()
        outputResolution = resolution
    }

    func beginColorAdjustment() {
        recordUndo()
    }

    func resetColorAdjustments() {
        guard !colorAdjustment.isNeutral else { return }
        recordUndo()
        colorAdjustment = .neutral
    }

    func createTranscriptDraft() async {
        guard !isTranscribing else { return }
        isTranscribing = true
        errorMessage = nil
        defer { isTranscribing = false }
        do {
            draftTranscript = try await RecordingEditorTranscriptionService.transcribe(recording: primaryRecording)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func approveTranscriptDraft() {
        guard let draftTranscript else { return }
        recordUndo()
        transcript = draftTranscript
        self.draftTranscript = nil
    }

    func removeCaption(id: UUID) {
        guard captions.contains(where: { $0.id == id }) else { return }
        recordUndo()
        captions.removeAll { $0.id == id }
    }

    func addOverlay(kind: RecordingEditorOverlayKind, at timelineSeconds: Double) {
        let start = min(max(0, timelineSeconds), max(0, outputDurationSeconds - 0.1))
        let end = min(outputDurationSeconds, start + 2)
        guard end - start > 0.05 else { return }
        recordUndo()
        overlays.append(RecordingEditorOverlay(kind: kind, startSeconds: start, endSeconds: end, text: kind == .callout ? "Callout" : ""))
    }

    func updateOverlay(_ overlay: RecordingEditorOverlay) {
        guard let index = overlays.firstIndex(where: { $0.id == overlay.id }) else { return }
        var updated = overlay
        updated.startSeconds = min(max(0, updated.startSeconds.isFinite ? updated.startSeconds : 0), outputDurationSeconds)
        updated.endSeconds = min(max(updated.startSeconds + 0.05, updated.endSeconds.isFinite ? updated.endSeconds : updated.startSeconds + 0.05), outputDurationSeconds)
        updated.x = min(max(0, updated.x.isFinite ? updated.x : 0), 0.95)
        updated.y = min(max(0, updated.y.isFinite ? updated.y : 0), 0.95)
        updated.width = min(max(0.05, updated.width.isFinite ? updated.width : 0.05), 1 - updated.x)
        updated.height = min(max(0.05, updated.height.isFinite ? updated.height : 0.05), 1 - updated.y)
        overlays[index] = updated
    }

    func removeOverlay(id: UUID) {
        guard overlays.contains(where: { $0.id == id }) else { return }
        recordUndo()
        overlays.removeAll { $0.id == id }
    }

    func setSelectedTransition(_ transition: WebRTCStreamRecordingTransitionStyle) {
        guard let index = selectedSegmentIndex, index > 0, segments[index].transitionBefore != transition else { return }
        recordUndo()
        segments[index].transitionBefore = transition
    }

    func setSelectedTransitionDuration(_ duration: Double) {
        guard let index = selectedSegmentIndex, index > 0 else { return }
        segments[index].transitionDurationSeconds = min(max(duration.isFinite ? duration : 0.5, 0.1), 2)
    }

    func createCaptionsFromTranscript() {
        guard let transcript else { return }
        recordUndo()
        var timelineCursor = 0.0
        var generated: [RecordingEditorCaption] = []
        for segment in segments {
            if segment.recording.id == transcript.sourceRecordingID {
                for word in transcript.segments {
                    let sourceStart = max(word.startSeconds, segment.startSeconds)
                    let sourceEnd = min(word.startSeconds + word.durationSeconds, segment.endSeconds)
                    guard sourceEnd > sourceStart else { continue }
                    let rate = max(0.25, playbackRate)
                    generated.append(RecordingEditorCaption(
                        startSeconds: timelineCursor + (sourceStart - segment.startSeconds) / rate,
                        endSeconds: timelineCursor + (sourceEnd - segment.startSeconds) / rate,
                        text: word.text,
                        language: transcript.language
                    ))
                }
            }
            timelineCursor += segment.durationSeconds / max(0.25, playbackRate)
        }
        captions = generated.sorted { $0.startSeconds < $1.startSeconds }
    }

    func cutTranscriptPhrase(_ phrase: RecordingEditorTranscript.Segment, recordingID: UUID) {
        guard let segment = segments.first(where: { $0.recording.id == recordingID && phrase.startSeconds < $0.endSeconds && phrase.startSeconds + phrase.durationSeconds > $0.startSeconds }) else { return }
        let start = max(segment.startSeconds, phrase.startSeconds)
        let end = min(segment.endSeconds, phrase.startSeconds + phrase.durationSeconds)
        guard end - start > 0.05 else { return }
        selectedSegmentID = segment.id
        cutRange(startSeconds: start, endSeconds: end)
    }

    func addOCRMarker(at timelineSeconds: Double) async {
        guard timelineSeconds.isFinite else { return }
        let rate = max(0.25, playbackRate)
        var cursor = 0.0
        for segment in segments {
            let duration = segment.durationSeconds / rate
            if timelineSeconds >= cursor, timelineSeconds <= cursor + duration {
                let sourceTime = segment.startSeconds + (timelineSeconds - cursor) * rate
                do {
                    let asset = AVURLAsset(url: segment.recording.videoURL)
                    let generator = AVAssetImageGenerator(asset: asset)
                    generator.appliesPreferredTrackTransform = true
                    generator.maximumSize = CGSize(width: 1920, height: 1920)
                    let frame = try await generator.image(at: CMTime(seconds: sourceTime, preferredTimescale: 600)).image
                    let request = VNRecognizeTextRequest()
                    request.recognitionLevel = .accurate
                    request.usesLanguageCorrection = false
                    try VNImageRequestHandler(cgImage: frame).perform([request])
                    let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                        .joined(separator: " · ")
                    guard !text.isEmpty else {
                        errorMessage = "No readable screen text was found at the playhead."
                        return
                    }
                    addMarker(at: timelineSeconds, name: String(text.prefix(100)))
                } catch {
                    errorMessage = "Screen text could not be recognized: \(error.localizedDescription)"
                }
                return
            }
            cursor += duration
        }
    }

    func removeSelectedPointerMetadata() {
        guard let selectedSegment,
              selectedSegment.recording.pointerEvents?.isEmpty == false else { return }
        var recording = selectedSegment.recording
        recording.pointerEvents = nil
        do {
            let data = try JSONEncoder.recordingEncoder.encode(recording)
            try data.write(to: recording.metadataURL, options: .atomic)
            library = library.map { $0.id == recording.id ? recording : $0 }
            for index in segments.indices where segments[index].recording.id == recording.id {
                segments[index].recording = recording
            }
        } catch {
            errorMessage = "Captured pointer metadata could not be removed: \(error.localizedDescription)"
        }
    }

    func suggestZoomsFromSelectedPointerClicks() {
        guard let selectedSegment, let selectedIndex = selectedSegmentIndex,
              let events = selectedSegment.recording.pointerEvents else { return }
        let playbackRate = max(0.25, self.playbackRate)
        let timelineStart = segments.prefix(selectedIndex).reduce(0) { $0 + $1.durationSeconds / playbackRate }
        let segmentDuration = selectedSegment.durationSeconds / playbackRate
        let candidates = events.filter {
            $0.clickType != nil && $0.timeSeconds >= selectedSegment.startSeconds && $0.timeSeconds <= selectedSegment.endSeconds && $0.x.isFinite && $0.y.isFinite
        }.sorted { $0.timeSeconds < $1.timeSeconds }
        var acceptedEvents: [RecordingPointerEvent] = []
        for event in candidates {
            let localTime = (event.timeSeconds - selectedSegment.startSeconds) / playbackRate
            guard !acceptedEvents.contains(where: { abs(($0.timeSeconds - selectedSegment.startSeconds) / playbackRate - localTime) < 2.6 }) else { continue }
            acceptedEvents.append(event)
        }
        guard !acceptedEvents.isEmpty else {
            errorMessage = "No pointer clicks fall inside the selected clip range."
            return
        }
        recordUndo()
        let end = timelineStart + segmentDuration
        let suggestions = acceptedEvents.flatMap { event -> [RecordingEditorZoomKeyframe] in
            let time = timelineStart + (event.timeSeconds - selectedSegment.startSeconds) / playbackRate
            let centerX = min(max(event.x, 0.2), 0.8)
            let centerY = min(max(event.y, 0.2), 0.8)
            return [
                RecordingEditorZoomKeyframe(timeSeconds: max(timelineStart, time - 0.15), centerX: 0.5, centerY: 0.5, scale: 1),
                RecordingEditorZoomKeyframe(timeSeconds: time, centerX: centerX, centerY: centerY, scale: 1.5),
                RecordingEditorZoomKeyframe(timeSeconds: min(end, time + 0.95), centerX: centerX, centerY: centerY, scale: 1.5),
                RecordingEditorZoomKeyframe(timeSeconds: min(end, time + 1.2), centerX: 0.5, centerY: 0.5, scale: 1)
            ]
        }
        zoomKeyframes = zoomKeyframes.filter { $0.timeSeconds < timelineStart || $0.timeSeconds > end } + suggestions
        zoomKeyframes.sort { $0.timeSeconds < $1.timeSeconds }
        errorMessage = nil
    }

    func updateZoomKeyframe(_ keyframe: RecordingEditorZoomKeyframe) {
        guard let index = zoomKeyframes.firstIndex(where: { $0.id == keyframe.id }) else { return }
        zoomKeyframes[index] = RecordingEditorZoomKeyframe(
            id: keyframe.id,
            timeSeconds: min(max(keyframe.timeSeconds.isFinite ? keyframe.timeSeconds : 0, 0), outputDurationSeconds),
            centerX: min(max(keyframe.centerX.isFinite ? keyframe.centerX : 0.5, 0.2), 0.8),
            centerY: min(max(keyframe.centerY.isFinite ? keyframe.centerY : 0.5, 0.2), 0.8),
            scale: min(max(keyframe.scale.isFinite ? keyframe.scale : 1, 1), 2.5)
        )
        zoomKeyframes.sort { $0.timeSeconds < $1.timeSeconds }
    }

    func removeZoomKeyframe(id: UUID) {
        guard zoomKeyframes.contains(where: { $0.id == id }) else { return }
        recordUndo()
        zoomKeyframes.removeAll { $0.id == id }
    }

    func timelineSeconds(forSourceTime seconds: Double, recordingID: UUID) -> Double? {
        var timelineCursor = 0.0
        for segment in segments {
            if segment.recording.id == recordingID, seconds >= segment.startSeconds, seconds <= segment.endSeconds {
                return timelineCursor + (seconds - segment.startSeconds) / max(0.25, playbackRate)
            }
            timelineCursor += segment.durationSeconds / max(0.25, playbackRate)
        }
        return nil
    }

    func srtContents() -> String {
        captions.sorted { $0.startSeconds < $1.startSeconds }.enumerated().map { index, caption in
            "\(index + 1)\n\(Self.srtTimestamp(caption.startSeconds)) --> \(Self.srtTimestamp(caption.endSeconds))\n\(caption.text.replacingOccurrences(of: "\n", with: " "))"
        }.joined(separator: "\n\n")
    }

    private static func srtTimestamp(_ seconds: Double) -> String {
        let milliseconds = max(0, Int((seconds * 1000).rounded()))
        let hours = milliseconds / 3_600_000
        let minutes = milliseconds / 60_000 % 60
        let secondsPart = milliseconds / 1000 % 60
        return String(format: "%02d:%02d:%02d,%03d", hours, minutes, secondsPart, milliseconds % 1000)
    }

    func trimStartToPlayhead(_ playheadSeconds: Double) {
        guard let index = selectedSegmentIndex else { return }
        recordUndo()
        let segment = segments[index]
        segments[index].startSeconds = min(max(0, playheadSeconds), max(0, segment.endSeconds - 0.05))
    }

    func trimEndToPlayhead(_ playheadSeconds: Double) {
        guard let index = selectedSegmentIndex else { return }
        recordUndo()
        let segment = segments[index]
        segments[index].endSeconds = max(min(segment.recording.durationSeconds, playheadSeconds), segment.startSeconds + 0.05)
    }

    func markIn(_ playheadSeconds: Double) {
        recordUndo()
        markInSeconds = clampedPlayhead(playheadSeconds)
        if let markOutSeconds, let markInSeconds, markOutSeconds < markInSeconds {
            self.markOutSeconds = nil
        }
    }

    func markOut(_ playheadSeconds: Double) {
        recordUndo()
        markOutSeconds = clampedPlayhead(playheadSeconds)
        if let markInSeconds, let markOutSeconds, markInSeconds > markOutSeconds {
            self.markInSeconds = nil
        }
    }

    func addMarker(at timelineSeconds: Double, name: String = "") {
        guard timelineSeconds.isFinite else { return }
        recordUndo()
        markers.append(RecordingEditorMarker(timeSeconds: min(max(0, timelineSeconds), outputDurationSeconds), name: name))
    }

    func toggleSnapping() {
        snappingEnabled.toggle()
    }

    @discardableResult
    func restoreProjectIfAvailable() -> Bool {
        do {
            guard let project = try RecordingEditorProjectStore.load(primaryRecordingID: primaryRecording.id) else { return false }
            var recordingsByID = Dictionary(uniqueKeysWithValues: library.map { ($0.id, $0) })
            recordingsByID[primaryRecording.id] = primaryRecording
            let missingIDs = Set(project.segments.map(\.recordingID)).subtracting(recordingsByID.keys)
            guard missingIDs.isEmpty else {
                pendingProject = project
                missingProjectRecordingIDs = missingIDs.sorted { $0.uuidString < $1.uuidString }
                errorMessage = "This edit project references missing recordings. Relink the missing source media to continue."
                return false
            }
            return applyProject(project, recordingsByID: recordingsByID)
        } catch {
            errorMessage = "The saved edit project could not be loaded: \(error.localizedDescription)"
            return false
        }
    }

    func relinkMissingRecording(_ missingID: UUID, from sourceURL: URL) async {
        guard missingProjectRecordingIDs.contains(missingID) else { return }
        let accessStarted = sourceURL.startAccessingSecurityScopedResource()
        defer { if accessStarted { sourceURL.stopAccessingSecurityScopedResource() } }
        do {
            let recording = try await WebRTCStreamRecordingLibrary.importVideo(from: sourceURL)
            relinkedRecordings[missingID] = recording
            library.append(recording)
            missingProjectRecordingIDs.removeAll { $0 == missingID }
            if missingProjectRecordingIDs.isEmpty, let pendingProject {
                var recordingsByID = Dictionary(uniqueKeysWithValues: library.map { ($0.id, $0) })
                recordingsByID[primaryRecording.id] = primaryRecording
                for (oldID, replacement) in relinkedRecordings { recordingsByID[oldID] = replacement }
                _ = applyProject(pendingProject, recordingsByID: recordingsByID)
                self.pendingProject = nil
                relinkedRecordings.removeAll()
            }
        } catch {
            errorMessage = "The selected recording could not be relinked: \(error.localizedDescription)"
        }
    }

    private func applyProject(_ project: RecordingEditorProject, recordingsByID: [UUID: WebRTCStreamRecording]) -> Bool {
        let restoredSegments = project.segments.compactMap { item -> RecordingEditorSegment? in
            guard let recording = recordingsByID[item.recordingID], item.startSeconds.isFinite, item.endSeconds.isFinite,
                  item.startSeconds >= 0, item.endSeconds > item.startSeconds, item.endSeconds <= recording.durationSeconds + 0.05 else { return nil }
            return RecordingEditorSegment(id: item.id, recording: recording, startSeconds: item.startSeconds, endSeconds: item.endSeconds, audioGain: item.audioGain, isAudioMuted: item.isAudioMuted, fadeInSeconds: item.fadeInSeconds, fadeOutSeconds: item.fadeOutSeconds, transitionBefore: WebRTCStreamRecordingTransitionStyle(rawValue: item.transitionBefore ?? "cut") ?? .cut, transitionDurationSeconds: item.transitionDurationSeconds ?? 0.5)
        }
        guard restoredSegments.count == project.segments.count, !restoredSegments.isEmpty else {
            errorMessage = "The saved edit project contains invalid clip ranges and could not be restored."
            return false
        }
        editorProjectID = project.id
        outputTitle = project.title
        segments = restoredSegments
        selectedSegmentID = project.selectedSegmentID.flatMap { id in restoredSegments.contains(where: { $0.id == id }) ? id : nil } ?? restoredSegments.first?.id
        let restoredOutputDuration = totalSourceDurationSeconds / max(0.25, project.playbackRate)
        markers = project.markers.filter { $0.timeSeconds.isFinite && $0.timeSeconds >= 0 && $0.timeSeconds <= restoredOutputDuration }
        timelineZoomScale = min(max(project.timelineSettings.zoomScale, 1), 12)
        timelineVisibleStartSeconds = min(max(project.timelineSettings.visibleStartSeconds ?? 0, 0), restoredOutputDuration)
        snappingEnabled = project.timelineSettings.snappingEnabled
        cropX = project.cropX
        cropY = project.cropY
        cropWidth = project.cropWidth
        cropHeight = project.cropHeight
        cropEnabled = project.cropEnabled
        cropAspectPreset = RecordingEditorAspectPreset(rawValue: project.cropAspectPreset ?? "source") ?? .source
        rotation = WebRTCStreamRecordingRotation(rawValue: project.rotationRawValue) ?? .degrees0
        isFlippedHorizontally = project.isFlippedHorizontally
        isFlippedVertically = project.isFlippedVertically
        playbackRate = min(max(project.playbackRate, 0.25), 4)
        isMuted = project.isMuted
        volume = min(max(project.volume, 0), 2)
        fadeInSeconds = max(0, project.fadeInSeconds)
        fadeOutSeconds = max(0, project.fadeOutSeconds)
        if let quality = RecordingEditorExportQuality(rawValue: project.exportQuality) { exportQuality = quality }
        if let resolution = WebRTCStreamRecordingOutputResolution(rawValue: project.outputResolution) { outputResolution = resolution }
        colorAdjustment = WebRTCStreamRecordingColorAdjustment(exposure: project.colorExposure, contrast: project.colorContrast, saturation: project.colorSaturation, temperature: project.colorTemperature, tint: project.colorTint, vignette: project.colorVignette)
        transcript = project.transcript
        captions = project.captions
        burnInCaptions = project.burnInCaptions
        overlays = project.overlays ?? []
        zoomKeyframes = (project.zoomKeyframes ?? []).filter { $0.timeSeconds.isFinite && $0.timeSeconds >= 0 && $0.centerX.isFinite && $0.centerY.isFinite && $0.scale.isFinite }.map {
            var keyframe = $0
            keyframe.centerX = min(max(keyframe.centerX, 0.2), 0.8)
            keyframe.centerY = min(max(keyframe.centerY, 0.2), 0.8)
            keyframe.scale = min(max(keyframe.scale, 1), 2.5)
            return keyframe
        }.sorted { $0.timeSeconds < $1.timeSeconds }
        errorMessage = nil
        return true
    }

    func saveProject() {
        let project = RecordingEditorProject(
            schemaVersion: 5,
            id: editorProjectID,
            primaryRecordingID: primaryRecording.id,
            title: outputTitle,
            segments: segments.map { RecordingEditorProject.Segment(id: $0.id, recordingID: $0.recording.id, startSeconds: $0.startSeconds, endSeconds: $0.endSeconds, audioGain: $0.audioGain, isAudioMuted: $0.isAudioMuted, fadeInSeconds: $0.fadeInSeconds, fadeOutSeconds: $0.fadeOutSeconds, transitionBefore: $0.transitionBefore.rawValue, transitionDurationSeconds: $0.transitionDurationSeconds) },
            selectedSegmentID: selectedSegmentID,
            markers: markers,
            timelineSettings: RecordingEditorProject.TimelineSettings(zoomScale: timelineZoomScale, snappingEnabled: snappingEnabled, visibleStartSeconds: timelineVisibleStartSeconds),
            cropX: cropX,
            cropY: cropY,
            cropWidth: cropWidth,
            cropHeight: cropHeight,
            cropEnabled: cropEnabled,
            cropAspectPreset: cropAspectPreset.rawValue,
            rotationRawValue: rotation.rawValue,
            isFlippedHorizontally: isFlippedHorizontally,
            isFlippedVertically: isFlippedVertically,
            playbackRate: playbackRate,
            isMuted: isMuted,
            volume: volume,
            fadeInSeconds: fadeInSeconds,
            fadeOutSeconds: fadeOutSeconds,
            exportQuality: exportQuality.rawValue,
            outputResolution: outputResolution.rawValue,
            colorExposure: colorAdjustment.exposure,
            colorContrast: colorAdjustment.contrast,
            colorSaturation: colorAdjustment.saturation,
            colorTemperature: colorAdjustment.temperature,
            colorTint: colorAdjustment.tint,
            colorVignette: colorAdjustment.vignette,
            transcript: transcript,
            captions: captions,
            burnInCaptions: burnInCaptions,
            overlays: overlays,
            zoomKeyframes: zoomKeyframes
        )
        do {
            try RecordingEditorProjectStore.save(project)
        } catch {
            errorMessage = "The edit project could not be saved: \(error.localizedDescription)"
        }
    }

    func duplicateProject() {
        recordUndo()
        editorProjectID = UUID()
        outputTitle = "\(outputTitle) Copy"
        saveProject()
    }

    @discardableResult
    func discardProject() -> Bool {
        do {
            try RecordingEditorProjectStore.discard(projectID: editorProjectID)
            errorMessage = nil
            return true
        } catch {
            errorMessage = "The saved edit project could not be discarded: \(error.localizedDescription)"
            return false
        }
    }

    func setSelectedSegmentAudioGain(_ value: Double) {
        guard let index = selectedSegmentIndex else { return }
        segments[index].audioGain = min(max(value.isFinite ? value : 1, 0), 8)
    }

    func analyzeSelectedAudio() async {
        guard !isAnalyzingAudio, let segment = selectedSegment else { return }
        isAnalyzingAudio = true
        errorMessage = nil
        defer { isAnalyzingAudio = false }
        do {
            let result = try await RecordingEditorAudioAnalysisService.analyze(recordingURL: segment.recording.videoURL, startSeconds: segment.startSeconds, endSeconds: segment.endSeconds)
            guard selectedSegmentID == segment.id else { return }
            audioAnalysis = RecordingEditorAudioAnalysis(segmentID: segment.id, recordingID: segment.recording.id, result: result)
            selectedSilenceRangeIDs = []
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func normalizeSelectedAudio() {
        guard let analysis = audioAnalysis, analysis.segmentID == selectedSegmentID,
              let index = selectedSegmentIndex else { return }
        recordUndo()
        segments[index].audioGain = min(max(analysis.result.normalizationGain, 0), 8)
    }

    func removeSelectedSilenceRanges() {
        guard let analysis = audioAnalysis, analysis.segmentID == selectedSegmentID,
              let index = selectedSegmentIndex else { return }
        let segment = segments[index]
        let removedRanges = analysis.result.silenceRanges
            .filter { selectedSilenceRangeIDs.contains($0.id) }
            .map { RecordingEditorAudioRange(startSeconds: max(segment.startSeconds, $0.startSeconds), endSeconds: min(segment.endSeconds, $0.endSeconds)) }
            .filter { $0.endSeconds - $0.startSeconds > 0.05 }
            .sorted { $0.startSeconds < $1.startSeconds }
        guard !removedRanges.isEmpty else { return }
        recordUndo()
        var keptRanges: [RecordingEditorTimeRange] = []
        var cursor = segment.startSeconds
        for range in removedRanges {
            let start = max(cursor, range.startSeconds)
            if start - cursor > 0.05 {
                keptRanges.append(RecordingEditorTimeRange(startSeconds: cursor, endSeconds: start))
            }
            cursor = max(cursor, range.endSeconds)
        }
        if segment.endSeconds - cursor > 0.05 {
            keptRanges.append(RecordingEditorTimeRange(startSeconds: cursor, endSeconds: segment.endSeconds))
        }
        let outputStart = segments[..<index].reduce(0.0) { $0 + $1.durationSeconds / max(0.25, playbackRate) }
        let removedTimelineRanges = removedRanges.map { range in
            let start = outputStart + (range.startSeconds - segment.startSeconds) / max(0.25, playbackRate)
            let duration = (range.endSeconds - range.startSeconds) / max(0.25, playbackRate)
            return RecordingEditorTimeRange(startSeconds: start, endSeconds: start + duration)
        }
        let kept = makeSegmentFragments(of: segment, ranges: keptRanges)
        segments.replaceSubrange(index...index, with: kept)
        rebaseTimelineContent(afterRemoving: removedTimelineRanges)
        if let firstKept = kept.first {
            selectedSegmentID = firstKept.id
        } else if segments.indices.contains(index) {
            selectedSegmentID = segments[index].id
        } else {
            selectedSegmentID = segments.last?.id
        }
        markInSeconds = nil
        markOutSeconds = nil
        audioAnalysis = nil
        selectedSilenceRangeIDs.removeAll()
    }

    func setSelectedSegmentMuted(_ muted: Bool) {
        guard let index = selectedSegmentIndex, segments[index].isAudioMuted != muted else { return }
        recordUndo()
        segments[index].isAudioMuted = muted
    }

    func setSelectedSegmentFadeIn(_ value: Double) {
        guard let index = selectedSegmentIndex else { return }
        segments[index].fadeInSeconds = max(0, value.isFinite ? value : 0)
    }

    func setSelectedSegmentFadeOut(_ value: Double) {
        guard let index = selectedSegmentIndex else { return }
        segments[index].fadeOutSeconds = max(0, value.isFinite ? value : 0)
    }

    func cutMarkedRange() {
        guard let markInSeconds, let markOutSeconds else { return }
        cutRange(startSeconds: min(markInSeconds, markOutSeconds), endSeconds: max(markInSeconds, markOutSeconds))
        self.markInSeconds = nil
        self.markOutSeconds = nil
    }

    func splitAtPlayhead(_ playheadSeconds: Double) {
        guard let index = selectedSegmentIndex else { return }
        let segment = segments[index]
        guard playheadSeconds.isFinite,
              playheadSeconds >= segment.startSeconds + 0.05,
              playheadSeconds <= segment.endSeconds - 0.05 else { return }
        let fragments = makeSegmentFragments(of: segment, ranges: [
            RecordingEditorTimeRange(startSeconds: segment.startSeconds, endSeconds: playheadSeconds),
            RecordingEditorTimeRange(startSeconds: playheadSeconds, endSeconds: segment.endSeconds),
        ])
        guard let right = fragments.last, fragments.count == 2 else { return }
        recordUndo()
        segments.replaceSubrange(index...index, with: fragments)
        selectedSegmentID = right.id
        markInSeconds = nil
        markOutSeconds = nil
    }

    func cutRange(startSeconds: Double, endSeconds: Double) {
        guard let index = selectedSegmentIndex else { return }
        let segment = segments[index]
        guard startSeconds.isFinite, endSeconds.isFinite else { return }
        let start = min(max(segment.startSeconds, startSeconds), segment.endSeconds)
        let end = max(min(segment.endSeconds, endSeconds), segment.startSeconds)
        guard end - start > 0.05 else { return }
        recordUndo()
        var replacementRanges: [RecordingEditorTimeRange] = []
        if start - segment.startSeconds > 0.05 {
            replacementRanges.append(RecordingEditorTimeRange(startSeconds: segment.startSeconds, endSeconds: start))
        }
        if segment.endSeconds - end > 0.05 {
            replacementRanges.append(RecordingEditorTimeRange(startSeconds: end, endSeconds: segment.endSeconds))
        }
        let replacements = makeSegmentFragments(of: segment, ranges: replacementRanges)
        let rate = max(0.25, playbackRate)
        let outputStart = segments[..<index].reduce(0.0) { $0 + $1.durationSeconds / rate }
        let removalStart = outputStart + (start - segment.startSeconds) / rate
        let removalDuration = (end - start) / rate
        segments.replaceSubrange(index...index, with: replacements)
        rebaseTimelineContent(afterRemoving: [RecordingEditorTimeRange(startSeconds: removalStart, endSeconds: removalStart + removalDuration)])
        if let replacement = replacements.last {
            selectedSegmentID = replacement.id
        } else if segments.indices.contains(index) {
            selectedSegmentID = segments[index].id
        } else {
            selectedSegmentID = segments.first?.id
        }
        markInSeconds = nil
        markOutSeconds = nil
    }

    func appendRecording(_ recording: WebRTCStreamRecording) {
        guard recording.durationSeconds > 0 else { return }
        recordUndo()
        let segment = RecordingEditorSegment(recording: recording, startSeconds: 0, endSeconds: recording.durationSeconds)
        segments.append(segment)
        selectedSegmentID = segment.id
    }

    func appendRecording(_ recording: WebRTCStreamRecording, at insertionIndex: Int) {
        guard recording.durationSeconds > 0 else { return }
        recordUndo()
        let segment = RecordingEditorSegment(recording: recording, startSeconds: 0, endSeconds: recording.durationSeconds)
        segments.insert(segment, at: min(max(0, insertionIndex), segments.count))
        selectedSegmentID = segment.id
    }

    func handleDropPayload(_ payload: String, at insertionIndex: Int) -> Bool {
        guard let payload = RecordingEditorDragPayload(stringValue: payload) else { return false }
        switch payload {
        case .recording(let id):
            guard let recording = library.first(where: { $0.id == id }) else { return false }
            appendRecording(recording, at: insertionIndex)
            return true
        case .segment(let id):
            return moveSegment(id: id, to: insertionIndex)
        }
    }

    @discardableResult
    func moveSegment(id: UUID, to insertionIndex: Int) -> Bool {
        guard let currentIndex = segments.firstIndex(where: { $0.id == id }) else { return false }
        let boundedIndex = min(max(0, insertionIndex), segments.count)
        var adjustedIndex = boundedIndex
        if currentIndex < boundedIndex { adjustedIndex -= 1 }
        guard currentIndex != adjustedIndex, currentIndex + 1 != boundedIndex else { return false }
        recordUndo()
        let segment = segments.remove(at: currentIndex)
        segments.insert(segment, at: min(max(0, adjustedIndex), segments.count))
        selectedSegmentID = segment.id
        return true
    }

    func joinSelectedSection() {
        guard let pair = joinablePairContainingSelectedSegment() else { return }
        let left = segments[pair.leftIndex]
        let right = segments[pair.rightIndex]
        let selectedID = segments[pair.selectedIndex].id
        let insertionIndex = pair.selectedIndex - [pair.leftIndex, pair.rightIndex].filter { $0 < pair.selectedIndex }.count
        recordUndo()
        let joined = RecordingEditorSegment(id: selectedID, recording: left.recording, startSeconds: left.startSeconds, endSeconds: right.endSeconds, audioGain: left.audioGain, isAudioMuted: left.isAudioMuted, fadeInSeconds: left.fadeInSeconds, fadeOutSeconds: right.fadeOutSeconds)
        for index in [pair.leftIndex, pair.rightIndex].sorted(by: >) {
            segments.remove(at: index)
        }
        segments.insert(joined, at: min(max(0, insertionIndex), segments.count))
        selectedSegmentID = joined.id
        markInSeconds = nil
        markOutSeconds = nil
    }

    func duplicateSelectedSegment() {
        guard let index = selectedSegmentIndex else { return }
        recordUndo()
        let segment = segments[index]
        let duplicate = copySegment(segment, startSeconds: segment.startSeconds, endSeconds: segment.endSeconds)
        segments.insert(duplicate, at: segments.index(after: index))
        selectedSegmentID = duplicate.id
    }

    func removeSelectedSegment() {
        guard let index = selectedSegmentIndex, segments.count > 1 else { return }
        recordUndo()
        let rate = max(0.25, playbackRate)
        let removalStart = segments[..<index].reduce(0.0) { $0 + $1.durationSeconds / rate }
        let removalDuration = segments[index].durationSeconds / rate
        segments.remove(at: index)
        rebaseTimelineContent(afterRemoving: [RecordingEditorTimeRange(startSeconds: removalStart, endSeconds: removalStart + removalDuration)])
        selectedSegmentID = segments.indices.contains(index) ? segments[index].id : segments.last?.id
        markInSeconds = nil
        markOutSeconds = nil
    }

    func moveSelectedSegment(offset: Int) {
        guard let index = selectedSegmentIndex else { return }
        let nextIndex = index + offset
        guard segments.indices.contains(nextIndex) else { return }
        recordUndo()
        segments.swapAt(index, nextIndex)
    }

    func setCropAspectPreset(_ preset: RecordingEditorAspectPreset) {
        guard let targetAspect = preset.aspectRatio else {
            guard cropAspectPreset != preset || cropEnabled || cropX != 0 || cropY != 0 || cropWidth != 1 || cropHeight != 1 else { return }
            recordUndo()
            cropAspectPreset = preset
            cropEnabled = false
            cropX = 0
            cropY = 0
            cropWidth = 1
            cropHeight = 1
            return
        }
        let desiredCropAspect = (rotation == .degrees90 || rotation == .degrees270) ? 1 / targetAspect : targetAspect
        let sourceAspect = Double(primaryRecording.width) / Double(max(1, primaryRecording.height))
        let cropWidth: Double
        let cropHeight: Double
        if desiredCropAspect > sourceAspect {
            cropWidth = 1
            cropHeight = max(0.05, sourceAspect / desiredCropAspect)
        } else {
            cropHeight = 1
            cropWidth = max(0.05, desiredCropAspect / sourceAspect)
        }
        let cropX = (1 - cropWidth) / 2
        let cropY = (1 - cropHeight) / 2
        guard cropAspectPreset != preset || !cropEnabled || self.cropX != cropX || self.cropY != cropY || self.cropWidth != cropWidth || self.cropHeight != cropHeight else { return }
        recordUndo()
        cropAspectPreset = preset
        self.cropX = cropX
        self.cropY = cropY
        self.cropWidth = cropWidth
        self.cropHeight = cropHeight
        cropEnabled = true
    }

    func updateCropFromViewer(x: Double, y: Double, width: Double, height: Double) {
        cropX = min(max(0, x), 0.95)
        cropY = min(max(0, y), 0.95)
        cropWidth = min(max(0.05, width), 1 - cropX)
        cropHeight = min(max(0.05, height), 1 - cropY)
        cropEnabled = true
    }

    func rotateLeft() {
        recordUndo()
        rotation = WebRTCStreamRecordingRotation(rawValue: (rotation.rawValue + 270) % 360) ?? .degrees0
    }

    func rotateRight() {
        recordUndo()
        rotation = WebRTCStreamRecordingRotation(rawValue: (rotation.rawValue + 90) % 360) ?? .degrees0
    }

    func toggleHorizontalFlip() {
        recordUndo()
        isFlippedHorizontally.toggle()
    }

    func toggleVerticalFlip() {
        recordUndo()
        isFlippedVertically.toggle()
    }

    func resetEdits() {
        recordUndo()
        let segment = RecordingEditorSegment(recording: primaryRecording, startSeconds: 0, endSeconds: primaryRecording.durationSeconds)
        outputTitle = primaryRecording.title + " Edit"
        segments = [segment]
        selectedSegmentID = segment.id
        markInSeconds = nil
        markOutSeconds = nil
        cropEnabled = false
        cropAspectPreset = .source
        cropX = 0
        cropY = 0
        cropWidth = 1
        cropHeight = 1
        rotation = .degrees0
        isFlippedHorizontally = false
        isFlippedVertically = false
        playbackRate = 1
        isMuted = false
        volume = 1
        fadeInSeconds = 0
        fadeOutSeconds = 0
        exportQuality = .highest
        outputResolution = .source
        colorAdjustment = .neutral
        transcript = nil
        draftTranscript = nil
        captions = []
        burnInCaptions = false
        overlays = []
        zoomKeyframes = []
    }

    func undo() {
        guard let snapshot = undoStack.popLast() else { return }
        redoStack.append(makeSnapshot())
        apply(snapshot)
    }

    func redo() {
        guard let snapshot = redoStack.popLast() else { return }
        undoStack.append(makeSnapshot())
        apply(snapshot)
    }

    func request(isCropEditingPreview: Bool = false) -> WebRTCStreamRecordingEditRequest {
        WebRTCStreamRecordingEditRequest(
            title: outputTitle,
            segments: segments.map { segment in
                WebRTCStreamRecordingEditSegment(
                    recording: segment.recording,
                    startSeconds: segment.startSeconds,
                    endSeconds: segment.endSeconds,
                    audio: WebRTCStreamRecordingAudioEdit(
                        volume: segment.audioGain,
                        isMuted: segment.isAudioMuted,
                        fadeInSeconds: segment.fadeInSeconds,
                        fadeOutSeconds: segment.fadeOutSeconds
                    ),
                    transitionBefore: segment.transitionBefore,
                    transitionDurationSeconds: segment.transitionDurationSeconds
                )
            },
            crop: cropEnabled && !isCropEditingPreview ? WebRTCStreamRecordingCrop(x: cropX, y: cropY, width: cropWidth, height: cropHeight) : nil,
            rotation: isCropEditingPreview ? .degrees0 : rotation,
            isFlippedHorizontally: !isCropEditingPreview && isFlippedHorizontally,
            isFlippedVertically: !isCropEditingPreview && isFlippedVertically,
            playbackRate: playbackRate,
            audio: WebRTCStreamRecordingAudioEdit(volume: volume, isMuted: isMuted, fadeInSeconds: fadeInSeconds, fadeOutSeconds: fadeOutSeconds),
            exportPreset: exportQuality.preset,
            outputResolution: outputResolution,
            color: colorAdjustment,
            captions: captions,
            burnInCaptions: burnInCaptions,
            overlays: overlays,
            zoomKeyframes: zoomKeyframes
        )
    }

    func cancelExport() {
        activeExportSession?.cancelExport()
        activeExportSession = nil
    }

    func export() async throws -> WebRTCStreamRecording {
        guard !isExporting else { throw WebRTCStreamRecordingEditorError.exportFailed("An export is already running.") }
        isExporting = true
        exportProgress = 0
        errorMessage = nil
        do {
            let request = request()
            let recording = try await WebRTCStreamRecordingLibrary.exportEditedRecording(
                request,
                sessionHandler: { [weak self] sessionBox in
                    self?.activeExportSession = sessionBox.session
                },
                progressHandler: { [weak self] progress in
                    self?.exportProgress = progress
                }
            )
            activeExportSession = nil
            isExporting = false
            exportProgress = 1
            return recording
        } catch {
            activeExportSession = nil
            isExporting = false
            if case WebRTCStreamRecordingEditorError.exportCancelled = error {
                exportProgress = 0
            } else {
                errorMessage = error.localizedDescription
            }
            throw error
        }
    }

    func exportCopy(to destinationURL: URL) async throws -> URL {
        guard !isExporting else { throw WebRTCStreamRecordingEditorError.exportFailed("An export is already running.") }
        isExporting = true
        exportProgress = 0
        errorMessage = nil
        do {
            let outputURL = try await WebRTCStreamRecordingLibrary.exportEditedRecordingCopy(
                request(),
                to: destinationURL,
                sessionHandler: { [weak self] sessionBox in self?.activeExportSession = sessionBox.session },
                progressHandler: { [weak self] progress in self?.exportProgress = progress }
            )
            activeExportSession = nil
            isExporting = false
            exportProgress = 1
            return outputURL
        } catch {
            activeExportSession = nil
            isExporting = false
            if case WebRTCStreamRecordingEditorError.exportCancelled = error {
                exportProgress = 0
            } else {
                errorMessage = error.localizedDescription
            }
            throw error
        }
    }

    private func clampedPlayhead(_ playheadSeconds: Double) -> Double {
        guard let segment = selectedSegment else { return 0 }
        return min(max(segment.startSeconds, playheadSeconds), segment.endSeconds)
    }

    private func makeSegmentFragments(of segment: RecordingEditorSegment, ranges: [RecordingEditorTimeRange]) -> [RecordingEditorSegment] {
        let validRanges = ranges
            .filter { $0.startSeconds.isFinite && $0.endSeconds.isFinite && $0.endSeconds > $0.startSeconds }
            .sorted { $0.startSeconds < $1.startSeconds }
        return validRanges.enumerated().map { index, range in
            let keepsLeadingEffects = index == 0
            let keepsTrailingEffects = index == validRanges.count - 1
            return RecordingEditorSegment(
                recording: segment.recording,
                startSeconds: range.startSeconds,
                endSeconds: range.endSeconds,
                audioGain: segment.audioGain,
                isAudioMuted: segment.isAudioMuted,
                fadeInSeconds: keepsLeadingEffects ? segment.fadeInSeconds : 0,
                fadeOutSeconds: keepsTrailingEffects ? segment.fadeOutSeconds : 0,
                transitionBefore: keepsLeadingEffects ? segment.transitionBefore : .cut,
                transitionDurationSeconds: segment.transitionDurationSeconds
            )
        }
    }

    private func rebaseTimelineContent(afterRemoving ranges: [RecordingEditorTimeRange]) {
        let removals = mergedTimelineRanges(ranges)
        guard !removals.isEmpty else { return }

        markers = markers.compactMap { marker in
            guard let time = mappedTimelineTime(marker.timeSeconds, removing: removals) else { return nil }
            return RecordingEditorMarker(id: marker.id, timeSeconds: time, name: marker.name)
        }
        captions = captions.flatMap { caption in
            mappedTimelineIntervals(from: caption.startSeconds, to: caption.endSeconds, removing: removals)
                .enumerated()
                .map { index, interval in
                    RecordingEditorCaption(
                        id: index == 0 ? caption.id : UUID(),
                        startSeconds: interval.startSeconds,
                        endSeconds: interval.endSeconds,
                        text: caption.text,
                        language: caption.language
                    )
                }
        }.sorted { $0.startSeconds < $1.startSeconds }
        overlays = overlays.flatMap { overlay in
            mappedTimelineIntervals(from: overlay.startSeconds, to: overlay.endSeconds, removing: removals)
                .enumerated()
                .map { index, interval in
                    RecordingEditorOverlay(
                        id: index == 0 ? overlay.id : UUID(),
                        kind: overlay.kind,
                        startSeconds: interval.startSeconds,
                        endSeconds: interval.endSeconds,
                        x: overlay.x,
                        y: overlay.y,
                        width: overlay.width,
                        height: overlay.height,
                        text: overlay.text
                    )
                }
        }
        zoomKeyframes = zoomKeyframes.compactMap { keyframe in
            guard let time = mappedTimelineTime(keyframe.timeSeconds, removing: removals) else { return nil }
            var updated = keyframe
            updated.timeSeconds = time
            return updated
        }.sorted { $0.timeSeconds < $1.timeSeconds }
        let visibleTime = mappedTimelineTime(timelineVisibleStartSeconds, removing: removals)
            ?? mappedTimelineBoundary(timelineVisibleStartSeconds, removing: removals)
        timelineVisibleStartSeconds = min(max(visibleTime, 0), outputDurationSeconds)
    }

    private func mergedTimelineRanges(_ ranges: [RecordingEditorTimeRange]) -> [RecordingEditorTimeRange] {
        let sortedRanges = ranges
            .filter { $0.startSeconds.isFinite && $0.endSeconds.isFinite && $0.endSeconds > $0.startSeconds }
            .sorted { $0.startSeconds < $1.startSeconds }
        var merged: [RecordingEditorTimeRange] = []
        for range in sortedRanges {
            if let lastIndex = merged.indices.last, range.startSeconds <= merged[lastIndex].endSeconds {
                merged[lastIndex].endSeconds = max(merged[lastIndex].endSeconds, range.endSeconds)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    private func mappedTimelineTime(_ seconds: Double, removing ranges: [RecordingEditorTimeRange]) -> Double? {
        guard seconds.isFinite else { return nil }
        var removedDuration = 0.0
        for range in ranges {
            if seconds < range.startSeconds { break }
            if seconds < range.endSeconds { return nil }
            removedDuration += range.durationSeconds
        }
        return max(0, seconds - removedDuration)
    }

    private func mappedTimelineBoundary(_ seconds: Double, removing ranges: [RecordingEditorTimeRange]) -> Double {
        var removedDuration = 0.0
        for range in ranges {
            if seconds < range.startSeconds { break }
            if seconds < range.endSeconds { return max(0, range.startSeconds - removedDuration) }
            removedDuration += range.durationSeconds
        }
        return max(0, seconds - removedDuration)
    }

    private func mappedTimelineIntervals(from startSeconds: Double, to endSeconds: Double, removing ranges: [RecordingEditorTimeRange]) -> [RecordingEditorTimeRange] {
        guard startSeconds.isFinite, endSeconds.isFinite, endSeconds > startSeconds else { return [] }
        var retained = [RecordingEditorTimeRange(startSeconds: startSeconds, endSeconds: endSeconds)]
        for removal in ranges {
            retained = retained.flatMap { interval in
                guard removal.startSeconds < interval.endSeconds, removal.endSeconds > interval.startSeconds else { return [interval] }
                var fragments: [RecordingEditorTimeRange] = []
                if removal.startSeconds > interval.startSeconds {
                    fragments.append(RecordingEditorTimeRange(startSeconds: interval.startSeconds, endSeconds: min(removal.startSeconds, interval.endSeconds)))
                }
                if removal.endSeconds < interval.endSeconds {
                    fragments.append(RecordingEditorTimeRange(startSeconds: max(removal.endSeconds, interval.startSeconds), endSeconds: interval.endSeconds))
                }
                return fragments
            }
        }
        return retained.compactMap { interval in
            let mappedStart = mappedTimelineBoundary(interval.startSeconds, removing: ranges)
            let mappedEnd = mappedTimelineBoundary(interval.endSeconds, removing: ranges)
            guard mappedEnd > mappedStart else { return nil }
            return RecordingEditorTimeRange(startSeconds: mappedStart, endSeconds: mappedEnd)
        }
    }

    private func copySegment(_ segment: RecordingEditorSegment, startSeconds: Double, endSeconds: Double) -> RecordingEditorSegment {
        RecordingEditorSegment(recording: segment.recording, startSeconds: startSeconds, endSeconds: endSeconds, audioGain: segment.audioGain, isAudioMuted: segment.isAudioMuted, fadeInSeconds: segment.fadeInSeconds, fadeOutSeconds: segment.fadeOutSeconds, transitionBefore: segment.transitionBefore, transitionDurationSeconds: segment.transitionDurationSeconds)
    }

    private func joinablePairContainingSelectedSegment() -> (leftIndex: Int, rightIndex: Int, selectedIndex: Int)? {
        guard let index = selectedSegmentIndex else { return nil }
        let selected = segments[index]
        if let previousSourceIndex = nearestJoinableIndex(to: index, matching: { canJoin(left: segments[$0], right: selected) }) {
            return (previousSourceIndex, index, index)
        }
        if let nextSourceIndex = nearestJoinableIndex(to: index, matching: { canJoin(left: selected, right: segments[$0]) }) {
            return (index, nextSourceIndex, index)
        }
        return nil
    }

    private func nearestJoinableIndex(to selectedIndex: Int, matching isJoinable: (Int) -> Bool) -> Int? {
        segments.indices
            .filter { $0 != selectedIndex && isJoinable($0) }
            .min { abs($0 - selectedIndex) < abs($1 - selectedIndex) }
    }

    private func canJoin(left: RecordingEditorSegment, right: RecordingEditorSegment) -> Bool {
        left.recording.id == right.recording.id && left.audioGain == right.audioGain && left.isAudioMuted == right.isAudioMuted && left.fadeOutSeconds == 0 && right.fadeInSeconds == 0 && right.transitionBefore == .cut && abs(left.endSeconds - right.startSeconds) <= Self.sectionJoinTolerance
    }

    private func recordUndo() {
        undoStack.append(makeSnapshot())
        if undoStack.count > 50 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    private func makeSnapshot() -> RecordingEditorSnapshot {
        RecordingEditorSnapshot(
            outputTitle: outputTitle,
            segments: segments,
            selectedSegmentID: selectedSegmentID,
            markInSeconds: markInSeconds,
            markOutSeconds: markOutSeconds,
            cropX: cropX,
            cropY: cropY,
            cropWidth: cropWidth,
            cropHeight: cropHeight,
            cropEnabled: cropEnabled,
            cropAspectPreset: cropAspectPreset,
            rotation: rotation,
            isFlippedHorizontally: isFlippedHorizontally,
            isFlippedVertically: isFlippedVertically,
            playbackRate: playbackRate,
            isMuted: isMuted,
            volume: volume,
            fadeInSeconds: fadeInSeconds,
            fadeOutSeconds: fadeOutSeconds,
            exportQuality: exportQuality,
            markers: markers,
            outputResolution: outputResolution,
            colorAdjustment: colorAdjustment,
            transcript: transcript,
            captions: captions,
            burnInCaptions: burnInCaptions,
            overlays: overlays,
            zoomKeyframes: zoomKeyframes
        )
    }

    private func apply(_ snapshot: RecordingEditorSnapshot) {
        outputTitle = snapshot.outputTitle
        segments = snapshot.segments
        selectedSegmentID = snapshot.selectedSegmentID
        markInSeconds = snapshot.markInSeconds
        markOutSeconds = snapshot.markOutSeconds
        cropX = snapshot.cropX
        cropY = snapshot.cropY
        cropWidth = snapshot.cropWidth
        cropHeight = snapshot.cropHeight
        cropEnabled = snapshot.cropEnabled
        cropAspectPreset = snapshot.cropAspectPreset
        rotation = snapshot.rotation
        isFlippedHorizontally = snapshot.isFlippedHorizontally
        isFlippedVertically = snapshot.isFlippedVertically
        playbackRate = snapshot.playbackRate
        isMuted = snapshot.isMuted
        volume = snapshot.volume
        fadeInSeconds = snapshot.fadeInSeconds
        fadeOutSeconds = snapshot.fadeOutSeconds
        exportQuality = snapshot.exportQuality
        markers = snapshot.markers
        outputResolution = snapshot.outputResolution
        colorAdjustment = snapshot.colorAdjustment
        transcript = snapshot.transcript
        captions = snapshot.captions
        burnInCaptions = snapshot.burnInCaptions
        overlays = snapshot.overlays
        zoomKeyframes = snapshot.zoomKeyframes
    }
}
