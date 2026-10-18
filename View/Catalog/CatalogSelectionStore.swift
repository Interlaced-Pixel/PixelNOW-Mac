import Foundation
import Combine
import SwiftUI

@MainActor
final class CatalogSelectionStore: ObservableObject {
    @Published private(set) var games: [CatalogGameObject] = []
    @Published private(set) var selectedIndex: Int = 0

    var selectedGame: CatalogGameObject? {
        games.indices.contains(selectedIndex) ? games[selectedIndex] : nil
    }

    private var initiallySelectedIdentity: String?

    func setInitiallySelectedIdentity(_ identity: String) {
        self.initiallySelectedIdentity = identity
    }

    func load(from gamesList: [CatalogGameObject]) {
        var result: [CatalogGameObject] = []
        var identities = Set<String>()
        for game in gamesList {
            let identity = Self.gameIdentity(game)
            guard identities.insert(identity).inserted else { continue }
            result.append(game)
        }
        
        if games.count == result.count,
           games.indices.allSatisfy({ Self.gameIdentity(games[$0]) == Self.gameIdentity(result[$0]) }) {
            return
        }

        games = result
        
        if let initial = initiallySelectedIdentity, !initial.isEmpty {
            if let index = games.firstIndex(where: { Self.gameIdentity($0) == initial }) {
                selectedIndex = index
                initiallySelectedIdentity = nil
                return
            }
        }
        
        if !games.isEmpty && !games.indices.contains(selectedIndex) {
            selectedIndex = 0
        }
    }

    func load(from sections: [CatalogSectionModel]) {
        load(from: sections.flatMap(\.games))
    }

    func select(at index: Int) {
        guard games.indices.contains(index) else { return }
        selectedIndex = index
    }

    func selectNext() {
        guard !games.isEmpty else { return }
        select(at: (selectedIndex + 1) % games.count)
    }

    func selectPrevious() {
        guard !games.isEmpty else { return }
        select(at: (selectedIndex - 1 + games.count) % games.count)
    }
    
    func jump(by offset: Int) {
        guard !games.isEmpty else { return }
        var newIndex = selectedIndex + offset
        if newIndex < 0 { newIndex = 0 }
        if newIndex >= games.count { newIndex = games.count - 1 }
        select(at: newIndex)
    }
    
    func selectGame(withId identity: String) {
        if let index = games.firstIndex(where: { Self.gameIdentity($0) == identity }) {
            select(at: index)
        }
    }

    static func gameIdentity(_ game: CatalogGameObject) -> String {
        "\(game.id)|\(game.uuid)|\(game.title)"
    }
}
