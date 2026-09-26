import Foundation
import SwiftUI

struct HomeDashboardView: View {
    @ObservedObject var viewModel: CatalogViewModel
    @ObservedObject var store: CatalogSelectionStore
    let play: (CatalogGameObject) -> Void
    @State private var hasMoreGamesToRight = false

    var body: some View {
        GeometryReader { geometry in
            let centerWidth = min(920, max(700, geometry.size.width - 448))

            ZStack {
                PixelPatternBackground()

                centerContent(width: centerWidth)
                    .padding(.top, max(geometry.size.height * 0.08, 48))
                    .padding(.bottom, 40)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                DashboardEdgeMetricsView()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func centerContent(width: CGFloat) -> some View {
        VStack(spacing: 16) {
            GameDetailOverlayPanel(
                game: store.selectedGame,
                isFavorite: {
                    if let game = store.selectedGame { return viewModel.isFavorite(game) }
                    return false
                }(),
                play: { if let game = store.selectedGame { play(game) } },
                toggleFavorite: {
                    if let game = store.selectedGame {
                        viewModel.selectGame(game)
                        viewModel.toggleFavoriteSelectedGame()
                    }
                }
            )

            ScrollViewReader { proxy in
                GeometryReader { railGeometry in
                    ScrollView(.horizontal, showsIndicators: true) {
                        HStack(spacing: 12) {
                            ForEach(Array(store.games.enumerated()), id: \.element.id) { index, game in
                                GameCardView(
                                    game: game,
                                    isSelected: index == store.selectedIndex,
                                    scale: railCardScale(for: railGeometry.size.width),
                                    select: { store.select(at: index) },
                                    launch: { play(game) },
                                    onToggleFavorite: { viewModel.toggleFavorite(for: game) },
                                    onSelectPlatform: { variantIndex in viewModel.selectVariant(for: game, variantIndex: variantIndex) },
                                    onAddShortcut: { viewModel.addShortcut(for: game) },
                                    onOpenStore: { viewModel.openStore(for: game) }
                                )
                                .id(CatalogSelectionStore.gameIdentity(game))
                            }
                        }
                        .frame(minWidth: railGeometry.size.width)
                        .frame(maxWidth: .infinity, alignment: .center)
                    }
                    .onScrollGeometryChange(for: Bool.self) { scrollGeometry in
                        scrollGeometry.contentOffset.x + scrollGeometry.containerSize.width
                            < scrollGeometry.contentSize.width - 1
                    } action: { _, canScrollRight in
                        hasMoreGamesToRight = canScrollRight
                    }
                    .overlay(alignment: .trailing) {
                        if hasMoreGamesToRight {
                            LinearGradient(
                                colors: [.clear, Color.black.opacity(0.34)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                            .frame(width: 52)
                            .overlay(alignment: .trailing) {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.76))
                                    .padding(.trailing, 8)
                            }
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                        }
                    }
                }
                .frame(height: 207 * railCardScale(for: width) + 18)
                .onChange(of: store.selectedIndex) { _, newIndex in
                    guard store.games.indices.contains(newIndex) else { return }
                    let identity = CatalogSelectionStore.gameIdentity(store.games[newIndex])
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo(identity, anchor: nil)
                    }
                }
            }
        }
        .frame(maxWidth: width)
    }

    private func railCardScale(for width: CGFloat) -> CGFloat {
        guard !store.games.isEmpty else { return 0.88 }
        let spacing = CGFloat(max(store.games.count - 1, 0)) * 12
        let scaleThatFits = (width - spacing) / (CGFloat(store.games.count) * 138)
        return min(0.92, max(0.76, scaleThatFits))
    }
}

struct PixelPatternBackground: View {
    private static let glyphBitmaps: [[[UInt8]]] = [
        [
            [1, 1, 0, 0, 0, 0, 1, 1],
            [0, 1, 1, 0, 0, 1, 1, 0],
            [0, 0, 1, 1, 1, 1, 0, 0],
            [0, 0, 0, 1, 1, 0, 0, 0],
            [0, 0, 0, 1, 1, 0, 0, 0],
            [0, 0, 1, 1, 1, 1, 0, 0],
            [0, 1, 1, 0, 0, 1, 1, 0],
            [1, 1, 0, 0, 0, 0, 1, 1]
        ],
        [
            [0, 0, 1, 1, 1, 1, 0, 0],
            [0, 1, 1, 0, 0, 1, 1, 0],
            [1, 1, 0, 0, 0, 0, 1, 1],
            [1, 1, 0, 0, 0, 0, 1, 1],
            [1, 1, 0, 0, 0, 0, 1, 1],
            [1, 1, 0, 0, 0, 0, 1, 1],
            [0, 1, 1, 0, 0, 1, 1, 0],
            [0, 0, 1, 1, 1, 1, 0, 0]
        ],
        [
            [1, 1, 1, 1, 1, 1, 1, 1],
            [1, 1, 1, 1, 1, 1, 1, 1],
            [1, 1, 0, 0, 0, 0, 1, 1],
            [1, 1, 0, 0, 0, 0, 1, 1],
            [1, 1, 0, 0, 0, 0, 1, 1],
            [1, 1, 0, 0, 0, 0, 1, 1],
            [1, 1, 1, 1, 1, 1, 1, 1],
            [1, 1, 1, 1, 1, 1, 1, 1]
        ],
        [
            [0, 0, 0, 1, 1, 0, 0, 0],
            [0, 0, 1, 1, 1, 1, 0, 0],
            [0, 0, 1, 0, 0, 1, 0, 0],
            [0, 1, 1, 0, 0, 1, 1, 0],
            [0, 1, 0, 0, 0, 0, 1, 0],
            [1, 1, 0, 0, 0, 0, 1, 1],
            [1, 1, 1, 1, 1, 1, 1, 1],
            [1, 1, 1, 1, 1, 1, 1, 1]
        ]
    ]

    private static let glyphColors: [Color] = [
        Color(red: 0.12, green: 0.52, blue: 1.0),
        Color(red: 0.98, green: 0.28, blue: 0.38),
        Color(red: 0.90, green: 0.32, blue: 0.72),
        Color(red: 0.15, green: 0.75, blue: 0.98)
    ]

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color(red: 0.035, green: 0.043, blue: 0.078)

                RadialGradient(
                    colors: [
                        Color(red: 0.08, green: 0.35, blue: 0.95).opacity(0.18),
                        .clear
                    ],
                    center: .topLeading,
                    startRadius: 40,
                    endRadius: 750
                )

                RadialGradient(
                    colors: [
                        Color(red: 0.52, green: 0.15, blue: 0.68).opacity(0.12),
                        .clear
                    ],
                    center: .bottomTrailing,
                    startRadius: 60,
                    endRadius: 700
                )

                Canvas { context, size in
                    let cellWidth: CGFloat = 110
                    let cellHeight: CGFloat = 110
                    let cols = Int(ceil(size.width / cellWidth)) + 1
                    let rows = Int(ceil(size.height / cellHeight)) + 1

                    var dotPath = Path()
                    let dotSpacing: CGFloat = 28
                    let dotCols = Int(ceil(size.width / dotSpacing)) + 1
                    let dotRows = Int(ceil(size.height / dotSpacing)) + 1
                    for r in 0..<dotRows {
                        for c in 0..<dotCols {
                            if (c * 7 + r * 13) % 5 == 0 {
                                let x = CGFloat(c) * dotSpacing
                                let y = CGFloat(r) * dotSpacing
                                dotPath.addRect(CGRect(x: x, y: y, width: 1.5, height: 1.5))
                            }
                        }
                    }
                    context.fill(dotPath, with: .color(Color.white.opacity(0.04)))

                    let megaGlyphs: [(type: Int, x: CGFloat, y: CGFloat, pixelSize: CGFloat, opacity: Double)] = [
                        (0, size.width * 0.15, size.height * 0.65, 8.0, 0.028),
                        (1, size.width * 0.82, size.height * 0.35, 7.5, 0.024),
                        (2, size.width * 0.45, size.height * 0.78, 6.5, 0.022),
                        (3, size.width * 0.70, size.height * 0.85, 7.0, 0.026)
                    ]
                    for mega in megaGlyphs {
                        let bitmap = Self.glyphBitmaps[mega.type]
                        let color = Self.glyphColors[mega.type]
                        var megaPath = Path()
                        for (r, rowData) in bitmap.enumerated() {
                            for (c, val) in rowData.enumerated() {
                                if val == 1 {
                                    let rect = CGRect(
                                        x: mega.x + CGFloat(c) * mega.pixelSize,
                                        y: mega.y + CGFloat(r) * mega.pixelSize,
                                        width: mega.pixelSize - 0.5,
                                        height: mega.pixelSize - 0.5
                                    )
                                    megaPath.addRect(rect)
                                }
                            }
                        }
                        context.fill(megaPath, with: .color(color.opacity(mega.opacity)))
                    }

                    for row in 0..<rows {
                        for col in 0..<cols {
                            let seed = col * 37 + row * 19
                            let glyphType = (col * 3 + row * 7 + (seed % 3)) % 4
                            let bitmap = Self.glyphBitmaps[glyphType]
                            let color = Self.glyphColors[glyphType]

                            let pixelSize: CGFloat = (seed % 4 == 0) ? 4.5 : ((seed % 3 == 0) ? 3.5 : 2.5)
                            let glyphPixelWidth = CGFloat(bitmap[0].count) * pixelSize
                            let glyphPixelHeight = CGFloat(bitmap.count) * pixelSize

                            let jitterX = CGFloat((seed * 17) % 36) - 18
                            let jitterY = CGFloat((seed * 23) % 36) - 18

                            let originX = CGFloat(col) * cellWidth + (cellWidth - glyphPixelWidth) / 2 + jitterX
                            let originY = CGFloat(row) * cellHeight + (cellHeight - glyphPixelHeight) / 2 + jitterY

                            let opacity: Double = 0.035 + Double(seed % 8) * 0.007

                            var glyphPath = Path()
                            for (r, rowData) in bitmap.enumerated() {
                                for (c, val) in rowData.enumerated() {
                                    if val == 1 {
                                        let rect = CGRect(
                                            x: originX + CGFloat(c) * pixelSize,
                                            y: originY + CGFloat(r) * pixelSize,
                                            width: pixelSize - 0.4,
                                            height: pixelSize - 0.4
                                        )
                                        glyphPath.addRect(rect)
                                    }
                                }
                            }
                            context.fill(glyphPath, with: .color(color.opacity(opacity)))

                            if seed % 3 == 0 {
                                var sparklePath = Path()
                                let sx = originX + glyphPixelWidth + 14
                                let sy = originY + 6
                                sparklePath.addRect(CGRect(x: sx - 1.5, y: sy, width: 4.5, height: 1.5))
                                sparklePath.addRect(CGRect(x: sx, y: sy - 1.5, width: 1.5, height: 4.5))
                                context.fill(sparklePath, with: .color(color.opacity(opacity * 0.75)))
                            }
                        }
                    }
                }
            }
        }
        .ignoresSafeArea()
    }
}

private struct DashboardEdgeMetricsView: View {
    var body: some View {
        GeometryReader { geometry in
            Color.clear
                .overlay(alignment: .bottomTrailing) {
                    ClientBuildDetailsView()
                        .padding(.trailing, 14)
                        .padding(.bottom, 10)
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .allowsHitTesting(false)
    }
}

private struct ClientBuildDetailsView: View {
    private let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
    private let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"
    private let metadata = DashboardBuildMetadata.current

    var body: some View {
        Text("PixelNOW \(version) (\(build))  ·  Git \(metadata.gitHash)  ·  Built \(metadata.buildDate)")
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .accessibilityLabel("PixelNOW version \(version), build \(build), Git \(metadata.gitHash), built \(metadata.buildDate)")
    }
}

private struct DashboardBuildMetadata: Decodable {
    let gitHash: String
    let buildDate: String

    static let current: DashboardBuildMetadata = {
        guard let url = Bundle.main.url(forResource: "PixelNOWBuildMetadata", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let metadata = try? PropertyListDecoder().decode(DashboardBuildMetadata.self, from: data) else {
            return DashboardBuildMetadata(gitHash: "Unavailable", buildDate: "Unavailable")
        }
        return metadata
    }()
}
