import AppKit
import AVKit
import SwiftUI

enum RecordingsLayout {
    static let sidebar = Color(red: 0.035, green: 0.043, blue: 0.078)
    static let surface = Color(red: 0.035, green: 0.043, blue: 0.078)
    static let card = Color.white.opacity(0.075)
    static let raised = Color.white.opacity(0.12)
    static let stroke = Color.white.opacity(0.12)
    static let strongStroke = Color.white.opacity(0.2)
    static let accent = Color.pixelNowBlue
    static let danger = Color(red: 1, green: 78 / 255, blue: 78 / 255)
}

struct RecordingsView: View {
    @State private var recordings: [WebRTCStreamRecording] = []
    @State private var selectedRecording: WebRTCStreamRecording?
    @State private var player: AVPlayer?
    @State private var message = ""
    @State private var pendingDelete: WebRTCStreamRecording?
    @State private var searchText = ""
    @State private var sortOrder: RecordingSortOrder = .newest
    @State private var activeFilters = Set<RecordingFilter>()
    @State private var copiedPathRecordingID: UUID?
    @State private var editorViewModel: RecordingEditorViewModel?
    @State private var playerTimeSeconds = 0.0
    @State private var playerTimeObserver: Any?
    @State private var editorPreviewTask: Task<Void, Never>?
    @State private var editorPreviewDurationSeconds = 0.0

    private var visibleRecordings: [WebRTCStreamRecording] {
        let normalizedQuery = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return recordings
            .filter { recording in
                guard !normalizedQuery.isEmpty else { return true }
                return recording.title.lowercased().contains(normalizedQuery)
                    || recording.applicationID.lowercased().contains(normalizedQuery)
                    || recording.videoURL.lastPathComponent.lowercased().contains(normalizedQuery)
            }
            .filter { recording in
                activeFilters.allSatisfy { $0.matches(recording) }
            }
            .sorted(using: sortOrder)
    }

    private var stats: RecordingLibraryStats {
        RecordingLibraryStats(recordings: recordings)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                PixelPatternBackground()
                    .ignoresSafeArea()

                if let editorViewModel, let player {
                    RecordingEditorView(
                        viewModel: editorViewModel,
                        player: player,
                        playheadSeconds: playerTimeSeconds,
                        onSeek: seekEditorPreview,
                        onCancel: closeEditor,
                        onSaved: editedRecordingSaved,
                        onPreviewChanged: { refreshEditedPreview(debounce: true) }
                    )
                    .frame(width: proxy.size.width, height: proxy.size.height)
                } else {
                    recordingsWorkspace(size: proxy.size)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                }
            }
        }
        .onAppear { reload(showMessage: false) }
        .onChange(of: visibleRecordings.map(\.id)) { _, ids in
            guard let selectedRecording, !ids.contains(selectedRecording.id) else { return }
            select(visibleRecordings.first, autoplay: false)
        }
        .confirmationDialog(deleteDialogTitle, isPresented: deleteDialogPresented) {
            Button("Delete Recording", role: .destructive) { deletePendingRecording() }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("This permanently removes the video file and metadata from PixelNOW recordings.")
        }
        .onDisappear {
            cancelEditorPreview()
            removePlayerTimeObserver()
        }
    }

    @ViewBuilder
    private func recordingsWorkspace(size: CGSize) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            libraryHeader
            HStack(spacing: 12) {
                RecordingSearchField(text: $searchText)
                    .frame(maxWidth: 420)
                Spacer(minLength: 12)
                sortMenu
                Text("\(visibleRecordings.count) shown")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.62))
                    .lineLimit(1)
            }
            sortAndFilters

            if recordings.isEmpty {
                RecordingEmptyState(kind: .library, action: { reload(showMessage: true) })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .modifier(LiquidGlassModifier(cornerRadius: 24))
            } else if visibleRecordings.isEmpty {
                RecordingEmptyState(kind: .search, action: clearSearchAndFilters)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .modifier(LiquidGlassModifier(cornerRadius: 24))
            } else if size.width >= 1100 {
                HStack(alignment: .top, spacing: 18) {
                    ScrollView(.vertical, showsIndicators: false) {
                        recordingsGrid(minimumCardWidth: 190)
                            .padding(.bottom, 24)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    playerPane
                        .frame(width: Design.clamped(size.width * 0.34, minimum: 340, maximum: 470))
                        .frame(maxHeight: .infinity)
                }
                .frame(maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 18) {
                        recordingsGrid(minimumCardWidth: 190)
                        playerPane
                            .frame(minHeight: 420)
                    }
                    .padding(.bottom, 32)
                }
            }
        }
        .padding(.horizontal, 42)
        .padding(.top, 104)
        .padding(.bottom, 28)
        .frame(maxWidth: 1560, maxHeight: .infinity, alignment: .topLeading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func recordingsGrid(minimumCardWidth: CGFloat) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: minimumCardWidth), spacing: 16)], spacing: 16) {
            ForEach(visibleRecordings) { recording in
                RecordingRow(recording: recording, isSelected: selectedRecording?.id == recording.id) {
                    select(recording, autoplay: true)
                }
                .contextMenu {
                    Button("Open Recording") { open(recording) }
                    Button("Edit Recording") { startEditing(recording) }
                    Button("Reveal in Finder") { reveal(recording) }
                    Button("Copy File Path") { copyPath(recording) }
                    Divider()
                    Button("Delete", role: .destructive) { pendingDelete = recording }
                }
            }
        }
    }

    private var libraryHeader: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text("SAVED VIDEOS")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(1.5)
                    .foregroundStyle(Color.pixelNowBlue)
                Text("Recordings")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(.white)
                Text(stats.subtitle == "Gameplay capture library" ? "Your gameplay captures, ready to replay or edit." : stats.subtitle)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.66))
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            HStack(spacing: 8) {
                RecordingMetric(title: "VIDEOS", value: "\(recordings.count)")
                RecordingMetric(title: "RUNTIME", value: durationText(stats.totalDurationSeconds))
                RecordingMetric(title: "SIZE", value: compactFileSizeText(stats.totalBytes))
            }
            Button { reload(showMessage: true) } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.88))
                    .frame(width: 40, height: 40)
                    .background(Color.white.opacity(0.11), in: Circle())
                    .overlay { Circle().stroke(RecordingsLayout.stroke, lineWidth: 1) }
            }
            .buttonStyle(.plain)
            .help("Refresh recordings")
        }
    }

    private var sortAndFilters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(RecordingFilter.allCases) { filter in
                    RecordingFilterChip(filter: filter, isActive: activeFilters.contains(filter)) {
                        toggleFilter(filter)
                    }
                }
            }
        }
    }

    private var sortMenu: some View {
        Menu {
            ForEach(RecordingSortOrder.allCases) { order in
                Button(order.title) { sortOrder = order }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.up.arrow.down")
                Text(sortOrder.title)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 14)
            .frame(height: 40)
            .background(Color.white.opacity(0.085), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(RecordingsLayout.stroke, lineWidth: 1) }
        }
        .buttonStyle(.plain)
    }

    private var playerPane: some View {
        Group {
            if let selectedRecording, let player {
                selectedPlayer(recording: selectedRecording, player: player)
            } else {
                RecordingEmptyPlayer(message: message)
            }
        }
    }

    private func selectedPlayer(recording: WebRTCStreamRecording, player: AVPlayer) -> some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                RecordingPlayerView(player: player)
                    .background(Color.black)
                    .overlay(alignment: .top) {
                        LinearGradient(colors: [.black.opacity(0.62), .black.opacity(0.00)], startPoint: .top, endPoint: .bottom)
                            .frame(height: 120)
                    }
                    .overlay(alignment: .bottom) {
                        LinearGradient(colors: [.black.opacity(0.00), .black.opacity(0.58)], startPoint: .top, endPoint: .bottom)
                            .frame(height: 140)
                    }
                    .onAppear { player.play() }

                RecordingNowPlayingBadge(recording: recording)
                    .padding(22)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay { Rectangle().stroke(Color.black.opacity(0.72), lineWidth: 1) }

            RecordingInspector(
                recording: recording,
                copiedPath: copiedPathRecordingID == recording.id,
                message: message,
                onRestart: { restart(recording) },
                onEdit: { startEditing(recording) },
                onOpen: { open(recording) },
                onReveal: { reveal(recording) },
                onCopyPath: { copyPath(recording) },
                onDelete: { pendingDelete = recording }
            )
        }
        .modifier(LiquidGlassModifier(cornerRadius: 24))
        .padding(1)
    }

    private var deleteDialogPresented: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }

    private var deleteDialogTitle: String {
        guard let pendingDelete else { return "Delete recording?" }
        return "Delete \"\(pendingDelete.title)\"?"
    }

    private func reload(showMessage: Bool) {
        recordings = WebRTCStreamRecordingLibrary.loadRecordings()
        if let selectedRecording, let refreshed = recordings.first(where: { $0.id == selectedRecording.id }) {
            self.selectedRecording = refreshed
            if player == nil { select(refreshed, autoplay: false) }
        } else {
            select(visibleRecordings.first, autoplay: false)
        }
        if showMessage {
            message = recordings.isEmpty ? "No recordings found in your GeForce NOW movies folder." : "Loaded \(recordings.count) recording\(recordings.count == 1 ? "" : "s")."
        }
    }

    private func select(_ recording: WebRTCStreamRecording?, autoplay: Bool) {
        removePlayerTimeObserver()
        if let recording, editorViewModel?.primaryRecording.id != recording.id {
            cancelEditorPreview()
            editorViewModel = nil
        }
        selectedRecording = recording
        guard let recording else {
            cancelEditorPreview()
            player?.pause()
            player = nil
            playerTimeSeconds = 0
            return
        }
        player?.pause()
        let nextPlayer = AVPlayer(url: recording.videoURL)
        player = nextPlayer
        playerTimeSeconds = 0
        playerTimeObserver = nextPlayer.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.2, preferredTimescale: 600), queue: .main) { time in
            let seconds = max(0, time.seconds.isFinite ? time.seconds : 0)
            MainActor.assumeIsolated {
                playerTimeSeconds = seconds
                syncEditorSelectionForPreviewTime(seconds)
            }
        }
        if autoplay { nextPlayer.play() }
    }

    private func restart(_ recording: WebRTCStreamRecording) {
        if editorViewModel?.primaryRecording.id == recording.id {
            seekEditorPreview(seconds: 0)
            player?.play()
            return
        }
        guard selectedRecording?.id == recording.id else {
            select(recording, autoplay: true)
            return
        }
        player?.seek(to: .zero)
        player?.play()
    }

    private func seek(_ recording: WebRTCStreamRecording, seconds: Double) {
        guard selectedRecording?.id == recording.id else { return }
        let time = CMTime(seconds: min(max(0, seconds), max(0, recording.durationSeconds)), preferredTimescale: 600)
        player?.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        playerTimeSeconds = max(0, time.seconds)
    }

    private func seekEditorPreview(seconds: Double) {
        guard editorViewModel != nil else {
            if let selectedRecording { seek(selectedRecording, seconds: seconds) }
            return
        }
        let duration = editorPreviewDurationSeconds > 0 ? editorPreviewDurationSeconds : max(0, editorViewModel?.outputDurationSeconds ?? seconds)
        let boundedSeconds = min(max(0, seconds), duration)
        let time = CMTime(seconds: boundedSeconds, preferredTimescale: 600)
        player?.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        playerTimeSeconds = boundedSeconds
        syncEditorSelectionForPreviewTime(boundedSeconds)
    }

    private func startEditing(_ recording: WebRTCStreamRecording) {
        if selectedRecording?.id != recording.id { select(recording, autoplay: false) }
        player?.pause()
        editorViewModel = RecordingEditorViewModel(recording: recording, library: recordings)
        refreshEditedPreview(debounce: false, preservePlaybackTime: false)
        message = "Editing \(recording.title). Export saves a new video."
    }

    private func closeEditor() {
        cancelEditorPreview()
        editorViewModel = nil
        if let selectedRecording { select(selectedRecording, autoplay: false) }
        message = "Editor closed."
    }

    private func editedRecordingSaved(_ recording: WebRTCStreamRecording) {
        cancelEditorPreview()
        editorViewModel = nil
        reload(showMessage: false)
        if let refreshed = recordings.first(where: { $0.id == recording.id }) {
            select(refreshed, autoplay: true)
        }
        message = "Saved \(recording.title) as a new video."
    }

    private func refreshEditedPreview(debounce: Bool, preservePlaybackTime: Bool = true) {
        guard let editorViewModel else { return }
        let request = editorViewModel.request()
        let signature = editorViewModel.previewSignature
        let targetSeconds = preservePlaybackTime ? playerTimeSeconds : 0
        let shouldResumePlayback = player?.timeControlStatus == .playing
        editorPreviewTask?.cancel()
        editorPreviewTask = Task {
            if debounce {
                try? await Task.sleep(for: .milliseconds(150))
                if Task.isCancelled { return }
            }
            do {
                let preview = try await WebRTCStreamRecordingLibrary.previewEditedRecording(request)
                if Task.isCancelled { return }
                await MainActor.run {
                    guard self.editorViewModel?.previewSignature == signature else { return }
                    self.applyEditedPreview(preview, targetSeconds: targetSeconds, shouldResumePlayback: shouldResumePlayback)
                }
            } catch {
                if Task.isCancelled { return }
                await MainActor.run {
                    self.message = error.localizedDescription
                }
            }
        }
    }

    private func applyEditedPreview(_ preview: WebRTCStreamRecordingPreview, targetSeconds: Double, shouldResumePlayback: Bool) {
        guard let player else { return }
        let item = AVPlayerItem(asset: preview.asset)
        item.audioMix = preview.audioMix
        item.videoComposition = preview.videoComposition
        editorPreviewDurationSeconds = preview.durationSeconds
        player.replaceCurrentItem(with: item)
        let boundedSeconds = min(max(0, targetSeconds), max(0, preview.durationSeconds))
        let time = CMTime(seconds: boundedSeconds, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        playerTimeSeconds = boundedSeconds
        syncEditorSelectionForPreviewTime(boundedSeconds)
        if shouldResumePlayback {
            player.play()
        } else {
            player.pause()
        }
    }

    private func syncEditorSelectionForPreviewTime(_ outputSeconds: Double) {
        guard let editorViewModel else { return }
        let sourceTimelineSeconds = outputSeconds * max(0.25, editorViewModel.playbackRate)
        guard let target = editorViewModel.sourceTime(forTimelineSeconds: sourceTimelineSeconds) else { return }
        editorViewModel.selectPreviewSegment(target.segment)
    }

    private func cancelEditorPreview() {
        editorPreviewTask?.cancel()
        editorPreviewTask = nil
        editorPreviewDurationSeconds = 0
    }

    private func removePlayerTimeObserver() {
        guard let playerTimeObserver else { return }
        player?.removeTimeObserver(playerTimeObserver)
        self.playerTimeObserver = nil
    }

    private func reveal(_ recording: WebRTCStreamRecording) {
        NSWorkspace.shared.activateFileViewerSelecting([recording.videoURL])
        message = "Revealed \(recording.videoURL.lastPathComponent) in Finder."
    }

    private func open(_ recording: WebRTCStreamRecording) {
        NSWorkspace.shared.open(recording.videoURL)
        message = "Opened \(recording.videoURL.lastPathComponent)."
    }

    private func copyPath(_ recording: WebRTCStreamRecording) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(recording.videoURL.path, forType: .string)
        copiedPathRecordingID = recording.id
        message = "Copied recording path."
    }

    private func clearSearchAndFilters() {
        searchText = ""
        activeFilters.removeAll()
    }

    private func toggleFilter(_ filter: RecordingFilter) {
        if activeFilters.contains(filter) {
            activeFilters.remove(filter)
        } else {
            activeFilters.insert(filter)
        }
    }

    private func deletePendingRecording() {
        guard let recording = pendingDelete else { return }
        do {
            try WebRTCStreamRecordingLibrary.delete(recording)
            pendingDelete = nil
            message = "Deleted \(recording.title)."
            reload(showMessage: false)
        } catch {
            message = error.localizedDescription
            pendingDelete = nil
        }
    }
}

private struct RecordingMetric: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 9, weight: .bold))
                .tracking(1.0)
                .foregroundStyle(.white.opacity(0.42))
            Text(value)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RecordingsLayout.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(RecordingsLayout.stroke, lineWidth: 1) }
    }
}

private struct RecordingSearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(RecordingsLayout.accent)
            TextField("Search title, file, or app ID", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.94))
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.white.opacity(0.42))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(Color.white.opacity(0.065), in: Capsule())
        .overlay { Capsule().stroke(RecordingsLayout.stroke, lineWidth: 1) }
    }
}

private struct RecordingFilterChip: View {
    let filter: RecordingFilter
    let isActive: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: filter.systemImage)
                    .font(.system(size: 10, weight: .bold))
                Text(filter.title)
            }
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(isActive ? .white : .white.opacity(isHovering ? 0.92 : 0.64))
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(isActive ? RecordingsLayout.accent.opacity(0.28) : Color.white.opacity(isHovering ? 0.09 : 0.055), in: Capsule())
            .overlay { Capsule().stroke(isActive ? RecordingsLayout.accent.opacity(0.8) : RecordingsLayout.stroke, lineWidth: 1) }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

private struct RecordingRow: View {
    let recording: WebRTCStreamRecording
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        content
            .onDrag {
                NSItemProvider(object: RecordingEditorDragPayload.recording(recording.id).stringValue as NSString)
            }
    }

    private var content: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                RecordingThumbnail(recording: recording, isSelected: isSelected, isHovering: isHovering)
                    .frame(height: 118)
                VStack(alignment: .leading, spacing: 5) {
                    Text(recording.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.96))
                        .lineLimit(1)
                    Text(relativeDateText(recording.createdAt))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.54))
                        .lineLimit(1)
                }
                HStack(spacing: 6) {
                    RecordingPill(text: durationText(recording.durationSeconds), active: isSelected)
                    RecordingPill(text: qualityText(recording), active: false)
                    if recording.enhancedVideo {
                        RecordingPill(text: "RTX", active: true)
                    }
                }
                .lineLimit(1)
            }
            .padding(13)
            .background(background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(isSelected ? RecordingsLayout.accent.opacity(0.7) : Color.white.opacity(isHovering ? 0.18 : 0.08), lineWidth: isSelected ? 1.4 : 1) }
            .shadow(color: isSelected ? RecordingsLayout.accent.opacity(0.10) : .clear, radius: 18)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }

    private var background: some ShapeStyle {
        if isSelected { return AnyShapeStyle(Color.white.opacity(0.105)) }
        return AnyShapeStyle(Color.white.opacity(isHovering ? 0.075 : 0.04))
    }
}

private struct RecordingThumbnail: View {
    let recording: WebRTCStreamRecording
    let isSelected: Bool
    let isHovering: Bool
    @State private var thumbnail: NSImage?

    var body: some View {
        ZStack {
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .overlay {
                        LinearGradient(colors: [.black.opacity(0.10), .black.opacity(0.58)], startPoint: .top, endPoint: .bottom)
                    }
            } else {
                LinearGradient(
                    colors: [Color.white.opacity(0.13), Color.white.opacity(0.03), RecordingsLayout.accent.opacity(isSelected ? 0.24 : 0.08)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                DiagonalGrid()
                    .stroke(Color.black.opacity(0.35), lineWidth: 1)
            }
            Image(systemName: isHovering || isSelected ? "play.fill" : "play.rectangle.fill")
                .font(.system(size: 19, weight: .bold))
                .foregroundStyle(isSelected ? RecordingsLayout.accent : .white.opacity(thumbnail == nil ? 0.76 : 0.92))
                .shadow(color: .black.opacity(thumbnail == nil ? 0 : 0.60), radius: 7, x: 0, y: 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .aspectRatio(16 / 9, contentMode: .fit)
        .overlay(alignment: .bottomTrailing) {
            Text(resolutionBadge(recording))
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .frame(height: 15)
                .background(.black.opacity(0.65), in: Capsule())
                .padding(7)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.white.opacity(0.12), lineWidth: 1) }
        .task(id: recording.id) {
            thumbnail = await RecordingThumbnailLoader.thumbnail(for: recording)
        }
    }
}

struct RecordingPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView(frame: .zero)
        configure(view)
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        configure(view)
        if view.player !== player {
            view.player = player
        }
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player = nil
    }

    private func configure(_ view: AVPlayerView) {
        view.controlsStyle = .floating
        view.videoGravity = .resizeAspect
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
    }
}

@MainActor
private enum RecordingThumbnailLoader {
    private static let cache = NSCache<NSString, NSImage>()

    static func thumbnail(for recording: WebRTCStreamRecording) async -> NSImage? {
        let key = recording.id.uuidString as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let image = await generateThumbnail(videoURL: recording.videoURL, durationSeconds: recording.durationSeconds)
        if let image { cache.setObject(image, forKey: key) }
        return image
    }

    private static func generateThumbnail(videoURL: URL, durationSeconds: Double) async -> NSImage? {
        await Task.detached(priority: .utility) {
            let asset = AVURLAsset(url: videoURL)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 360, height: 216)
            generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
            generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
            let targetSeconds = max(0.2, min(max(durationSeconds * 0.18, 0.2), max(durationSeconds - 0.2, 0.2)))
            let time = CMTime(seconds: targetSeconds, preferredTimescale: 600)
            let cgImage = await withCheckedContinuation { continuation in
                generator.generateCGImageAsynchronously(for: time) { image, _, error in
                    continuation.resume(returning: error == nil ? image : nil)
                }
            }
            guard let cgImage else { return nil }
            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        }.value
    }
}

private struct RecordingPill: View {
    let text: String
    let active: Bool

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(active ? .black.opacity(0.86) : .white.opacity(0.62))
            .lineLimit(1)
            .padding(.horizontal, 7)
            .frame(height: 20)
            .background(active ? RecordingsLayout.accent : Color.white.opacity(0.065))
            .overlay { Rectangle().stroke(active ? RecordingsLayout.accent : Color.white.opacity(0.10), lineWidth: 1) }
    }
}

private struct RecordingNowPlayingBadge: View {
    let recording: WebRTCStreamRecording

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(RecordingsLayout.accent)
                    .frame(width: 8, height: 8)
                Text("NOW PLAYING")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1.3)
                    .foregroundStyle(RecordingsLayout.accent)
            }
            Text(recording.title)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1)
            Text("\(qualityText(recording)) · \(durationText(recording.durationSeconds)) · \(compactFileSizeText(recording.fileSizeBytes))")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.70))
                .lineLimit(1)
        }
        .padding(15)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.white.opacity(0.14), lineWidth: 1) }
    }
}

private struct RecordingInspector: View {
    let recording: WebRTCStreamRecording
    let copiedPath: Bool
    let message: String
    let onRestart: () -> Void
    let onEdit: () -> Void
    let onOpen: () -> Void
    let onReveal: () -> Void
    let onCopyPath: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(recording.title)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.96))
                        .lineLimit(2)
                    Text("\(dateText(recording.createdAt)) · \(recording.videoURL.deletingLastPathComponent().lastPathComponent)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.58))
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Button(action: onRestart) {
                    Image(systemName: "backward.end.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(RecordingActionButtonStyle(tone: .secondary))
                .help("Restart playback")
            }
            HStack(spacing: 8) {
                Button("Edit Recording", action: onEdit)
                    .buttonStyle(RecordingActionButtonStyle(tone: .primary))
                    .frame(maxWidth: .infinity)
                Menu {
                    Button("Open in Default Player", action: onOpen)
                    Button("Reveal in Finder", action: onReveal)
                    Button(copiedPath ? "Path Copied" : "Copy File Path", action: onCopyPath)
                    Divider()
                    Button("Delete Recording", role: .destructive, action: onDelete)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 15, weight: .bold))
                        .frame(width: 38, height: 36)
                        .background(Color.white.opacity(0.075), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(RecordingsLayout.stroke, lineWidth: 1) }
                }
                .menuStyle(.borderlessButton)
                .help("More recording actions")
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                RecordingDetailTile(title: "QUALITY", value: qualityText(recording), detail: "\(recording.width)x\(recording.height)")
                RecordingDetailTile(title: "BITRATE", value: bitrateText(recording), detail: "Audio \(recording.audioBitrateKbps) Kbps")
                RecordingDetailTile(title: "DURATION", value: durationText(recording.durationSeconds), detail: compactFileSizeText(recording.fileSizeBytes))
                RecordingDetailTile(title: "ENHANCEMENT", value: recording.enhancedVideo ? "Enabled" : "Standard", detail: recording.enhancedVideo ? "Enhanced video" : "Original stream")
            }
            if !message.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle.fill")
                    Text(message)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.58))
            }
        }
        .padding(16)
        .modifier(LiquidGlassModifier(cornerRadius: 22))
    }
}

private struct RecordingDetailTile: View {
    let title: String
    let value: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 9, weight: .bold))
                .tracking(1.1)
                .foregroundStyle(RecordingsLayout.accent.opacity(0.86))
            Text(value)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white.opacity(0.94))
                .lineLimit(1)
            Text(detail)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.50))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RecordingsLayout.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(RecordingsLayout.stroke, lineWidth: 1) }
    }
}

private struct RecordingEmptyState: View {
    enum Kind {
        case library
        case search
    }

    let kind: Kind
    let action: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(RecordingsLayout.accent.opacity(0.10))
                    .frame(width: 78, height: 78)
                Image(systemName: kind == .library ? "record.circle" : "line.3.horizontal.decrease.circle")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(RecordingsLayout.accent)
            }
            Text(kind == .library ? "No recordings yet" : "No matches")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white.opacity(0.94))
            Text(kind == .library ? "Start a stream, open the sidebar, and press Record to save gameplay videos here." : "Clear search or filters to show the rest of your recording library.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.58))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
            Button(kind == .library ? "Refresh" : "Clear Filters", action: action)
                .buttonStyle(RecordingActionButtonStyle(tone: .primary))
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct RecordingEmptyPlayer: View {
    let message: String

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.white.opacity(0.045))
                    .frame(width: 180, height: 108)
                    .overlay { DiagonalGrid().stroke(Color.white.opacity(0.08), lineWidth: 1) }
                    .overlay { RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.white.opacity(0.13), lineWidth: 1) }
                Image(systemName: "play.rectangle.fill")
                    .font(.system(size: 46, weight: .bold))
                    .foregroundStyle(RecordingsLayout.accent.opacity(0.88))
            }
            Text("Select a recording")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(.white.opacity(0.92))
            Text(message.isEmpty ? "Your saved gameplay videos appear here with playback, file actions, and capture details." : message)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.58))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct RecordingsBackdrop: View {
    var body: some View {
        ZStack {
            RecordingsLayout.surface
            RadialGradient(colors: [RecordingsLayout.accent.opacity(0.12), .clear], center: .topLeading, startRadius: 20, endRadius: 620)
            RadialGradient(colors: [Color.white.opacity(0.06), .clear], center: .bottomTrailing, startRadius: 20, endRadius: 520)
            DiagonalGrid()
                .stroke(Color.white.opacity(0.026), lineWidth: 1)
                .blendMode(.screen)
        }
        .ignoresSafeArea()
    }
}

private struct DiagonalGrid: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let spacing: CGFloat = 42
        var x = -rect.height
        while x < rect.width + rect.height {
            path.move(to: CGPoint(x: x, y: rect.maxY))
            path.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            x += spacing
        }
        x = 0
        while x < rect.width + rect.height {
            path.move(to: CGPoint(x: x, y: rect.minY))
            path.addLine(to: CGPoint(x: x - rect.height, y: rect.maxY))
            x += spacing
        }
        return path
    }
}

struct RecordingActionButtonStyle: ButtonStyle {
    enum Tone {
        case primary
        case secondary
        case destructive
    }

    let tone: Tone
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(foreground(isEnabled: isEnabled))
            .padding(.horizontal, 14)
            .frame(height: 36)
            .background(background(isPressed: configuration.isPressed, isEnabled: isEnabled), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(stroke(isEnabled: isEnabled), lineWidth: 1) }
            .opacity(isEnabled ? 1 : 0.42)
    }

    private func foreground(isEnabled: Bool) -> Color {
        switch tone {
        case .primary: return .white
        case .secondary: return .white.opacity(0.90)
        case .destructive: return RecordingsLayout.danger
        }
    }

    private func background(isPressed: Bool, isEnabled: Bool) -> Color {
        switch tone {
        case .primary: return RecordingsLayout.accent.opacity(isPressed ? 0.68 : 1)
        case .secondary: return Color.white.opacity(isPressed ? 0.16 : 0.075)
        case .destructive: return RecordingsLayout.danger.opacity(isPressed ? 0.22 : 0.10)
        }
    }

    private func stroke(isEnabled: Bool) -> Color {
        switch tone {
        case .primary: return RecordingsLayout.accent.opacity(isEnabled ? 1 : 0.5)
        case .secondary: return RecordingsLayout.stroke
        case .destructive: return RecordingsLayout.danger.opacity(0.36)
        }
    }
}

private struct RecordingLibraryStats {
    let count: Int
    let totalDurationSeconds: Double
    let totalBytes: Int64
    let newest: WebRTCStreamRecording?

    init(recordings: [WebRTCStreamRecording]) {
        count = recordings.count
        totalDurationSeconds = recordings.reduce(0) { $0 + $1.durationSeconds }
        totalBytes = recordings.reduce(0) { $0 + $1.fileSizeBytes }
        newest = recordings.max { $0.createdAt < $1.createdAt }
    }

    var subtitle: String {
        guard let newest else { return "Gameplay capture library" }
        return "Latest: \(relativeDateText(newest.createdAt))"
    }
}

private enum RecordingSortOrder: String, CaseIterable, Identifiable {
    case newest
    case oldest
    case longest
    case largest
    case title

    var id: String { rawValue }

    var title: String {
        switch self {
        case .newest: return "Newest first"
        case .oldest: return "Oldest first"
        case .longest: return "Longest"
        case .largest: return "Largest"
        case .title: return "Title A-Z"
        }
    }
}

private extension Array where Element == WebRTCStreamRecording {
    func sorted(using order: RecordingSortOrder) -> [WebRTCStreamRecording] {
        switch order {
        case .newest: return sorted { $0.createdAt > $1.createdAt }
        case .oldest: return sorted { $0.createdAt < $1.createdAt }
        case .longest: return sorted { $0.durationSeconds > $1.durationSeconds }
        case .largest: return sorted { $0.fileSizeBytes > $1.fileSizeBytes }
        case .title: return sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        }
    }
}

private enum RecordingFilter: String, CaseIterable, Identifiable {
    case fourK
    case qhd
    case fullHD
    case enhanced
    case large

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fourK: return "4K"
        case .qhd: return "1440p+"
        case .fullHD: return "1080p+"
        case .enhanced: return "Enhanced"
        case .large: return "Large"
        }
    }

    var systemImage: String {
        switch self {
        case .fourK: return "4k.tv"
        case .qhd: return "display"
        case .fullHD: return "rectangle.inset.filled"
        case .enhanced: return "sparkles"
        case .large: return "externaldrive.fill"
        }
    }

    func matches(_ recording: WebRTCStreamRecording) -> Bool {
        switch self {
        case .fourK: return recording.width >= 3840 || recording.height >= 2160
        case .qhd: return recording.width >= 2560 || recording.height >= 1440
        case .fullHD: return recording.width >= 1920 || recording.height >= 1080
        case .enhanced: return recording.enhancedVideo
        case .large: return recording.fileSizeBytes >= 1_000_000_000
        }
    }
}

private func dateText(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return formatter.string(from: date)
}

private func relativeDateText(_ date: Date) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .full
    return formatter.localizedString(for: date, relativeTo: Date())
}

private func durationText(_ seconds: Double) -> String {
    let value = max(0, Int(seconds.rounded()))
    if value >= 3600 { return String(format: "%d:%02d:%02d", value / 3600, (value / 60) % 60, value % 60) }
    return String(format: "%d:%02d", value / 60, value % 60)
}

private func compactFileSizeText(_ bytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useKB, .useMB, .useGB]
    formatter.countStyle = .file
    formatter.includesUnit = true
    formatter.isAdaptive = true
    return formatter.string(fromByteCount: bytes)
}

private func qualityText(_ recording: WebRTCStreamRecording) -> String {
    if recording.width >= 3840 || recording.height >= 2160 { return "4K" }
    if recording.width >= 2560 || recording.height >= 1440 { return "1440p" }
    if recording.width >= 1920 || recording.height >= 1080 { return "1080p" }
    if recording.height > 0 { return "\(recording.height)p" }
    return "Auto"
}

private func resolutionBadge(_ recording: WebRTCStreamRecording) -> String {
    recording.width > 0 && recording.height > 0 ? "\(recording.width)x\(recording.height)" : "AUTO"
}

private func bitrateText(_ recording: WebRTCStreamRecording) -> String {
    recording.videoBitrateMbps == 0 ? "Auto" : "\(recording.videoBitrateMbps) Mbps"
}
