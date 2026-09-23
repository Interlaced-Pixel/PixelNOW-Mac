import SwiftUI

struct HomeDashboardView: View {
    @ObservedObject var viewModel: CatalogViewModel
    @ObservedObject var store: CatalogSelectionStore
    let play: (CatalogGameObject) -> Void

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 20) {
                HStack(alignment: .top, spacing: 20) {
                    VStack(spacing: 12) {
                        GameDetailOverlayPanel(
                            game: store.selectedGame,
                            isFavorite: {
                                if let g = store.selectedGame { return viewModel.isFavorite(g) }
                                return false
                            }(),
                            play: { if let g = store.selectedGame { play(g) } },
                            toggleFavorite: {
                                if let g = store.selectedGame {
                                    viewModel.selectGame(g)
                                    viewModel.toggleFavoriteSelectedGame()
                                }
                            }
                        )

                        ScrollViewReader { proxy in
                            GeometryReader { railGeometry in
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 12) {
                                        ForEach(Array(store.games.enumerated()), id: \.element.id) { index, game in
                                            GameCardView(
                                                game: game,
                                                isSelected: index == store.selectedIndex,
                                                scale: 0.8,
                                                select: { store.select(at: index) },
                                                launch: { play(game) },
                                                onToggleFavorite: { viewModel.toggleFavorite(for: game) },
                                                onSelectPlatform: { idx in viewModel.selectVariant(for: game, variantIndex: idx) },
                                                onAddShortcut: { viewModel.addShortcut(for: game) },
                                                onOpenStore: { viewModel.openStore(for: game) }
                                            )
                                            .id(CatalogSelectionStore.gameIdentity(game))
                                        }
                                    }
                                    .frame(minWidth: railGeometry.size.width)
                                    .frame(maxWidth: .infinity, alignment: .center)
                                }
                            }
                            .frame(height: 207 * 0.8 + 11 * 0.8 + 5)
                            .onChange(of: store.selectedIndex) { _, newIndex in
                                guard store.games.indices.contains(newIndex) else { return }
                                let identity = CatalogSelectionStore.gameIdentity(store.games[newIndex])
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    proxy.scrollTo(identity, anchor: nil)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)

                    PlayerStatsWidgetView(
                        statistics: viewModel.playtimeStatistics,
                        subscriptionStatus: viewModel.subscriptionStatus
                    )
                }

                Spacer()
            }
            .padding(.horizontal, 40)
            .padding(.top, 120)
            .padding(.bottom, 20)
            .background(PixelPatternBackground())
        }
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

                            let opacity: Double = 0.05 + Double(seed % 8) * 0.012

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

struct PlayerStatsWidgetView: View {
    let statistics: CatalogPlaytimeStatistics
    let subscriptionStatus: CatalogSubscriptionStatus

    private var usageProgress: Double {
        guard subscriptionStatus.totalHours > 0 else { return 0 }
        return min(subscriptionStatus.usedHours / subscriptionStatus.totalHours, 1.0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Player Stats")
                .font(.title2).bold()
                .foregroundStyle(.white)

            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    StatRow(icon: "clock.fill", label: "Remaining Playtime", value: subscriptionStatus.remainingPlaytimeText)
                    if subscriptionStatus.isAvailable && !subscriptionStatus.isUnlimited && !subscriptionStatus.usageText.isEmpty {
                        UsageRow(
                            usedHours: subscriptionStatus.usedHours,
                            totalHours: subscriptionStatus.totalHours,
                            progress: usageProgress
                        )
                    }
                    if subscriptionStatus.rolledOverHours > 0 {
                        StatRow(icon: "arrow.clockwise", label: "Rolled Over", value: CatalogSubscriptionStatus.hoursText(subscriptionStatus.rolledOverHours))
                    }
                    if subscriptionStatus.purchasedHours > 0 {
                        StatRow(icon: "plus.circle.fill", label: "Extra Playtime", value: CatalogSubscriptionStatus.hoursText(subscriptionStatus.purchasedHours))
                    }
                }
                .padding(.bottom, 10)

                Divider()
                    .background(Color.white.opacity(0.12))
                    .padding(.bottom, 10)

                VStack(alignment: .leading, spacing: 10) {
                    StatRow(icon: "timer", label: "Total Playtime", value: formatDuration(statistics.totalSeconds))
                    StatRow(icon: "gamecontroller.fill", label: "Total Sessions", value: "\(statistics.sessionCount)")
                    if statistics.lastSessionSeconds > 0 {
                        StatRow(icon: "play.circle.fill", label: "Last Session", value: formatDuration(statistics.lastSessionSeconds))
                    }
                    if statistics.averageSessionSeconds > 0 {
                        StatRow(icon: "chart.bar.fill", label: "Average Session", value: formatDuration(statistics.averageSessionSeconds))
                    }
                    if statistics.longestSessionSeconds > 0 {
                        StatRow(icon: "trophy.fill", label: "Longest Session", value: formatDuration(statistics.longestSessionSeconds))
                    }
                    if !statistics.lastPlayedTitle.isEmpty {
                        StatRow(icon: "sparkles", label: "Last Played", value: statistics.lastPlayedTitle)
                    }
                }
            }
            .padding()
            .background(Color.black.opacity(0.4))
            .cornerRadius(12)
        }
        .padding()
        .background(.ultraThinMaterial)
        .cornerRadius(16)
        .frame(width: 320)
    }

    private func formatDuration(_ seconds: Double) -> String {
        let totalMinutes = max(0, Int((seconds / 60).rounded()))
        let hrs = totalMinutes / 60
        let mins = totalMinutes % 60
        if hrs > 0, mins > 0 {
            return "\(hrs)h \(mins)m"
        }
        if hrs > 0 {
            return "\(hrs)h"
        }
        return "\(mins)m"
    }
}

private struct UsageRow: View {
    let usedHours: Double
    let totalHours: Double
    let progress: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: "calendar.circle.fill")
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text("Monthly Usage")
                    .foregroundStyle(.secondary)
                    .layoutPriority(1)
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text(CatalogSubscriptionStatus.hoursText(usedHours))
                        .foregroundStyle(.white)
                        .bold()
                    if totalHours > 0 {
                        Text("of \(CatalogSubscriptionStatus.hoursText(totalHours))")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                }
            }
            ProgressView(value: progress)
                .tint(progress >= 0.9 ? .red : progress >= 0.7 ? .orange : .blue)
                .padding(.leading, 22)
        }
    }
}

struct StatRow: View {
    let icon: String
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(label)
                .foregroundStyle(.secondary)
                .layoutPriority(1)
            Spacer()
            Text(value)
                .foregroundStyle(.white)
                .bold()
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
    }
}


