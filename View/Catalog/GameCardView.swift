import SwiftUI

struct GameCardView: View {
    let game: CatalogGameObject
    let isSelected: Bool
    var scale: CGFloat = 1.0
    let select: () -> Void
    let launch: () -> Void

    var isFavorite: Bool = false
    var onToggleFavorite: (() -> Void)? = nil
    var onSelectPlatform: ((Int) -> Void)? = nil
    var onAddShortcut: (() -> Void)? = nil
    var onOpenStore: (() -> Void)? = nil
    var onOpenSettings: (() -> Void)? = nil
    var showsArtworkProgress = false
    var artworkProgress = CatalogImageLoadProgress.queued

    @State private var isLaunchSettingsPresented = false

    private var cardWidth: CGFloat { 138 * scale }
    private var cardHeight: CGFloat { 207 * scale }
    private var isArtworkProgressActive: Bool {
        showsArtworkProgress && (artworkProgress.status == .queued || artworkProgress.status == .downloading)
    }

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 5) {
                ZStack(alignment: .topTrailing) {
                    CatalogRemoteImage(url: URL(string: game.bestStorePickerPosterURL), contentMode: .fill)
                        .frame(width: cardWidth, height: cardHeight)
                        .clipped()

                    if isArtworkProgressActive {
                        LibraryArtworkProgressIndicator(progress: artworkProgress, scale: scale)
                            .padding(.bottom, scale)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }

                    if isFavorite {
                        Image(systemName: "heart.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(5)
                            .background(Color.red.opacity(0.85))
                            .clipShape(Circle())
                            .padding(6)
                            .shadow(color: .black.opacity(0.4), radius: 4, x: 0, y: 2)
                    }
                }
                .frame(width: cardWidth, height: cardHeight)
                .clipShape(RoundedRectangle(cornerRadius: 12 * scale, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12 * scale, style: .continuous)
                        .stroke(isSelected ? Color.white : Color.white.opacity(0.18), lineWidth: isSelected ? 2 * scale : 1 * scale)
                )
                .shadow(color: isSelected ? Color.accentColor.opacity(0.4) : .clear, radius: isSelected ? 8 * scale : 0)

                Text(game.title.isEmpty ? "Untitled" : game.title)
                    .font(.system(size: 11 * scale, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: cardWidth, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: launch)
        .contextMenu {
            GameCardContextMenuContent(
                game: game,
                isFavorite: isFavorite,
                onPlay: launch,
                onSelectPlatform: { idx in onSelectPlatform?(idx) },
                onToggleFavorite: { onToggleFavorite?() },
                onOpenSettings: {
                    if let onOpenSettings {
                        onOpenSettings()
                    } else {
                        isLaunchSettingsPresented = true
                    }
                },
                onAddShortcut: { onAddShortcut?() },
                onOpenStore: { onOpenStore?() }
            )
        }
        .sheet(isPresented: $isLaunchSettingsPresented) {
            GameLaunchSettingsSheet(game: game) {
                isLaunchSettingsPresented = false
            }
        }
        .animation(.interactiveSpring(response: 0.24, dampingFraction: 0.86), value: isSelected)
        .accessibilityLabel(game.title.isEmpty ? "Untitled game" : game.title)
        .accessibilityValue(isArtworkProgressActive ? artworkProgress.accessibilityDescription : "")
        .accessibilityHint("Click to select. Double-click to launch. Right-click for game options.")
    }
}

private struct LibraryArtworkProgressIndicator: View {
    let progress: CatalogImageLoadProgress
    let scale: CGFloat

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            switch progress.status {
            case .queued:
                statusPanel(
                    label: "QUEUED",
                    detail: "WAITING FOR DOWNLOAD",
                    symbol: "clock",
                    tint: .white.opacity(0.82),
                    bar: .determinate(0)
                )
            case .downloading:
                statusPanel(
                    label: "DOWNLOADING",
                    detail: byteProgressDescription,
                    symbol: "arrow.down.circle.fill",
                    tint: Color.pixelNowGreen,
                    bar: progress.fractionCompleted.map(ProgressBarState.determinate) ?? .indeterminate
                )
            case .loaded:
                statusPanel(
                    label: "READY",
                    detail: ByteCountFormatter.string(fromByteCount: progress.receivedBytes, countStyle: .file),
                    symbol: "checkmark.circle.fill",
                    tint: Color.pixelNowGreen,
                    bar: .determinate(1)
                )
            case .failed:
                statusPanel(
                    label: "FAILED",
                    detail: progress.receivedBytes > 0 ? "\(formattedBytes(progress.receivedBytes)) RECEIVED" : "ARTWORK UNAVAILABLE",
                    symbol: "exclamationmark.triangle.fill",
                    tint: .orange,
                    bar: progress.fractionCompleted.map(ProgressBarState.determinate)
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .animation(.easeInOut(duration: 0.2), value: progress)
    }

    private var byteProgressDescription: String {
        guard let expectedBytes = progress.expectedBytes, expectedBytes > 0 else {
            return "\(formattedBytes(progress.receivedBytes)) RECEIVED"
        }
        return "\(formattedBytes(progress.receivedBytes)) / \(formattedBytes(expectedBytes))"
    }

    private func formattedBytes(_ byteCount: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
    }

    @ViewBuilder
    private func statusPanel(
        label: String,
        detail: String,
        symbol: String,
        tint: Color,
        bar: ProgressBarState?
    ) -> some View {
        VStack(spacing: 4 * scale) {
            HStack(spacing: 5 * scale) {
                Image(systemName: symbol)
                    .font(.system(size: 9 * scale, weight: .semibold))
                Text(label)
                    .font(.system(size: 7.5 * scale, weight: .bold, design: .rounded))
                    .tracking(0.35)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if progress.status == .downloading, let fraction = progress.fractionCompleted {
                    Text("\(Int(fraction * 100))%")
                        .font(.system(size: 7.5 * scale, weight: .semibold, design: .monospaced))
                }
            }
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(detail)
                .font(.system(size: 7.5 * scale, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.88))
                .lineLimit(1)
                .minimumScaleFactor(0.65)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let bar {
                switch bar {
                case let .determinate(value):
                    ProgressView(value: value)
                        .progressViewStyle(.linear)
                        .tint(tint)
                case .indeterminate:
                    ProgressView()
                        .progressViewStyle(.linear)
                        .tint(tint)
                }
            }
        }
        .padding(.horizontal, 8 * scale)
        .padding(.top, 18 * scale)
        .padding(.bottom, 7 * scale)
        .background(
            LinearGradient(
                colors: [.clear, .black.opacity(0.88)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private enum ProgressBarState {
        case determinate(Double)
        case indeterminate
    }
}


