import AVKit
import SwiftUI

private enum RecordingAdvancedEditorSection: String, CaseIterable, Identifiable {
    case arrange
    case frame
    case audio
    case export

    var id: String { rawValue }

    var title: String {
        switch self {
        case .arrange: return "Arrange"
        case .frame: return "Frame"
        case .audio: return "Audio"
        case .export: return "Export"
        }
    }
}

struct RecordingEditorView: View {
    @ObservedObject var viewModel: RecordingEditorViewModel
    let player: AVPlayer
    let playheadSeconds: Double
    let onSeek: (Double) -> Void
    let onCancel: () -> Void
    let onSaved: (WebRTCStreamRecording) -> Void
    let onPreviewChanged: () -> Void

    @State private var exportTask: Task<Void, Never>?
    @State private var showsAdvanced = false
    @State private var advancedSection: RecordingAdvancedEditorSection = .arrange

    var body: some View {
        GeometryReader { geometry in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    previewCard(height: min(max(geometry.size.height * 0.38, 245), 390))
                    timelineCard
                    quickActions
                    if showsAdvanced { advancedDrawer }
                    exportBar
                }
                .frame(maxWidth: 1420, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .top)
                .padding(.horizontal, 42)
                .padding(.top, 98)
                .padding(.bottom, 32)
            }
        }
        .onChange(of: viewModel.previewSignature) { _, _ in onPreviewChanged() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("VIDEO EDITOR")
                        .font(.system(size: 11, weight: .bold))
                        .tracking(1.5)
                        .foregroundStyle(RecordingsLayout.accent)
                    Text("Shape your next highlight")
                        .font(.system(size: 25, weight: .bold))
                        .foregroundStyle(.white)
                }
                Spacer(minLength: 12)
                Button { viewModel.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                    .disabled(!viewModel.canUndo || viewModel.isExporting)
                    .buttonStyle(RecordingActionButtonStyle(tone: .secondary))
                Button { viewModel.redo() } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
                    .disabled(!viewModel.canRedo || viewModel.isExporting)
                    .buttonStyle(RecordingActionButtonStyle(tone: .secondary))
                Button(showsAdvanced ? "Hide Advanced" : "Advanced") { showsAdvanced.toggle() }
                    .disabled(viewModel.isExporting)
                    .buttonStyle(RecordingActionButtonStyle(tone: .secondary))
                Button("Close", action: onCancel)
                    .disabled(viewModel.isExporting)
                    .buttonStyle(RecordingActionButtonStyle(tone: .secondary))
            }
            HStack(spacing: 12) {
                Image(systemName: "pencil.line")
                    .foregroundStyle(RecordingsLayout.accent)
                TextField("New clip title", text: $viewModel.outputTitle)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.95))
                Text("Export will save a new video")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .padding(.horizontal, 14)
            .frame(height: 42)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(RecordingsLayout.stroke, lineWidth: 1) }
        }
        .padding(18)
        .modifier(LiquidGlassModifier(cornerRadius: 22))
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
            RecordingPlayerView(player: player)
                .frame(maxWidth: .infinity)
                .frame(height: height)
                .background(Color.black, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.white.opacity(0.10), lineWidth: 1) }
        }
        .padding(16)
        .modifier(LiquidGlassModifier(cornerRadius: 22))
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
            }
            RecordingTimelineView(
                segments: viewModel.segments,
                selectedSegmentID: viewModel.selectedSegmentID,
                playheadSeconds: sourceTimelinePlayheadSeconds,
                markInSeconds: viewModel.markInSeconds,
                markOutSeconds: viewModel.markOutSeconds,
                onSelect: viewModel.selectSegment,
                onSeek: seekTimeline,
                onRangeSelected: selectTimelineRange,
                onPayloadDropped: { payload, insertionIndex in viewModel.handleDropPayload(payload, at: insertionIndex) },
                onTrimBegin: { _ in viewModel.beginInteractiveEdit() },
                onSegmentTrimStart: viewModel.updateSegmentStart,
                onSegmentTrimEnd: viewModel.updateSegmentEnd
            )
        }
        .padding(14)
        .modifier(LiquidGlassModifier(cornerRadius: 20))
    }

    private var quickActions: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 8)], alignment: .leading, spacing: 8) {
            quickButton("Trim Start", systemImage: "arrow.left.to.line") { applyAtSourcePlayhead(viewModel.trimStartToPlayhead) }
            quickButton("Trim End", systemImage: "arrow.right.to.line") { applyAtSourcePlayhead(viewModel.trimEndToPlayhead) }
            quickButton("Split", systemImage: "scissors") { applyAtSourcePlayhead(viewModel.splitAtPlayhead) }
            quickButton("Join", systemImage: "link", isDisabled: !viewModel.canJoinSelectedSection) { viewModel.joinSelectedSection() }
            quickButton("Set In", systemImage: "bracket.left") { applyAtSourcePlayhead(viewModel.markIn) }
            quickButton("Set Out", systemImage: "bracket.right") { applyAtSourcePlayhead(viewModel.markOut) }
            quickButton("Remove Selection", systemImage: "trash", isDisabled: !viewModel.canCutMarkedRange) { viewModel.cutMarkedRange() }
            Button("Reset Edits") { viewModel.resetEdits() }
                .disabled(viewModel.isExporting)
                .buttonStyle(RecordingActionButtonStyle(tone: .secondary))
        }
        .padding(14)
        .modifier(LiquidGlassModifier(cornerRadius: 20))
    }

    private var advancedDrawer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Advanced section", selection: $advancedSection) {
                ForEach(RecordingAdvancedEditorSection.allCases) { section in
                    Text(section.title).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch advancedSection {
            case .arrange:
                arrangePanel
            case .frame:
                framePanel
            case .audio:
                audioPanel
            case .export:
                exportSettingsPanel
            }
        }
        .padding(14)
        .modifier(LiquidGlassModifier(cornerRadius: 20))
    }

    private var arrangePanel: some View {
        HStack(alignment: .top, spacing: 10) {
            editorPanel(title: "Selected Clip") {
                HStack(spacing: 7) {
                    smallButton("Duplicate") { viewModel.duplicateSelectedSegment() }
                    smallButton("Remove") { viewModel.removeSelectedSegment() }
                    smallButton("Join", isDisabled: !viewModel.canJoinSelectedSection) { viewModel.joinSelectedSection() }
                    smallButton("Move Left") { viewModel.moveSelectedSegment(offset: -1) }
                    smallButton("Move Right") { viewModel.moveSelectedSegment(offset: 1) }
                }
            }
            editorPanel(title: "Add Clip") {
                if viewModel.library.isEmpty {
                    Text("No other recordings in library.")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.40))
                } else {
                    Menu {
                        ForEach(viewModel.library) { recording in
                            Button("\(recording.title) · \(recordingEditorDurationText(recording.durationSeconds))") {
                                viewModel.appendRecording(recording)
                            }
                        }
                    } label: {
                        menuLabel("Append Recording", systemImage: "plus.rectangle.on.rectangle")
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var framePanel: some View {
        HStack(alignment: .top, spacing: 10) {
            editorPanel(title: "Crop") {
                HStack(spacing: 7) {
                    ForEach(RecordingEditorCropPreset.allCases) { preset in
                        smallButton(preset.title) { viewModel.applyCropPreset(preset) }
                    }
                }
                Toggle("Custom crop", isOn: $viewModel.cropEnabled)
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
                HStack(spacing: 7) {
                    smallButton("Rotate Left") { viewModel.rotateLeft() }
                    smallButton("Rotate Right") { viewModel.rotateRight() }
                    smallButton(viewModel.isFlippedHorizontally ? "Unflip H" : "Flip H") { viewModel.toggleHorizontalFlip() }
                    smallButton(viewModel.isFlippedVertically ? "Unflip V" : "Flip V") { viewModel.toggleVerticalFlip() }
                }
            }
        }
    }

    private var audioPanel: some View {
        HStack(alignment: .top, spacing: 10) {
            editorPanel(title: "Playback") {
                compactSlider("Speed", value: $viewModel.playbackRate, range: 0.25...4, valueText: String(format: "%.2fx", viewModel.playbackRate))
            }
            editorPanel(title: "Audio") {
                Toggle("Mute audio", isOn: $viewModel.isMuted)
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
            HStack(spacing: 10) {
                Text("Quality")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.62))
                Picker("Quality", selection: $viewModel.exportQuality) {
                    ForEach(RecordingEditorExportQuality.allCases) { quality in
                        Text(quality.title).tag(quality)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
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
                Text("Edits are non-destructive. Export creates a new recording.")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.52))
            }
            Spacer(minLength: 0)
            Button("Save as New Video") { startExport() }
                .disabled(!viewModel.canExport)
                .buttonStyle(RecordingActionButtonStyle(tone: .primary))
        }
    }

    private var sourceTimelinePlayheadSeconds: Double {
        playheadSeconds * max(0.25, viewModel.playbackRate)
    }

    private func seekTimeline(_ timelineSeconds: Double) {
        guard let target = viewModel.sourceTime(forTimelineSeconds: timelineSeconds) else { return }
        viewModel.selectSegment(target.segment)
        onSeek(timelineSeconds / max(0.25, viewModel.playbackRate))
    }

    private func applyAtSourcePlayhead(_ action: (Double) -> Void) {
        guard let target = viewModel.sourceTime(forTimelineSeconds: sourceTimelinePlayheadSeconds) else { return }
        if viewModel.selectedSegmentID != target.segment.id {
            viewModel.selectSegment(target.segment)
        }
        action(target.seconds)
    }

    private func selectTimelineRange(startSeconds: Double, endSeconds: Double) {
        guard let start = viewModel.sourceTime(forTimelineSeconds: min(startSeconds, endSeconds)),
              let end = viewModel.sourceTime(forTimelineSeconds: max(startSeconds, endSeconds)) else { return }
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
            Slider(value: value, in: range)
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

    private func quickButton(_ title: String, systemImage: String, isDisabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                Text(title)
            }
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.white.opacity(0.88))
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(Color.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(Color.white.opacity(0.12), lineWidth: 1) }
        }
        .buttonStyle(.plain)
        .disabled(viewModel.isExporting || isDisabled)
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

    private func menuLabel(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
            Text(title)
        }
        .font(.system(size: 11, weight: .bold))
        .foregroundStyle(.white.opacity(0.88))
        .frame(maxWidth: .infinity)
        .frame(height: 30)
        .background(Color.white.opacity(0.075), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.white.opacity(0.12), lineWidth: 1) }
    }
}
