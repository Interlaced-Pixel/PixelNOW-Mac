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

    @State private var isLaunchSettingsPresented = false

    private var cardWidth: CGFloat { 138 * scale }
    private var cardHeight: CGFloat { 207 * scale }

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 5) {
                ZStack(alignment: .topTrailing) {
                    CatalogRemoteImage(url: URL(string: game.bestStorePickerPosterURL), contentMode: .fill)
                        .frame(width: cardWidth, height: cardHeight)
                        .clipped()

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
        .accessibilityHint("Click to select. Double-click to launch. Right-click for game options.")
    }
}


