import SwiftUI

enum LibrarySortOption: String, CaseIterable, Identifiable {
    case nameAsc = "Name (A-Z)"
    case nameDesc = "Name (Z-A)"
    case recent = "Recently Released"
    case oldest = "Oldest First"
    case favorites = "Favorites First"

    var id: String { rawValue }
}

struct LibraryGridView: View {
    @ObservedObject var viewModel: CatalogViewModel
    @ObservedObject var store: CatalogSelectionStore
    let play: (CatalogGameObject) -> Void

    let columns = [GridItem(.adaptive(minimum: 140), spacing: 16)]
    
    @State private var searchQuery = ""
    @AppStorage("LibrarySortOption") private var sortOption = LibrarySortOption.nameAsc
    
    @State private var displayedGames: [CatalogGameObject] = []
    @State private var isProcessing: Bool = false
    
    private struct GridStateHash: Equatable {
        let query: String
        let sort: LibrarySortOption
        let libraryCount: Int
        let catalogCount: Int
        let knownCount: Int
        let favCount: Int
    }
    
    private var gridStateHash: GridStateHash {
        GridStateHash(
            query: searchQuery,
            sort: sortOption,
            libraryCount: viewModel.libraryGames.count,
            catalogCount: viewModel.catalogGames.count,
            knownCount: viewModel.allKnownGames.count,
            favCount: viewModel.favoriteGameIdentities.count
        )
    }

    var body: some View {
        let trimmedQuery = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField("Search all games...", text: $searchQuery)
                            .textFieldStyle(.plain)
                        if !searchQuery.isEmpty {
                            Button {
                                searchQuery = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Color.white.opacity(0.07))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.white.opacity(0.12), lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .frame(maxWidth: 320)

                    if !displayedGames.isEmpty {
                        Text(displayedGames.count == 1 ? "1 game" : "\(displayedGames.count) games")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    HStack(spacing: 4) {
                        Text("Sort By")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Picker("", selection: $sortOption) {
                            ForEach(LibrarySortOption.allCases) { option in
                                Text(option.rawValue).tag(option)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(minWidth: 155)
                    }
                }
                .padding(.horizontal, 40)
                .padding(.top, 90)
                .padding(.bottom, 20)

                if trimmedQuery.isEmpty && viewModel.libraryGames.isEmpty {
                    if viewModel.isCatalogRefreshInProgress {
                        VStack(spacing: 16) {
                            Spacer()
                            ProgressView().controlSize(.large)
                            Text("Loading library...").font(.headline).foregroundStyle(.secondary)
                            Spacer()
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        VStack(spacing: 12) {
                            Spacer()
                            Text("No Games in Library").font(.title2).foregroundStyle(.secondary)
                            Text("Games you own or sync will appear here.").font(.subheadline).foregroundStyle(.secondary.opacity(0.8))
                            Spacer()
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else if displayedGames.isEmpty {
                    VStack(spacing: 12) {
                        Spacer()
                        if isProcessing || viewModel.isLoading {
                            ProgressView().controlSize(.large)
                            Text(isProcessing ? "Sorting games..." : "Searching catalog...").font(.headline).foregroundStyle(.secondary)
                        } else {
                            Text("No Games Found").font(.title2).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVGrid(columns: columns, spacing: 16) {
                                ForEach(displayedGames, id: \.catalogIdentity) { game in
                                    let identity = CatalogSelectionStore.gameIdentity(game)
                                    let isSelected = store.selectedGame.map(CatalogSelectionStore.gameIdentity) == identity
                                    GameCardView(
                                        game: game,
                                        isSelected: isSelected,
                                        select: { store.selectGame(withId: identity) },
                                        launch: { play(game) },
                                        isFavorite: viewModel.isFavorite(game),
                                        onToggleFavorite: { viewModel.toggleFavorite(for: game) },
                                        onSelectPlatform: { idx in viewModel.selectVariant(for: game, variantIndex: idx) },
                                        onAddShortcut: { viewModel.addShortcut(for: game) },
                                        onOpenStore: { viewModel.openStore(for: game) }
                                    )
                                    .id(identity)
                                }
                            }
                            .padding(.top, 16)
                            .padding(.horizontal, 40)
                            .padding(.bottom, 60)
                        }
                        .onChange(of: store.selectedIndex) { _, newIndex in
                            guard store.games.indices.contains(newIndex) else { return }
                            let identity = CatalogSelectionStore.gameIdentity(store.games[newIndex])
                            withAnimation(.easeInOut(duration: 0.2)) {
                                proxy.scrollTo(identity, anchor: .center)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .task(id: gridStateHash) {
                let query = gridStateHash.query
                let sort = gridStateHash.sort
                let favorites = viewModel.favoriteGameIdentities
                
                isProcessing = true
                
                struct GameSortData: Sendable {
                    let identity: String
                    let title: String
                    let releaseDate: String
                    let variantDates: [String]
                    let isFavorite: Bool
                    let isLibraryCandidate: Bool
                }
                
                let isSearching = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                
                // Map to Sendable wrapper on MainActor
                var mappedData: [GameSortData] = []
                var gameDictionary: [String: CatalogGameObject] = [:]
                
                if isSearching {
                    var seen = Set<String>()
                    for game in viewModel.catalogGames + viewModel.allKnownGames {
                        let identity = CatalogSelectionStore.gameIdentity(game)
                        guard !identity.isEmpty, seen.insert(identity).inserted else { continue }
                        gameDictionary[identity] = game
                        mappedData.append(GameSortData(
                            identity: identity,
                            title: game.title,
                            releaseDate: game.releaseDate,
                            variantDates: game.variants.map { $0.releaseDate },
                            isFavorite: game.isFavorited || favorites.contains(identity),
                            isLibraryCandidate: false // Not needed for search
                        ))
                    }
                } else {
                    for game in viewModel.libraryGames {
                        let identity = CatalogSelectionStore.gameIdentity(game)
                        gameDictionary[identity] = game
                        mappedData.append(GameSortData(
                            identity: identity,
                            title: game.title,
                            releaseDate: game.releaseDate,
                            variantDates: game.variants.map { $0.releaseDate },
                            isFavorite: game.isFavorited || favorites.contains(identity),
                            isLibraryCandidate: game.isInLibrary || CatalogViewModel.gameHasOwnedVariant(game)
                        ))
                    }
                }
                
                // Pass lightweight sendable array to background task
                let sortedIdentities = await Task.detached(priority: .userInitiated) {
                    let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
                    var pool: [GameSortData] = []
                    
                    if trimmedQuery.isEmpty {
                        let owned = mappedData.filter { $0.isLibraryCandidate }
                        pool = owned.isEmpty && !mappedData.isEmpty ? mappedData : owned
                    } else {
                        pool = mappedData.filter { $0.title.localizedCaseInsensitiveContains(trimmedQuery) }
                    }
                    
                    guard !Task.isCancelled else { return [String]() }
                    
                    struct SortedWrapper {
                        let identity: String
                        let timestamp: TimeInterval
                        let titleForSort: String
                        let isFavorite: Bool
                    }
                    
                    let isoFull = ISO8601DateFormatter()
                    isoFull.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    let isoStandard = ISO8601DateFormatter()
                    isoStandard.formatOptions = [.withInternetDateTime]
                    let isoDate = ISO8601DateFormatter()
                    isoDate.formatOptions = [.withFullDate, .withDashSeparatorInDate]
                    let df = DateFormatter()
                    df.locale = Locale(identifier: "en_US_POSIX")
                    
                    func extractTimestamp(for rawDate: String, variants: [String]) -> TimeInterval {
                        var raw = rawDate.trimmingCharacters(in: .whitespacesAndNewlines)
                        if raw.isEmpty {
                            for vrRaw in variants {
                                let vr = vrRaw.trimmingCharacters(in: .whitespacesAndNewlines)
                                if !vr.isEmpty { raw = vr; break }
                            }
                        }
                        guard !raw.isEmpty else { return 0 }
                        if let epoch = Double(raw) { return epoch > 10_000_000_000 ? epoch / 1000.0 : epoch }
                        if let d = isoFull.date(from: raw) { return d.timeIntervalSince1970 }
                        if let d = isoStandard.date(from: raw) { return d.timeIntervalSince1970 }
                        if let d = isoDate.date(from: raw) { return d.timeIntervalSince1970 }
                        for fmt in ["yyyy-MM-dd", "yyyy/MM/dd", "MM/dd/yyyy", "yyyy-MM", "yyyy"] {
                            df.dateFormat = fmt
                            if let d = df.date(from: raw) { return d.timeIntervalSince1970 }
                        }
                        if let year = Int(raw.prefix(4)), year >= 1970, year <= 2100 {
                            var comp = DateComponents()
                            comp.year = year
                            comp.month = 1
                            comp.day = 1
                            return Calendar.current.date(from: comp)?.timeIntervalSince1970 ?? 0
                        }
                        return 0
                    }
                    
                    var wrapped = pool.map { data in
                        SortedWrapper(
                            identity: data.identity,
                            timestamp: (sort == .recent || sort == .oldest) ? extractTimestamp(for: data.releaseDate, variants: data.variantDates) : 0,
                            titleForSort: data.title,
                            isFavorite: data.isFavorite
                        )
                    }
                    
                    guard !Task.isCancelled else { return [] }
                    
                    switch sort {
                    case .nameAsc:
                        wrapped.sort { $0.titleForSort.localizedCaseInsensitiveCompare($1.titleForSort) == .orderedAscending }
                    case .nameDesc:
                        wrapped.sort { $0.titleForSort.localizedCaseInsensitiveCompare($1.titleForSort) == .orderedDescending }
                    case .recent:
                        wrapped.sort {
                            if $0.timestamp != $1.timestamp {
                                if $0.timestamp == 0 { return false }
                                if $1.timestamp == 0 { return true }
                                return $0.timestamp > $1.timestamp
                            }
                            return $0.titleForSort.localizedCaseInsensitiveCompare($1.titleForSort) == .orderedAscending
                        }
                    case .oldest:
                        wrapped.sort {
                            if $0.timestamp != $1.timestamp {
                                if $0.timestamp == 0 { return false }
                                if $1.timestamp == 0 { return true }
                                return $0.timestamp < $1.timestamp
                            }
                            return $0.titleForSort.localizedCaseInsensitiveCompare($1.titleForSort) == .orderedAscending
                        }
                    case .favorites:
                        wrapped.sort {
                            if $0.isFavorite != $1.isFavorite { return $0.isFavorite && !$1.isFavorite }
                            return $0.titleForSort.localizedCaseInsensitiveCompare($1.titleForSort) == .orderedAscending
                        }
                    }
                    
                    guard !Task.isCancelled else { return [] }
                    
                    return wrapped.map { $0.identity }
                }.value
                
                guard !Task.isCancelled else { return }
                
                let finalGames = sortedIdentities.compactMap { gameDictionary[$0] }
                self.displayedGames = finalGames
                self.store.load(from: finalGames)
                self.isProcessing = false
            }
            .onChange(of: displayedGames.map(CatalogSelectionStore.gameIdentity)) { _, _ in
                store.load(from: displayedGames)
            }

            LibrarySidePanel(
                viewModel: viewModel,
                game: store.selectedGame,
                play: { if let g = store.selectedGame { play(g) } },
                toggleFavorite: {
                    if let g = store.selectedGame {
                        viewModel.selectGame(g)
                        viewModel.toggleFavoriteSelectedGame()
                    }
                }
            )
            .frame(width: 380)
            .background(.black.opacity(0.4))
            .background(.ultraThinMaterial)
        }
    }
}

private struct LibrarySidePanel: View {
    @ObservedObject var viewModel: CatalogViewModel
    let game: CatalogGameObject?
    let play: () -> Void
    let toggleFavorite: () -> Void

    @State private var isSettingsSheetPresented = false

    private var selectedVariantIndex: Int {
        guard let game else { return 0 }
        if viewModel.selectedGame?.id == game.id, viewModel.selectedVariantIndex >= 0 {
            return min(viewModel.selectedVariantIndex, max(game.variants.count - 1, 0))
        }
        return CatalogViewModel.preferredVariantIndex(for: game)
    }

    private var activeVariant: CatalogGameVariantObject? {
        guard let game, !game.variants.isEmpty else { return nil }
        let idx = selectedVariantIndex
        return game.variants.indices.contains(idx) ? game.variants[idx] : game.variants.first
    }

    var body: some View {
        if let game = game {
            VStack(spacing: 0) {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 20) {
                        // Title & Studio Info
                        headerSection(game: game)

                        // Highlight Badges (In Library, Free to Play, Patching, Tier)
                        badgesRow(game: game)

                        // Specs & Features Grid (Controls, Players, Cloud Saves)
                        specsGrid(game: game)

                        // NVIDIA Graphics Technologies
                        if !nvidiaTechItems(for: game).isEmpty {
                            nvidiaTechSection(game: game)
                        }

                        // Available Platforms / Switchable Game Variants
                        storesSection(game: game)

                        // Genres & Categories
                        if !game.genres.isEmpty {
                            genresSection(game: game)
                        }

                        // Content & Age Ratings
                        if let rating = ratingDisplay(for: game) {
                            ratingSection(rating: rating)
                        }

                        // Supported Languages
                        let languages = normalizedSupportedLanguages(for: game)
                        if !languages.isEmpty {
                            languagesSection(languages: languages)
                        }

                        // Game Description / About
                        descriptionSection(game: game)
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 84)
                    .padding(.bottom, 24)
                }

                Divider()
                    .background(Color.white.opacity(0.12))

                // Bottom Pinned Actions
                VStack(spacing: 10) {
                    let isLaunchable = activeVariant?.inLibrary == true || activeVariant?.librarySelected == true || game.isFreeToPlay || game.variants.isEmpty || game.cardPrimaryActionIsLaunchable
                    let actionText = game.isLaunchPatching ? "Queue"
                        : (isLaunchable ? "Play" : "Mark Owned")
                    let actionIcon = game.isLaunchPatching ? "wrench.and.screwdriver.fill" : "play.fill"

                    Button(action: {
                        viewModel.selectGame(game)
                        viewModel.focusGameStoreVariant(at: selectedVariantIndex)
                        play()
                    }) {
                        HStack(spacing: 8) {
                            Image(systemName: actionIcon)
                            Text(actionText)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    HStack(spacing: 8) {
                        Button(action: toggleFavorite) {
                            Label(viewModel.isFavorite(game) ? "Remove Favorite" : "Add to Favorites",
                                  systemImage: viewModel.isFavorite(game) ? "heart.fill" : "heart")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)

                        Button {
                            isSettingsSheetPresented = true
                        } label: {
                            Image(systemName: "slider.horizontal.3")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(viewModel.isCustomLaunchProfileActive(for: game) ? Color.pixelNowGreen : .white)
                                .frame(width: 44)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .help("Per-Game Launch Settings")
                    }
                }
                .padding(24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .transition(.opacity)
            .animation(.easeInOut(duration: 0.2), value: game.id)
            .sheet(isPresented: $isSettingsSheetPresented) {
                GameLaunchSettingsSheet(game: game) {
                    isSettingsSheetPresented = false
                }
            }
        } else {
            VStack(spacing: 12) {
                Spacer()
                Image(systemName: "gamecontroller")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(.white.opacity(0.25))
                Text("Select a Game")
                    .font(.headline)
                    .foregroundStyle(.white.opacity(0.5))
                Text("Click any title to view details")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.3))
                Spacer()
            }
            .padding(.top, 80)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Subsections

    private func headerSection(game: CatalogGameObject) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(game.title.isEmpty ? "Untitled Game" : game.title)
                .font(.title2.weight(.bold))
                .foregroundStyle(.white)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 5) {
                if !game.developerName.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "hammer.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.5))
                        Text(game.developerName)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                }
                if !game.publisherName.isEmpty && game.publisherName != game.developerName {
                    HStack(spacing: 6) {
                        Image(systemName: "building.2.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.5))
                        Text(game.publisherName)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                }
                if !game.releaseDate.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "calendar")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.5))
                        Text(formattedReleaseDate(game.releaseDate))
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func badgesRow(game: CatalogGameObject) -> some View {
        let hasInLibrary = activeVariant?.inLibrary == true || activeVariant?.librarySelected == true || game.isInLibrary
        let hasFree = game.isFreeToPlay
        let hasPatching = game.isLaunchPatching
        let hasTier = !game.membershipTierLabel.isEmpty

        if hasInLibrary || hasFree || hasPatching || hasTier {
            FlowLayout(spacing: 8) {
                if hasInLibrary {
                    SidePanelChip(
                        icon: "checkmark.circle.fill",
                        text: "In Library",
                        tintColor: Color.pixelNowBlue.opacity(0.2),
                        foregroundColor: Color.pixelNowBlue
                    )
                }
                if hasFree {
                    SidePanelChip(
                        icon: "gift.fill",
                        text: "Free to Play",
                        tintColor: Color.purple.opacity(0.2),
                        foregroundColor: Color(red: 0.8, green: 0.6, blue: 1.0)
                    )
                }
                if hasPatching {
                    SidePanelChip(
                        icon: "wrench.and.screwdriver.fill",
                        text: game.patchStatusPrimaryDisplayText,
                        tintColor: Color.orange.opacity(0.2),
                        foregroundColor: .orange
                    )
                }
                if hasTier {
                    SidePanelChip(
                        icon: "crown.fill",
                        text: game.membershipTierLabel,
                        tintColor: Color.yellow.opacity(0.2),
                        foregroundColor: .yellow
                    )
                }
                if viewModel.isCustomLaunchProfileActive(for: game) {
                    SidePanelChip(
                        icon: "slider.horizontal.3",
                        text: "Custom Launch Settings",
                        tintColor: Color.pixelNowGreen.opacity(0.2),
                        foregroundColor: Color.pixelNowGreen
                    )
                }
            }
        }
    }

    private func specsGrid(game: CatalogGameObject) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SidePanelSectionHeader(icon: "slider.horizontal.3", title: "Game Specs")

            FlowLayout(spacing: 8) {
                // Controls
                if game.supportsGamepad {
                    SidePanelChip(icon: "gamecontroller.fill", text: "Controller")
                }
                if game.supportsKeyboard {
                    SidePanelChip(icon: "keyboard.fill", text: "Keyboard & Mouse")
                }

                // Players
                ForEach(playerModeBadges(for: game), id: \.title) { mode in
                    SidePanelChip(icon: mode.icon, text: mode.title)
                }

                // Cloud Saves
                if hasCloudSaves(for: game) {
                    SidePanelChip(icon: "icloud.fill", text: "Cloud Saves")
                }
            }
        }
    }

    private func nvidiaTechSection(game: CatalogGameObject) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SidePanelSectionHeader(icon: "sparkles", title: "NVIDIA RTX & Graphics")

            FlowLayout(spacing: 8) {
                ForEach(nvidiaTechItems(for: game), id: \.title) { tech in
                    SidePanelChip(
                        icon: tech.icon,
                        text: tech.title,
                        tintColor: Color.pixelNowBlue.opacity(0.18),
                        foregroundColor: Color(red: 0.35, green: 0.68, blue: 1.0)
                    )
                }
            }
        }
    }

    private func storesSection(game: CatalogGameObject) -> some View {
        let platforms = platformItems(for: game)
        return VStack(alignment: .leading, spacing: 10) {
            SidePanelSectionHeader(icon: "cart.fill", title: "Available Platforms")

            FlowLayout(spacing: 8) {
                ForEach(platforms) { platform in
                    Button {
                        viewModel.selectGame(game)
                        viewModel.selectGameStoreVariant(at: platform.variantIndex)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: platform.icon)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(platform.isSelected ? .white : (platform.isOwned ? Color(red: 0.5, green: 0.8, blue: 1.0) : .white.opacity(0.7)))

                            Text(platform.isOwned ? "\(platform.title) (Owned)" : platform.title)
                                .font(.system(size: 11, weight: platform.isSelected ? .bold : .medium))
                                .foregroundStyle(platform.isSelected ? .white : (platform.isOwned ? Color(red: 0.7, green: 0.9, blue: 1.0) : .white.opacity(0.85)))

                            if platform.isSelected {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            platform.isSelected
                                ? Color(red: 0.0, green: 0.48, blue: 1.0)
                                : (platform.isOwned ? Color.blue.opacity(0.2) : Color.white.opacity(0.08))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(
                                    platform.isSelected ? Color.white.opacity(0.8) : (platform.isOwned ? Color.blue.opacity(0.4) : Color.white.opacity(0.12)),
                                    lineWidth: platform.isSelected ? 1.5 : 1
                                )
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func genresSection(game: CatalogGameObject) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SidePanelSectionHeader(icon: "square.grid.2x2.fill", title: "Genres")

            FlowLayout(spacing: 8) {
                ForEach(game.genres, id: \.self) { genre in
                    SidePanelChip(
                        icon: CatalogGenreCopy.icon(genre),
                        text: CatalogGenreCopy.displayName(genre)
                    )
                }
            }
        }
    }

    private func ratingSection(rating: (title: String, descriptors: [String])) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SidePanelSectionHeader(icon: "shield.fill", title: "Age & Content Rating")

            HStack(spacing: 8) {
                SidePanelChip(
                    icon: "exclamationmark.shield.fill",
                    text: rating.title,
                    tintColor: Color.white.opacity(0.1),
                    foregroundColor: .white.opacity(0.9)
                )
            }

            if !rating.descriptors.isEmpty {
                Text(rating.descriptors.joined(separator: " • "))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func languagesSection(languages: [NormalizedLanguage]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SidePanelSectionHeader(icon: "globe", title: "Supported Languages")

            FlowLayout(spacing: 6) {
                ForEach(languages) { lang in
                    HStack(spacing: 5) {
                        Text(lang.flag)
                            .font(.system(size: 11))
                        Text(lang.name)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.88))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
            }
        }
    }

    private func descriptionSection(game: CatalogGameObject) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SidePanelSectionHeader(icon: "text.alignleft", title: "About")

            let description = game.shortDescription.isEmpty ? game.longDescription : game.shortDescription
            let resolved = description.isEmpty ? game.gameDescription : description
            Text(resolved.isEmpty ? "No description available." : resolved)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.82))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Helpers

    private func formattedReleaseDate(_ raw: String) -> String {
        guard !raw.isEmpty else { return "" }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withDashSeparatorInDate]
        if let date = formatter.date(from: raw) {
            let displayFormatter = DateFormatter()
            displayFormatter.dateStyle = .medium
            return displayFormatter.string(from: date)
        }
        let fullFormatter = ISO8601DateFormatter()
        if let date = fullFormatter.date(from: raw) {
            let displayFormatter = DateFormatter()
            displayFormatter.dateStyle = .medium
            return displayFormatter.string(from: date)
        }
        if raw.count >= 4 {
            return String(raw.prefix(4))
        }
        return raw
    }

    private func nvidiaTechItems(for game: CatalogGameObject) -> [(title: String, icon: String)] {
        var items: [(title: String, icon: String)] = []
        var seen = Set<String>()
        for tech in game.nvidiaTech {
            let lower = tech.lowercased()
            if (lower.contains("rtx") || lower.contains("ray")) && seen.insert("rtx").inserted {
                items.append(("Ray Tracing / RTX", "sparkles"))
            } else if lower.contains("dlss") && seen.insert("dlss").inserted {
                items.append(("DLSS", "cpu.fill"))
            } else if lower.contains("reflex") && seen.insert("reflex").inserted {
                items.append(("Reflex", "bolt.fill"))
            } else if lower.contains("hdr") && seen.insert("hdr").inserted {
                items.append(("HDR", "sun.max.fill"))
            }
        }
        return items
    }

    private func platformItems(for game: CatalogGameObject) -> [GamePlatformItem] {
        var items: [GamePlatformItem] = []
        let selectedIndex = selectedVariantIndex

        if !game.variants.isEmpty {
            for (index, variant) in game.variants.enumerated() {
                let name = variant.appStoreLabel.isEmpty ? variant.appStore : variant.appStoreLabel
                guard !name.isEmpty else { continue }
                let isOwned = variant.inLibrary || variant.librarySelected
                let isSelected = (index == selectedIndex)
                let storeKey = variant.appStore.lowercased()
                items.append(GamePlatformItem(
                    id: "\(variant.id)_\(index)",
                    variantIndex: index,
                    title: cleanStoreName(name),
                    isOwned: isOwned,
                    isSelected: isSelected,
                    icon: storeIconName(for: storeKey)
                ))
            }
        } else {
            for (index, store) in game.availableStores.enumerated() {
                guard !store.isEmpty else { continue }
                let storeKey = store.lowercased()
                items.append(GamePlatformItem(
                    id: "\(store)_\(index)",
                    variantIndex: index,
                    title: cleanStoreName(store),
                    isOwned: game.isInLibrary,
                    isSelected: (index == 0),
                    icon: storeIconName(for: storeKey)
                ))
            }
        }
        return items
    }

    private func cleanStoreName(_ raw: String) -> String {
        let lower = raw.lowercased()
        if lower.contains("steam") { return "Steam" }
        if lower.contains("epic") { return "Epic Games" }
        if lower.contains("xbox") || lower.contains("msstore") || lower.contains("microsoft") { return "Xbox" }
        if lower.contains("ubisoft") || lower.contains("uplay") { return "Ubisoft Connect" }
        if lower.contains("ea") || lower.contains("origin") { return "EA App" }
        if lower.contains("gog") { return "GOG" }
        if lower.contains("battle") || lower.contains("bnet") { return "Battle.net" }
        return raw.capitalized
    }

    private func storeIconName(for lower: String) -> String {
        if lower.contains("steam") { return "flame.fill" }
        if lower.contains("xbox") || lower.contains("msstore") || lower.contains("microsoft") { return "gamecontroller" }
        if lower.contains("epic") { return "bolt.fill" }
        if lower.contains("ea") || lower.contains("origin") { return "sportscourt.fill" }
        if lower.contains("gog") { return "star.fill" }
        if lower.contains("battle") || lower.contains("bnet") { return "shield.fill" }
        if lower.contains("ubisoft") || lower.contains("uplay") { return "u.circle.fill" }
        return "cart.fill"
    }

    private func normalizedSupportedLanguages(for game: CatalogGameObject) -> [NormalizedLanguage] {
        var rawLanguages: [String] = []
        if let variant = activeVariant, !variant.supportedLanguages.isEmpty {
            rawLanguages = variant.supportedLanguages
        } else {
            for v in game.variants {
                rawLanguages.append(contentsOf: v.supportedLanguages)
            }
        }

        var result: [NormalizedLanguage] = []
        var seen = Set<String>()

        for raw in rawLanguages {
            let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "-", with: "_")
            guard !clean.isEmpty else { continue }
            let (name, flag) = parseLanguage(clean)
            guard seen.insert(name.lowercased()).inserted else { continue }
            result.append(NormalizedLanguage(id: clean, name: name, flag: flag))
        }
        return result
    }

    private func parseLanguage(_ clean: String) -> (name: String, flag: String) {
        let components = clean.split(separator: "_")
        let langCode = String(components.first ?? "").lowercased()
        let regionCode = components.count > 1 ? String(components[1]).uppercased() : ""

        switch (langCode, regionCode) {
        case ("en", "US"): return ("English (US)", "🇺🇸")
        case ("en", "GB"), ("en", "UK"): return ("English (UK)", "🇬🇧")
        case ("en", _): return ("English", "🇺🇸")
        case ("es", "MX"), ("es", "419"): return ("Spanish (Latin America)", "🇲🇽")
        case ("es", "ES"): return ("Spanish (Spain)", "🇪🇸")
        case ("es", _): return ("Spanish", "🇪🇸")
        case ("pt", "BR"): return ("Portuguese (Brazil)", "🇧🇷")
        case ("pt", "PT"), ("pt", _): return ("Portuguese", "🇵🇹")
        case ("zh", "TW"), ("zh", "HK"): return ("Traditional Chinese", "🇹🇼")
        case ("zh", "CN"), ("zh", "HANS"), ("zh", "SG"): return ("Simplified Chinese", "🇨🇳")
        case ("zh", _): return ("Chinese", "🇨🇳")
        case ("fr", "FR"), ("fr", "CA"), ("fr", _): return ("French", "🇫🇷")
        case ("de", "DE"), ("de", "AT"), ("de", _): return ("German", "🇩🇪")
        case ("it", "IT"), ("it", _): return ("Italian", "🇮🇹")
        case ("ja", "JP"), ("ja", _): return ("Japanese", "🇯🇵")
        case ("ko", "KR"), ("ko", _): return ("Korean", "🇰🇷")
        case ("ru", "RU"), ("ru", _): return ("Russian", "🇷🇺")
        case ("pl", "PL"), ("pl", _): return ("Polish", "🇵🇱")
        case ("tr", "TR"), ("tr", _): return ("Turkish", "🇹🇷")
        case ("ar", "SA"), ("ar", "AE"), ("ar", _): return ("Arabic", "🇸🇦")
        case ("nl", "NL"), ("nl", "BE"), ("nl", _): return ("Dutch", "🇳🇱")
        case ("sv", "SE"), ("sv", _): return ("Swedish", "🇸🇪")
        case ("da", "DK"), ("da", _): return ("Danish", "🇩🇰")
        case ("fi", "FI"), ("fi", _): return ("Finnish", "🇫🇮")
        case ("no", "NO"), ("nb", _), ("nn", _): return ("Norwegian", "🇳🇴")
        case ("cs", "CZ"), ("cs", _): return ("Czech", "🇨🇿")
        case ("hu", "HU"), ("hu", _): return ("Hungarian", "🇭🇺")
        case ("el", "GR"), ("el", _): return ("Greek", "🇬🇷")
        case ("th", "TH"), ("th", _): return ("Thai", "🇹🇭")
        case ("vi", "VN"), ("vi", _): return ("Vietnamese", "🇻🇳")
        case ("id", "ID"), ("id", _): return ("Indonesian", "🇮🇩")
        case ("ro", "RO"), ("ro", _): return ("Romanian", "🇷🇴")
        case ("uk", "UA"), ("uk", _): return ("Ukrainian", "🇺🇦")
        case ("he", "IL"), ("he", _): return ("Hebrew", "🇮🇱")
        default:
            let locale = Locale(identifier: "en_US")
            if let localized = locale.localizedString(forIdentifier: clean) {
                return (localized, "🌐")
            }
            if let localized = locale.localizedString(forLanguageCode: langCode) {
                return (localized, "🌐")
            }
            return (clean.replacingOccurrences(of: "_", with: " ").capitalized, "🌐")
        }
    }

    private func ratingDisplay(for game: CatalogGameObject) -> (title: String, descriptors: [String])? {
        let rating = game.ratingCategoryTitle.isEmpty ? (game.contentRatings.first ?? "") : game.ratingCategoryTitle
        guard !rating.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        var descriptors: [String] = []
        for d in game.ratingDescriptors + game.ratingInteractiveElements {
            let cleaned = d.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty && !descriptors.contains(cleaned) {
                descriptors.append(cleaned)
            }
        }
        return (rating, descriptors)
    }

    private func hasCloudSaves(for game: CatalogGameObject) -> Bool {
        if let variant = activeVariant {
            return variant.cloudSaveSupported || game.featureLabels.contains { $0.localizedCaseInsensitiveContains("cloud") }
        }
        return game.variants.contains { $0.cloudSaveSupported } || game.featureLabels.contains { $0.localizedCaseInsensitiveContains("cloud") }
    }

    private func playerModeBadges(for game: CatalogGameObject) -> [(title: String, icon: String)] {
        var badges: [(title: String, icon: String)] = []
        if game.maxOnlinePlayers > 1 {
            badges.append(("\(game.maxOnlinePlayers) Online", "person.3.fill"))
        } else if game.maxOnlinePlayers == 1 {
            badges.append(("Online", "person.fill"))
        }
        if game.maxLocalPlayers > 1 {
            badges.append(("\(game.maxLocalPlayers) Local", "person.2.fill"))
        }
        if !game.playType.isEmpty {
            let cleanType = game.playType.replacingOccurrences(of: "_", with: " ").capitalized
            if !badges.contains(where: { $0.title.localizedCaseInsensitiveContains(cleanType) }) {
                badges.append((cleanType, "person.crop.rectangle.stack.fill"))
            }
        }
        if badges.isEmpty && (game.maxLocalPlayers == 1 || game.maxOnlinePlayers == 0) {
            badges.append(("Single-Player", "person.fill"))
        }
        return badges
    }
}

// MARK: - Models & UI Components

private struct GamePlatformItem: Identifiable {
    let id: String
    let variantIndex: Int
    let title: String
    let isOwned: Bool
    let isSelected: Bool
    let icon: String
}

private struct NormalizedLanguage: Identifiable, Hashable {
    let id: String
    let name: String
    let flag: String
}

private struct SidePanelSectionHeader: View {
    let icon: String
    let title: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.6))
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(0.6))
                .tracking(0.8)
        }
    }
}

private struct SidePanelChip: View {
    let icon: String?
    let text: String
    var tintColor: Color = .white.opacity(0.08)
    var foregroundColor: Color = .white.opacity(0.88)

    var body: some View {
        HStack(spacing: 5) {
            if let icon = icon, !icon.isEmpty {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(foregroundColor.opacity(0.9))
            }
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(foregroundColor)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(tintColor)
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(foregroundColor.opacity(0.2), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}
