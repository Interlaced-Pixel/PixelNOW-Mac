import AVKit
import AppKit
import SwiftUI
import UniformTypeIdentifiers

private struct RecordingTimelineScrollOffsetPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct RecordingEditorWorkspaceMetrics {
    let size: CGSize
    let horizontalPadding: CGFloat
    let verticalPadding: CGFloat
    let panelSpacing: CGFloat
    let headerHeight: CGFloat
    let timelineHeight: CGFloat
    let footerHeight: CGFloat
    let browserWidth: CGFloat
    let inspectorWidth: CGFloat

    init(size: CGSize) {
        self.size = size
        horizontalPadding = Design.clamped(size.width * 0.018, minimum: 12, maximum: 24)
        verticalPadding = Design.clamped(size.height * 0.02, minimum: 10, maximum: 24)
        panelSpacing = size.width < 1_120 ? 8 : 12
        headerHeight = size.width < 1_120 ? 56 : 64
        timelineHeight = Design.clamped(size.height * 0.21, minimum: 170, maximum: 212)
        footerHeight = 42
        browserWidth = Design.clamped(size.width * 0.19, minimum: 210, maximum: 300)
        inspectorWidth = Design.clamped(size.width * 0.20, minimum: 238, maximum: 330)
    }

    func workspaceHeight() -> CGFloat {
        let verticalGaps = panelSpacing * 3
        return max(250, size.height - (verticalPadding * 2) - headerHeight - timelineHeight - footerHeight - verticalGaps)
    }

    func previewHeight(preferred: CGFloat) -> CGFloat {
        let chromeHeight: CGFloat = 86
        let available = workspaceHeight() - chromeHeight
        return min(max(156, preferred), max(156, available))
    }
}

private enum RecordingAdvancedEditorSection: String, CaseIterable, Identifiable {
    case frame
    case audio
    case color
    case transcript
    case overlays
    case export

    var id: String { rawValue }

    var title: String {
        switch self {
        case .frame: return "Frame"
        case .audio: return "Audio"
        case .color: return "Color"
        case .transcript: return "Transcript"
        case .overlays: return "Overlays"
        case .export: return "Export"
        }
    }
}

struct RecordingEditorView: View {
    @ObservedObject var viewModel: RecordingEditorViewModel
    let player: AVPlayer
    let playheadSeconds: Double
    let isPlaying: Bool
    let onSeek: (Double) -> Void
    let onTogglePlayback: () -> Void
    let onPause: () -> Void
    let onShuttle: (Float) -> Void
    let onCancel: () -> Void
    let onSaved: (WebRTCStreamRecording) -> Void
    let onPreviewChanged: () -> Void

    @State private var exportTask: Task<Void, Never>?
    @State private var exportedCopyURL: URL?
    @State private var selectedExportQuality: RecordingEditorExportQuality = .highest
    @State private var showsAdvanced = true
    @State private var advancedSection: RecordingAdvancedEditorSection = .frame
    @State private var selectedBrowserRecordingID: UUID?
    @State private var browserSearchText = ""
    @State private var showsDiscardProjectConfirmation = false
    @State private var transcriptSearchText = ""
    @State private var previewHeight: CGFloat = .greatestFiniteMagnitude
    @State private var previewDragStartHeight: CGFloat?
    @State private var timelineZoomScale: CGFloat = 1
    @State private var timecodeEntry = ""
    @FocusState private var isOutputTitleFocused: Bool
    @FocusState private var isTimecodeFocused: Bool

    var body: some View {
        GeometryReader { geometry in
            let metrics = RecordingEditorWorkspaceMetrics(size: geometry.size)
            let workspaceHeight = metrics.workspaceHeight()
            VStack(alignment: .leading, spacing: metrics.panelSpacing) {
                header
                HStack(alignment: .top, spacing: metrics.panelSpacing) {
                    browserPanel
                        .frame(width: metrics.browserWidth)
                        .frame(height: workspaceHeight)

                    previewCard(height: metrics.previewHeight(preferred: previewHeight))
                        .frame(maxWidth: .infinity, maxHeight: workspaceHeight, alignment: .top)

                    if showsAdvanced {
                        ScrollView(.vertical, showsIndicators: false) {
                            advancedDrawer
                                .frame(width: metrics.inspectorWidth)
                        }
                        .frame(width: metrics.inspectorWidth, height: workspaceHeight, alignment: .top)
                    }
                }
                .frame(maxWidth: 1880, minHeight: workspaceHeight, maxHeight: workspaceHeight, alignment: .top)
                .frame(maxWidth: .infinity, alignment: .top)

                timelineCard
                    .frame(maxWidth: 1880, minHeight: metrics.timelineHeight, maxHeight: metrics.timelineHeight, alignment: .top)
                    .frame(maxWidth: .infinity, alignment: .top)

                exportBar
                    .frame(height: metrics.footerHeight)
                    .padding(.horizontal, 12)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .frame(maxWidth: 1880, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, metrics.horizontalPadding)
            .padding(.vertical, metrics.verticalPadding)
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
        }
        .onChange(of: viewModel.previewSignature) { _, _ in onPreviewChanged() }
        .onAppear {
            selectedExportQuality = viewModel.exportQuality
            selectedBrowserRecordingID = viewModel.primaryRecording.id
        }
        .onAppear { timelineZoomScale = CGFloat(viewModel.timelineZoomScale) }
        .onChange(of: timelineZoomScale) { _, scale in viewModel.timelineZoomScale = Double(scale) }
        .confirmationDialog("Discard this edit project?", isPresented: $showsDiscardProjectConfirmation) {
            Button("Discard Project", role: .destructive) {
                if viewModel.discardProject() {
                    onCancel()
                }
            }
            Button("Keep Editing", role: .cancel) {}
        } message: {
            Text("The original recordings will remain unchanged.")
        }
        .onChange(of: selectedExportQuality) { _, quality in viewModel.setExportQuality(quality) }
        .onChange(of: viewModel.exportQuality) { _, quality in selectedExportQuality = quality }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("VIDEO EDITOR")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1.4)
                    .foregroundStyle(RecordingsLayout.accent)
                Text("Edit video")
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(.white)
            }
            HStack(spacing: 10) {
                Image(systemName: "pencil.line")
                    .foregroundStyle(RecordingsLayout.accent)
                TextField("Name your exported video", text: Binding(
                    get: { viewModel.outputTitle },
                    set: viewModel.updateOutputTitle
                ))
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.95))
                    .help("Exports to Recordings; the source stays unchanged")
                    .focused($isOutputTitleFocused)
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: 360)
            .frame(height: 40)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(RecordingsLayout.stroke, lineWidth: 1) }
            Spacer(minLength: 4)
            Button { viewModel.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                .disabled(!viewModel.canUndo || viewModel.isExporting || isOutputTitleFocused || isTimecodeFocused)
                .buttonStyle(RecordingActionButtonStyle(tone: .secondary))
                .keyboardShortcut("z", modifiers: .command)
            Button { viewModel.redo() } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
                .disabled(!viewModel.canRedo || viewModel.isExporting || isOutputTitleFocused || isTimecodeFocused)
                .buttonStyle(RecordingActionButtonStyle(tone: .secondary))
                .keyboardShortcut("z", modifiers: [.command, .shift])
            Menu("Edit") {
                Button("Trim Start to Playhead") { applyAtSourcePlayhead(viewModel.trimStartToPlayhead) }
                Button("Trim End to Playhead") { applyAtSourcePlayhead(viewModel.trimEndToPlayhead) }
                Divider()
                Button("Split at Playhead") { applyAtSourcePlayhead(viewModel.splitAtPlayhead) }
                    .keyboardShortcut("b", modifiers: .command)
                Button("Join Selected Sections") { viewModel.joinSelectedSection() }
                    .disabled(!viewModel.canJoinSelectedSection)
                Divider()
                Button("Set In Point") { applyAtSourcePlayhead(viewModel.markIn) }
                    .keyboardShortcut("i", modifiers: [])
                Button("Set Out Point") { applyAtSourcePlayhead(viewModel.markOut) }
                    .keyboardShortcut("o", modifiers: [])
                Button("Remove Marked Range", role: .destructive) { viewModel.cutMarkedRange() }
                    .disabled(!viewModel.canCutMarkedRange)
                Button("Add Marker") { viewModel.addMarker(at: playheadSeconds) }
                    .keyboardShortcut("m", modifiers: [])
                Divider()
                Button("Reset Edits", role: .destructive) { viewModel.resetEdits() }
            }
            .disabled(viewModel.isExporting || isOutputTitleFocused || isTimecodeFocused)
            Menu("Clip") {
                Button("Duplicate Selected Clip") { viewModel.duplicateSelectedSegment() }
                Button("Remove Selected Clip", role: .destructive) { viewModel.removeSelectedSegment() }
                Button("Join Selected Clip") { viewModel.joinSelectedSection() }
                    .disabled(!viewModel.canJoinSelectedSection)
                Divider()
                Button("Move Clip Left") { viewModel.moveSelectedSegment(offset: -1) }
                Button("Move Clip Right") { viewModel.moveSelectedSegment(offset: 1) }
            }
            .disabled(viewModel.isExporting || isOutputTitleFocused || isTimecodeFocused)
            Button(showsAdvanced ? "Hide Inspector" : "Show Inspector") { showsAdvanced.toggle() }
                .disabled(viewModel.isExporting)
                .buttonStyle(RecordingActionButtonStyle(tone: .secondary))
            Menu("Project") {
                Button("Save Project") { viewModel.saveProject() }
                    .keyboardShortcut("s", modifiers: .command)
                Divider()
                Button("Duplicate Project") { viewModel.duplicateProject() }
                if let missingID = viewModel.missingProjectRecordingIDs.first {
                    Button("Relink Missing Media") { relinkMissingMedia(missingID) }
                }
                Button("Discard Project", role: .destructive) { showsDiscardProjectConfirmation = true }
            }
            .disabled(viewModel.isExporting)
            Button("Close", action: onCancel)
                .disabled(viewModel.isExporting)
                .buttonStyle(RecordingActionButtonStyle(tone: .secondary))
        }
        .padding(12)
        .modifier(LiquidGlassModifier(cornerRadius: 18))
        .onChange(of: isOutputTitleFocused) { _, isFocused in
            if isFocused {
                viewModel.beginOutputTitleEdit()
            } else {
                viewModel.endOutputTitleEdit()
            }
        }
    }

    private func previewCard(height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("PREVIEW", systemImage: "play.rectangle.fill")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1.2)
                    .foregroundStyle(RecordingsLayout.accent)
                Spacer()
                Text("\(recordingEditorDurationText(viewModel.outputDurationSeconds)) total")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.62))
            }
            ZStack {
                RecordingPlayerView(player: player)
                    .frame(maxWidth: .infinity)
                    .frame(height: height)
                if viewModel.isCropOverlayEditing {
                    RecordingCropOverlay(
                        sourceWidth: CGFloat(viewModel.primaryRecording.width),
                        sourceHeight: CGFloat(viewModel.primaryRecording.height),
                        cropX: viewModel.cropX,
                        cropY: viewModel.cropY,
                        cropWidth: viewModel.cropWidth,
                        cropHeight: viewModel.cropHeight,
                        lockedAspectRatio: viewModel.normalizedCropAspectRatio,
                        showsSafeAreaGuides: viewModel.showsSafeAreaGuides,
                        onBeginEdit: viewModel.beginInteractiveEdit,
                        onChange: viewModel.updateCropFromViewer
                    )
                }
            }
                .frame(maxWidth: .infinity)
                .frame(height: height)
                .background(Color.black, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.white.opacity(0.10), lineWidth: 1) }
            transportControls
        }
        .padding(16)
        .modifier(LiquidGlassModifier(cornerRadius: 22))
        .overlay(alignment: .bottom) {
            Capsule()
                .fill(Color.white.opacity(0.42))
                .frame(width: 38, height: 4)
                .padding(.bottom, 7)
                .frame(width: 72, height: 24)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 2)
                        .onChanged { value in
                            let startingHeight = previewDragStartHeight ?? height
                            previewDragStartHeight = startingHeight
                            previewHeight = min(max(startingHeight + value.translation.height, 180), 420)
                        }
                        .onEnded { _ in previewDragStartHeight = nil }
                )
                .help("Drag to resize the preview")
                .accessibilityLabel("Resize video preview")
        }
    }

    private var transportControls: some View {
        HStack(spacing: 10) {
            Menu {
                Button("Back 5 Seconds") { jump(by: -5) }
                    .keyboardShortcut(.leftArrow, modifiers: .shift)
                Button("Back 1 Second") { jump(by: -1) }
                Button("Forward 1 Second") { jump(by: 1) }
                Button("Forward 5 Seconds") { jump(by: 5) }
                    .keyboardShortcut(.rightArrow, modifiers: .shift)
                Divider()
                Button("Previous Edit Point") { jumpToEditPoint(direction: -1) }
                    .disabled(viewModel.editPointTime(from: playheadSeconds, direction: -1) == nil)
                Button("Next Edit Point") { jumpToEditPoint(direction: 1) }
                    .disabled(viewModel.editPointTime(from: playheadSeconds, direction: 1) == nil)
                Divider()
                Button("Reverse Shuttle") { onShuttle(-1) }
                    .keyboardShortcut("j", modifiers: [])
                Button("Pause Shuttle") { onPause() }
                    .keyboardShortcut("k", modifiers: [])
                Button("Forward Shuttle") { onShuttle(2) }
                    .keyboardShortcut("l", modifiers: [])
            } label: {
                Image(systemName: "backward.end")
                    .frame(width: 20, height: 22)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .help("Navigation")
            .disabled(isOutputTitleFocused || isTimecodeFocused)

            Spacer(minLength: 0)

            Button { stepFrame(by: -1) } label: { Image(systemName: "backward.frame") }
                .help("Previous frame (←)")
                .keyboardShortcut(.leftArrow, modifiers: [])
                .disabled(isOutputTitleFocused || isTimecodeFocused)
            Button(action: onTogglePlayback) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 20, height: 22)
                    .contentShape(Rectangle())
            }
            .help("Play or pause (Space)")
            .keyboardShortcut(.space, modifiers: [])
            .disabled(isOutputTitleFocused || isTimecodeFocused)
            Button { stepFrame(by: 1) } label: { Image(systemName: "forward.frame") }
                .help("Next frame (→)")
                .keyboardShortcut(.rightArrow, modifiers: [])
                .disabled(isOutputTitleFocused || isTimecodeFocused)

            Spacer(minLength: 0)

            Menu {
                Button("Set In Point") { viewModel.markIn(playheadSeconds) }
                    .keyboardShortcut("i", modifiers: [])
                Button("Set Out Point") { viewModel.markOut(playheadSeconds) }
                    .keyboardShortcut("o", modifiers: [])
                Divider()
                Button("Split at Playhead") { viewModel.splitAtPlayhead(playheadSeconds) }
                    .keyboardShortcut("b", modifiers: .command)
                    .disabled(viewModel.selectedSegment == nil)
                Button("Add Marker") { viewModel.addMarker(at: playheadSeconds) }
                    .keyboardShortcut("m", modifiers: [])
            } label: {
                Image(systemName: "scissors")
                    .frame(width: 20, height: 22)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .help("Mark and edit")
            .disabled(isOutputTitleFocused || isTimecodeFocused)

            TextField("0:00.00", text: Binding(
                get: { isTimecodeFocused ? timecodeEntry : recordingEditorTimecode(playheadSeconds) },
                set: { value in
                    timecodeEntry = value
                }
            ))
            .textFieldStyle(.plain)
            .focused($isTimecodeFocused)
            .onSubmit {
                if let seconds = recordingEditorSeconds(fromTimecode: timecodeEntry) {
                    onSeek(min(max(0, seconds), viewModel.outputDurationSeconds))
                }
                isTimecodeFocused = false
            }
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .frame(width: 58)
            .help("Current time in seconds")
            Text("/ \(recordingEditorDurationText(viewModel.outputDurationSeconds))")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.52))
            Spacer(minLength: 0)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(0.86))
        .font(.system(size: 11, weight: .medium))
        .padding(.horizontal, 2)
        .onChange(of: playheadSeconds) { _, seconds in
            if !isTimecodeFocused { timecodeEntry = recordingEditorTimecode(seconds) }
        }
        .onChange(of: isTimecodeFocused) { _, isFocused in
            if isFocused { timecodeEntry = recordingEditorTimecode(playheadSeconds) }
        }
        .onKeyPress(.escape) {
            if isTimecodeFocused {
                isTimecodeFocused = false
                return .handled
            }
            if isOutputTitleFocused {
                isOutputTitleFocused = false
                return .handled
            }
            return .ignored
        }
    }

    private func jump(by delta: Double) {
        onSeek(min(max(0, playheadSeconds + delta), viewModel.outputDurationSeconds))
    }

    private func stepFrame(by frames: Int) {
        let frameDuration = 1.0 / 30.0
        onSeek(min(max(0, playheadSeconds + Double(frames) * frameDuration), viewModel.outputDurationSeconds))
    }

    private func jumpToEditPoint(direction: Int) {
        guard let seconds = viewModel.editPointTime(from: playheadSeconds, direction: direction) else { return }
        onSeek(seconds)
    }

    private var timelineCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("Timeline")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1.2)
                    .foregroundStyle(RecordingsLayout.accent.opacity(0.86))
                Text("\(recordingEditorDurationText(viewModel.outputDurationSeconds)) output")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.58))
                Spacer(minLength: 0)
                Text("\(viewModel.segments.count) clip\(viewModel.segments.count == 1 ? "" : "s")")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.46))
                Button { timelineZoomScale = max(1, timelineZoomScale / 1.25) } label: { Image(systemName: "minus.magnifyingglass") }
                    .help("Zoom timeline out")
                Button { timelineZoomScale = min(12, timelineZoomScale * 1.25) } label: { Image(systemName: "plus.magnifyingglass") }
                    .help("Zoom timeline in")
                Button("Fit") { timelineZoomScale = 1 }
                    .help("Fit the full edit in the timeline")
                Toggle(isOn: Binding(get: { viewModel.snappingEnabled }, set: { _ in viewModel.toggleSnapping() })) {
                    Image(systemName: "magnet")
                }
                .toggleStyle(.button)
                .keyboardShortcut("s", modifiers: [])
                .help("Toggle snapping (S)")
            }
            GeometryReader { proxy in
                ScrollViewReader { scrollProxy in
                    ScrollView(.horizontal) {
                RecordingTimelineView(
                            segments: viewModel.segments,
                            selectedSegmentID: viewModel.selectedSegmentID,
                            playheadSeconds: playheadSeconds,
                            markInSeconds: viewModel.markInSeconds,
                            markOutSeconds: viewModel.markOutSeconds,
                    markers: viewModel.markers,
                    snappingEnabled: viewModel.snappingEnabled,
                    playbackRate: viewModel.playbackRate,
                    restoreVisibleTimeSeconds: viewModel.timelineVisibleStartSeconds,
                            onSelect: viewModel.selectSegment,
                            onSeek: seekTimeline,
                            onRangeSelected: selectTimelineRange,
                            onPayloadDropped: { payload, insertionIndex in viewModel.handleDropPayload(payload, at: insertionIndex) },
                            onTrimBegin: { _ in viewModel.beginInteractiveEdit() },
                            onSegmentTrimStart: viewModel.updateSegmentStart,
                            onSegmentTrimEnd: viewModel.updateSegmentEnd
                )
                .frame(width: max(proxy.size.width, proxy.size.width * timelineZoomScale))
                .background {
                    GeometryReader { contentGeometry in
                        Color.clear.preference(key: RecordingTimelineScrollOffsetPreferenceKey.self, value: -contentGeometry.frame(in: .named("recording-timeline-scroll")).minX)
                    }
                }
            }
            .coordinateSpace(name: "recording-timeline-scroll")
            .scrollIndicators(.visible)
            .onPreferenceChange(RecordingTimelineScrollOffsetPreferenceKey.self) { offset in
                let contentWidth = max(1, proxy.size.width * timelineZoomScale)
                let visibleTime = Double(offset / contentWidth) * viewModel.outputDurationSeconds
                if abs(viewModel.timelineVisibleStartSeconds - visibleTime) > 0.02 {
                    viewModel.timelineVisibleStartSeconds = min(max(0, visibleTime), viewModel.outputDurationSeconds)
                }
            }
            .onAppear {
                scrollProxy.scrollTo("timeline-saved-position", anchor: .leading)
            }
                    .onChange(of: playheadSeconds) { _, _ in
                        guard isPlaying else { return }
                        scrollProxy.scrollTo("timeline-playhead", anchor: .center)
                    }
                    .onChange(of: timelineZoomScale) { _, _ in
                        scrollProxy.scrollTo("timeline-playhead", anchor: .center)
                    }
                }
            }
            .frame(height: 86)
            trimTimeFields
        }
        .padding(14)
        .modifier(LiquidGlassModifier(cornerRadius: 20))
    }

    private var trimTimeFields: some View {
        HStack(spacing: 10) {
            Text("Selected clip")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(0.62))
            if let selectedSegment = viewModel.selectedSegment {
                RecordingTrimTimeField(title: "In", seconds: selectedSegment.startSeconds) { seconds in
                    viewModel.beginInteractiveEdit()
                    viewModel.updateSelectedStart(seconds)
                }
                RecordingTrimTimeField(title: "Out", seconds: selectedSegment.endSeconds) { seconds in
                    viewModel.beginInteractiveEdit()
                    viewModel.updateSelectedEnd(seconds)
                }
                Text("Enter seconds or m:ss.xx")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.42))
            }
            Spacer(minLength: 0)
        }
    }

    private var browserPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "film.stack")
                    .foregroundStyle(RecordingsLayout.accent)
                Text("Browser")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(0.8)
                Spacer(minLength: 4)
                Text("\(viewModel.library.count)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.48))
            }

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
                TextField("Search media", text: $browserSearchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .accessibilityLabel("Search media browser")
            }
            .padding(.horizontal, 9)
            .frame(height: 30)
            .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            HStack(spacing: 6) {
                Image(systemName: "square.stack.3d.up.fill")
                    .foregroundStyle(RecordingsLayout.accent)
                Text("Recordings")
                    .foregroundStyle(.white.opacity(0.86))
                Spacer(minLength: 0)
                Text("ALL MEDIA")
                    .font(.system(size: 8, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(.white.opacity(0.42))
            }
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 4)
            .padding(.vertical, 3)

            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(spacing: 5) {
                    ForEach(filteredBrowserRecordings) { recording in
                        RecordingEditorBrowserClipRow(
                            recording: recording,
                            isSelected: selectedBrowserRecordingID == recording.id,
                            timelineUsesRecording: viewModel.segments.contains { $0.recording.id == recording.id },
                            onSelect: { selectedBrowserRecordingID = recording.id },
                            onAppend: { viewModel.appendRecording(recording) }
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .overlay {
                if filteredBrowserRecordings.isEmpty {
                    Text(viewModel.library.isEmpty ? "No recordings in library." : "No matching recordings.")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.48))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }

            Text("Drag a clip to the timeline or use + to append it.")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white.opacity(0.42))
                .lineLimit(2)
        }
        .padding(10)
        .modifier(LiquidGlassModifier(cornerRadius: 16))
        .accessibilityElement(children: .contain)
    }

    private var filteredBrowserRecordings: [WebRTCStreamRecording] {
        let query = browserSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return viewModel.library }
        return viewModel.library.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.applicationID.localizedCaseInsensitiveContains(query)
                || $0.fileName.localizedCaseInsensitiveContains(query)
        }
    }

    private var advancedDrawer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Inspector")
                .font(.system(size: 10, weight: .bold))
                .tracking(1.2)
                .foregroundStyle(RecordingsLayout.accent)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    ForEach(RecordingAdvancedEditorSection.allCases) { section in
                        Button {
                            advancedSection = section
                        } label: {
                            Text(section.title)
                                .font(.system(size: 10, weight: .semibold))
                                .lineLimit(1)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 6)
                                .background(advancedSection == section ? RecordingsLayout.accent.opacity(0.24) : Color.white.opacity(0.055), in: Capsule())
                                .overlay { Capsule().stroke(advancedSection == section ? RecordingsLayout.accent.opacity(0.45) : Color.white.opacity(0.10), lineWidth: 1) }
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(advancedSection == section ? .isSelected : [])
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 30)

            switch advancedSection {
            case .frame:
                framePanel
            case .audio:
                audioPanel
            case .color:
                colorPanel
            case .transcript:
                transcriptPanel
            case .overlays:
                overlaysPanel
            case .export:
                exportSettingsPanel
            }
        }
        .padding(14)
        .modifier(LiquidGlassModifier(cornerRadius: 20))
    }

    private var framePanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            editorPanel(title: "Crop") {
                Picker("Aspect", selection: Binding(
                    get: { viewModel.cropAspectPreset },
                    set: viewModel.setCropAspectPreset
                )) {
                    ForEach(RecordingEditorAspectPreset.allCases) { preset in
                        Text(preset.title).tag(preset)
                    }
                }
                .pickerStyle(.menu)
                Button(viewModel.isCropOverlayEditing ? "Finish Viewer Crop" : "Crop in Viewer") {
                    viewModel.isCropOverlayEditing.toggle()
                }
                if viewModel.isCropOverlayEditing {
                    Toggle("Safe area guides", isOn: $viewModel.showsSafeAreaGuides)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 10, weight: .medium))
                }
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 5), GridItem(.flexible(), spacing: 5), GridItem(.flexible(), spacing: 5)], alignment: .leading, spacing: 5) {
                    ForEach(RecordingEditorCropPreset.allCases) { preset in
                        smallButton(preset.title) { viewModel.applyCropPreset(preset) }
                    }
                }
                Toggle("Custom crop", isOn: Binding(
                    get: { viewModel.cropEnabled },
                    set: viewModel.setCropEnabled
                ))
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11, weight: .medium))
                if viewModel.cropEnabled {
                    compactSlider("X", value: $viewModel.cropX, range: 0...max(0, 1 - viewModel.cropWidth), valueText: String(format: "%.0f%%", viewModel.cropX * 100))
                    compactSlider("Y", value: $viewModel.cropY, range: 0...max(0, 1 - viewModel.cropHeight), valueText: String(format: "%.0f%%", viewModel.cropY * 100))
                    compactSlider("W", value: $viewModel.cropWidth, range: 0.1...max(0.1, 1 - viewModel.cropX), valueText: String(format: "%.0f%%", viewModel.cropWidth * 100))
                    compactSlider("H", value: $viewModel.cropHeight, range: 0.1...max(0.1, 1 - viewModel.cropY), valueText: String(format: "%.0f%%", viewModel.cropHeight * 100))
                }
            }
            editorPanel(title: "Orientation") {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 5), GridItem(.flexible(), spacing: 5)], alignment: .leading, spacing: 5) {
                    smallButton("Rotate Left") { viewModel.rotateLeft() }
                    smallButton("Rotate Right") { viewModel.rotateRight() }
                    smallButton(viewModel.isFlippedHorizontally ? "Unflip H" : "Flip H") { viewModel.toggleHorizontalFlip() }
                    smallButton(viewModel.isFlippedVertically ? "Unflip V" : "Flip V") { viewModel.toggleVerticalFlip() }
                }
            }
        }
    }

    private var audioPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            editorPanel(title: "Playback") {
                compactSlider("Speed", value: $viewModel.playbackRate, range: 0.25...4, valueText: String(format: "%.2fx", viewModel.playbackRate))
            }
            editorPanel(title: "Audio") {
                Text(viewModel.selectedSegment.map { "Clip: \($0.recording.title)" } ?? "No clip selected")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.58))
                Toggle("Mute selected clip", isOn: Binding(
                    get: { viewModel.selectedSegment?.isAudioMuted ?? false },
                    set: viewModel.setSelectedSegmentMuted
                ))
                .toggleStyle(.checkbox)
                .font(.system(size: 11, weight: .medium))
                compactSlider("Clip Gain", value: Binding(
                    get: { viewModel.selectedSegment?.audioGain ?? 1 },
                    set: viewModel.setSelectedSegmentAudioGain
                ), range: 0...8, valueText: String(format: "%.1fx", viewModel.selectedSegment?.audioGain ?? 1))
                    .disabled(viewModel.selectedSegment?.isAudioMuted ?? true)
                compactSlider("Clip Fade In", value: Binding(
                    get: { viewModel.selectedSegment?.fadeInSeconds ?? 0 },
                    set: viewModel.setSelectedSegmentFadeIn
                ), range: 0...10, valueText: String(format: "%.1fs", viewModel.selectedSegment?.fadeInSeconds ?? 0))
                    .disabled(viewModel.selectedSegment?.isAudioMuted ?? true)
                compactSlider("Clip Fade Out", value: Binding(
                    get: { viewModel.selectedSegment?.fadeOutSeconds ?? 0 },
                    set: viewModel.setSelectedSegmentFadeOut
                ), range: 0...10, valueText: String(format: "%.1fs", viewModel.selectedSegment?.fadeOutSeconds ?? 0))
                    .disabled(viewModel.selectedSegment?.isAudioMuted ?? true)
                Button {
                    Task { await viewModel.analyzeSelectedAudio() }
                } label: {
                    Label(viewModel.isAnalyzingAudio ? "Analyzing…" : "Analyze Clip Audio", systemImage: "waveform.path")
                }
                .disabled(viewModel.isAnalyzingAudio || viewModel.selectedSegment == nil)
                if let analysis = viewModel.audioAnalysis, analysis.segmentID == viewModel.selectedSegmentID {
                    Text("Peak analysis · proposed \(String(format: "%.2fx", analysis.result.normalizationGain)) gain toward a −1 dBFS ceiling")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.white.opacity(0.56))
                    Button("Apply Peak Normalization") { viewModel.normalizeSelectedAudio() }
                    Text("Silence suggestions: below −48 dBFS for at least 0.5 seconds")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.white.opacity(0.56))
                    ForEach(analysis.result.silenceRanges) { range in
                        Toggle(isOn: Binding(
                            get: { viewModel.selectedSilenceRangeIDs.contains(range.id) },
                            set: { isSelected in
                                if isSelected { viewModel.selectedSilenceRangeIDs.insert(range.id) }
                                else { viewModel.selectedSilenceRangeIDs.remove(range.id) }
                            }
                        )) {
                            Text("\(recordingEditorTimecode(range.startSeconds))–\(recordingEditorTimecode(range.endSeconds))")
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                        }
                        .toggleStyle(.checkbox)
                    }
                    if !analysis.result.silenceRanges.isEmpty {
                        Button("Remove Selected Silence") { viewModel.removeSelectedSilenceRanges() }
                            .disabled(viewModel.selectedSilenceRangeIDs.isEmpty)
                    }
                }
                Toggle("Mute audio", isOn: Binding(
                    get: { viewModel.isMuted },
                    set: viewModel.setMuted
                ))
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11, weight: .medium))
                compactSlider("Volume", value: $viewModel.volume, range: 0...2, valueText: "\(Int(viewModel.volume * 100))%")
                    .disabled(viewModel.isMuted)
                compactSlider("Fade In", value: $viewModel.fadeInSeconds, range: 0...10, valueText: String(format: "%.1fs", viewModel.fadeInSeconds))
                    .disabled(viewModel.isMuted)
                compactSlider("Fade Out", value: $viewModel.fadeOutSeconds, range: 0...10, valueText: String(format: "%.1fs", viewModel.fadeOutSeconds))
                    .disabled(viewModel.isMuted)
            }
        }
    }

    private var exportSettingsPanel: some View {
        editorPanel(title: "Output") {
            Picker("Resolution", selection: Binding(
                get: { viewModel.outputResolution },
                set: viewModel.setOutputResolution
            )) {
                Text("Source Match").tag(WebRTCStreamRecordingOutputResolution.source)
                Text("1080p MP4").tag(WebRTCStreamRecordingOutputResolution.p1080)
                Text("720p MP4").tag(WebRTCStreamRecordingOutputResolution.p720)
                Text("Up to 4K MP4").tag(WebRTCStreamRecordingOutputResolution.p4k).disabled(!viewModel.supports4KOutput)
            }
            .pickerStyle(.menu)
            let dimensions = viewModel.predictedOutputDimensions
            let sizeRange = viewModel.estimatedFileSizeRange
            Text("\(dimensions.width) × \(dimensions.height) · source frame rate · \(fileSizeText(sizeRange.lowerBound))–\(fileSizeText(sizeRange.upperBound)) estimated")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.58))
            HStack(spacing: 10) {
                Text("Quality")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.62))
                Picker("Quality", selection: $selectedExportQuality) {
                    ForEach(RecordingEditorExportQuality.allCases) { quality in
                        Text(quality.title).tag(quality)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
    }

    private var colorPanel: some View {
        editorPanel(title: "Color Adjustments") {
            compactSlider("Exposure", value: $viewModel.colorAdjustment.exposure, range: -4...4, valueText: String(format: "%.1f EV", viewModel.colorAdjustment.exposure))
            compactSlider("Contrast", value: $viewModel.colorAdjustment.contrast, range: 0...2, valueText: String(format: "%.2f", viewModel.colorAdjustment.contrast))
            compactSlider("Saturation", value: $viewModel.colorAdjustment.saturation, range: 0...2, valueText: String(format: "%.2f", viewModel.colorAdjustment.saturation))
            compactSlider("Temperature", value: $viewModel.colorAdjustment.temperature, range: -1...1, valueText: String(format: "%.2f", viewModel.colorAdjustment.temperature))
            compactSlider("Tint", value: $viewModel.colorAdjustment.tint, range: -1...1, valueText: String(format: "%.2f", viewModel.colorAdjustment.tint))
            compactSlider("Vignette", value: $viewModel.colorAdjustment.vignette, range: 0...1, valueText: String(format: "%.2f", viewModel.colorAdjustment.vignette))
            smallButton("Reset Color") { viewModel.resetColorAdjustments() }
        }
    }

    private var transcriptPanel: some View {
        editorPanel(title: "Transcript and Captions") {
            Button {
                Task { await viewModel.createTranscriptDraft() }
            } label: {
                Label(viewModel.isTranscribing ? "Transcribing…" : "Create Transcript", systemImage: "waveform")
            }
            .disabled(viewModel.isTranscribing)
            Button {
                Task { await viewModel.addOCRMarker(at: playheadSeconds) }
            } label: {
                Label("Read Screen Text at Playhead", systemImage: "text.viewfinder")
            }
            if let draftTranscript = viewModel.draftTranscript {
                Text("Draft · \(draftTranscript.segments.count) phrases · review before saving")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                Button("Save Transcript") { viewModel.approveTranscriptDraft() }
            }
            if let transcript = viewModel.transcript {
                HStack {
                    Text("\(transcript.language) · \(transcript.segments.count) phrases")
                    Spacer()
                    Button("Build Captions") { viewModel.createCaptionsFromTranscript() }
                    Button("Export SRT…") { exportSRT() }
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
                Toggle("Burn captions into video", isOn: $viewModel.burnInCaptions)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 10, weight: .medium))
                TextField("Search transcript", text: $transcriptSearchText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 10))
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(transcript.segments.filter { transcriptSearchText.isEmpty || $0.text.localizedCaseInsensitiveContains(transcriptSearchText) }) { phrase in
                            HStack(alignment: .top) {
                                Button {
                                    guard let timelineSeconds = viewModel.timelineSeconds(forSourceTime: phrase.startSeconds, recordingID: transcript.sourceRecordingID) else { return }
                                    onSeek(timelineSeconds)
                                } label: {
                                    HStack(alignment: .top) {
                                    Text(recordingEditorTimecode(phrase.startSeconds))
                                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                                    Text(phrase.text)
                                        .font(.system(size: 10, weight: .regular))
                                        .lineLimit(2)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .buttonStyle(.plain)
                                Button("Cut") { viewModel.cutTranscriptPhrase(phrase, recordingID: transcript.sourceRecordingID) }
                                    .font(.system(size: 9, weight: .semibold))
                                    .help("Remove this recognized phrase from the selected recording")
                            }
                        }
                    }
                }
                .frame(maxHeight: 120)
                if !viewModel.captions.isEmpty {
                    ForEach($viewModel.captions) { $caption in
                        HStack(spacing: 5) {
                            Text(recordingEditorTimecode(caption.startSeconds))
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                            TextField("Caption", text: $caption.text)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 10))
                            Button(role: .destructive) { viewModel.removeCaption(id: caption.id) } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            } else {
                Text("Recognition stays a draft until you save it. Captions can be edited before export.")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
    }

    private var overlaysPanel: some View {
        editorPanel(title: "Timed Overlays") {
            if let selectedSegment = viewModel.selectedSegment,
               selectedSegment.recording.pointerEvents?.isEmpty == false {
                Text("Cursor position and click metadata is available for this clip.")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.56))
                Button("Suggest Zooms from Clicks") {
                    viewModel.suggestZoomsFromSelectedPointerClicks()
                }
                .help("Create editable zoom keyframes around captured clicks in the selected clip")
                Button("Remove Captured Pointer Metadata", role: .destructive) {
                    viewModel.removeSelectedPointerMetadata()
                }
                .help("Remove cursor and click metadata from the recording sidecar")
            }
            if let selectedSegment = viewModel.selectedSegment, viewModel.selectedSegmentID != viewModel.segments.first?.id {
                Picker("Transition", selection: Binding(
                    get: { selectedSegment.transitionBefore },
                    set: viewModel.setSelectedTransition
                )) {
                    Text("Cut").tag(WebRTCStreamRecordingTransitionStyle.cut)
                    Text("Fade Through Black").tag(WebRTCStreamRecordingTransitionStyle.fadeThroughBlack)
                }
                .pickerStyle(.menu)
                if selectedSegment.transitionBefore == .fadeThroughBlack {
                    compactSlider("Fade", value: Binding(
                        get: { selectedSegment.transitionDurationSeconds },
                        set: viewModel.setSelectedTransitionDuration
                    ), range: 0.1...2, valueText: String(format: "%.1fs", selectedSegment.transitionDurationSeconds))
                }
            } else {
                Text("Select a clip after the first to set its incoming transition.")
                    .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
            }
            if !viewModel.zoomKeyframes.isEmpty {
                Text("Pointer Zoom Keyframes")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.82))
                ForEach(viewModel.zoomKeyframes) { keyframe in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            RecordingTrimTimeField(title: "Time", seconds: keyframe.timeSeconds) { seconds in
                                viewModel.beginInteractiveEdit()
                                var updated = keyframe
                                updated.timeSeconds = seconds
                                viewModel.updateZoomKeyframe(updated)
                            }
                            Spacer()
                            Button(role: .destructive) { viewModel.removeZoomKeyframe(id: keyframe.id) } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.plain)
                            .help("Remove zoom keyframe")
                        }
                        compactSlider("Center X", value: zoomKeyframeBinding(keyframe, keyPath: \.centerX), range: 0.2...0.8, valueText: "\(Int(keyframe.centerX * 100))%")
                        compactSlider("Center Y", value: zoomKeyframeBinding(keyframe, keyPath: \.centerY), range: 0.2...0.8, valueText: "\(Int(keyframe.centerY * 100))%")
                        compactSlider("Scale", value: zoomKeyframeBinding(keyframe, keyPath: \.scale), range: 1...2.5, valueText: String(format: "%.1fx", keyframe.scale))
                    }
                    .padding(7)
                    .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            HStack(spacing: 6) {
                Button("Callout") { viewModel.addOverlay(kind: .callout, at: playheadSeconds) }
                Button("Redact") { viewModel.addOverlay(kind: .redaction, at: playheadSeconds) }
                Button("Blur") { viewModel.addOverlay(kind: .blur, at: playheadSeconds) }
            }
            .font(.system(size: 10, weight: .semibold))
            Text("Overlays render only during their time range and never change the source recording.")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white.opacity(0.56))
            if viewModel.overlays.isEmpty {
                Text("No overlays yet.")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
            }
            ForEach(viewModel.overlays) { overlay in
                overlayEditor(overlay)
            }
        }
    }

    private func overlayEditor(_ overlay: RecordingEditorOverlay) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(overlay.kind.title)
                    .font(.system(size: 10, weight: .bold))
                Spacer()
                Button(role: .destructive) { viewModel.removeOverlay(id: overlay.id) } label: {
                    Image(systemName: "trash")
                }
                .help("Remove overlay")
            }
            if overlay.kind == .callout {
                TextField("Callout text", text: Binding(
                    get: { overlay.text },
                    set: { text in var updated = overlay; updated.text = text; viewModel.updateOverlay(updated) }
                ), onEditingChanged: { isEditing in if isEditing { viewModel.beginInteractiveEdit() } })
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 10))
            }
            HStack(spacing: 6) {
                RecordingTrimTimeField(title: "In", seconds: overlay.startSeconds) { seconds in
                    viewModel.beginInteractiveEdit()
                    var updated = overlay
                    updated.startSeconds = seconds
                    viewModel.updateOverlay(updated)
                }
                RecordingTrimTimeField(title: "Out", seconds: overlay.endSeconds) { seconds in
                    viewModel.beginInteractiveEdit()
                    var updated = overlay
                    updated.endSeconds = seconds
                    viewModel.updateOverlay(updated)
                }
            }
            compactSlider("X", value: overlayBinding(overlay, keyPath: \.x), range: 0...max(0, 1 - overlay.width), valueText: "\(Int(overlay.x * 100))%")
            compactSlider("Y", value: overlayBinding(overlay, keyPath: \.y), range: 0...max(0, 1 - overlay.height), valueText: "\(Int(overlay.y * 100))%")
            compactSlider("Width", value: overlayBinding(overlay, keyPath: \.width), range: 0.05...max(0.05, 1 - overlay.x), valueText: "\(Int(overlay.width * 100))%")
            compactSlider("Height", value: overlayBinding(overlay, keyPath: \.height), range: 0.05...max(0.05, 1 - overlay.y), valueText: "\(Int(overlay.height * 100))%")
        }
        .padding(8)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }

    private func overlayBinding(_ overlay: RecordingEditorOverlay, keyPath: WritableKeyPath<RecordingEditorOverlay, Double>) -> Binding<Double> {
        Binding(
            get: { overlay[keyPath: keyPath] },
            set: { value in var updated = overlay; updated[keyPath: keyPath] = value; viewModel.updateOverlay(updated) }
        )
    }

    private func zoomKeyframeBinding(_ keyframe: RecordingEditorZoomKeyframe, keyPath: WritableKeyPath<RecordingEditorZoomKeyframe, Double>) -> Binding<Double> {
        Binding(
            get: { keyframe[keyPath: keyPath] },
            set: { value in var updated = keyframe; updated[keyPath: keyPath] = value; viewModel.updateZoomKeyframe(updated) }
        )
    }

    private func exportSRT() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "srt") ?? .plainText]
        panel.nameFieldStringValue = viewModel.outputTitle + ".srt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Data(viewModel.srtContents().utf8).write(to: url, options: .atomic)
        } catch {
            viewModel.errorMessage = "The SRT file could not be saved: \(error.localizedDescription)"
        }
    }

    private var exportBar: some View {
        HStack(spacing: 10) {
            if viewModel.isExporting {
                ProgressView(value: viewModel.exportProgress)
                    .progressViewStyle(.linear)
                    .frame(width: 180)
                Text("Exporting \(Int(viewModel.exportProgress * 100))%")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.68))
                Button("Cancel Export") {
                    viewModel.cancelExport()
                    exportTask?.cancel()
                    exportTask = nil
                }
                .buttonStyle(RecordingActionButtonStyle(tone: .secondary))
            } else if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.red.opacity(0.88))
                    .lineLimit(1)
            } else {
                Text("MP4 · \(outputResolutionTitle) · \(recordingEditorDurationText(viewModel.outputDurationSeconds)) · source stays unchanged")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.52))
            }
            Spacer(minLength: 0)
            if let exportedCopyURL {
                Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([exportedCopyURL]) }
                    .help("Reveal the exported copy in Finder")
                ShareLink(item: exportedCopyURL) { Label("Share", systemImage: "square.and.arrow.up") }
            }
            Button("Export Copy…") { beginExportCopy() }
                .disabled(!viewModel.canExport)
                .buttonStyle(RecordingActionButtonStyle(tone: .secondary))
            Button("Export to Library") { startExport() }
                .disabled(!viewModel.canExport)
                .buttonStyle(RecordingActionButtonStyle(tone: .primary))
                .keyboardShortcut("e", modifiers: .command)
        }
    }

    private var outputResolutionTitle: String {
        switch viewModel.outputResolution {
        case .source: "Source Match"
        case .p720: "720p"
        case .p1080: "1080p"
        case .p4k: "4K"
        }
    }

    private func fileSizeText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func seekTimeline(_ timelineSeconds: Double) {
        guard let target = viewModel.sourceTime(forOutputSeconds: timelineSeconds) else { return }
        viewModel.selectSegment(target.segment)
        onSeek(timelineSeconds)
    }

    private func applyAtSourcePlayhead(_ action: (Double) -> Void) {
        guard let target = viewModel.sourceTime(forOutputSeconds: playheadSeconds) else { return }
        if viewModel.selectedSegmentID != target.segment.id {
            viewModel.selectSegment(target.segment)
        }
        action(target.seconds)
    }

    private func selectTimelineRange(startSeconds: Double, endSeconds: Double) {
        guard let start = viewModel.sourceTime(forOutputSeconds: min(startSeconds, endSeconds)),
              let end = viewModel.sourceTime(forOutputSeconds: max(startSeconds, endSeconds)) else { return }
        viewModel.selectSegment(start.segment)
        if start.segment.id == end.segment.id {
            viewModel.markInSeconds = min(start.seconds, end.seconds)
            viewModel.markOutSeconds = max(start.seconds, end.seconds)
        } else {
            viewModel.markInSeconds = start.seconds
            viewModel.markOutSeconds = start.segment.endSeconds
        }
    }

    private func startExport() {
        viewModel.errorMessage = nil
        exportTask = Task {
            do {
                let recording = try await viewModel.export()
                exportTask = nil
                onSaved(recording)
            } catch {
                exportTask = nil
            }
        }
    }

    private func beginExportCopy() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = viewModel.outputTitle.trimmingCharacters(in: .whitespacesAndNewlines) + ".mp4"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destinationURL = panel.url else { return }
        exportTask = Task {
            do {
                exportedCopyURL = try await viewModel.exportCopy(to: destinationURL)
                exportTask = nil
            } catch {
                exportTask = nil
            }
        }
    }

    private func relinkMissingMedia(_ missingID: UUID) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .mpeg4Movie]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let sourceURL = panel.url else { return }
        Task { await viewModel.relinkMissingRecording(missingID, from: sourceURL) }
    }

    private func editorPanel<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 9, weight: .bold))
                .tracking(1.1)
                .foregroundStyle(RecordingsLayout.accent.opacity(0.82))
            content()
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(12)
        .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.white.opacity(0.10), lineWidth: 1) }
    }

    private func compactSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, valueText: String? = nil) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.62))
                .frame(width: 60, alignment: .leading)
                .lineLimit(1)
            Slider(value: value, in: range, onEditingChanged: { isEditing in
                if isEditing { viewModel.beginInteractiveEdit() }
            })
                .tint(RecordingsLayout.accent)
            if let valueText {
                Text(valueText)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.78))
                    .frame(width: 52, alignment: .trailing)
                    .lineLimit(1)
            }
        }
    }

    private func smallButton(_ title: String, isDisabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.white.opacity(0.86))
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.white.opacity(0.11), lineWidth: 1) }
            .buttonStyle(.plain)
            .disabled(viewModel.isExporting || isDisabled)
    }

}

private struct RecordingEditorBrowserClipRow: View {
    let recording: WebRTCStreamRecording
    let isSelected: Bool
    let timelineUsesRecording: Bool
    let onSelect: () -> Void
    let onAppend: () -> Void

    @State private var thumbnail: NSImage?

    var body: some View {
        HStack(spacing: 7) {
            Button(action: onSelect) {
                HStack(spacing: 8) {
                    thumbnailView
                    VStack(alignment: .leading, spacing: 3) {
                        Text(recording.title)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.92))
                            .lineLimit(1)
                        Text("\(recordingEditorDurationText(recording.durationSeconds)) · \(recording.width) × \(recording.height)")
                            .font(.system(size: 8, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.54))
                            .lineLimit(1)
                        if timelineUsesRecording {
                            Text("IN TIMELINE")
                                .font(.system(size: 7, weight: .bold))
                                .tracking(0.5)
                                .foregroundStyle(RecordingsLayout.accent)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(recording.title), \(recordingEditorDurationText(recording.durationSeconds))")

            Button(action: onAppend) {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.78))
                    .frame(width: 25, height: 25)
                    .background(Color.white.opacity(0.075), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)
            .help("Append recording to timeline")
            .accessibilityLabel("Append \(recording.title) to timeline")
        }
        .padding(5)
        .background(isSelected ? RecordingsLayout.accent.opacity(0.15) : Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(isSelected ? RecordingsLayout.accent.opacity(0.48) : Color.white.opacity(0.06), lineWidth: 1)
        }
        .draggable(RecordingEditorDragPayload.recording(recording.id).stringValue)
        .task(id: recording.id) {
            thumbnail = await RecordingEditorBrowserThumbnailCache.thumbnail(for: recording)
        }
    }

    private var thumbnailView: some View {
        Group {
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Color.black.opacity(0.36)
                    Image(systemName: "film")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
        }
        .frame(width: 74, height: 42)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay(alignment: .bottomTrailing) {
            Text("\(recordingEditorDurationText(recording.durationSeconds))")
                .font(.system(size: 7, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 3, style: .continuous))
                .padding(3)
        }
    }
}

@MainActor
private enum RecordingEditorBrowserThumbnailCache {
    private static let cache = NSCache<NSString, NSImage>()

    static func thumbnail(for recording: WebRTCStreamRecording) async -> NSImage? {
        let key = recording.id.uuidString as NSString
        if let cachedImage = cache.object(forKey: key) { return cachedImage }
        guard FileManager.default.fileExists(atPath: recording.videoURL.path) else { return nil }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: recording.videoURL))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 240, height: 136)
        let sampleTime = CMTime(seconds: min(max(recording.durationSeconds * 0.15, 0.1), max(recording.durationSeconds - 0.1, 0.1)), preferredTimescale: 600)
        do {
            let result = try await generator.image(at: sampleTime)
            let image = NSImage(cgImage: result.image, size: .zero)
            cache.setObject(image, forKey: key)
            return image
        } catch {
            return nil
        }
    }
}

private struct RecordingTrimTimeField: View {
    let title: String
    let seconds: Double
    let onCommit: (Double) -> Void
    @State private var text: String

    init(title: String, seconds: Double, onCommit: @escaping (Double) -> Void) {
        self.title = title
        self.seconds = seconds
        self.onCommit = onCommit
        _text = State(initialValue: Self.formattedTime(seconds))
    }

    var body: some View {
        HStack(spacing: 5) {
            Text(title)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white.opacity(0.5))
            TextField("0:00.00", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.94))
                .frame(width: 68)
                .onSubmit(commit)
                .onChange(of: seconds) { _, value in text = Self.formattedTime(value) }
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(RecordingsLayout.stroke, lineWidth: 1) }
        .help("Enter seconds or minutes:seconds.hundredths")
    }

    private func commit() {
        guard let value = Self.parseTime(text), value.isFinite else {
            text = Self.formattedTime(seconds)
            return
        }
        onCommit(max(0, value))
    }

    private static func parseTime(_ value: String) -> Double? {
        let parts = value.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":", omittingEmptySubsequences: false)
        if parts.count == 1 { return Double(parts[0]) }
        guard parts.count == 2,
              let minutes = Double(parts[0]),
              let seconds = Double(parts[1]),
              minutes >= 0,
              seconds >= 0,
              seconds < 60 else { return nil }
        return minutes * 60 + seconds
    }

    private static func formattedTime(_ value: Double) -> String {
        let boundedValue = max(0, value.isFinite ? value : 0)
        let minutes = Int(boundedValue / 60)
        return String(format: "%d:%05.2f", minutes, boundedValue - Double(minutes * 60))
    }
}
