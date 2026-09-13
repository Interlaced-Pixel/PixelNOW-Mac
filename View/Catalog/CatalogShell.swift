import SwiftUI

struct CatalogShell: View {
    @ObservedObject var viewModel: CatalogViewModel
    let accounts: [LoginAccount]
    let onSwitch: (LoginAccount) -> Void
    let onAddAccount: () -> Void
    let onSignOut: () -> Void
    let onForget: (LoginAccount) -> Void

    @StateObject private var homeStore = CatalogSelectionStore()
    @StateObject private var libraryStore = CatalogSelectionStore()
    @StateObject private var controllerInputRouter = ControllerInputRouter()
    @AppStorage(InterfacePreferences.controllerModeEnabledKey) private var controllerModeEnabled = false
    @State private var backgroundIndex = 0
    @FocusState private var catalogHasFocus: Bool

    private var activeStore: CatalogSelectionStore {
        viewModel.selectedCatalogDestination == .library ? libraryStore : homeStore
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                DynamicGameBackground(game: activeStore.selectedGame, imageIndex: backgroundIndex)
                    .frame(width: geometry.size.width, height: geometry.size.height)

                if viewModel.selectedMainPage == .recordings {
                    RecordingsView()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                } else if viewModel.selectedMainPage == .settings {
                    SettingsView(
                        viewModel: viewModel,
                        accounts: accounts,
                        controllerInputRouter: controllerInputRouter,
                        onSwitch: onSwitch,
                        onAddAccount: onAddAccount,
                        onSignOut: onSignOut,
                        onForget: onForget
                    )
                    .frame(width: geometry.size.width, height: geometry.size.height)
                } else if viewModel.selectedCatalogDestination == .library {
                    LibraryGridView(
                        viewModel: viewModel,
                        store: libraryStore,
                        play: { game in performPrimaryAction(for: game) }
                    )
                    .frame(width: geometry.size.width, height: geometry.size.height)
                } else {
                    HomeDashboardView(viewModel: viewModel, store: homeStore) { game in
                        performPrimaryAction(for: game, store: homeStore)
                    }
                }
            }
            .overlay(alignment: .top) {
                CatalogChrome(
                    viewModel: viewModel,
                    accounts: accounts,
                    onSwitch: onSwitch,
                    onAddAccount: onAddAccount,
                    onSignOut: onSignOut,
                    onForget: onForget
                )
            }
            .overlay {
                if let candidate = viewModel.favoriteReplacementCandidate {
                    FavoriteLimitReplacementOverlay(
                        viewModel: viewModel,
                        candidateGame: candidate
                    )
                    .transition(.opacity)
                }
            }
            .focusable(true)
            .focusEffectDisabled()
            .focused($catalogHasFocus)
            .onMoveCommand { direction in
                if viewModel.selectedMainPage == .games {
                    let availableWidth = geometry.size.width - 380 - 80
                    let columns = max(1, Int(floor((availableWidth + 16) / 156)))
                    switch direction {
                    case .left: activeStore.selectPrevious()
                    case .right: activeStore.selectNext()
                    case .up:
                        if viewModel.selectedCatalogDestination == .library {
                            activeStore.jump(by: -columns)
                        }
                    case .down:
                        if viewModel.selectedCatalogDestination == .library {
                            activeStore.jump(by: columns)
                        }
                    default: break
                    }
                }
            }
        }
        .task { viewModel.loadIfNeeded() }
        .task(id: activeStore.selectedGame?.id) {
            backgroundIndex = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(9))
                guard !Task.isCancelled else { return }
                backgroundIndex += 1
            }
        }
        .onAppear {
            controllerInputRouter.onCommand = handleControllerCommand
            if let selected = viewModel.selectedGame {
                homeStore.setInitiallySelectedIdentity(CatalogSelectionStore.gameIdentity(selected))
                libraryStore.setInitiallySelectedIdentity(CatalogSelectionStore.gameIdentity(selected))
            }
            if viewModel.selectedCatalogDestination != .library {
                homeStore.load(from: viewModel.catalogSections)
            }
            catalogHasFocus = true
        }
        .onDisappear {
            controllerInputRouter.onCommand = nil
        }
        .onChange(of: viewModel.catalogSections) { _, newSections in
            homeStore.load(from: newSections)
        }
        .onChange(of: viewModel.selectedCatalogDestination) { _, newDest in
            let store = newDest == .library ? libraryStore : homeStore
            if let game = store.selectedGame {
                viewModel.selectGame(game)
            }
            if newDest != .library {
                homeStore.load(from: viewModel.catalogSections)
            }
        }
        .onChange(of: homeStore.selectedIndex) { _, _ in
            if viewModel.selectedCatalogDestination != .library, let game = homeStore.selectedGame {
                viewModel.selectGame(game)
            }
        }
        .onChange(of: libraryStore.selectedIndex) { _, _ in
            if viewModel.selectedCatalogDestination == .library, let game = libraryStore.selectedGame {
                viewModel.selectGame(game)
            }
        }
    }

    private func performPrimaryAction(for game: CatalogGameObject, store: CatalogSelectionStore? = nil) {
        let targetStore = store ?? (viewModel.selectedCatalogDestination == .library ? libraryStore : homeStore)
        targetStore.selectGame(withId: CatalogSelectionStore.gameIdentity(game))
        if game.isLaunchPatching {
            viewModel.queuePatchingLaunch(game: game)
        } else if game.cardPrimaryActionIsLaunchable {
            viewModel.launch(game: game)
        } else {
            viewModel.beginMarkSelectedVariantOwnedFlow()
        }
    }

    private func handleControllerCommand(_ command: ControllerInputCommand) {
        guard controllerModeEnabled else { return }
        switch command {
        case .move(.left):
            if viewModel.selectedMainPage == .games { activeStore.selectPrevious() }
        case .move(.right):
            if viewModel.selectedMainPage == .games { activeStore.selectNext() }
        case .move(.up):
            if viewModel.selectedMainPage == .games { activeStore.jump(by: -1) }
        case .move(.down):
            if viewModel.selectedMainPage == .games { activeStore.jump(by: 1) }
        case .confirm:
            if viewModel.selectedMainPage == .games, let game = activeStore.selectedGame {
                performPrimaryAction(for: game)
            }
        case .back:
            if viewModel.selectedMainPage != .games {
                viewModel.showGames()
            } else if viewModel.isBrowseMode {
                viewModel.clearSearchAndFilters()
            } else {
                viewModel.showCatalogDestination(.home)
            }
        case .search:
            viewModel.showSearch()
        case .actions:
            if viewModel.selectedMainPage == .games, viewModel.isBrowseMode {
                viewModel.clearSearchAndFilters()
            } else {
                viewModel.refresh()
            }
        case .menu:
            viewModel.showSettings()
        case .pageLeft:
            selectCatalogDestination(offset: -1)
        case .pageRight:
            selectCatalogDestination(offset: 1)
        }
    }

    private func selectCatalogDestination(offset: Int) {
        guard viewModel.selectedMainPage == .games,
              let currentIndex = CatalogDestination.allCases.firstIndex(of: viewModel.selectedCatalogDestination) else { return }
        let nextIndex = (currentIndex + offset + CatalogDestination.allCases.count) % CatalogDestination.allCases.count
        viewModel.showCatalogDestination(CatalogDestination.allCases[nextIndex])
    }
}

private struct DynamicGameBackground: View {
    let game: CatalogGameObject?
    let imageIndex: Int

    private var imageURLs: [URL] {
        guard let game else { return [] }
        var values: [String] = []
        var seen = Set<String>()

        func append(_ value: String) {
            guard !value.isEmpty, seen.insert(value).inserted, let url = URL(string: value) else { return }
            values.append(url.absoluteString)
        }

        for key in ["HERO_IMAGE", "MARQUEE_HERO_IMAGE", "FEATURE_IMAGE", "KEY_ART", "TV_BANNER"] {
            for value in game.imageUrlsByType[key] ?? [] { append(value) }
            for value in game.imageUrlsByType[key.lowercased()] ?? [] { append(value) }
        }
        append(game.heroImageUrl)
        for value in game.screenshotUrls { append(value) }
        append(game.imageUrl)
        return values.compactMap(URL.init(string:))
    }

    var body: some View {
        ZStack {
            Color.black
            if let url = imageURLs.isEmpty ? nil : imageURLs[imageIndex % imageURLs.count] {
                CatalogRemoteImage(url: url, contentMode: .fill)
                    .id(url)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .transition(.opacity)
                    .animation(.easeInOut(duration: 1.1), value: url)
                    .overlay(Color.black.opacity(0.38))
            }
            LinearGradient(
                colors: [.black.opacity(0.72), .black.opacity(0.10), .black.opacity(0.74)],
                startPoint: .top,
                endPoint: .bottom
            )
            LinearGradient(
                colors: [.black.opacity(0.58), .clear, .black.opacity(0.60)],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
        .ignoresSafeArea()
        .opacity(game == nil ? 0 : 1)
        .animation(.easeInOut(duration: 0.3), value: game?.id)
    }
}
