import AppKit
import Combine
import Foundation

private final class CatalogWeakObject<T: AnyObject>: @unchecked Sendable {
    weak var value: T?

    init(_ value: T) {
        self.value = value
    }
}

private extension CatalogGameObject {
    func matchesGFNShortcutIdentifiers(_ identifiers: Set<String>) -> Bool {
        for value in [id, uuid, launchAppId, shortName] where identifiers.contains(value.lowercased()) {
            return true
        }
        return variants.contains { identifiers.contains($0.id.lowercased()) }
    }
}

private final class CatalogSendableValue<T>: @unchecked Sendable {
    nonisolated(unsafe) let value: T

    nonisolated init(_ value: T) {
        self.value = value
    }
}

private struct CatalogSettingsPreferencesSnapshot: Sendable {
    let capabilities: StreamDeviceCapabilities
    let profile: StreamPreferenceProfile
    let nativeNVSTRuntimeAvailable: Bool
    let nativeNVSTRuntimeMessage: String
    let remoteCoOpPreferences: RemoteCoOpPreferences
    let selectedRegionUrl: String
    let regionOptions: [StreamRegionOption]
    let microphoneDeviceOptions: [StreamMicrophoneDeviceOption]
}

@MainActor
enum CatalogLaunchFlowState: Equatable {
    case idle
    case checkingSession
    case activeSessionPrompt
    case stoppingSession
    case startingStream
}

@MainActor
enum CatalogOwnershipFlowStage: Equatable {
    case hidden
    case resyncing
    case storeSelection
    case manualMark
    case success
}

@MainActor
enum CatalogMainPage: String, CaseIterable, Identifiable {
    case games
    case recordings
    case settings

    var id: String { rawValue }
}

@MainActor
enum CatalogDestination: String, CaseIterable, Identifiable {
    case home
    case library

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "Games"
        case .library: return "My Library"
        }
    }
}

@MainActor
enum CatalogSettingsPage: String, CaseIterable, Identifiable {
    case account
    case interface
    case connections
    case gameplay
    case experimentalFeatures
    case serverLocation
    case resolutionUpscaling
    case system
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .account: return "Account"
        case .interface: return "Interface"
        case .connections: return "Connections"
        case .gameplay: return "Gameplay"
        case .experimentalFeatures: return "Experimental Features"
        case .serverLocation: return "Server Location"
        case .resolutionUpscaling: return "MetalFX Upscaling"
        case .system: return "System"
        case .about: return "About"
        }
    }
}

@MainActor
struct CatalogStreamAdPlayback: Identifiable, Equatable {
    let id: String
    let title: String
    let mediaUrl: String
    let durationMs: Int
}

@MainActor
final class CatalogViewModel: ObservableObject {
    @Published var selectedMainPage = CatalogMainPage.games
    @Published var selectedCatalogDestination = CatalogDestination.home
    @Published var selectedSettingsPage = CatalogSettingsPage.account
    @Published var searchQuery = ""
    @Published var selectedGenreFilter = ""
    @Published var isSearchPresented = false
    @Published var selectedSortId = "a_to_z"
    @Published var selectedFilterIds: [String] = []
    @Published var isLoading = false
    @Published var isLoadingPanels = false
    @Published var errorMessage = ""
    @Published var launchMessage = ""
    @Published var actionMessage = ""
    @Published var marqueePanels: [CatalogPanelObject] = []
    @Published var mainPanels: [CatalogPanelObject] = []
    @Published var catalogGames: [CatalogGameObject] = []
    @Published var libraryGames: [CatalogGameObject] = []
    @Published private var fullSectionGames: [String: [CatalogGameObject]] = [:]
    @Published private var loadingFullSectionIds: Set<String> = []
    @Published var filterGroups: [CatalogFilterGroupObject] = []
    @Published var sortOptions: [CatalogSortOptionObject] = []
    @Published var totalCatalogCount = 0
    @Published var supportedCatalogCount = 0
    @Published var hasMoreCatalogResults = false
    @Published var expandedSectionIds: Set<String> = []
    @Published var accountStores: [CatalogStoreAccount] = []
    @Published var accountSubscriptions: [String] = []
    @Published var storeDefinitions: [CatalogStoreDefinition] = []
    @Published var subscriptionDefinitions: [CatalogSubscriptionDefinition] = []
    @Published var selectedGame: CatalogGameObject?
    @Published var selectedSectionId = ""
    @Published var selectedVariantIndex = -1
    @Published var activeStreamConfiguration: PreparedLaunchConfiguration?
    @Published var activeStreamProgress: StreamProgress?
    @Published var activeStreamAdPlayback: CatalogStreamAdPlayback?
    @Published var isActiveStreamLaunchOverlayVisible = false
    @Published var launchFlowState = CatalogLaunchFlowState.idle
    @Published var launchFlowTitle = ""
    @Published var launchFlowMessage = ""
    @Published var launchFlowError = ""
    @Published var activeLaunchSession: ActiveStreamSessionDescriptor?
    @Published var streamProfile = StreamPreferenceProfile()
    @Published var remoteCoOpPreferences = RemoteCoOpPreferencesStore.load()
    @Published var streamCapabilities = StreamDeviceCapabilities()
    @Published var nativeNVSTRuntimeAvailable = false
    @Published var nativeNVSTRuntimeMessage = "Checking native NVST runtime availability."
    @Published var settingsRegionOptions: [StreamRegionOption] = []
    @Published var selectedSettingsRegionUrl = ""
    @Published var unavailableSettingsRegionUrl = ""
    @Published var isRefreshingSettingsRegions = false
    @Published var microphoneDeviceOptions: [StreamMicrophoneDeviceOption] = []
    @Published var previousGameSession: CatalogPreviousGameSession?
    @Published var playtimeStatistics = CatalogPlaytimeStatistics.empty
    @Published var subscriptionStatus = CatalogSubscriptionStatus.unavailable
    static let maxFavoritesLimit = 5
    @Published var favoriteGameIdentities: Set<String> = []
    @Published var favoriteGames: [CatalogGameObject] = []
    @Published var favoriteReplacementCandidate: CatalogGameObject?
    @Published var selectedGameRevealRequest: CatalogGameRevealRequest?
    @Published var catalogImageCacheSummary = "Calculating"
    @Published var isStorePickerVisible = false
    @Published var ownershipFlowStage = CatalogOwnershipFlowStage.hidden
    @Published var ownershipFlowMessage = ""
    @Published var queuedPatchingLaunchGameTitle = ""
    @Published var desktopLaunchInProgress = false
    @Published var desktopMacroStatus = ""
    @Published var desktopMacroInitialDelay: Double = StreamPreferences.loadDesktopMacroInitialDelay()
    @Published var desktopMacroKeystrokeDelay: Double = StreamPreferences.loadDesktopMacroKeystrokeDelay()
    @Published var desktopMacroNavigationDelay: Double = StreamPreferences.loadDesktopMacroNavigationDelay()
    @Published var desktopMacroDownloadDelay: Double = StreamPreferences.loadDesktopMacroDownloadDelay()
    @Published var desktopCustomAppId: String = StreamPreferences.loadDesktopCustomAppId()

    let account: LoginAccount
    let session: LoginSession
    let onRefreshAuth: () async -> Bool

    var isFreeTierAccount: Bool {
        subscriptionStatus.isAvailable && subscriptionStatus.isFreeTierAccount
    }

    private var hasLoaded = false
    private var browseGeneration = 0
    private var authRefreshInFlight = false
    private var cancellables = Set<AnyCancellable>()
    private var pendingLaunchGame: CatalogGameObject?
    private var pendingLaunchVariantIndex = -1
    private var activeSessionResumeConfiguration: PreparedLaunchConfiguration?
    private var activeSessionReplacementConfiguration: PreparedLaunchConfiguration?
    private var activeStreamReplacementConfiguration: PreparedLaunchConfiguration?
    private var streamProgressGeneration = 0
    private var activeStreamAdContinuation: CheckedContinuation<Int, Error>?
    private var settingsPreferencesGeneration = 0
    private var selectedGameRevealSequence = 0
    private var settingsPreferencesTask: Task<Void, Never>?
    private var patchingPollTask: Task<Void, Never>?
    private var patchingPollInFlight = false
    private var queuedPatchingLaunchIdentity = ""
    private var queuedPatchingLaunchVariantIndex = -1
    init(account: LoginAccount, session: LoginSession, onRefreshAuth: @escaping () async -> Bool) {
        self.account = account
        self.session = session
        self.onRefreshAuth = onRefreshAuth
        let playtimeAccountIdentifier = Self.playtimeAccountIdentifier(account: account, session: session)
        playtimeStatistics = CatalogPlaytimeStatistics.load(
            accountIdentifier: playtimeAccountIdentifier
        )
        previousGameSession = CatalogPreviousGameSession.load(userId: playtimeAccountIdentifier)
        $searchQuery
            .dropFirst()
            .removeDuplicates()
            .debounce(for: .milliseconds(350), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.browseCatalog() }
            .store(in: &cancellables)
    }

    deinit {
        patchingPollTask?.cancel()
    }

    var marqueeGames: [CatalogGameObject] {
        var games: [CatalogGameObject] = []
        var seen = Set<String>()
        for panel in marqueePanels {
            for section in panel.sections {
                for game in section.games {
                    let key = Self.identity(for: game)
                    guard !key.isEmpty, !seen.contains(key) else { continue }
                    seen.insert(key)
                    games.append(game)
                }
            }
        }
        return games
    }

    var heroRotationGames: [CatalogGameObject] {
        var games: [CatalogGameObject] = []
        var seen = Set<String>()
        Self.appendUniqueHeroGames(from: marqueeGames, into: &games, seen: &seen)
        return games
    }

    var featuredGames: [CatalogGameObject] {
        var games: [CatalogGameObject] = []
        var seen = Set<String>()

        func append(_ game: CatalogGameObject) {
            let key = Self.identity(for: game)
            guard !key.isEmpty, seen.insert(key).inserted else { return }
            games.append(game)
        }

        for panel in marqueePanels {
            for section in panel.sections {
                for game in section.games {
                    append(game)
                }
            }
        }

        if games.isEmpty {
            for panel in mainPanels {
                for section in panel.sections {
                    let title = section.title.lowercased()
                    if title.contains("featured") || title.contains("spotlight") || title.contains("popular") || title.contains("marquee") {
                        for game in section.games {
                            append(game)
                        }
                    }
                }
            }
        }

        if games.isEmpty {
            for panel in mainPanels {
                for section in panel.sections {
                    for game in section.games {
                        append(game)
                    }
                }
            }
        }

        return games
    }

    var catalogSections: [CatalogSectionModel] {
        if selectedCatalogDestination == .library, !isBrowseMode {
            return libraryGames.isEmpty ? [] : [CatalogSectionModel(id: "my-library", title: "My Library", games: libraryGames, kind: .library)]
        }
        if selectedCatalogDestination == .home, !isBrowseMode {
            let games = favoriteGames.isEmpty ? featuredGames : favoriteGames
            let title = favoriteGames.isEmpty ? "Featured Games" : "My Favorites"
            return games.isEmpty ? [] : [CatalogSectionModel(id: "home-games", title: title, games: games, kind: .panel)]
        }

        if isBrowseMode, !catalogGames.isEmpty {
            return [CatalogSectionModel(id: "catalog-results", title: "Search Results", games: catalogGames, kind: .catalog)]
        }

        var sections: [CatalogSectionModel] = []
        var seenTitles = Set<String>()
        for panel in mainPanels {
            for section in panel.sections where !section.games.isEmpty {
                let title = section.title.isEmpty ? panel.title : section.title
                let resolvedTitle = title.isEmpty ? "Featured Games" : title
                guard !seenTitles.contains(resolvedTitle) else { continue }
                seenTitles.insert(resolvedTitle)
                let sectionId = section.sectionIdentity(fallbackPanelId: panel.id)
                sections.append(CatalogSectionModel(
                    id: sectionId,
                    title: resolvedTitle,
                    games: games(for: section, title: resolvedTitle, sectionId: sectionId),
                    kind: .panel,
                    tiles: section.tiles,
                    seeMoreFilterIds: section.seeMoreFilterIds,
                    seeMoreSortId: section.seeMoreSortId,
                    seeMoreTitle: section.seeMoreTitle,
                    isLoadingFullList: loadingFullSectionIds.contains(sectionId)
                ))
            }
        }
        return Array(sections.prefix(10))
    }

    var isBrowseMode: Bool {
        !searchQuery.trimmed.isEmpty || !selectedFilterIds.isEmpty
    }

    var isCatalogRefreshInProgress: Bool {
        isLoading || isLoadingPanels
    }

    var selectedSortLabel: String {
        sortOptions.first { $0.id == selectedSortId }?.label ?? "A-Z"
    }

    var visibleFilterGroups: [CatalogFilterGroupObject] {
        filterGroups.filter { !$0.options.isEmpty }
    }

    var allKnownGames: [CatalogGameObject] {
        var games: [CatalogGameObject] = []
        var seen = Set<String>()
        for game in marqueeGames + catalogGames + libraryGames + favoriteGames + mainPanelGames {
            let key = Self.identity(for: game)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            games.append(game)
        }
        return games
    }

    private var mainPanelGames: [CatalogGameObject] {
        mainPanels.flatMap { panel in panel.sections.flatMap(\.games) }
    }

    var selectedFilterCount: Int { selectedFilterIds.count }

    var resultSummary: String {
        let total = totalCatalogCount > 0 ? totalCatalogCount : catalogGames.count
        if searchQuery.trimmed.isEmpty, selectedFilterIds.isEmpty { return "" }
        if total == 1 { return "1 result" }
        return "\(total) results"
    }

    func loadIfNeeded() {
        guard !hasLoaded else { return }
        hasLoaded = true
        Task { await loadCatalogDataAfterProviderConfiguration() }
    }

    func refresh() {
        Task { await loadCatalogDataAfterProviderConfiguration(forceCatalogRefresh: true) }
    }

    private func loadCatalogDataAfterProviderConfiguration(forceCatalogRefresh: Bool = false) async {
        configureCatalogService()
        await configureCatalogProviderEndpoint()
        loadPanels()
        loadLibrary()
        loadFavorites()
        loadAccountAndStores()
        loadSettingsPreferences()
        browseCatalog(forceRefresh: forceCatalogRefresh)
    }

    private func configureCatalogProviderEndpoint() async {
        let providerIdpId = session.idpId.isEmpty ? account.providerIdpId : session.idpId
        guard !providerIdpId.isEmpty else { return }
        await withCheckedContinuation { continuation in
            GameServiceSwiftAdapter.fetchGameProviderInfo(idpId: providerIdpId) { success, _, endpoint, error in
                let message = success
                    ? "Configured provider endpoint provider=\(endpoint.loginProvider) idpId=\(providerIdpId)"
                    : "Provider endpoint lookup failed idpId=\(providerIdpId) error=\(error)"
                Task { @MainActor in
                    if success {
                        Log.info(.auth, message)
                    } else {
                        Log.warning(.auth, message)
                    }
                    continuation.resume()
                }
            }
        }
    }

    func showGames() {
        selectedMainPage = .games
        selectedCatalogDestination = .home
    }

    func showCatalogDestination(_ destination: CatalogDestination) {
        selectedMainPage = .games
        selectedCatalogDestination = destination
        selectedGame = nil
        selectedSectionId = ""
        isSearchPresented = false
        selectedGenreFilter = ""
    }

    func showSearch() {
        selectedMainPage = .games
        isSearchPresented = true
    }

    func selectGenreFilter(_ genre: String) {
        selectedGenreFilter = genre
        if !searchQuery.trimmed.isEmpty {
            searchQuery = ""
            selectedFilterIds = []
            browseCatalog()
        }
    }

    func matchesSelectedGenre(_ game: CatalogGameObject) -> Bool {
        guard !selectedGenreFilter.isEmpty else { return true }
        return game.genres.contains { $0.caseInsensitiveCompare(selectedGenreFilter) == .orderedSame }
    }

    func showSettings(_ page: CatalogSettingsPage = .account) {
        selectedMainPage = .settings
        selectedSettingsPage = page
        loadSettingsPreferences()
    }

    func browseCatalog() {
        browseCatalog(forceRefresh: false)
    }

    private func browseCatalog(forceRefresh: Bool) {
        browseGeneration += 1
        let generation = browseGeneration
        isLoading = true
        errorMessage = ""
        configureCatalogService()
        let query = searchQuery.trimmed
        let selfBox = CatalogWeakObject(self)
        GameServiceSwiftAdapter.browseCatalogObject(
            searchQuery: query,
            sortId: selectedSortId.isEmpty ? "a_to_z" : selectedSortId,
            filterIds: selectedFilterIds,
            fetchCount: 200,
            forceRefresh: forceRefresh
        ) { success, result, error in
            let resultBox = CatalogSendableValue(result)
            Task { @MainActor in
                guard let self = selfBox.value, generation == self.browseGeneration else { return }
                self.isLoading = false
                guard success else {
                    if self.refreshAuthIfNeeded(error: error) { return }
                    self.errorMessage = error.isEmpty ? "Unable to browse the GeForce NOW catalog." : error
                    return
                }
                let browseResult = resultBox.value
                self.catalogGames = browseResult.games
                self.totalCatalogCount = browseResult.totalCount
                self.supportedCatalogCount = browseResult.numberSupported
                self.hasMoreCatalogResults = browseResult.hasNextPage
                self.filterGroups = browseResult.filterGroups
                self.sortOptions = browseResult.sortOptions
                if !browseResult.selectedSortId.isEmpty { self.selectedSortId = browseResult.selectedSortId }
                self.selectedFilterIds = browseResult.selectedFilterIds
                self.schedulePatchingPollIfNeeded()
            }
        }
    }

    private func games(for section: CatalogPanelSectionObject, title: String, sectionId: String) -> [CatalogGameObject] {
        if let games = fullSectionGames[sectionId], !games.isEmpty { return games }
        guard isAllGamesPanelSection(section, title: title), !catalogGames.isEmpty else { return section.games }
        return catalogGames
    }

    func loadFullSectionIfNeeded(_ section: CatalogSectionModel) {
        guard section.canLoadFullList, fullSectionGames[section.id] == nil, !loadingFullSectionIds.contains(section.id) else { return }
        let sectionId = section.id
        let sortId = section.seeMoreSortId.isEmpty ? selectedSortId : section.seeMoreSortId
        let filterIds = section.seeMoreFilterIds
        loadingFullSectionIds.insert(section.id)
        configureCatalogService()
        let selfBox = CatalogWeakObject(self)
        GameServiceSwiftAdapter.browseCatalogObject(
            searchQuery: "",
            sortId: sortId,
            filterIds: filterIds,
            fetchCount: 200,
            forceRefresh: false
        ) { success, result, error in
            let resultBox = CatalogSendableValue(result)
            Task { @MainActor in
                guard let self = selfBox.value else { return }
                self.loadingFullSectionIds.remove(sectionId)
                guard success else {
                    if self.refreshAuthIfNeeded(error: error) { return }
                    if self.errorMessage.isEmpty { self.errorMessage = error.isEmpty ? "Unable to load the full game list." : error }
                    return
                }
                self.fullSectionGames[sectionId] = resultBox.value.games
                self.schedulePatchingPollIfNeeded()
            }
        }
    }

    private func isAllGamesPanelSection(_ section: CatalogPanelSectionObject, title: String) -> Bool {
        let normalizedTitle = Self.normalizedCatalogSectionIdentifier(title)
        let normalizedId = Self.normalizedCatalogSectionIdentifier(section.id)
        return normalizedTitle == "allgames" || normalizedId == "allgames" || normalizedId == "catalog" || normalizedId == "catalogresults"
    }

    private static func normalizedCatalogSectionIdentifier(_ value: String) -> String {
        value.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    func setSort(_ sortId: String) {
        guard selectedSortId != sortId else { return }
        selectedSortId = sortId
        browseCatalog()
    }

    func toggleFilter(_ filterId: String) {
        if selectedFilterIds.contains(filterId) {
            selectedFilterIds.removeAll { $0 == filterId }
        } else {
            selectedFilterIds.append(filterId)
        }
        browseCatalog()
    }

    func clearFilters() {
        guard !selectedFilterIds.isEmpty else { return }
        selectedFilterIds = []
        browseCatalog()
    }

    func clearSearchAndFilters() {
        searchQuery = ""
        selectedFilterIds = []
        selectedGenreFilter = ""
        isSearchPresented = false
        browseCatalog()
    }

    func openPanelTile(_ tile: CatalogPanelTileObject) {
        if tile.kind == "filter", !tile.filterIds.isEmpty {
            selectedMainPage = .games
            selectedCatalogDestination = .home
            searchQuery = ""
            selectedFilterIds = tile.filterIds
            if !tile.sortId.isEmpty { selectedSortId = tile.sortId }
            browseCatalog()
            return
        }
        if let url = URL(string: tile.actionUrl), !tile.actionUrl.isEmpty {
            NSWorkspace.shared.open(url)
        }
    }

    func toggleSectionExpansion(_ sectionId: String) {
        if expandedSectionIds.contains(sectionId) {
            expandedSectionIds.remove(sectionId)
        } else {
            expandedSectionIds.insert(sectionId)
        }
    }

    func selectGame(_ game: CatalogGameObject?) {
        let resolvedGame = game.flatMap(resolveGameForDetails) ?? game
        selectedGame = resolvedGame
        selectedSectionId = ""
        selectedVariantIndex = resolvedGame.map { Self.preferredVariantIndex(for: $0) } ?? -1
        launchMessage = ""
        actionMessage = ""
    }

    func selectGame(_ game: CatalogGameObject, inSection sectionId: String) {
        let resolvedGame = resolveGameForDetails(game, preferredSectionId: sectionId)
        selectedGame = resolvedGame
        selectedSectionId = sectionId
        selectedVariantIndex = Self.preferredVariantIndex(for: resolvedGame)
        launchMessage = ""
        actionMessage = ""
    }

    func selectGameFromHero(_ game: CatalogGameObject) {
        selectGame(game)
        requestSelectedGameReveal(for: game, sectionId: "")
    }

    func closeGameDetailsFromBackground() {
        guard selectedGame != nil else { return }
        selectGame(nil)
    }

    func launchSelectedGame() {
        guard let selectedGame else { return }
        launch(game: selectedGame, variantIndex: selectedVariantIndex)
    }

    func launch(game: CatalogGameObject, variantIndex: Int? = nil) {
        beginVendorLaunch(game: game, variantIndex: variantIndex)
    }

    func launchDesktop() {
        desktopLaunchInProgress = true

        let customAppId = desktopCustomAppId.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedAppId: String

        if let valid = LaunchAppId.resolve(customAppId) {
            resolvedAppId = valid.stringValue
            Log.info(.launch, "Using custom configured GFN appId for desktop launch: \(resolvedAppId)")
        } else {
            // Battle for Wesnoth via Steam on GFN (GFN appId 106269727, Steam appId 599390).
            resolvedAppId = "106269727"
            Log.info(.launch, "Launching desktop via Battle for Wesnoth carrier (appId=\(resolvedAppId))")
        }

        let desktopGame = CatalogGameObject()
        desktopGame.id = "desktop-salsanow-\(resolvedAppId)"
        desktopGame.uuid = desktopGame.id
        desktopGame.launchAppId = resolvedAppId
        desktopGame.title = "Windows Desktop"
        desktopGame.shortName = "SalsaNOW Desktop"
        desktopGame.gameDescription = "Full Windows desktop environment powered by SalsaNOW on GeForce NOW."
        desktopGame.isInLibrary = true
        desktopGame.imageUrl = ""
        desktopGame.heroImageUrl = ""

        let variant = CatalogGameVariantObject()
        variant.id = resolvedAppId
        variant.appStore = "Steam"
        variant.inLibrary = true
        variant.librarySelected = true
        variant.installTimeInMinutes = 1
        desktopGame.variants = [variant]

        selectGame(desktopGame)
        launch(game: desktopGame)
    }

    func setDesktopMacroInitialDelay(_ value: Double) {
        desktopMacroInitialDelay = value
        StreamPreferences.saveDesktopMacroInitialDelay(value)
    }

    func setDesktopMacroKeystrokeDelay(_ value: Double) {
        desktopMacroKeystrokeDelay = value
        StreamPreferences.saveDesktopMacroKeystrokeDelay(value)
    }

    func setDesktopMacroNavigationDelay(_ value: Double) {
        desktopMacroNavigationDelay = value
        StreamPreferences.saveDesktopMacroNavigationDelay(value)
    }

    func setDesktopMacroDownloadDelay(_ value: Double) {
        desktopMacroDownloadDelay = value
        StreamPreferences.saveDesktopMacroDownloadDelay(value)
    }

    func setDesktopCustomAppId(_ value: String) {
        desktopCustomAppId = value
        StreamPreferences.saveDesktopCustomAppId(value)
    }

    func resetDesktopMacroSettings() {
        StreamPreferences.restoreDesktopMacroDefaults()
        desktopMacroInitialDelay = StreamPreferences.loadDesktopMacroInitialDelay()
        desktopMacroKeystrokeDelay = StreamPreferences.loadDesktopMacroKeystrokeDelay()
        desktopMacroNavigationDelay = StreamPreferences.loadDesktopMacroNavigationDelay()
        desktopMacroDownloadDelay = StreamPreferences.loadDesktopMacroDownloadDelay()
        desktopCustomAppId = StreamPreferences.loadDesktopCustomAppId()
    }

    func queuePatchingLaunch(game: CatalogGameObject, variantIndex: Int? = nil) {
        guard Self.isPatching(game) else { return }
        queuedPatchingLaunchIdentity = Self.identity(for: game)
        queuedPatchingLaunchVariantIndex = variantIndex ?? selectedVariantIndexIfMatching(game) ?? Self.preferredVariantIndex(for: game)
        queuedPatchingLaunchGameTitle = game.title.isEmpty ? "GeForce NOW" : game.title
        actionMessage = "Queued \(queuedPatchingLaunchGameTitle) to launch when patching finishes."
        errorMessage = ""
        schedulePatchingPollIfNeeded(immediate: true)
    }

    func isQueuedForPatching(_ game: CatalogGameObject) -> Bool {
        !queuedPatchingLaunchIdentity.isEmpty && Self.identity(for: game) == queuedPatchingLaunchIdentity
    }

    func openGameShortcut(_ shortcut: GFNGameShortcut) {
        configureCatalogService()
        let title = shortcut.lookupTitle.isEmpty ? shortcut.displayName : shortcut.lookupTitle
        Log.info(.shortcut, "CatalogViewModel resolving shortcut cmsId=\(shortcut.cmsId) shortName=\(shortcut.shortName) parentGameId=\(shortcut.parentGameId) title=\(title)")
        setActionMessage("Opening \(title.isEmpty ? "GeForce NOW shortcut" : title)...")
        if let game = matchingGame(for: shortcut, in: allKnownGames) {
            Log.info(.shortcut, "Resolved shortcut from loaded catalog: gameId=\(game.id) uuid=\(game.uuid) launchAppId=\(game.launchAppId) title=\(game.title)")
            selectGame(game)
            launch(game: game, variantIndex: variantIndex(for: shortcut, in: game))
            return
        }
        if Int(shortcut.cmsId) != nil {
            Log.info(.shortcut, "Shortcut not found in loaded catalog; fetching CMS metadata cmsId=\(shortcut.cmsId)")
            let selfBox = CatalogWeakObject(self)
            GameServiceSwiftAdapter.fetchGameObjectByCMSId(shortcut.cmsId) { success, game, error in
                let gameBox = CatalogSendableValue(game)
                Task { @MainActor in
                    guard let self = selfBox.value else { return }
                    let game = gameBox.value
                    if success, let game {
                        Log.info(.shortcut, "Resolved shortcut from CMS metadata: gameId=\(game.id) uuid=\(game.uuid) title=\(game.title)")
                        self.selectGame(game)
                        self.launch(game: game, variantIndex: self.variantIndex(for: shortcut, in: game))
                        return
                    }
                    Log.warning(.shortcut, "Shortcut CMS metadata lookup failed: \(error)")
                    if let game = Self.launchGame(from: shortcut, title: title) {
                        Log.info(.shortcut, "Launching shortcut directly from cmsId=\(shortcut.cmsId) title=\(game.title)")
                        self.selectGame(game)
                        self.launch(game: game, variantIndex: 0)
                    } else {
                        self.resolveShortcutByBrowsing(shortcut, title: title)
                    }
                }
            }
            return
        }
        if let game = Self.launchGame(from: shortcut, title: title) {
            Log.info(.shortcut, "Launching shortcut directly from cmsId=\(shortcut.cmsId) title=\(game.title)")
            selectGame(game)
            launch(game: game, variantIndex: 0)
            return
        }
        resolveShortcutByBrowsing(shortcut, title: title)
    }

    private func resolveShortcutByBrowsing(_ shortcut: GFNGameShortcut, title: String) {
        Log.info(.shortcut, "Shortcut not found in loaded catalog; browsing with query=\(title)")
        let selfBox = CatalogWeakObject(self)
        GameServiceSwiftAdapter.browseCatalogObject(searchQuery: title, sortId: "relevance", filterIds: [], fetchCount: 24) { success, result, error in
            let resultBox = CatalogSendableValue(result)
            Task { @MainActor in
                guard let self = selfBox.value else { return }
                guard success else {
                    Log.error(.shortcut, "Shortcut catalog browse failed: \(error)")
                    self.errorMessage = error.isEmpty ? "Unable to resolve this GeForce NOW shortcut." : error
                    return
                }
                let games = resultBox.value.games
                Log.info(.shortcut, "Shortcut catalog browse returned \(games.count) game(s)")
                guard let game = self.matchingGame(for: shortcut, in: games) ?? games.first else {
                    Log.error(.shortcut, "Shortcut catalog browse returned no matching games")
                    self.errorMessage = "No matching GeForce NOW catalog game was found for this shortcut."
                    return
                }
                Log.info(.shortcut, "Resolved shortcut from browse: gameId=\(game.id) uuid=\(game.uuid) launchAppId=\(game.launchAppId) title=\(game.title)")
                self.catalogGames = games
                self.selectGame(game)
                self.launch(game: game, variantIndex: self.variantIndex(for: shortcut, in: game))
            }
        }
    }

    var isLaunchFlowVisible: Bool {
        launchFlowState != .idle
    }

    var isStreamLaunchLoadingVisible: Bool {
        guard activeStreamConfiguration != nil else { return false }
        return isActiveStreamLaunchOverlayVisible
    }

    var canResumeActiveLaunchSession: Bool {
        activeSessionResumeConfiguration?.resumesExistingSession == true
    }

    func beginVendorLaunch(game: CatalogGameObject, variantIndex: Int? = nil) {
        Log.info(.launch, "Beginning launch for gameId=\(game.id) uuid=\(game.uuid) launchAppId=\(game.launchAppId) title=\(game.title) requestedVariantIndex=\(variantIndex ?? -1)")
        pendingLaunchGame = game
        pendingLaunchVariantIndex = variantIndex ?? Self.preferredVariantIndex(for: game)
        activeLaunchSession = nil
        activeSessionResumeConfiguration = nil
        activeSessionReplacementConfiguration = nil
        activeStreamReplacementConfiguration = nil
        launchFlowTitle = game.title.isEmpty ? "GeForce NOW" : game.title
        launchFlowMessage = "Checking for active GeForce NOW sessions..."
        launchFlowError = ""
        launchMessage = "Preparing \(game.title.isEmpty ? "game" : game.title)..."
        errorMessage = ""
        launchFlowState = .checkingSession
        continueVendorLaunch()
    }

    func selectSettingsRegion(_ regionUrl: String) {
        selectedSettingsRegionUrl = regionUrl
        unavailableSettingsRegionUrl = ""
        let userId = Self.playtimeAccountIdentifier(account: account, session: session)
        StreamPreferences.saveSelectedRegionUrl(regionUrl, userId: userId)
        account.preferredRegion = regionUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Auto" : regionUrl
        loadSettingsPreferences()
    }

    func keepUnavailableSettingsRegion() {
        unavailableSettingsRegionUrl = ""
    }

    func switchUnavailableSettingsRegionToAutomatic() {
        selectSettingsRegion("")
    }

    func refreshSettingsRegions() {
        guard !isRefreshingSettingsRegions else { return }
        isRefreshingSettingsRegions = true
        let token = launchToken
        let selfBox = CatalogWeakObject(self)
        StreamPreferences.fetchRegions(token: token, providerStreamingBaseUrl: GameServiceSwiftAdapter.providerStreamingBaseURL()) { regions in
            Task { @MainActor in
                guard let self = selfBox.value else { return }
                self.isRefreshingSettingsRegions = false
                self.settingsRegionOptions = Self.launchRegionOptions(from: regions)
                if !self.selectedSettingsRegionUrl.isEmpty, !regions.contains(where: { $0.url == self.selectedSettingsRegionUrl }) {
                    self.unavailableSettingsRegionUrl = self.selectedSettingsRegionUrl
                } else {
                    self.unavailableSettingsRegionUrl = ""
                }
            }
        }
    }

    func continueVendorLaunch() {
        guard let game = pendingLaunchGame else { return }
        launchFlowState = .checkingSession
        launchFlowMessage = "Checking for active GeForce NOW sessions..."
        launchFlowError = ""
        let userId = session.userId.isEmpty ? account.userId : session.userId
        GameLaunchBridge.shared.prepareLaunchPlan(
            game: game,
            accessToken: session.accessToken,
            idToken: session.idToken,
            userId: userId,
            idpId: session.idpId.isEmpty ? account.providerIdpId : session.idpId,
            variantIndex: pendingLaunchVariantIndex
        ) { [weak self] success, message, plan in
            guard let self else { return }
            self.launchMessage = ""
            guard success, let plan else {
                Log.error(.launch, "Launch plan failed: \(message)")
                self.clearLaunchFlow()
                self.errorMessage = message.isEmpty ? "Unable to prepare GeForce NOW launch." : message
                return
            }
            switch plan {
            case .ready(let configuration):
                Log.info(.launch, "Launch plan ready appId=\(configuration.applicationID) title=\(configuration.title)")
                self.startPreparedStream(Self.mediaConfiguration(from: configuration, membershipTier: self.account.membershipTier), message: message)
            case .activeSession(let active, let resume, let replacement):
                Log.info(.launch, "Launch plan found active session activeAppId=\(active.appId) replacementAppId=\(replacement.applicationID) resumeAppId=\(resume.applicationID)")
                let activeTitle = self.title(forActiveSession: active)
                self.activeLaunchSession = ActiveStreamSessionDescriptor(sessionId: active.id, appId: active.appId, serverIp: active.serverIp, streamingBaseUrl: active.streamingBaseUrl, title: activeTitle)
                self.activeSessionResumeConfiguration = Self.mediaConfiguration(from: resume, titleOverride: activeTitle, membershipTier: self.account.membershipTier)
                self.activeSessionReplacementConfiguration = Self.mediaConfiguration(from: replacement, membershipTier: self.account.membershipTier)
                self.launchFlowState = .activeSessionPrompt
                self.launchFlowMessage = !resume.resumeSessionID.isEmpty && !resume.resumeServer.isEmpty
                    ? "A GeForce NOW session is already running. Resume it or end it before launching \(self.launchFlowTitle)."
                    : "GeForce NOW reports a stale active session that cannot be resumed. End it before launching \(self.launchFlowTitle)."
            }
        }
    }

    func resumeActiveLaunchSession() {
        guard canResumeActiveLaunchSession else {
            launchFlowError = "This GeForce NOW session is no longer resumable. End it and launch again."
            return
        }
        guard let configuration = activeSessionResumeConfiguration else { return }
        let replacement = activeSessionReplacementConfiguration
        startPreparedStream(configuration, message: "Resuming \(configuration.title)...", replacementConfiguration: replacement)
    }

    func endActiveSessionAndLaunchSelectedGame() {
        guard let activeLaunchSession, let replacement = activeSessionReplacementConfiguration else { return }
        launchFlowState = .stoppingSession
        launchFlowMessage = "Ending the current GeForce NOW session..."
        launchFlowError = ""
        GameLaunchBridge.shared.stopActiveSession(activeLaunchSession, accessToken: launchToken) { [weak self] success, message in
            guard let self else { return }
            guard success else {
                self.launchFlowState = .activeSessionPrompt
                self.launchFlowError = message
                return
            }
            self.startPreparedStream(replacement, message: "Launching \(replacement.title)...")
        }
    }

    func cancelVendorLaunch() {
        clearLaunchFlow()
        launchMessage = ""
    }

    func cancelActiveStreamLaunch() {
        guard activeStreamConfiguration != nil else { return }
        streamProgressGeneration += 1
        cancelActiveStreamAdPlayback()
        if activeStreamConfiguration?.metadata["isDesktopLaunch"] == "true" {
            desktopLaunchInProgress = false
        }
        activeStreamConfiguration = nil
        activeStreamProgress = nil
        isActiveStreamLaunchOverlayVisible = false
        activeStreamReplacementConfiguration = nil
        clearLaunchFlow()
        launchMessage = ""
        actionMessage = "Stream launch cancelled."
    }

    func showRecordings() {
        selectedMainPage = .recordings
        actionMessage = ""
        errorMessage = ""
    }

    func finishActiveStream(success: Bool, message: String, report: StreamReport?) {
        let finishedConfiguration = activeStreamConfiguration
        let replacementConfiguration = activeStreamReplacementConfiguration ?? finishedConfiguration
        cancelActiveStreamAdPlayback()
        activeStreamConfiguration = nil
        activeStreamReplacementConfiguration = nil
        activeStreamProgress = nil
        isActiveStreamLaunchOverlayVisible = false
        streamProgressGeneration += 1
        if finishedConfiguration?.metadata["isDesktopLaunch"] == "true" {
            desktopLaunchInProgress = false
        }
        clearLaunchFlow()
        launchMessage = ""
        if let replacementConfiguration, let report, let conflict = StreamSessionConflict(reportMetadata: report.metadata) {
            presentSessionConflict(conflict, replacementConfiguration: replacementConfiguration)
            return
        }
        if let finishedConfiguration {
            let session = CatalogPreviousGameSession(configuration: finishedConfiguration, success: success, message: message, report: report)
            previousGameSession = session
            session.save(userId: Self.playtimeAccountIdentifier(account: account, session: self.session))
            if let report, report.durationSeconds > 0 {
                var statistics = playtimeStatistics
                statistics.record(title: session.title, durationSeconds: report.durationSeconds, endedAt: session.endedAt)
                playtimeStatistics = statistics
                statistics.save(accountIdentifier: Self.playtimeAccountIdentifier(account: account, session: self.session))
            }
        }
        if !success, !message.isEmpty {
            errorMessage = message
            return
        }
        if let report, !report.message.isEmpty {
            actionMessage = report.message
        }
    }

    func updateActiveStreamProgress(_ progress: StreamProgress) {
        activeStreamProgress = progress
        isActiveStreamLaunchOverlayVisible = true
        guard progress.isReady else { return }
        let generation = streamProgressGeneration
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            guard generation == self.streamProgressGeneration else { return }
            self.isActiveStreamLaunchOverlayVisible = false
        }
    }

    func presentRequiredStreamAd(_ ad: StreamSessionAdPresentation) async throws -> Int {
        guard URL(string: ad.mediaUrl) != nil else {
            throw StreamSessionError.sessionAllocationFailed("Required ad media URL is invalid.")
        }
        activeStreamAdContinuation?.resume(throwing: CancellationError())
        activeStreamAdContinuation = nil
        activeStreamAdPlayback = CatalogStreamAdPlayback(
            id: ad.adId,
            title: ad.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Sponsored Message" : ad.title,
            mediaUrl: ad.mediaUrl,
            durationMs: ad.durationMs
        )
        isActiveStreamLaunchOverlayVisible = true
        let title = activeStreamConfiguration?.title.trimmingCharacters(in: .whitespacesAndNewlines)
        activeStreamProgress = StreamProgress(
            title: title?.isEmpty == false ? title ?? "GeForce NOW" : "GeForce NOW",
            message: "Playing sponsored message before your free-tier session continues...",
            steps: StreamLaunchStep.allCases.map(\.title),
            currentStepIndex: StreamLaunchStep.allocateCloudSession.rawValue,
            isReady: false,
            queuePosition: activeStreamProgress?.queuePosition
        )
        return try await withCheckedThrowingContinuation { continuation in
            activeStreamAdContinuation = continuation
        }
    }

    func finishRequiredStreamAdPlayback(watchedTimeInMs: Int) {
        guard let continuation = activeStreamAdContinuation else { return }
        activeStreamAdContinuation = nil
        activeStreamAdPlayback = nil
        continuation.resume(returning: max(0, watchedTimeInMs))
    }

    func failRequiredStreamAdPlayback(_ message: String) {
        guard let continuation = activeStreamAdContinuation else { return }
        activeStreamAdContinuation = nil
        activeStreamAdPlayback = nil
        continuation.resume(throwing: StreamSessionError.sessionAllocationFailed(message.isEmpty ? "Required ad playback failed." : message))
    }

    private func cancelActiveStreamAdPlayback() {
        activeStreamAdPlayback = nil
        guard let continuation = activeStreamAdContinuation else { return }
        activeStreamAdContinuation = nil
        continuation.resume(throwing: CancellationError())
    }

    private var launchToken: String {
        session.idToken.isEmpty ? session.accessToken : session.idToken
    }

    private func startPreparedStream(_ configuration: PreparedLaunchConfiguration, message: String, replacementConfiguration: PreparedLaunchConfiguration? = nil) {
        launchFlowState = .startingStream
        launchFlowMessage = message.isEmpty ? "Starting GeForce NOW stream..." : message
        launchFlowError = ""
        streamProgressGeneration += 1
        isActiveStreamLaunchOverlayVisible = true
        activeStreamProgress = StreamProgress(title: configuration.title.isEmpty ? "GeForce NOW" : configuration.title, message: launchFlowMessage, steps: [], currentStepIndex: -1, isReady: false)
        activeStreamReplacementConfiguration = replacementConfiguration ?? configuration
        activeStreamConfiguration = configuration
        clearLaunchFlow()
    }

    private static func message(for error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription, !description.isEmpty { return description }
        return error.localizedDescription
    }

    private static func mediaConfiguration(from configuration: PreparedLaunchConfiguration, titleOverride: String = "", membershipTier: String = "") -> PreparedLaunchConfiguration {
        let overrideTitle = titleOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        var metadata = configuration.metadata
        metadata.merge(RemoteCoOpPreferencesStore.load().launchMetadata) { _, launchValue in launchValue }
        let tier = membershipTier.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tier.isEmpty { metadata["membershipTier"] = tier }
        return PreparedLaunchConfiguration(
            title: overrideTitle.isEmpty ? configuration.title : overrideTitle,
            applicationID: configuration.applicationID,
            accessToken: configuration.accessToken,
            accountLinked: configuration.accountLinked,
            selectedStore: configuration.selectedStore,
            resumeSessionID: configuration.resumeSessionID,
            resumeServer: configuration.resumeServer,
            metadata: metadata
        )
    }

    private func title(forActiveSession session: ActiveStreamSessionDescriptor) -> String {
        let fallback = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard session.appId > 0 else { return fallback.isEmpty ? "Current Stream" : fallback }
        let applicationID = String(session.appId)
        if let game = allKnownGames.first(where: { Self.game($0, matchesApplicationID: applicationID) }) {
            let title = game.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty { return title }
        }
        return fallback.isEmpty ? "Current Stream" : fallback
    }

    private func presentSessionConflict(_ conflict: StreamSessionConflict, replacementConfiguration: PreparedLaunchConfiguration) {
        let applicationID = conflict.applicationID.isEmpty ? replacementConfiguration.applicationID : conflict.applicationID
        let appID = Int(applicationID) ?? 0
        let unresolvedSession = ActiveStreamSessionDescriptor(
            sessionId: conflict.sessionID,
            appId: appID,
            serverIp: conflict.serverAddress,
            streamingBaseUrl: StreamPreferences.loadSelectedStreamingBaseUrl(forGame: applicationID),
            title: "Current Stream"
        )
        let activeTitle = title(forActiveSession: unresolvedSession)
        activeLaunchSession = ActiveStreamSessionDescriptor(
            sessionId: conflict.sessionID,
            appId: appID,
            serverIp: conflict.serverAddress,
            streamingBaseUrl: unresolvedSession.streamingBaseUrl,
            title: activeTitle
        )
        activeSessionResumeConfiguration = conflict.isResumable
            ? PreparedLaunchConfiguration(
                title: activeTitle,
                applicationID: applicationID,
                accessToken: replacementConfiguration.accessToken,
                accountLinked: true,
                selectedStore: "",
                resumeSessionID: conflict.sessionID,
                resumeServer: conflict.serverAddress,
                metadata: replacementConfiguration.metadata
            )
            : nil
        activeSessionReplacementConfiguration = replacementConfiguration
        launchFlowTitle = replacementConfiguration.title.isEmpty ? "GeForce NOW" : replacementConfiguration.title
        launchFlowMessage = conflict.isResumable
            ? "GeForce NOW reports an active session. Resume it or end it before launching \(launchFlowTitle)."
            : "GeForce NOW reports an active session that cannot be resumed. End it before launching \(launchFlowTitle)."
        launchFlowError = ""
        errorMessage = ""
        launchFlowState = .activeSessionPrompt
    }

    private func clearLaunchFlow() {
        launchFlowState = .idle
        launchFlowTitle = ""
        launchFlowMessage = ""
        launchFlowError = ""
        activeLaunchSession = nil
        activeSessionResumeConfiguration = nil
        activeSessionReplacementConfiguration = nil
        pendingLaunchGame = nil
        pendingLaunchVariantIndex = -1
    }

    nonisolated private static func launchRegionOptions(from regions: [StreamRegionOption]) -> [StreamRegionOption] {
        let measured = regions.filter { !$0.url.isEmpty }
        let bestLatency = measured.first?.latencyMs ?? -1
        return [StreamRegionOption(name: "Automatic", url: "", latencyMs: bestLatency, automatic: true)] + measured
    }

    func openStoreForSelectedVariant() {
        guard let selectedGame else { return }
        let variantIndex = selectedVariantIndex >= 0 ? selectedVariantIndex : Self.preferredVariantIndex(for: selectedGame)
        guard variantIndex >= 0, variantIndex < selectedGame.variants.count else { return }
        let variant = selectedGame.variants[variantIndex]
        if let url = URL(string: variant.storeUrl), !variant.storeUrl.isEmpty {
            NSWorkspace.shared.open(url)
            return
        }
        let selfBox = CatalogWeakObject(self)
        GameServiceSwiftAdapter.resolveStoreURL(game: selectedGame, variantIndex: variantIndex) { success, storeURL, error in
            Task { @MainActor in
                guard let self = selfBox.value else { return }
                guard success, let url = URL(string: storeURL), !storeURL.isEmpty else {
                    self.errorMessage = error.isEmpty ? "No store URL is available for this game." : error
                    return
                }
                NSWorkspace.shared.open(url)
            }
        }
    }

    func shareSelectedGame() {
        guard let selectedGame else { return }
        let title = selectedGame.title.isEmpty ? "GeForce NOW game" : selectedGame.title
        let url = selectedGame.primaryStoreURL ?? URL(string: "https://play.geforcenow.com/")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString([title, url?.absoluteString].compactMap { $0 }.joined(separator: "\n"), forType: .string)
        actionMessage = "Copied share details."
    }

    func isFavorite(_ game: CatalogGameObject) -> Bool {
        favoriteGameIdentities.contains(Self.identity(for: game))
    }

    func toggleFavorite(for game: CatalogGameObject) {
        selectGame(game)
        toggleFavoriteSelectedGame()
    }

    func addShortcut(for game: CatalogGameObject) {
        selectGame(game)
        addShortcutForSelectedGame()
    }

    func openStore(for game: CatalogGameObject) {
        selectGame(game)
        openStoreForSelectedVariant()
    }

    func selectVariant(for game: CatalogGameObject, variantIndex: Int) {
        selectGame(game)
        selectGameStoreVariant(at: variantIndex)
    }

    func isCustomLaunchProfileActive(for game: CatalogGameObject) -> Bool {
        let appId = game.launchAppId.isEmpty ? (game.uuid.isEmpty ? game.id : game.uuid) : game.launchAppId
        return StreamPreferences.profileEnabled(forGame: appId)
    }

    func toggleFavoriteSelectedGame() {
        guard let selectedGame else { return }
        let appId = Self.favoriteAppId(for: selectedGame)
        let identity = Self.identity(for: selectedGame)
        guard !appId.isEmpty, !identity.isEmpty else { return }
        let previousGames = CatalogSendableValue(favoriteGames)
        let previousIdentities = favoriteGameIdentities
        let selfBox = CatalogWeakObject(self)
        if isFavorite(selectedGame) {
            favoriteGameIdentities.remove(identity)
            favoriteGames.removeAll { Self.identity(for: $0) == identity }
            updateGameFavoriteState(identity: identity, isFavorited: false)
            actionMessage = "Removing from favorites..."
            GameServiceSwiftAdapter.removeFavoriteApp(appId) { success, error in
                Task { @MainActor in
                    guard let self = selfBox.value else { return }
                    if success {
                        self.actionMessage = "Removed from favorites."
                        self.loadFavorites()
                    } else {
                        self.favoriteGames = previousGames.value
                        self.favoriteGameIdentities = previousIdentities
                        self.updateGameFavoriteState(identity: identity, isFavorited: true)
                        if self.refreshAuthIfNeeded(error: error) { return }
                        self.errorMessage = error.isEmpty ? "Unable to remove this game from favorites." : error
                    }
                }
            }
        } else {
            if favoriteGames.count >= Self.maxFavoritesLimit {
                favoriteReplacementCandidate = selectedGame
                return
            }

            favoriteGameIdentities.insert(identity)
            updateGameFavoriteState(identity: identity, isFavorited: true)
            let favoriteSnapshot = Self.snapshotObject(for: selectedGame)
            favoriteSnapshot.isFavorited = true
            favoriteGames.insert(favoriteSnapshot, at: 0)
            actionMessage = "Adding to favorites..."
            GameServiceSwiftAdapter.addFavoriteApp(appId) { success, error in
                Task { @MainActor in
                    guard let self = selfBox.value else { return }
                    if success {
                        self.actionMessage = "Added to favorites."
                        self.loadFavorites()
                    } else {
                        self.favoriteGames = previousGames.value
                        self.favoriteGameIdentities = previousIdentities
                        self.updateGameFavoriteState(identity: identity, isFavorited: false)
                        if self.refreshAuthIfNeeded(error: error) { return }
                        self.errorMessage = error.isEmpty ? "Unable to add this game to favorites." : error
                    }
                }
            }
        }
    }

    func cancelFavoriteReplacement() {
        favoriteReplacementCandidate = nil
    }

    func replaceFavorite(existingGame: CatalogGameObject, with newGame: CatalogGameObject) {
        favoriteReplacementCandidate = nil
        let oldAppId = Self.favoriteAppId(for: existingGame)
        let oldIdentity = Self.identity(for: existingGame)
        let newAppId = Self.favoriteAppId(for: newGame)
        let newIdentity = Self.identity(for: newGame)
        guard !oldAppId.isEmpty, !oldIdentity.isEmpty, !newAppId.isEmpty, !newIdentity.isEmpty else { return }

        let oldTitle = existingGame.title
        let newTitle = newGame.title
        let previousGames = CatalogSendableValue(favoriteGames)
        let previousIdentities = favoriteGameIdentities
        let selfBox = CatalogWeakObject(self)

        favoriteGameIdentities.remove(oldIdentity)
        favoriteGameIdentities.insert(newIdentity)
        updateGameFavoriteState(identity: oldIdentity, isFavorited: false)
        updateGameFavoriteState(identity: newIdentity, isFavorited: true)

        let newSnapshot = Self.snapshotObject(for: newGame)
        newSnapshot.isFavorited = true

        if let replaceIndex = favoriteGames.firstIndex(where: { Self.identity(for: $0) == oldIdentity }) {
            favoriteGames[replaceIndex] = newSnapshot
        } else {
            favoriteGames.removeAll { Self.identity(for: $0) == oldIdentity }
            favoriteGames.insert(newSnapshot, at: 0)
        }

        actionMessage = "Updating favorites..."
        GameServiceSwiftAdapter.removeFavoriteApp(oldAppId) { removeSuccess, removeError in
            Task { @MainActor in
                guard let self = selfBox.value else { return }
                guard removeSuccess else {
                    self.favoriteGames = previousGames.value
                    self.favoriteGameIdentities = previousIdentities
                    self.updateGameFavoriteState(identity: oldIdentity, isFavorited: true)
                    self.updateGameFavoriteState(identity: newIdentity, isFavorited: false)
                    if self.refreshAuthIfNeeded(error: removeError) { return }
                    self.errorMessage = removeError.isEmpty ? "Unable to replace favorite game." : removeError
                    return
                }

                GameServiceSwiftAdapter.addFavoriteApp(newAppId) { addSuccess, addError in
                    Task { @MainActor in
                        guard let self = selfBox.value else { return }
                        if addSuccess {
                            self.actionMessage = "Replaced \(oldTitle) with \(newTitle)."
                            self.loadFavorites()
                        } else {
                            self.favoriteGames = previousGames.value
                            self.favoriteGameIdentities = previousIdentities
                            self.updateGameFavoriteState(identity: oldIdentity, isFavorited: true)
                            self.updateGameFavoriteState(identity: newIdentity, isFavorited: false)
                            GameServiceSwiftAdapter.addFavoriteApp(oldAppId) { _, _ in }
                            if self.refreshAuthIfNeeded(error: addError) { return }
                            self.errorMessage = addError.isEmpty ? "Unable to add \(newTitle) to favorites." : addError
                        }
                    }
                }
            }
        }
    }

    func changeSelectedGameStore() {
        guard let selectedGame, selectedGame.variants.count > 1 else {
            actionMessage = "No alternate store is available."
            return
        }
        ownershipFlowStage = .storeSelection
        ownershipFlowMessage = ""
        isStorePickerVisible = true
    }

    func closeStorePicker() {
        isStorePickerVisible = false
        ownershipFlowStage = .hidden
        ownershipFlowMessage = ""
    }

    func selectGameStoreVariant(at index: Int) {
        guard let selectedGame, index >= 0, index < selectedGame.variants.count else { return }
        focusGameStoreVariant(at: index)
        guard let option = platformOptions(for: selectedGame).first(where: { $0.variantIndex == index }) else { return }
        if option.isOwned {
            let variant = selectedGame.variants[index]
            selectOwnedVariant(variant)
            if ownershipFlowStage != .hidden { ownershipFlowStage = .success }
            ownershipFlowMessage = ""
        } else if option.hasAccess {
            if ownershipFlowStage != .hidden { ownershipFlowStage = .success }
            ownershipFlowMessage = ""
        } else if ownershipFlowStage != .hidden {
            ownershipFlowStage = .manualMark
            ownershipFlowMessage = ""
        }
        actionMessage = "Changed store to \(option.title)."
    }

    func focusGameStoreVariant(at index: Int) {
        guard let selectedGame, index >= 0, index < selectedGame.variants.count else { return }
        selectedVariantIndex = index
    }

    func cycleSelectedGameStore() {
        guard let selectedGame, selectedGame.variants.count > 1 else {
            actionMessage = "No alternate store is available."
            return
        }
        let currentIndex = selectedVariantIndex >= 0 ? selectedVariantIndex : Self.preferredVariantIndex(for: selectedGame)
        let nextIndex = (max(currentIndex, 0) + 1) % selectedGame.variants.count
        selectGameStoreVariant(at: nextIndex)
    }

    func addShortcutForSelectedGame() {
        guard let selectedGame else { return }
        let title = selectedGame.title.isEmpty ? "GeForce NOW Game" : selectedGame.title
        do {
            let desktopURL = try FileManager.default.url(for: .desktopDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let shortcutURL = desktopURL.appendingPathComponent(Self.safeShortcutFilename(title))
            let variantIndex = selectedVariantIndex >= 0 ? selectedVariantIndex : Self.preferredVariantIndex(for: selectedGame)
            let variant = variantIndex >= 0 && variantIndex < selectedGame.variants.count ? selectedGame.variants[variantIndex] : nil
            let cmsId = Self.shortcutCMSId(for: selectedGame, variant: variant)
            let shortName = !selectedGame.shortName.isEmpty ? selectedGame.shortName : (!selectedGame.uuid.isEmpty ? selectedGame.uuid : selectedGame.id)
            guard !cmsId.isEmpty || !shortName.isEmpty else {
                errorMessage = "No GeForce NOW identifier is available for this game."
                return
            }
            let shortcut = GFNGameShortcut(sourceURL: nil, displayName: title, cmsId: cmsId, shortName: shortName, parentGameId: shortName)
            try shortcut.write(to: shortcutURL)
            Self.applyShortcutIcon(to: shortcutURL)
            actionMessage = "Added GeForce NOW shortcut to Desktop."
        } catch {
            errorMessage = "Unable to add shortcut: \(error.localizedDescription)"
        }
    }

    func markSelectedVariantOwned() {
        beginMarkSelectedVariantOwnedFlow()
    }

    func handleUnownedSelectedVariantPrimaryAction() {
        guard let selectedGame else { return }
        if selectedGame.isFreeToPlay {
            autoMarkFreeToPlaySelectedVariantThenLaunch()
        } else {
            markSelectedVariantOwned()
        }
    }

    private func autoMarkFreeToPlaySelectedVariantThenLaunch() {
        guard let selectedGame, let variant = selectedVariant(in: selectedGame), !variant.id.isEmpty else { return }
        let gameIdentity = Self.identity(for: selectedGame)
        let variantId = variant.id
        let variantIndex = selectedVariantIndex
        let title = selectedGame.title.isEmpty ? "game" : selectedGame.title
        let selfBox = CatalogWeakObject(self)
        setActionMessage("Adding free-to-play \(title) to library...")
        GameServiceSwiftAdapter.addOwnedVariant(variantId) { success, error in
            Task { @MainActor in
                guard let self = selfBox.value else { return }
                if success {
                    self.updateSelectedGameOwnership(gameIdentity: gameIdentity, variantId: variantId, inLibrary: true)
                    self.actionMessage = "Added to library. Launching \(title)..."
                    self.refreshCatalogAfterOwnershipChange()
                    if let game = self.selectedGame {
                        self.launch(game: game, variantIndex: variantIndex)
                    }
                } else {
                    if self.refreshAuthIfNeeded(error: error) { return }
                    self.errorMessage = error.isEmpty ? "Unable to add this free-to-play game to your library." : error
                    self.markSelectedVariantOwned()
                }
            }
        }
    }

    func beginMarkSelectedVariantOwnedFlow() {
        guard let selectedGame, selectedVariant(in: selectedGame) != nil else { return }
        ownershipFlowStage = .resyncing
        isStorePickerVisible = true
        ownershipFlowMessage = syncingOwnershipMessage(for: selectedGame)
        let stores = Self.uniqueNonEmpty(selectedGame.variants.map(\.appStore))
        let syncableStores = stores.filter { accountStatus(forStore: $0)?.hasAccountSyncingData == true }
        guard let store = syncableStores.first else {
            ownershipFlowStage = .storeSelection
            ownershipFlowMessage = ""
            return
        }
        let selfBox = CatalogWeakObject(self)
        GameServiceSwiftAdapter.syncAccountProvider(store: store) { _, _ in
            Task { @MainActor in
                guard let self = selfBox.value, self.ownershipFlowStage == .resyncing else { return }
                self.loadAccountAndStores()
                self.loadLibrary()
                self.browseCatalog()
                self.ownershipFlowStage = .storeSelection
                self.ownershipFlowMessage = ""
            }
        }
    }

    func stopOwnershipResync() {
        ownershipFlowStage = .storeSelection
        ownershipFlowMessage = ""
    }

    func confirmSelectedVariantOwned() {
        guard let selectedGame, let variant = selectedVariant(in: selectedGame), !variant.id.isEmpty else { return }
        let gameIdentity = Self.identity(for: selectedGame)
        let variantId = variant.id
        let title = selectedGame.title.isEmpty ? "game" : selectedGame.title
        let selfBox = CatalogWeakObject(self)
        setActionMessage("Adding \(title) to library...")
        GameServiceSwiftAdapter.addOwnedVariant(variantId) { success, error in
            Task { @MainActor in
                guard let self = selfBox.value else { return }
                if success {
                    self.updateSelectedGameOwnership(gameIdentity: gameIdentity, variantId: variantId, inLibrary: true)
                    self.ownershipFlowStage = .success
                    self.ownershipFlowMessage = ""
                    self.actionMessage = "Added to library."
                    self.refreshCatalogAfterOwnershipChange()
                } else {
                    self.errorMessage = error.isEmpty ? "Unable to add this game to your library." : error
                }
            }
        }
    }

    func finishOwnershipFlow() {
        closeStorePicker()
    }

    func removeSelectedVariantOwned() {
        guard let selectedGame, let variant = selectedVariant(in: selectedGame), !variant.id.isEmpty else { return }
        let gameIdentity = Self.identity(for: selectedGame)
        let variantId = variant.id
        let title = selectedGame.title.isEmpty ? "game" : selectedGame.title
        let selfBox = CatalogWeakObject(self)
        setActionMessage("Removing \(title) from library...")
        GameServiceSwiftAdapter.removeOwnedVariant(variantId) { success, error in
            Task { @MainActor in
                guard let self = selfBox.value else { return }
                if success {
                    self.updateSelectedGameOwnership(gameIdentity: gameIdentity, variantId: variantId, inLibrary: false)
                    self.actionMessage = "Removed from library."
                    self.refreshCatalogAfterOwnershipChange()
                } else {
                    self.errorMessage = error.isEmpty ? "Unable to remove this game from your library." : error
                }
            }
        }
    }

    func selectOwnedVariant(_ variant: CatalogGameVariantObject) {
        guard !variant.id.isEmpty else { return }
        let variantId = variant.id
        let selfBox = CatalogWeakObject(self)
        GameServiceSwiftAdapter.selectOwnedVariant(variantId) { success, error in
            Task { @MainActor in
                guard let self = selfBox.value else { return }
                if success {
                    self.selectedGame?.variants.forEach { $0.librarySelected = $0.id == variantId }
                    self.actionMessage = "Store selection updated."
                    self.refreshCatalogAfterOwnershipChange()
                } else {
                    self.errorMessage = error.isEmpty ? "Unable to update store selection." : error
                }
            }
        }
    }

    func syncSelectedStoreAccount() {
        guard let store = selectedPlatformOption(in: selectedGame)?.accountStore, !store.isEmpty else { return }
        syncStoreAccount(store)
    }

    func syncStoreAccount(_ store: String) {
        guard !store.isEmpty else { return }
        let selfBox = CatalogWeakObject(self)
        setActionMessage("Syncing \(displayName(forStore: store)) account...")
        GameServiceSwiftAdapter.syncAccountProvider(store: store) { success, error in
            Task { @MainActor in
                guard let self = selfBox.value else { return }
                if success {
                    self.actionMessage = "Store sync started."
                    self.loadAccountAndStores()
                    self.loadLibrary()
                    self.browseCatalog()
                } else {
                    self.errorMessage = error.isEmpty ? "Unable to sync this store account." : error
                }
            }
        }
    }

    func linkSelectedStoreAccount() {
        guard let store = selectedPlatformOption(in: selectedGame)?.accountStore, !store.isEmpty else { return }
        linkStoreAccount(store)
    }

    func linkStoreAccount(_ store: String) {
        guard !store.isEmpty else { return }
        let selfBox = CatalogWeakObject(self)
        setActionMessage("Opening \(displayName(forStore: store)) account linking...")
        GameServiceSwiftAdapter.startAccountLinking(store: store) { success, error in
            Task { @MainActor in
                guard let self = selfBox.value else { return }
                if success {
                    self.actionMessage = "Account linked."
                    self.loadAccountAndStores()
                    self.loadLibrary()
                    self.browseCatalog()
                } else {
                    self.errorMessage = error.isEmpty ? "Unable to link this store account." : error
                }
            }
        }
    }

    func selectedVariant(in game: CatalogGameObject?) -> CatalogGameVariantObject? {
        guard let game else { return nil }
        let index = selectedVariantIndex >= 0 ? selectedVariantIndex : Self.preferredVariantIndex(for: game)
        guard index >= 0, index < game.variants.count else { return nil }
        return game.variants[index]
    }

    func selectedPlatformOption(in game: CatalogGameObject?) -> CatalogPlatformOption? {
        let options = platformOptions(for: game)
        return options.first(where: { $0.isSelected }) ?? options.first
    }

    func selectedPlatformHasAccess(in game: CatalogGameObject?) -> Bool {
        selectedPlatformOption(in: game)?.hasAccess == true
    }

    func storeIconURL(for game: CatalogGameObject) -> URL? {
        let raw = selectedPlatformOption(in: game)?.iconURL.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return raw.isEmpty ? nil : URL(string: raw)
    }

    func platformOptions(for game: CatalogGameObject?) -> [CatalogPlatformOption] {
        guard let game else { return [] }
        let selectedIndex = selectedVariantIndex >= 0 ? selectedVariantIndex : Self.preferredVariantIndex(for: game)
        return game.variants.enumerated().map { index, variant in
            let subscriptionIds = Self.visibleSubscriptionIds(for: variant)
            let subscriptionDefinition = subscriptionDefinition(for: subscriptionIds)
            let accountStore = subscriptionDefinition?.primaryStore.isEmpty == false ? subscriptionDefinition?.primaryStore ?? "" : variant.appStore
            let account = accountStatus(forStore: accountStore)
            let storeDefinition = storeDefinition(forStore: accountStore)
            let isOwned = Self.variantIsOwned(variant, in: game)
            let hasSubscriptionEntitlement = subscriptionIds.contains { accountHasSubscription($0) }
            let isUnavailable = Self.variantIsUnavailable(variant)
            let isSubscription = !subscriptionIds.isEmpty
            let title = displayName(forVariant: variant)
            let iconURL = iconURL(forVariant: variant)
            let canLink = account == nil && storeDefinition?.isAccountLinkingSupported == true
            let canSync = account?.hasAccountSyncingData == true
            return CatalogPlatformOption(
                id: variant.id.isEmpty ? "\(index)-\(variant.appStore)-\(title)" : variant.id,
                variantIndex: index,
                variant: variant,
                title: title,
                iconURL: iconURL,
                store: variant.appStore,
                subscriptionIds: subscriptionIds,
                primaryStore: accountStore,
                isSubscription: isSubscription,
                isOwned: isOwned,
                hasSubscriptionEntitlement: hasSubscriptionEntitlement,
                hasAccess: isOwned || hasSubscriptionEntitlement,
                isSelected: selectedIndex == index,
                isUnavailable: isUnavailable,
                canLink: canLink,
                canSync: canSync,
                accountDisplayName: account?.userDisplayName ?? "",
                status: platformStatusLabel(isOwned: isOwned, hasSubscriptionEntitlement: hasSubscriptionEntitlement, isUnavailable: isUnavailable, isSubscription: isSubscription, account: account, canLink: canLink, canSync: canSync)
            )
        }
    }

    func displayName(forStore store: String) -> String {
        if let definition = storeDefinitions.first(where: { $0.store.caseInsensitiveCompare(store) == .orderedSame }), !definition.label.isEmpty {
            return definition.label
        }
        return store.isEmpty ? "Store" : store.uppercased()
    }

    func displayName(forSubscription subscription: String) -> String {
        if let definition = subscriptionDefinitions.first(where: { $0.subscription.caseInsensitiveCompare(subscription) == .orderedSame }), !definition.label.isEmpty {
            return definition.label
        }
        return subscription.isEmpty ? "Subscription" : subscription.replacingOccurrences(of: "_", with: " ").capitalized
    }

    func iconURL(forSubscription subscription: String) -> String {
        subscriptionDefinitions.first { $0.subscription.caseInsensitiveCompare(subscription) == .orderedSame }?.logoURL ?? ""
    }

    func displayName(forVariant variant: CatalogGameVariantObject) -> String {
        let subscriptionNames = Self.visibleSubscriptionIds(for: variant).map { displayName(forSubscription: $0) }
        if !subscriptionNames.isEmpty { return subscriptionNames.joined(separator: " / ") }
        if !variant.appStoreLabel.isEmpty { return variant.appStoreLabel }
        return variant.appStore.isEmpty ? "GeForce NOW" : displayName(forStore: variant.appStore)
    }

    func iconURL(forVariant variant: CatalogGameVariantObject) -> String {
        let subscription = Self.visibleSubscriptionIds(for: variant).first ?? ""
        let subscriptionIconURL = iconURL(forSubscription: subscription)
        if !subscriptionIconURL.isEmpty { return subscriptionIconURL }
        return variant.appStoreSmallImageUrl
    }

    func accountStatus(forStore store: String) -> CatalogStoreAccount? {
        accountStores.first { $0.store.caseInsensitiveCompare(store) == .orderedSame }
    }

    private func accountHasSubscription(_ subscription: String) -> Bool {
        accountSubscriptions.contains { $0.caseInsensitiveCompare(subscription) == .orderedSame }
    }

    private func storeDefinition(forStore store: String) -> CatalogStoreDefinition? {
        storeDefinitions.first { $0.store.caseInsensitiveCompare(store) == .orderedSame }
    }

    private func subscriptionDefinition(for subscriptionIds: [String]) -> CatalogSubscriptionDefinition? {
        for subscription in subscriptionIds {
            if let definition = subscriptionDefinitions.first(where: { $0.subscription.caseInsensitiveCompare(subscription) == .orderedSame }) {
                return definition
            }
        }
        return nil
    }

    private func platformStatusLabel(isOwned: Bool, hasSubscriptionEntitlement: Bool, isUnavailable: Bool, isSubscription: Bool, account: CatalogStoreAccount?, canLink: Bool, canSync: Bool) -> String {
        if isOwned { return "Owned" }
        if hasSubscriptionEntitlement { return "Subscribed" }
        if isUnavailable { return "Game not found" }
        if canSync { return "Sync available" }
        if account?.hasAccountLinkingData == true { return "Connected" }
        if canLink { return "Connect" }
        if isSubscription { return "Subscription required" }
        return ""
    }

    var streamingQualityProfileAllowsCustomization: Bool {
        streamProfile.allowsStreamingCustomization
    }

    private func canEditStreamingQualitySettings() -> Bool {
        streamingQualityProfileAllowsCustomization
    }

    func setAspectIndex(_ index: Int) {
        guard canEditStreamingQualitySettings() else { return }
        StreamPreferences.saveAspectIndex(index)
        loadSettingsPreferences()
    }

    func setResolutionIndex(_ index: Int) {
        guard canEditStreamingQualitySettings() else { return }
        StreamPreferences.saveResolutionIndex(index)
        loadSettingsPreferences()
    }

    func setFpsIndex(_ index: Int) {
        guard canEditStreamingQualitySettings() else { return }
        StreamPreferences.saveFpsIndex(index)
        loadSettingsPreferences()
    }

    func setCodecIndex(_ index: Int) {
        guard canEditStreamingQualitySettings() else { return }
        StreamPreferences.saveCodecIndex(index)
        loadSettingsPreferences()
    }

    func setBitrateIndex(_ index: Int) {
        guard canEditStreamingQualitySettings() else { return }
        StreamPreferences.saveBitrateIndex(index)
        loadSettingsPreferences()
    }

    func setColorQualityIndex(_ index: Int) {
        guard canEditStreamingQualitySettings() else { return }
        StreamPreferences.saveColorQualityIndex(index)
        loadSettingsPreferences()
    }

    func setStreamingQualityProfileIndex(_ index: Int) {
        StreamPreferences.saveStreamingQualityProfileIndex(index)
        loadSettingsPreferences()
    }

    func setCloudGsyncEnabled(_ enabled: Bool) {
        guard canEditStreamingQualitySettings() else { return }
        StreamPreferences.saveCloudGsyncEnabled(enabled)
        loadSettingsPreferences()
    }

    func setFallbackToLogicalResolution(_ enabled: Bool) {
        guard canEditStreamingQualitySettings() else { return }
        StreamPreferences.saveFallbackToLogicalResolution(enabled)
        loadSettingsPreferences()
    }

    func setHudStreamingModeIndex(_ index: Int) {
        guard canEditStreamingQualitySettings() else { return }
        StreamPreferences.saveHudStreamingModeIndex(index)
        loadSettingsPreferences()
    }

    func setSDRColorSpaceIndex(_ index: Int) {
        guard canEditStreamingQualitySettings() else { return }
        StreamPreferences.saveSDRColorSpaceIndex(index)
        loadSettingsPreferences()
    }

    func setHDRColorSpaceIndex(_ index: Int) {
        guard canEditStreamingQualitySettings() else { return }
        StreamPreferences.saveHDRColorSpaceIndex(index)
        loadSettingsPreferences()
    }

    func setPrefilterModeIndex(_ index: Int) {
        StreamPreferences.savePrefilterModeIndex(index)
        loadSettingsPreferences()
    }

    func setPrefilterSharpness(_ value: Double) {
        StreamPreferences.savePrefilterSharpness(Int(value.rounded()))
        loadSettingsPreferences()
    }

    func setPrefilterDenoise(_ value: Double) {
        StreamPreferences.savePrefilterDenoise(Int(value.rounded()))
        loadSettingsPreferences()
    }

    func setUpscalingModeIndex(_ index: Int) {
        StreamPreferences.saveUpscalingModeIndex(index)
        loadSettingsPreferences()
    }

    func setUpscalingSharpness(_ value: Double) {
        StreamPreferences.saveUpscalingSharpness(Int(value.rounded()))
        loadSettingsPreferences()
    }

    func setUpscalingDenoise(_ value: Double) {
        StreamPreferences.saveUpscalingDenoise(Int(value.rounded()))
        loadSettingsPreferences()
    }

    func setL4SEnabled(_ enabled: Bool) {
        guard canEditStreamingQualitySettings() else { return }
        StreamPreferences.saveL4SEnabled(enabled)
        loadSettingsPreferences()
    }

    func setHDREnabled(_ enabled: Bool) {
        guard canEditStreamingQualitySettings() else { return }
        StreamPreferences.saveHDREnabled(enabled)
        loadSettingsPreferences()
    }

    func setPowerSaverEnabled(_ enabled: Bool) {
        guard canEditStreamingQualitySettings() else { return }
        StreamPreferences.savePowerSaverEnabled(enabled)
        loadSettingsPreferences()
    }

    func setSuppressInputWhenInactive(_ enabled: Bool) {
        StreamPreferences.saveSuppressInputWhenInactive(enabled)
        loadSettingsPreferences()
    }

    func setDirectMouseInputEnabled(_ enabled: Bool) {
        StreamPreferences.saveDirectMouseInputEnabled(enabled)
        loadSettingsPreferences()
    }

    func setAntiAFKMouseMovementEnabled(_ enabled: Bool) {
        StreamPreferences.saveAntiAFKMouseMovementEnabled(enabled)
        actionMessage = enabled ? "Anti-AFK mouse movement enabled." : "Anti-AFK mouse movement disabled."
        loadSettingsPreferences()
    }

    func setRemoteCoOpEnabled(_ enabled: Bool) {
        RemoteCoOpPreferencesStore.setEnabled(enabled)
        remoteCoOpPreferences = RemoteCoOpPreferencesStore.load()
        actionMessage = enabled ? "Remote Co-Op enabled. Reserved guest slots apply to newly launched streams." : "Remote Co-Op disabled."
        loadSettingsPreferences()
    }

    func setRemoteCoOpAlphaOptedIn(_ optedIn: Bool) {
        RemoteCoOpPreferencesStore.setAlphaOptedIn(optedIn)
        remoteCoOpPreferences = RemoteCoOpPreferencesStore.load()
        actionMessage = optedIn ? "Remote Co-Op alpha access enabled. Configure Remote Co-Op from Gameplay settings." : "Remote Co-Op alpha access disabled. Remote Co-Op settings are hidden."
        loadSettingsPreferences()
    }

    func setRemoteCoOpReservedGuestSlots(_ index: Int) {
        RemoteCoOpPreferencesStore.setReservedGuestSlots(index)
        remoteCoOpPreferences = RemoteCoOpPreferencesStore.load()
        actionMessage = index > 0 ? "Remote Co-Op will reserve \(index) guest controller slot(s) on newly launched streams." : "Remote Co-Op guest controller slots disabled."
        loadSettingsPreferences()
    }

    func setRemoteCoOpTransportModeIndex(_ index: Int) {
        let modes = RemoteCoOpTransportMode.allCases
        guard modes.indices.contains(index) else { return }
        RemoteCoOpPreferencesStore.setTransportMode(modes[index])
        remoteCoOpPreferences = RemoteCoOpPreferencesStore.load()
        loadSettingsPreferences()
    }

    func setRemoteCoOpQualityPresetIndex(_ index: Int) {
        let presets = RemoteCoOpQualityPreset.allCases
        guard presets.indices.contains(index) else { return }
        RemoteCoOpPreferencesStore.setQualityPreset(presets[index])
        remoteCoOpPreferences = RemoteCoOpPreferencesStore.load()
        loadSettingsPreferences()
    }

    func setRemoteCoOpLatencyModeIndex(_ index: Int) {
        let modes = RemoteCoOpLatencyMode.allCases
        guard modes.indices.contains(index) else { return }
        RemoteCoOpPreferencesStore.setLatencyMode(modes[index])
        remoteCoOpPreferences = RemoteCoOpPreferencesStore.load()
        loadSettingsPreferences()
    }

    func setRemoteCoOpRequireHostApproval(_ required: Bool) {
        RemoteCoOpPreferencesStore.setRequireHostApproval(required)
        remoteCoOpPreferences = RemoteCoOpPreferencesStore.load()
        loadSettingsPreferences()
    }

    func setRemoteCoOpSignalingServerURL(_ url: String) {
        RemoteCoOpPreferencesStore.setSignalingServerURL(url)
        remoteCoOpPreferences = RemoteCoOpPreferencesStore.load()
        loadSettingsPreferences()
    }

    func setRemoteCoOpGuestJoinBaseURL(_ url: String) {
        RemoteCoOpPreferencesStore.setGuestJoinBaseURL(url)
        remoteCoOpPreferences = RemoteCoOpPreferencesStore.load()
        loadSettingsPreferences()
    }

    func setRemoteCoOpHideGuestInviteDetails(_ hidden: Bool) {
        RemoteCoOpPreferencesStore.setHideGuestInviteDetails(hidden)
        remoteCoOpPreferences = RemoteCoOpPreferencesStore.load()
        actionMessage = hidden ? "Remote Co-Op guest invites will hide game details." : "Remote Co-Op guest invites will show game details."
        loadSettingsPreferences()
    }

    func setPreventDisplaySleepWhileStreaming(_ enabled: Bool) {
        StreamPreferences.savePreventDisplaySleepWhileStreaming(enabled)
        actionMessage = enabled ? "Display sleep prevention enabled for active streams." : "Display sleep prevention disabled for active streams."
        loadSettingsPreferences()
    }

    func setRecordingVideoBitrateMbps(_ value: Double) {
        StreamPreferences.saveRecordingVideoBitrateMbps(Int(value.rounded()))
        loadSettingsPreferences()
    }

    func setRecordingAudioBitrateKbps(_ value: Double) {
        StreamPreferences.saveRecordingAudioBitrateKbps(Int(value.rounded()))
        loadSettingsPreferences()
    }

    func setRecordingEnhancedVideoEnabled(_ enabled: Bool) {
        StreamPreferences.saveRecordingEnhancedVideoEnabled(enabled)
        loadSettingsPreferences()
    }

    func setGameVolume(_ value: Double) {
        StreamPreferences.saveGameVolume(value)
        loadSettingsPreferences()
    }

    func setMicrophoneVolume(_ value: Double) {
        StreamPreferences.saveMicrophoneVolume(value)
        loadSettingsPreferences()
    }

    func setMicrophoneMode(_ mode: String) {
        StreamPreferences.saveMicrophoneMode(mode)
        loadSettingsPreferences()
    }

    func setMicrophoneDeviceId(_ deviceId: String) {
        StreamPreferences.saveMicrophoneDeviceId(deviceId)
        loadSettingsPreferences()
    }

    var microphoneShortcutEnabled: Bool {
        StreamPreferences.loadMicrophoneShortcutEnabled()
    }

    func setMicrophoneShortcutEnabled(_ enabled: Bool) {
        StreamPreferences.saveMicrophoneShortcutEnabled(enabled)
        loadSettingsPreferences()
    }

    var showStreamMicToggle: Bool {
        StreamPreferences.loadShowStreamMicToggle()
    }

    func setShowStreamMicToggle(_ enabled: Bool) {
        StreamPreferences.saveShowStreamMicToggle(enabled)
        loadSettingsPreferences()
    }

    var streamMicrophoneEnabled: Bool {
        StreamPreferences.loadStreamMicrophoneEnabled()
    }

    func setStreamMicrophoneEnabled(_ enabled: Bool) {
        StreamPreferences.saveStreamMicrophoneEnabled(enabled)
        loadSettingsPreferences()
    }

    func restoreStreamingProfileDefaults() {
        StreamPreferences.restoreStreamingProfileDefaults()
        actionMessage = "Streaming profile defaults restored."
        loadSettingsPreferences()
    }

    func refreshCatalogImageCacheSummary() {
        Task { @MainActor in
            let statistics = await CatalogImageCache.shared.statistics()
            catalogImageCacheSummary = Self.formattedCacheSummary(statistics)
        }
    }

    func clearCatalogImageCache() {
        Task { @MainActor in
            let cleared = await CatalogImageCache.shared.clear()
            actionMessage = cleared ? "Catalog image cache cleared." : "Unable to clear catalog image cache."
            refreshCatalogImageCacheSummary()
        }
    }

    func optimizedImageURL(_ rawValue: String, width: Int) -> URL? {
        guard !rawValue.isEmpty else { return nil }
        let optimized = GameServiceSwiftAdapter.optimizeImageURL(rawValue, width: width)
        return URL(string: optimized.isEmpty ? rawValue : optimized)
    }

    private static func formattedCacheSummary(_ statistics: CatalogImageCacheStatistics) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        let bytes = formatter.string(fromByteCount: Int64(statistics.totalBytes))
        let entryLabel = statistics.entryCount == 1 ? "entry" : "entries"
        return "\(bytes) / \(statistics.entryCount) \(entryLabel)"
    }

    private func loadPanels() {
        isLoadingPanels = true
        errorMessage = ""
        configureCatalogService()
        let selfBox = CatalogWeakObject(self)
        GameServiceSwiftAdapter.fetchMarqueePanelObjects { success, panels, error in
            let panelBox = CatalogSendableValue(panels)
            Task { @MainActor in
                guard let self = selfBox.value else { return }
                if success {
                    self.marqueePanels = panelBox.value
                    self.schedulePatchingPollIfNeeded()
                } else if self.refreshAuthIfNeeded(error: error) {
                    self.isLoadingPanels = false
                } else if self.errorMessage.isEmpty {
                    self.errorMessage = error
                }
            }
        }
        GameServiceSwiftAdapter.fetchMainPanelObjects { success, panels, error in
            let panelBox = CatalogSendableValue(panels)
            Task { @MainActor in
                guard let self = selfBox.value else { return }
                self.isLoadingPanels = false
                if success {
                    self.mainPanels = panelBox.value
                    self.schedulePatchingPollIfNeeded()
                } else if self.refreshAuthIfNeeded(error: error) {
                    self.isLoadingPanels = false
                } else if self.errorMessage.isEmpty {
                    self.errorMessage = error.isEmpty ? "Unable to load GeForce NOW home panels." : error
                }
            }
        }
    }

    private func loadLibrary() {
        configureCatalogService()
        let selfBox = CatalogWeakObject(self)
        GameServiceSwiftAdapter.fetchLibraryGameObjects { success, games, error in
            let gamesBox = CatalogSendableValue(games)
            Task { @MainActor in
                guard let self = selfBox.value else { return }
                if success {
                    let ownedGames = gamesBox.value.filter { $0.isInLibrary || Self.gameHasOwnedVariant($0) }
                    self.libraryGames = ownedGames.isEmpty && !gamesBox.value.isEmpty ? gamesBox.value : ownedGames
                    for game in self.libraryGames {
                        game.isInLibrary = true
                    }
                    self.schedulePatchingPollIfNeeded()
                } else if self.refreshAuthIfNeeded(error: error) {
                    self.libraryGames = []
                }
            }
        }
    }

    private func loadFavorites() {
        configureCatalogService()
        let selfBox = CatalogWeakObject(self)
        GameServiceSwiftAdapter.fetchFavoriteGameObjects { success, games, error in
            let gamesBox = CatalogSendableValue(games)
            Task { @MainActor in
                guard let self = selfBox.value else { return }
                if success {
                    self.updateFavoriteGames(gamesBox.value)
                    self.schedulePatchingPollIfNeeded()
                } else if self.refreshAuthIfNeeded(error: error) {
                    self.updateFavoriteGames([])
                } else if self.errorMessage.isEmpty {
                    self.errorMessage = error.isEmpty ? "Unable to load GeForce NOW favorites." : error
                }
            }
        }
    }

    private func updateFavoriteGames(_ games: [CatalogGameObject]) {
        var uniqueGames: [CatalogGameObject] = []
        var identities = Set<String>()
        for game in games {
            let identity = Self.identity(for: game)
            guard !identity.isEmpty, identities.insert(identity).inserted else { continue }
            game.isFavorited = true
            uniqueGames.append(game)
            if uniqueGames.count >= Self.maxFavoritesLimit {
                break
            }
        }
        favoriteGames = uniqueGames
        favoriteGameIdentities = identities
        for game in allKnownGames {
            let ident = Self.identity(for: game)
            game.isFavorited = identities.contains(ident)
        }
    }

    private func loadAccountAndStores() {
        configureCatalogService()
        let selfBox = CatalogWeakObject(self)
        GameServiceSwiftAdapter.fetchUserAccountDictionary { success, account, error in
            let accountBox = CatalogSendableValue(account)
            Task { @MainActor in
                guard let self = selfBox.value else { return }
                if success {
                    self.accountStores = Self.parseStoreAccounts(accountBox.value)
                    self.accountSubscriptions = Self.parseAccountSubscriptions(accountBox.value)
                } else if self.refreshAuthIfNeeded(error: error) {
                    self.accountStores = []
                    self.accountSubscriptions = []
                }
            }
        }
        GameServiceSwiftAdapter.fetchStoreDefinitionDictionaries { success, definitions, _ in
            let definitionsBox = CatalogSendableValue(definitions)
            Task { @MainActor in
                guard let self = selfBox.value else { return }
                if success { self.storeDefinitions = definitionsBox.value.map(Self.parseStoreDefinition) }
            }
        }
        GameServiceSwiftAdapter.fetchSubscriptionDefinitionDictionaries { success, definitions, _ in
            let definitionsBox = CatalogSendableValue(definitions)
            Task { @MainActor in
                guard let self = selfBox.value else { return }
                if success { self.subscriptionDefinitions = definitionsBox.value.map(Self.parseSubscriptionDefinition) }
            }
        }
        let userId = session.userId.isEmpty ? account.userId : session.userId
        guard !userId.isEmpty else {
            subscriptionStatus = .unavailable
            return
        }
        GameServiceSwiftAdapter.fetchSubscriptionInfo(userId: userId) { success, subscription, error in
            let subscriptionBox = CatalogSendableValue(subscription)
            Task { @MainActor in
                guard let self = selfBox.value else { return }
                if success {
                    let subscription = subscriptionBox.value
                    self.subscriptionStatus = CatalogSubscriptionStatus(subscription: subscription)
                    let membershipTier = subscription.membershipTier.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !membershipTier.isEmpty {
                        self.account.membershipTier = membershipTier
                    }
                } else if self.refreshAuthIfNeeded(error: error) {
                    self.subscriptionStatus = .unavailable
                }
            }
        }
    }

    private func loadSettingsPreferences() {
        settingsPreferencesGeneration += 1
        let generation = settingsPreferencesGeneration
        let userId = Self.playtimeAccountIdentifier(account: account, session: session)
        settingsPreferencesTask?.cancel()
        settingsPreferencesTask = Task.detached(priority: .userInitiated) {
            let capabilities = StreamPreferences.loadDeviceCapabilities()
            var profile = StreamPreferences.effectiveProfile(StreamPreferences.loadProfile(), capabilities: capabilities)
            let nativeNVSTRuntimeAvailable = true
            let nativeNVSTRuntimeMessage = "Native NVST runtime is available."
            let snapshot = CatalogSettingsPreferencesSnapshot(
                capabilities: capabilities,
                profile: profile,
                nativeNVSTRuntimeAvailable: nativeNVSTRuntimeAvailable,
                nativeNVSTRuntimeMessage: nativeNVSTRuntimeMessage,
                remoteCoOpPreferences: RemoteCoOpPreferencesStore.load(),
                selectedRegionUrl: StreamPreferences.loadSelectedRegionUrl(userId: userId),
                regionOptions: Self.launchRegionOptions(from: StreamPreferences.loadCachedRegions(userId: userId)),
                microphoneDeviceOptions: StreamPreferences.loadMicrophoneDeviceOptions()
            )
            await MainActor.run { [weak self] in
                guard let self, generation == self.settingsPreferencesGeneration, !Task.isCancelled else { return }
                self.streamCapabilities = snapshot.capabilities
                self.streamProfile = snapshot.profile
                self.nativeNVSTRuntimeAvailable = snapshot.nativeNVSTRuntimeAvailable
                self.nativeNVSTRuntimeMessage = snapshot.nativeNVSTRuntimeMessage
                self.remoteCoOpPreferences = snapshot.remoteCoOpPreferences
                self.selectedSettingsRegionUrl = snapshot.selectedRegionUrl
                self.settingsRegionOptions = snapshot.regionOptions
                self.unavailableSettingsRegionUrl = snapshot.selectedRegionUrl.isEmpty || snapshot.regionOptions.contains(where: { $0.url == snapshot.selectedRegionUrl }) ? "" : snapshot.selectedRegionUrl
                self.microphoneDeviceOptions = snapshot.microphoneDeviceOptions
                self.settingsPreferencesTask = nil
            }
        }
    }

    private func refreshCatalogAfterOwnershipChange() {
        loadLibrary()
        browseCatalog()
        if let selectedGame {
            let selectedIdentity = Self.identity(for: selectedGame)
            let refreshedGame = (libraryGames + catalogGames).first { Self.identity(for: $0) == selectedIdentity }
            if let refreshedGame { selectGame(refreshedGame) }
        }
    }

    private func schedulePatchingPollIfNeeded(immediate: Bool = true) {
        let patchingAppIds = patchingPollAppIds()
        guard !patchingAppIds.isEmpty else {
            patchingPollTask?.cancel()
            patchingPollTask = nil
            return
        }
        guard patchingPollTask == nil else {
            if immediate {
                Task { @MainActor [weak self] in await self?.refreshPatchingStatuses() }
            }
            return
        }
        patchingPollTask = Task { @MainActor [weak self] in
            if immediate { await self?.refreshPatchingStatuses() }
            while let self, !Task.isCancelled {
                let delaySeconds = UInt64(Int.random(in: 30...60))
                try? await Task.sleep(for: .seconds(delaySeconds))
                guard !Task.isCancelled else { return }
                await self.refreshPatchingStatuses()
                if self.patchingPollAppIds().isEmpty {
                    self.patchingPollTask = nil
                    return
                }
            }
        }
    }

    private func refreshPatchingStatuses() async {
        guard !patchingPollInFlight else { return }
        let appIds = patchingPollAppIds()
        guard !appIds.isEmpty else { return }
        patchingPollInFlight = true
        defer { patchingPollInFlight = false }
        let libraryResult = await fetchLibraryPatchStatuses()
        let targetedResult = await fetchAppPatchStatuses(appIds: appIds)
        var mergedStatuses = libraryResult.statuses
        Self.mergePatchStatuses(targetedResult.statuses, into: &mergedStatuses)
        if !mergedStatuses.isEmpty {
            applyPatchingStatuses(mergedStatuses)
        }
        for error in [libraryResult.error, targetedResult.error] where !error.isEmpty {
            if refreshAuthIfNeeded(error: error) { return }
            Log.warning(.catalog, "App patch status poll failed: \(error)")
        }
    }

    private func fetchLibraryPatchStatuses() async -> (statuses: [String: AppPatchStatus], error: String) {
        await withCheckedContinuation { continuation in
            GameServiceSwiftAdapter.fetchLibraryPatchStatuses { success, statuses, error in
                continuation.resume(returning: (success ? statuses : [:], success ? "" : error))
            }
        }
    }

    private func fetchAppPatchStatuses(appIds: [String]) async -> (statuses: [String: AppPatchStatus], error: String) {
        await withCheckedContinuation { continuation in
            GameServiceSwiftAdapter.fetchAppPatchStatuses(appIds: appIds) { success, statuses, error in
                continuation.resume(returning: (success ? statuses : [:], success ? "" : error))
            }
        }
    }

    private func patchingPollAppIds() -> [String] {
        let ids = allKnownGames.filter(Self.isPatching).compactMap(Self.patchStatusAppId)
        return Array(Set(ids)).sorted()
    }

    private func applyPatchingStatuses(_ statuses: [String: AppPatchStatus]) {
        guard !statuses.isEmpty else { return }
        updatePatchingStatuses(in: &catalogGames, statuses: statuses)
        updatePatchingStatuses(in: &libraryGames, statuses: statuses)
        updatePatchingStatuses(in: &favoriteGames, statuses: statuses)
        updatePatchingStatuses(in: &marqueePanels, statuses: statuses)
        updatePatchingStatuses(in: &mainPanels, statuses: statuses)
        if let selectedGame, let status = Self.patchStatus(for: selectedGame, statuses: statuses) {
            applyPatchingStatus(status, to: selectedGame)
        }
        launchQueuedPatchingGameIfReady()
    }

    private func updatePatchingStatuses(in games: inout [CatalogGameObject], statuses: [String: AppPatchStatus]) {
        for game in games {
            guard let status = Self.patchStatus(for: game, statuses: statuses) else { continue }
            applyPatchingStatus(status, to: game)
        }
    }

    private func updatePatchingStatuses(in panels: inout [CatalogPanelObject], statuses: [String: AppPatchStatus]) {
        for panel in panels {
            for section in panel.sections {
                for game in section.games {
                    guard let status = Self.patchStatus(for: game, statuses: statuses) else { continue }
                    applyPatchingStatus(status, to: game)
                }
            }
        }
    }

    private func applyPatchingStatus(_ status: AppPatchStatus, to game: CatalogGameObject) {
        for variant in game.variants {
            if let isPatching = status.variantPatchingById[variant.id] {
                variant.isPatching = isPatching
                variant.patchStatusPrimaryText = isPatching ? status.primaryTextByVariantId[variant.id] ?? variant.patchStatusPrimaryText : ""
                variant.patchStatusSecondaryText = isPatching ? status.secondaryTextByVariantId[variant.id] ?? variant.patchStatusSecondaryText : ""
            }
        }
        game.isPatching = status.isPatching || game.variants.contains { $0.isPatching }
        game.patchStatusPrimaryText = game.isPatching ? game.variants.first { !$0.patchStatusPrimaryText.isEmpty }?.patchStatusPrimaryText ?? status.primaryTextByVariantId.values.first ?? "Patching" : ""
        game.patchStatusSecondaryText = game.isPatching ? game.variants.first { !$0.patchStatusSecondaryText.isEmpty }?.patchStatusSecondaryText ?? status.secondaryTextByVariantId.values.first ?? "" : ""
    }

    private static func mergePatchStatuses(_ source: [String: AppPatchStatus], into target: inout [String: AppPatchStatus]) {
        for (appId, status) in source {
            guard var existing = target[appId] else {
                target[appId] = status
                continue
            }
            existing.isPatching = existing.isPatching || status.isPatching
            existing.variantPatchingById.merge(status.variantPatchingById) { _, new in new }
            existing.primaryTextByVariantId.merge(status.primaryTextByVariantId) { _, new in new }
            existing.secondaryTextByVariantId.merge(status.secondaryTextByVariantId) { _, new in new }
            target[appId] = existing
        }
    }

    private func launchQueuedPatchingGameIfReady() {
        guard !queuedPatchingLaunchIdentity.isEmpty else { return }
        guard let game = allKnownGames.first(where: { Self.identity(for: $0) == queuedPatchingLaunchIdentity }) else { return }
        guard !Self.isPatching(game) else { return }
        let variantIndex = queuedPatchingLaunchVariantIndex
        let title = queuedPatchingLaunchGameTitle.isEmpty ? (game.title.isEmpty ? "GeForce NOW" : game.title) : queuedPatchingLaunchGameTitle
        queuedPatchingLaunchIdentity = ""
        queuedPatchingLaunchVariantIndex = -1
        queuedPatchingLaunchGameTitle = ""
        actionMessage = "Patching finished. Launching \(title)..."
        selectGame(game)
        launch(game: game, variantIndex: variantIndex)
    }

    private func selectedVariantIndexIfMatching(_ game: CatalogGameObject) -> Int? {
        guard let selectedGame, Self.identity(for: selectedGame) == Self.identity(for: game) else { return nil }
        return selectedVariantIndex
    }

    private func updateSelectedGameOwnership(gameIdentity: String, variantId: String, inLibrary: Bool) {
        guard let selectedGame, Self.identity(for: selectedGame) == gameIdentity else { return }
        for variant in selectedGame.variants where variant.id == variantId {
            variant.inLibrary = inLibrary
            variant.librarySelected = inLibrary
        }
        selectedGame.isInLibrary = Self.gameHasOwnedVariant(selectedGame)
    }

    private func updateGameFavoriteState(identity: String, isFavorited: Bool) {
        guard !identity.isEmpty else { return }
        func update(_ games: [CatalogGameObject]) {
            for game in games where Self.identity(for: game) == identity {
                game.isFavorited = isFavorited
            }
        }
        if selectedGame.map(Self.identity(for:)) == identity { selectedGame?.isFavorited = isFavorited }
        update(catalogGames)
        update(libraryGames)
        update(favoriteGames)
        update(marqueeGames)
        update(mainPanelGames)
        for games in fullSectionGames.values { update(games) }
    }

    private func setActionMessage(_ message: String) {
        actionMessage = message
        errorMessage = ""
    }

    private static func appendUniqueHeroGames(from source: [CatalogGameObject], into games: inout [CatalogGameObject], seen: inout Set<String>) {
        for game in source {
            guard hasMarqueeHeroArtwork(game) else { continue }
            let identity = identity(for: game)
            guard !identity.isEmpty, !seen.contains(identity) else { continue }
            seen.insert(identity)
            games.append(game)
        }
    }

    private static func isPatching(_ game: CatalogGameObject) -> Bool {
        game.isPatching || game.variants.contains { $0.isPatching }
    }

    private static func patchStatusAppId(_ game: CatalogGameObject) -> String? {
        for value in [game.uuid, game.id, game.launchAppId] where !value.isEmpty { return value }
        return nil
    }

    private static func patchStatus(for game: CatalogGameObject, statuses: [String: AppPatchStatus]) -> AppPatchStatus? {
        for key in [game.uuid, game.id, game.launchAppId] where !key.isEmpty {
            if let status = statuses[key] { return status }
        }
        return nil
    }

    private static func hasMarqueeHeroArtwork(_ game: CatalogGameObject) -> Bool {
        for key in ["MARQUEE_HERO_IMAGE", "marquee_hero_image"] {
            if game.imageUrlsByType[key]?.contains(where: { !$0.isEmpty }) == true { return true }
        }
        return false
    }

    private func syncingOwnershipMessage(for game: CatalogGameObject) -> String {
        let stores = Self.uniqueNonEmpty(game.variants.map { displayName(forStore: $0.appStore) })
        if stores.isEmpty { return "Syncing connected game libraries..." }
        if stores.count == 1 { return "Syncing \(stores[0]) game library..." }
        return "Syncing \(stores.dropLast().joined(separator: ", ")) and \(stores.last ?? "") game libraries..."
    }

    private static func uniqueNonEmpty(_ values: [String]) -> [String] {
        var result: [String] = []
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !result.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) else { continue }
            result.append(trimmed)
        }
        return result
    }

    private func matchingGame(for shortcut: GFNGameShortcut, in games: [CatalogGameObject]) -> CatalogGameObject? {
        let identifiers = Set([shortcut.cmsId, shortcut.shortName, shortcut.parentGameId].map { $0.lowercased() }.filter { !$0.isEmpty })
        if !identifiers.isEmpty {
            for game in games where game.matchesGFNShortcutIdentifiers(identifiers) { return game }
        }
        let title = shortcut.lookupTitle
        guard !title.isEmpty else { return nil }
        return games.first { $0.title.caseInsensitiveCompare(title) == .orderedSame }
    }

    private func variantIndex(for shortcut: GFNGameShortcut, in game: CatalogGameObject) -> Int {
        if !shortcut.cmsId.isEmpty, let index = game.variants.firstIndex(where: { $0.id.caseInsensitiveCompare(shortcut.cmsId) == .orderedSame }) {
            return index
        }
        return Self.preferredVariantIndex(for: game)
    }

    private func resolveSelectedStoreURL(completion: @escaping @Sendable (URL?) -> Void) {
        guard let selectedGame else {
            completion(nil)
            return
        }
        let variantIndex = selectedVariantIndex >= 0 ? selectedVariantIndex : Self.preferredVariantIndex(for: selectedGame)
        if variantIndex >= 0, variantIndex < selectedGame.variants.count {
            let variant = selectedGame.variants[variantIndex]
            if let url = URL(string: variant.storeUrl), !variant.storeUrl.isEmpty {
                completion(url)
                return
            }
        }
        if let url = selectedGame.primaryStoreURL {
            completion(url)
            return
        }
        let selfBox = CatalogWeakObject(self)
        GameServiceSwiftAdapter.resolveStoreURL(game: selectedGame, variantIndex: max(variantIndex, 0)) { success, storeURL, _ in
            Task { @MainActor in
                guard selfBox.value != nil else { return }
                completion(success ? URL(string: storeURL) : nil)
            }
        }
    }

    private func configureCatalogService() {
        let userId = session.userId.isEmpty ? account.userId : session.userId
        GameServiceSwiftAdapter.configureCatalogSession(accessToken: session.accessToken, idToken: session.idToken, userId: userId)
        SessionManager.shared.setAccessToken(session.accessToken)
        if let canonical = AccountStorageKeys.requireUserId(userId) {
            let storedRegion = StreamPreferences.loadSelectedRegionUrl(userId: canonical)
            if storedRegion.isEmpty {
                let preferred = account.preferredRegion.trimmingCharacters(in: .whitespacesAndNewlines)
                if !preferred.isEmpty, preferred.caseInsensitiveCompare("Auto") != .orderedSame {
                    StreamPreferences.saveSelectedRegionUrl(preferred, userId: canonical)
                }
            }
        }
    }

    private func refreshAuthIfNeeded(error: String) -> Bool {
        guard error.contains("401"), !authRefreshInFlight else { return false }
        authRefreshInFlight = true
        isLoading = false
        isLoadingPanels = false
        errorMessage = "Refreshing NVIDIA session..."
        Task { [weak self] in
            guard let self else { return }
            let refreshed = await onRefreshAuth()
            await MainActor.run {
                self.authRefreshInFlight = false
                guard refreshed else {
                    self.errorMessage = "NVIDIA session refresh failed. Sign in again or refresh the catalog after reconnecting."
                    return
                }
                self.errorMessage = ""
                self.refresh()
            }
        }
        return true
    }

    nonisolated static func identity(for game: CatalogGameObject) -> String {
        if !game.id.isEmpty { return game.id }
        if !game.uuid.isEmpty { return game.uuid }
        if !game.launchAppId.isEmpty { return game.launchAppId }
        return game.title
    }

    private static func favoriteAppId(for game: CatalogGameObject) -> String {
        if !game.id.isEmpty { return game.id }
        return game.uuid
    }

    private static func game(_ game: CatalogGameObject, matchesApplicationID applicationID: String) -> Bool {
        guard !applicationID.isEmpty else { return false }
        for value in [game.id, game.uuid, game.launchAppId, game.shortName] where value == applicationID {
            return true
        }
        return game.variants.contains { $0.id == applicationID }
    }

    static func looseIdentityMatches(_ lhs: CatalogGameObject, _ rhs: CatalogGameObject) -> Bool {
        let lhsIdentity = identity(for: lhs)
        let rhsIdentity = identity(for: rhs)
        if !lhsIdentity.isEmpty, !rhsIdentity.isEmpty, lhsIdentity == rhsIdentity { return true }
        return !lhs.title.isEmpty && lhs.title.caseInsensitiveCompare(rhs.title) == .orderedSame
    }

    private static func playtimeAccountIdentifier(account: LoginAccount, session: LoginSession) -> String {
        AccountStorageKeys.canonicalUserId(accountUserId: account.userId, sessionUserId: session.userId) ?? ""
    }

    private static func snapshotObject(for game: CatalogGameObject) -> CatalogGameObject {
        CatalogGameObject(game: game.swiftValue)
    }

    private static func safeShortcutFilename(_ title: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: ":/").union(.newlines).union(.controlCharacters)
        let sanitized = title.components(separatedBy: invalidCharacters).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let baseName = sanitized.isEmpty ? "GeForce NOW Game" : sanitized
        return "\(baseName) on GeForce NOW.gfnpc"
    }

    private static func applyShortcutIcon(to url: URL) {
        guard let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
              let icon = NSImage(contentsOf: iconURL) else { return }
        NSWorkspace.shared.setIcon(icon, forFile: url.path)
    }

    private func requestSelectedGameReveal(for game: CatalogGameObject, sectionId: String) {
        selectedGameRevealSequence += 1
        selectedGameRevealRequest = CatalogGameRevealRequest(sectionId: sectionId, gameIdentity: Self.identity(for: game), sequence: selectedGameRevealSequence)
    }

    private static func shortcutCMSId(for game: CatalogGameObject, variant: CatalogGameVariantObject?) -> String {
        for value in [variant?.id ?? "", game.launchAppId, game.id] where isPositiveInteger(value) {
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let variantId = game.variants.map(\.id).first(where: isPositiveInteger) {
            return variantId.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let variantId = variant?.id, !variantId.isEmpty { return variantId }
        return identity(for: game)
    }

    private static func launchGame(from shortcut: GFNGameShortcut, title: String) -> CatalogGameObject? {
        let cmsId = shortcut.cmsId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isPositiveInteger(cmsId) else { return nil }
        let game = CatalogGameObject()
        game.id = shortcut.parentGameId.isEmpty ? cmsId : shortcut.parentGameId
        game.uuid = game.id
        game.launchAppId = cmsId
        game.title = title.isEmpty ? "GeForce NOW" : title
        game.shortName = shortcut.shortName
        game.isInLibrary = true
        let variant = CatalogGameVariantObject()
        variant.id = cmsId
        variant.inLibrary = true
        variant.librarySelected = true
        game.variants = [variant]
        return game
    }

    private static func isPositiveInteger(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let intValue = Int(trimmed) else { return false }
        return intValue > 0
    }

    private func resolveGameForDetails(_ game: CatalogGameObject) -> CatalogGameObject {
        resolveGameForDetails(game, preferredSectionId: "")
    }

    private func resolveGameForDetails(_ game: CatalogGameObject, preferredSectionId: String) -> CatalogGameObject {
        if !preferredSectionId.isEmpty,
           let section = catalogSections.first(where: { $0.id == preferredSectionId }),
           let sectionGame = section.games.first(where: { Self.looseIdentityMatches($0, game) }) {
            return sectionGame
        }
        for section in catalogSections {
            if let sectionGame = section.games.first(where: { Self.looseIdentityMatches($0, game) }) {
                return sectionGame
            }
        }
        return game
    }

    static func preferredVariantIndex(for game: CatalogGameObject) -> Int {
        if let index = game.variants.firstIndex(where: { $0.librarySelected }) { return index }
        if let index = game.variants.firstIndex(where: { $0.inLibrary }) { return index }
        return game.variants.isEmpty ? -1 : 0
    }

    static func variantIsOwned(_ variant: CatalogGameVariantObject, in game: CatalogGameObject) -> Bool {
        variant.inLibrary || variant.librarySelected || GameRemediation.gameServiceStatusOwnedForLaunch(variant.serviceStatus) || (game.variants.count == 1 && game.isInLibrary)
    }

    static func gameHasOwnedVariant(_ game: CatalogGameObject) -> Bool {
        game.variants.contains { $0.inLibrary || $0.librarySelected || GameRemediation.gameServiceStatusOwnedForLaunch($0.serviceStatus) }
    }

    static func visibleSubscriptionIds(for variant: CatalogGameVariantObject) -> [String] {
        uniqueNonEmpty([variant.librarySubscription] + variant.subscriptionIds).filter { $0.caseInsensitiveCompare("NONE") != .orderedSame }
    }

    static func variantIsUnavailable(_ variant: CatalogGameVariantObject) -> Bool {
        let status = variant.serviceStatus.lowercased()
        return status.contains("not") || status.contains("unavailable") || status.contains("unsupported")
    }

    private static func parseAccountSubscriptions(_ account: NSDictionary) -> [String] {
        uniqueNonEmpty(account["subscriptions"] as? [String] ?? [])
    }

    private static func parseStoreAccounts(_ account: NSDictionary) -> [CatalogStoreAccount] {
        guard let stores = account["stores"] as? [NSDictionary] else { return [] }
        return stores.map { store in
            let syncing = store["syncing"] as? NSDictionary
            return CatalogStoreAccount(
                store: store["store"] as? String ?? "",
                userDisplayName: store["userDisplayName"] as? String ?? "",
                expiresIn: store["expiresIn"] as? String ?? "",
                userIdentifier: store["userIdentifier"] as? String ?? "",
                hasAccountLinkingData: store["hasAccountLinkingData"] as? Bool ?? false,
                hasAccountSyncingData: store["hasAccountSyncingData"] as? Bool ?? false,
                totalSyncedGames: syncing?["totalNumberOfSyncedGfnGames"] as? Int ?? 0,
                syncState: syncing?["syncState"] as? String ?? "",
                syncDate: syncing?["syncDate"] as? String ?? ""
            )
        }
    }

    private static func parseStoreDefinition(_ definition: NSDictionary) -> CatalogStoreDefinition {
        let metadata = definition["accountLinkingMetadata"] as? NSDictionary
        return CatalogStoreDefinition(
            store: definition["store"] as? String ?? "",
            label: definition["label"] as? String ?? "",
            smallImageUrl: definition["smallImageUrl"] as? String ?? "",
            isAccountLinkingSupported: metadata?["isSupported"] as? Bool ?? false,
            isAccountLinkingRequired: metadata?["isRequired"] as? Bool ?? false,
            accountLinkingLabel: metadata?["label"] as? String ?? ""
        )
    }

    private static func parseSubscriptionDefinition(_ definition: NSDictionary) -> CatalogSubscriptionDefinition {
        CatalogSubscriptionDefinition(
            subscription: definition["subscription"] as? String ?? "",
            label: definition["label"] as? String ?? "",
            logoURL: definition["logoURL"] as? String ?? "",
            primaryStore: definition["primaryStore"] as? String ?? ""
        )
    }
}

struct CatalogSectionModel: Identifiable, Equatable {
    enum Kind: Equatable {
        case catalog
        case library
        case panel
    }

    let id: String
    let title: String
    let games: [CatalogGameObject]
    let kind: Kind
    var tiles: [CatalogPanelTileObject] = []
    var seeMoreFilterIds: [String] = []
    var seeMoreSortId = ""
    var seeMoreTitle = ""
    var isLoadingFullList = false

    var canLoadFullList: Bool {
        !seeMoreFilterIds.isEmpty || !seeMoreSortId.isEmpty
    }

    func visibleGames(expanded: Bool) -> [CatalogGameObject] {
        expanded ? games : Array(games.prefix(18))
    }
}

struct CatalogGameRevealRequest: Equatable {
    let sectionId: String
    let gameIdentity: String
    let sequence: Int
}

struct CatalogStoreAccount: Identifiable, Equatable {
    var id: String { store }
    let store: String
    let userDisplayName: String
    let expiresIn: String
    let userIdentifier: String
    let hasAccountLinkingData: Bool
    let hasAccountSyncingData: Bool
    let totalSyncedGames: Int
    let syncState: String
    let syncDate: String
}

struct CatalogStoreDefinition: Identifiable, Equatable {
    var id: String { store }
    let store: String
    let label: String
    let smallImageUrl: String
    let isAccountLinkingSupported: Bool
    let isAccountLinkingRequired: Bool
    let accountLinkingLabel: String
}

struct CatalogSubscriptionDefinition: Identifiable, Equatable {
    var id: String { subscription }
    let subscription: String
    let label: String
    let logoURL: String
    let primaryStore: String
}

struct CatalogPlatformOption: Identifiable {
    let id: String
    let variantIndex: Int
    let variant: CatalogGameVariantObject
    let title: String
    let iconURL: String
    let store: String
    let subscriptionIds: [String]
    let primaryStore: String
    let isSubscription: Bool
    let isOwned: Bool
    let hasSubscriptionEntitlement: Bool
    let hasAccess: Bool
    let isSelected: Bool
    let isUnavailable: Bool
    let canLink: Bool
    let canSync: Bool
    let accountDisplayName: String
    let status: String

    var accountStore: String { primaryStore.isEmpty ? store : primaryStore }
}

struct CatalogPlaytimeStatistics: Codable, Equatable {
    static let empty = CatalogPlaytimeStatistics(totalSeconds: 0, sessionCount: 0, lastSessionSeconds: 0, longestSessionSeconds: 0, lastPlayedTitle: "", lastPlayedAt: nil, recentTitles: nil)

    private(set) var totalSeconds: Double
    private(set) var sessionCount: Int
    private(set) var lastSessionSeconds: Double
    private(set) var longestSessionSeconds: Double
    private(set) var lastPlayedTitle: String
    private(set) var lastPlayedAt: Date?
    var recentTitles: [String]?

    var averageSessionSeconds: Double {
        sessionCount > 0 ? totalSeconds / Double(sessionCount) : 0
    }

    mutating func record(title: String, durationSeconds: Double, endedAt: Date) {
        let duration = max(0, durationSeconds.isFinite ? durationSeconds : 0)
        guard duration > 0 else { return }
        totalSeconds += duration
        sessionCount += 1
        lastSessionSeconds = duration
        longestSessionSeconds = max(longestSessionSeconds, duration)
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        lastPlayedTitle = trimmedTitle
        lastPlayedAt = endedAt

        var recents = recentTitles ?? (trimmedTitle.isEmpty ? [] : [trimmedTitle])
        if !trimmedTitle.isEmpty {
            if let idx = recents.firstIndex(of: trimmedTitle) {
                recents.remove(at: idx)
            }
            recents.insert(trimmedTitle, at: 0)
        }
        recentTitles = Array(recents.prefix(10))
    }

    static func load(accountIdentifier: String) -> CatalogPlaytimeStatistics {
        guard let key = storageKey(accountIdentifier: accountIdentifier),
              let data = UserDefaults.standard.data(forKey: key),
              let statistics = try? JSONDecoder().decode(CatalogPlaytimeStatistics.self, from: data) else {
            return .empty
        }
        return statistics
    }

    func save(accountIdentifier: String) {
        guard let key = Self.storageKey(accountIdentifier: accountIdentifier),
              let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    private static func storageKey(accountIdentifier: String) -> String? {
        AccountStorageKeys.key(.playtimeStatistics, userId: accountIdentifier)
    }

}

struct CatalogSubscriptionStatus: Equatable {
    static let unavailable = CatalogSubscriptionStatus(
        membershipTier: "Performance",
        remainingPlaytimeText: "Unavailable",
        usageText: "Playtime refresh pending",
        isAvailable: false
    )

    let membershipTier: String
    let remainingPlaytimeText: String
    let usageText: String
    let isAvailable: Bool
    let totalHours: Double
    let usedHours: Double
    let remainingHours: Double
    let allottedHours: Double
    let purchasedHours: Double
    let rolledOverHours: Double
    let isUnlimited: Bool

    var isFreeTierAccount: Bool {
        CatalogGameObject.isFreeMembershipTier(membershipTier)
    }

    init(
        membershipTier: String,
        remainingPlaytimeText: String,
        usageText: String,
        isAvailable: Bool,
        totalHours: Double = 0,
        usedHours: Double = 0,
        remainingHours: Double = 0,
        allottedHours: Double = 0,
        purchasedHours: Double = 0,
        rolledOverHours: Double = 0,
        isUnlimited: Bool = false
    ) {
        self.membershipTier = membershipTier.isEmpty ? "Performance" : membershipTier
        self.remainingPlaytimeText = remainingPlaytimeText
        self.usageText = usageText
        self.isAvailable = isAvailable
        self.totalHours = totalHours
        self.usedHours = usedHours
        self.remainingHours = remainingHours
        self.allottedHours = allottedHours
        self.purchasedHours = purchasedHours
        self.rolledOverHours = rolledOverHours
        self.isUnlimited = isUnlimited
    }

    init(subscription: ParsedSubscriptionInfo) {
        let tier = subscription.membershipTier.isEmpty ? "Performance" : subscription.membershipTier.capitalized
        if subscription.isUnlimited {
            self.init(
                membershipTier: tier,
                remainingPlaytimeText: "Unlimited",
                usageText: "No monthly playtime cap",
                isAvailable: true,
                totalHours: subscription.totalHours,
                usedHours: subscription.usedHours,
                remainingHours: subscription.remainingHours,
                allottedHours: subscription.allottedHours,
                purchasedHours: subscription.purchasedHours,
                rolledOverHours: subscription.rolledOverHours,
                isUnlimited: true
            )
            return
        }
        let remaining = Self.hoursText(subscription.remainingHours)
        let used = Self.hoursText(subscription.usedHours)
        let total = Self.hoursText(subscription.totalHours)
        let usage = subscription.totalHours > 0 ? "\(used) used of \(total)" : "\(used) used"
        self.init(
            membershipTier: tier,
            remainingPlaytimeText: "\(remaining) left",
            usageText: usage,
            isAvailable: true,
            totalHours: subscription.totalHours,
            usedHours: subscription.usedHours,
            remainingHours: subscription.remainingHours,
            allottedHours: subscription.allottedHours,
            purchasedHours: subscription.purchasedHours,
            rolledOverHours: subscription.rolledOverHours,
            isUnlimited: false
        )
    }

    static func hoursText(_ hours: Double) -> String {
        let totalMinutes = max(0, Int((hours * 60).rounded()))
        let wholeHours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if wholeHours > 0, minutes > 0 { return "\(wholeHours)h \(minutes)m" }
        if wholeHours > 0 { return "\(wholeHours)h" }
        return "\(minutes)m"
    }
}

struct CatalogPreviousGameSession: Codable, Equatable {
    let title: String
    let appId: String
    let store: String
    let result: String
    let endedAt: Date
    let launchTime: String
    let averageLatency: String
    let averageBitrate: String
    let droppedFrames: String

    init(configuration: PreparedLaunchConfiguration, success: Bool, message: String, report: StreamReport?) {
        let reportTitle = report?.title ?? ""
        title = reportTitle.isEmpty ? (configuration.title.isEmpty ? "GeForce NOW" : configuration.title) : reportTitle
        appId = configuration.applicationID
        store = configuration.selectedStore
        if success {
            result = report?.success == false ? "Ended with warnings" : "Ended normally"
        } else {
            result = message.isEmpty ? "Ended with error" : message
        }
        endedAt = Date()
        launchTime = report.map { Self.durationText(seconds: $0.durationSeconds) } ?? "Unknown"
        averageLatency = report?.metadata["averageLatency"] ?? "Unknown"
        averageBitrate = report?.metadata["averageBitrate"] ?? "Unknown"
        droppedFrames = report?.metadata["droppedFrames"] ?? "Unknown"
    }

    private static func durationText(seconds: Double) -> String {
        let totalSeconds = max(0, Int(seconds.rounded()))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        if minutes > 0 { return "\(minutes)m \(seconds)s" }
        return "\(seconds)s"
    }

    static func load(userId: String) -> CatalogPreviousGameSession? {
        guard let key = AccountStorageKeys.key(.previousGameSession, userId: userId) else { return nil }
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(CatalogPreviousGameSession.self, from: data)
    }

    func save(userId: String) {
        guard let key = AccountStorageKeys.key(.previousGameSession, userId: userId),
              let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

private extension CatalogPanelSectionObject {
    func sectionIdentity(fallbackPanelId: String) -> String {
        if !id.isEmpty { return id }
        let titlePart = title.isEmpty ? "section" : title
        return [fallbackPanelId, titlePart].filter { !$0.isEmpty }.joined(separator: ":")
    }
}

extension CatalogGameObject {
    var primaryStoreURL: URL? {
        variants.compactMap { URL(string: $0.storeUrl) }.first
    }
}
