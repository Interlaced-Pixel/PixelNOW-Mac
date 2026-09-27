import AVFoundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers

private struct RecordingTimelineTrimSession {
    let handleID: String
    let segment: RecordingEditorSegment
    let x: CGFloat
    let width: CGFloat
    let isLeading: Bool
}

struct RecordingTimelineView: View {
    let segments: [RecordingEditorSegment]
    let selectedSegmentID: UUID?
    let playheadSeconds: Double
    let markInSeconds: Double?
    let markOutSeconds: Double?
    let markers: [RecordingEditorMarker]
    let snappingEnabled: Bool
    let playbackRate: Double
    let restoreVisibleTimeSeconds: Double
    let onSelect: (RecordingEditorSegment) -> Void
    let onSeek: (Double) -> Void
    let onRangeSelected: (Double, Double) -> Void
    let onPayloadDropped: (String, Int) -> Bool
    let onTrimBegin: (RecordingEditorSegment) -> Void
    let onSegmentTrimStart: (RecordingEditorSegment, Double) -> Void
    let onSegmentTrimEnd: (RecordingEditorSegment, Double) -> Void

    @State private var dragStartSeconds: Double?
    @State private var dragEndSeconds: Double?
    @State private var trimSession: RecordingTimelineTrimSession?
    @State private var proposedInsertionIndex: Int?

    private var totalDuration: Double {
        max(segments.reduce(0) { $0 + $1.durationSeconds }, 0.01) / max(playbackRate, 0.25)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Color.black.opacity(0.34))
                    .contentShape(Rectangle())
                    .gesture(timelineGesture(width: proxy.size.width))
                timelineTicks(width: proxy.size.width)
                ForEach(segmentFrames(in: proxy.size.width), id: \.segment.id) { item in
                    timelineClip(item, canvasWidth: proxy.size.width)
                    if item.segment.id == selectedSegmentID {
                        trimHandle(item: item, isLeading: true, canvasWidth: proxy.size.width)
                            .offset(x: item.x - 6)
                        trimHandle(item: item, isLeading: false, canvasWidth: proxy.size.width)
                            .offset(x: item.x + item.width - 6)
                    }
                }
                ForEach(markers) { marker in
                    Rectangle()
                        .fill(Color.orange.opacity(0.9))
                        .frame(width: 2, height: 70)
                        .overlay(alignment: .top) {
                            Image(systemName: "bookmark.fill")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.orange)
                                .offset(y: -1)
                        }
                        .offset(x: markerX(marker.timeSeconds, width: proxy.size.width), y: 10)
                        .accessibilityLabel(marker.name.isEmpty ? "Marker" : marker.name)
                }
                if let frame = activeSelectionFrame(in: proxy.size.width) {
                    selectionOverlay(frame: frame, opacity: 0.24)
                }
                if let frame = markedSelectionFrame(in: proxy.size.width) {
                    selectionOverlay(frame: frame, opacity: 0.36)
                }
                if let insertionX = insertionX(index: proposedInsertionIndex, width: proxy.size.width) {
                    insertionIndicator(x: insertionX)
                }
                playhead(width: proxy.size.width)
                Color.clear
                    .frame(width: 1, height: 1)
                    .position(x: min(max(0, restoreVisibleTimeSeconds / totalDuration), 1) * proxy.size.width, y: 1)
                    .id("timeline-saved-position")
            }
            .onDrop(of: [.text], delegate: RecordingTimelineDropDelegate(
                width: proxy.size.width,
                segments: segments,
                proposedInsertionIndex: $proposedInsertionIndex,
                onPayloadDropped: onPayloadDropped
            ))
        }
        .frame(height: 86)
        .overlay { RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.white.opacity(0.12), lineWidth: 1) }
    }

    private func timelineClip(_ item: (segment: RecordingEditorSegment, x: CGFloat, width: CGFloat), canvasWidth: CGFloat) -> some View {
        let isSelected = item.segment.id == selectedSegmentID
        return ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? RecordingsLayout.accent.opacity(0.30) : Color.white.opacity(0.10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(isSelected ? RecordingsLayout.accent : Color.white.opacity(0.18), lineWidth: isSelected ? 1.4 : 1)
                }
            if item.width > 100 {
                RecordingTimelineThumbnailStrip(segment: item.segment)
                    .frame(height: 58)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .opacity(0.58)
            }
            if item.width > 140 {
                RecordingTimelineWaveformStrip(segment: item.segment)
                    .frame(height: 36)
                    .padding(.horizontal, 5)
                    .offset(y: 13)
            }
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.segment.recording.title)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(1)
                    Text("\(recordingEditorDurationText(item.segment.startSeconds)) - \(recordingEditorDurationText(item.segment.endSeconds))")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.white.opacity(0.52))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if isSelected {
                    Text("KEEP")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .frame(height: 15)
                        .background(RecordingsLayout.accent, in: Capsule())
                }
            }
            .padding(.horizontal, 10)
        }
        .frame(width: max(2, item.width), height: 58)
        .offset(x: item.x, y: 14)
        .gesture(SpatialTapGesture().onEnded { value in
            onSelect(item.segment)
            let seconds = timelineSeconds(for: item.x + value.location.x, width: canvasWidth)
            onSeek(snappedTimelineSeconds(seconds, width: canvasWidth))
        })
        .onDrag {
            NSItemProvider(object: RecordingEditorDragPayload.segment(item.segment.id).stringValue as NSString)
        }
    }

    private func trimHandle(item: (segment: RecordingEditorSegment, x: CGFloat, width: CGFloat), isLeading: Bool, canvasWidth: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(RecordingsLayout.accent)
            .frame(width: 12, height: 72)
            .overlay(alignment: isLeading ? .leading : .trailing) {
                Rectangle().fill(Color.black.opacity(0.30)).frame(width: 2)
            }
            .shadow(color: RecordingsLayout.accent.opacity(0.55), radius: 6)
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { value in
                    let handleID = item.segment.id.uuidString + (isLeading ? "-leading" : "-trailing")
                    let session: RecordingTimelineTrimSession
                    if let activeSession = trimSession, activeSession.handleID == handleID {
                        session = activeSession
                    } else {
                        let startedSession = RecordingTimelineTrimSession(
                            handleID: handleID,
                            segment: item.segment,
                            x: item.x,
                            width: item.width,
                            isLeading: isLeading
                        )
                        trimSession = startedSession
                        session = startedSession
                        onTrimBegin(item.segment)
                    }
                    let baseline = (segment: session.segment, x: session.x, width: session.width)
                    let handleX = session.x + (session.isLeading ? 0 : session.width) + value.translation.width
                    let seconds = sourceSeconds(in: baseline, timelineX: handleX, canvasWidth: canvasWidth)
                    if session.isLeading {
                        onSegmentTrimStart(item.segment, seconds)
                    } else {
                        onSegmentTrimEnd(item.segment, seconds)
                    }
                }
                .onEnded { _ in trimSession = nil }
            )
    }

    private func playhead(width: CGFloat) -> some View {
        Rectangle()
            .fill(Color.white.opacity(0.94))
            .frame(width: 2, height: 94)
            .shadow(color: RecordingsLayout.accent.opacity(0.95), radius: 7)
            .offset(x: playheadX(in: width), y: -4)
            .id("timeline-playhead")
    }

    private func selectionOverlay(frame: (x: CGFloat, width: CGFloat), opacity: Double) -> some View {
        Rectangle()
            .fill(Color.red.opacity(opacity))
            .frame(width: max(2, frame.width), height: 58)
            .overlay { Rectangle().stroke(Color.red.opacity(0.62), lineWidth: 1) }
            .offset(x: frame.x, y: 14)
    }

    private func insertionIndicator(x: CGFloat) -> some View {
        Rectangle()
            .fill(RecordingsLayout.accent)
            .frame(width: 3, height: 78)
            .shadow(color: RecordingsLayout.accent.opacity(0.80), radius: 8)
            .offset(x: x - 1.5, y: 8)
    }

    private func timelineTicks(width: CGFloat) -> some View {
        let interval = rulerInterval(width: width)
        let values = Array(stride(from: 0.0, through: totalDuration, by: interval))
        return ZStack(alignment: .topLeading) {
            Path { path in
                for seconds in values {
                    let x = CGFloat(seconds / totalDuration) * width
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: 14))
                }
            }
            .stroke(Color.white.opacity(0.18), lineWidth: 1)

            ForEach(values, id: \.self) { seconds in
                let x = CGFloat(seconds / totalDuration) * width
                Text(recordingEditorDurationText(seconds))
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.white.opacity(0.38))
                    .offset(x: seconds >= totalDuration ? x - 28 : max(x - (seconds == 0 ? 0 : 14), 0), y: 16)
            }
        }
    }

    private func rulerInterval(width: CGFloat) -> Double {
        let rawInterval = max(0.1, totalDuration * 100 / Double(max(width, 1)))
        let magnitude = pow(10, floor(log10(rawInterval)))
        let normalized = rawInterval / magnitude
        let preferred: Double = normalized <= 1 ? 1 : normalized <= 2 ? 2 : normalized <= 5 ? 5 : 10
        return preferred * magnitude
    }

    private func timelineGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let current = timelineSeconds(for: value.location.x, width: width)
                if dragStartSeconds == nil { dragStartSeconds = current }
                dragEndSeconds = current
            }
            .onEnded { value in
                let end = timelineSeconds(for: value.location.x, width: width)
                let start = dragStartSeconds ?? end
                defer {
                    dragStartSeconds = nil
                    dragEndSeconds = nil
                }
                if abs(value.translation.width) < 4 {
                    if let segment = segment(at: end) { onSelect(segment) }
                    onSeek(snappedTimelineSeconds(end, width: width))
                } else {
                    onRangeSelected(snappedTimelineSeconds(start, width: width), snappedTimelineSeconds(end, width: width))
                }
            }
    }

    private func segmentFrames(in width: CGFloat) -> [(segment: RecordingEditorSegment, x: CGFloat, width: CGFloat)] {
        var cursor = 0.0
        return segments.map { segment in
            let segmentOutputDuration = segment.durationSeconds / max(playbackRate, 0.25)
            let segmentWidth = CGFloat(segmentOutputDuration / totalDuration) * width
            let x = CGFloat(cursor / totalDuration) * width
            cursor += segmentOutputDuration
            return (segment, x, segmentWidth)
        }
    }

    private func insertionX(index: Int?, width: CGFloat) -> CGFloat? {
        guard let index else { return nil }
        let frames = segmentFrames(in: width)
        if index <= 0 { return 0 }
        if index >= frames.count { return width }
        return frames[index].x
    }

    private func segment(at timelineSeconds: Double) -> RecordingEditorSegment? {
        var cursor = 0.0
        for segment in segments {
            let next = cursor + segment.durationSeconds / max(playbackRate, 0.25)
            if timelineSeconds <= next || segment.id == segments.last?.id { return segment }
            cursor = next
        }
        return nil
    }

    private func timelineSeconds(for x: CGFloat, width: CGFloat) -> Double {
        totalDuration * min(max(0, Double(x / max(width, 1))), 1)
    }

    private func sourceSeconds(in item: (segment: RecordingEditorSegment, x: CGFloat, width: CGFloat), timelineX: CGFloat, canvasWidth: CGFloat) -> Double {
        let snappedX = snappingEnabled ? snappedPosition(timelineX, canvasWidth: canvasWidth) : timelineX
        let ratio = min(max(0, Double((snappedX - item.x) / max(item.width, 1))), 1)
        return item.segment.startSeconds + item.segment.durationSeconds * ratio
    }

    private func snappedTimelineSeconds(_ seconds: Double, width: CGFloat) -> Double {
        guard snappingEnabled else { return seconds }
        let candidates = [0, totalDuration] + markers.map(\.timeSeconds) + segments.flatMap { segment in
            var start = 0.0
            if let index = segments.firstIndex(where: { $0.id == segment.id }) {
                start = segments[..<index].reduce(0) { $0 + $1.durationSeconds / max(playbackRate, 0.25) }
            }
            return [start, start + segment.durationSeconds / max(playbackRate, 0.25)]
        } + [playheadSeconds]
        let threshold = totalDuration * 8 / Double(max(width, 1))
        return candidates.min(by: { abs($0 - seconds) < abs($1 - seconds) }).flatMap { abs($0 - seconds) <= threshold ? $0 : nil } ?? seconds
    }

    private func snappedPosition(_ x: CGFloat, canvasWidth: CGFloat) -> CGFloat {
        guard snappingEnabled else { return x }
        let seconds = timelineSeconds(for: x, width: canvasWidth)
        let snapped = snappedTimelineSeconds(seconds, width: canvasWidth)
        return CGFloat(snapped / totalDuration) * canvasWidth
    }

    private func markerX(_ seconds: Double, width: CGFloat) -> CGFloat {
        CGFloat(min(max(0, seconds), totalDuration) / totalDuration) * width
    }

    private func playheadX(in width: CGFloat) -> CGFloat {
        var cursor = 0.0
        for segment in segments {
            let segmentOutputDuration = segment.durationSeconds / max(playbackRate, 0.25)
            let segEnd = cursor + segmentOutputDuration
            if playheadSeconds <= segEnd || segment.id == segments.last?.id {
                let local = min(max(0, playheadSeconds - cursor), segmentOutputDuration)
                return CGFloat((cursor + local) / totalDuration) * width
            }
            cursor = segEnd
        }
        return CGFloat(min(max(0, playheadSeconds), totalDuration) / totalDuration) * width
    }

    private func markedSelectionFrame(in width: CGFloat) -> (x: CGFloat, width: CGFloat)? {
        guard let markInSeconds, let markOutSeconds, let selected = segments.first(where: { $0.id == selectedSegmentID }) else { return nil }
        var cursor = 0.0
        for segment in segments {
            if segment.id == selected.id {
                let start = min(max(selected.startSeconds, min(markInSeconds, markOutSeconds)), selected.endSeconds) - selected.startSeconds
                let end = min(max(selected.startSeconds, max(markInSeconds, markOutSeconds)), selected.endSeconds) - selected.startSeconds
                let rate = max(playbackRate, 0.25)
                return (CGFloat((cursor + start / rate) / totalDuration) * width, CGFloat(max(0, end - start) / rate / totalDuration) * width)
            }
            cursor += segment.durationSeconds / max(playbackRate, 0.25)
        }
        return nil
    }

    private func activeSelectionFrame(in width: CGFloat) -> (x: CGFloat, width: CGFloat)? {
        guard let dragStartSeconds, let dragEndSeconds, abs(dragStartSeconds - dragEndSeconds) > 0.03 else { return nil }
        let start = CGFloat(min(dragStartSeconds, dragEndSeconds) / totalDuration) * width
        let end = CGFloat(max(dragStartSeconds, dragEndSeconds) / totalDuration) * width
        return (start, end - start)
    }
}

private struct RecordingTimelineThumbnailStrip: View {
    let segment: RecordingEditorSegment
    @State private var thumbnails: [NSImage] = []

    var body: some View {
        HStack(spacing: 1) {
            ForEach(Array(thumbnails.enumerated()), id: \.offset) { entry in
                Image(nsImage: entry.element)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            }
        }
        .task(id: cacheKey) {
            thumbnails = await RecordingTimelineThumbnailCache.thumbnails(for: segment)
        }
        .accessibilityHidden(true)
    }

    private var cacheKey: String {
        "\(segment.recording.id.uuidString):\(segment.startSeconds):\(segment.endSeconds)"
    }
}

@MainActor
private enum RecordingTimelineThumbnailCache {
    private static var cachedImages: [String: NSImage] = [:]

    static func thumbnails(for segment: RecordingEditorSegment) async -> [NSImage] {
        let frameCount = 6
        let sourceTimes = (0..<frameCount).map { index in
            segment.startSeconds + segment.durationSeconds * (Double(index) + 0.5) / Double(frameCount)
        }
        let missing = sourceTimes.filter { cachedImages[cacheKey(segment.recording.id, $0)] == nil }
        if !missing.isEmpty {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: segment.recording.videoURL))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 160, height: 90)
            for seconds in missing {
                do {
                    let result = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600))
                    cachedImages[cacheKey(segment.recording.id, seconds)] = NSImage(cgImage: result.image, size: .zero)
                } catch {
                    continue
                }
            }
            if cachedImages.count > 512 { cachedImages.removeAll(keepingCapacity: true) }
        }
        return sourceTimes.compactMap { cachedImages[cacheKey(segment.recording.id, $0)] }
    }

    private static func cacheKey(_ recordingID: UUID, _ seconds: Double) -> String {
        "\(recordingID.uuidString):\(Int((seconds * 2).rounded()))"
    }
}

private struct RecordingTimelineWaveformStrip: View {
    let segment: RecordingEditorSegment
    @State private var values: [Float] = []

    var body: some View {
        Canvas { context, size in
            guard !values.isEmpty else { return }
            let middle = size.height / 2
            var path = Path()
            for (index, value) in values.enumerated() {
                let x = CGFloat(index) / CGFloat(max(values.count - 1, 1)) * size.width
                let amplitude = max(1, CGFloat(value) * middle * 0.92)
                path.move(to: CGPoint(x: x, y: middle - amplitude))
                path.addLine(to: CGPoint(x: x, y: middle + amplitude))
            }
            context.stroke(path, with: .color(.cyan.opacity(0.66)), lineWidth: 1)
        }
        .task(id: cacheKey) {
            let result = await RecordingTimelineWaveformCache.waveform(recordingID: segment.recording.id, url: segment.recording.videoURL, startSeconds: segment.startSeconds, endSeconds: segment.endSeconds, bucketCount: 96)
            if !Task.isCancelled { values = result }
        }
        .accessibilityHidden(true)
    }

    private var cacheKey: String {
        "\(segment.recording.id.uuidString):\(segment.startSeconds):\(segment.endSeconds)"
    }
}

func recordingEditorDurationText(_ seconds: Double) -> String {
    let value = max(0, Int(seconds.rounded()))
    if value >= 3600 { return String(format: "%d:%02d:%02d", value / 3600, (value / 60) % 60, value % 60) }
    return String(format: "%d:%02d", value / 60, value % 60)
}

func recordingEditorTimecode(_ seconds: Double) -> String {
    let value = max(0, seconds.isFinite ? seconds : 0)
    let hours = Int(value / 3600)
    let minutes = Int(value / 60) % 60
    let remainder = value.truncatingRemainder(dividingBy: 60)
    return hours > 0
        ? String(format: "%d:%02d:%05.2f", hours, minutes, remainder)
        : String(format: "%d:%05.2f", Int(value / 60), remainder)
}

func recordingEditorSeconds(fromTimecode timecode: String) -> Double? {
    let components = timecode.split(separator: ":", omittingEmptySubsequences: false)
    guard (1...3).contains(components.count) else { return nil }
    let values = components.compactMap { Double($0) }
    guard values.count == components.count, values.allSatisfy({ $0.isFinite && $0 >= 0 }) else { return nil }
    let seconds: Double
    switch values.count {
    case 1: seconds = values[0]
    case 2: seconds = values[0] * 60 + values[1]
    case 3: seconds = values[0] * 3600 + values[1] * 60 + values[2]
    default: return nil
    }
    return seconds.isFinite ? seconds : nil
}

private struct RecordingTimelineDropDelegate: DropDelegate {
    let width: CGFloat
    let segments: [RecordingEditorSegment]
    @Binding var proposedInsertionIndex: Int?
    let onPayloadDropped: (String, Int) -> Bool

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.text])
    }

    func dropEntered(info: DropInfo) {
        proposedInsertionIndex = insertionIndex(for: info.location.x)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        proposedInsertionIndex = insertionIndex(for: info.location.x)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        proposedInsertionIndex = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        let insertionIndex = proposedInsertionIndex ?? insertionIndex(for: info.location.x)
        proposedInsertionIndex = nil
        guard let provider = info.itemProviders(for: [.text]).first else { return false }
        provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let payload = object as? String else { return }
            DispatchQueue.main.async {
                _ = onPayloadDropped(payload, insertionIndex)
            }
        }
        return true
    }

    private func insertionIndex(for x: CGFloat) -> Int {
        guard !segments.isEmpty else { return 0 }
        var cursor = CGFloat.zero
        let totalDuration = max(segments.reduce(0) { $0 + $1.durationSeconds }, 0.01)
        for (index, segment) in segments.enumerated() {
            let segmentWidth = CGFloat(segment.durationSeconds / totalDuration) * width
            if x < cursor + segmentWidth / 2 { return index }
            cursor += segmentWidth
        }
        return segments.count
    }
}
