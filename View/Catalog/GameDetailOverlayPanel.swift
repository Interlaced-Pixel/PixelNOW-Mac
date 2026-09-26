import SwiftUI

struct GameDetailOverlayPanel: View {
    let game: CatalogGameObject?
    let isFavorite: Bool
    let play: () -> Void
    let toggleFavorite: () -> Void

    private static let panelWidth: CGFloat = 700
    private static let panelHeight: CGFloat = 220

    var body: some View {
        ZStack {
            panelContent
                .id(game?.id ?? "")
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.18), value: game?.id ?? "")
        }
        .frame(width: Self.panelWidth, height: Self.panelHeight)
        .modifier(LiquidGlassModifier(cornerRadius: 22))
    }

    @ViewBuilder
    private var panelContent: some View {
        VStack(spacing: 6) {
            Text(game?.title ?? "")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(width: 652, height: 54, alignment: .bottom)

            HStack(spacing: 14) {
                if let dev = game?.developerName, !dev.isEmpty {
                    Label(dev, systemImage: "person.crop.circle")
                }
                if let release = game?.releaseDate, !release.isEmpty {
                    Label(String(release.prefix(4)), systemImage: "calendar")
                }
                if let genres = game?.genres, !genres.isEmpty {
                    Label(genres.prefix(2).joined(separator: ", "), systemImage: "gamecontroller")
                }
                if game?.isFreeToPlay == true {
                    Label("Free", systemImage: "tag")
                }
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.white.opacity(0.80))
            .lineLimit(1)
            .frame(height: 18)

            let description = game.map { $0.shortDescription.isEmpty ? $0.longDescription : $0.shortDescription } ?? ""
            Text(description)
                .font(.callout.weight(.medium))
                .foregroundStyle(.white.opacity(0.88))
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .frame(width: 652, height: 56, alignment: .top)

            HStack(spacing: 12) {
                let actionText = game?.isLaunchPatching == true ? "Queue"
                    : ((game?.cardPrimaryActionIsLaunchable ?? false) ? "Play" : "Mark Owned")
                Button(actionText, action: play)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(game == nil)

                Button(action: toggleFavorite) {
                    Image(systemName: isFavorite ? "heart.fill" : "heart")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(game == nil)
                .help(isFavorite ? "Remove from favorites" : "Add to favorites")
            }
            .frame(height: 44)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
    }
}
