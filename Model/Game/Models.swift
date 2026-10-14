import Foundation


@objc public enum AuthScreen: Int {
    case emailEntry
    case authenticating
    case store
    case catalog
    case settings
    case error
    case oAuthBrowser
}

public struct SubscriptionInfo: Equatable, Sendable {
    public var membershipTier = "Free"
    public var subscriptionType = ""
    public var subscriptionSubType = ""
    public var allottedHours = 0.0
    public var purchasedHours = 0.0
    public var rolledOverHours = 0.0
    public var usedHours = 0.0
    public var remainingHours = 0.0
    public var totalHours = 0.0
    public var isUnlimited = false
    public var isGamePlayAllowed = true
}

public struct GameVariant: Codable, Equatable, Sendable {
    public var id = ""
    public var shortName = ""
    public var appStore = ""
    public var appStoreLabel = ""
    public var appStoreSmallImageUrl = ""
    public var storeUrl = ""
    public var developerName = ""
    public var publisherName = ""
    public var releaseDate = ""
    public var supportedControls: [String] = []
    public var serviceStatus = ""
    public var libraryStatus = ""
    public var libraryPlayStatus = ""
    public var libraryInstalled = false
    public var librarySubscription = ""
    public var subscriptionIds: [String] = []
    public var paymentModelTypes: [String] = []
    public var minimumSizeInBytes = 0
    public var cloudSaveSupported = false
    public var installTimeInMinutes = 0
    public var supportedLanguages: [String] = []
    public var gfnFeatureLabels: [String] = []
    public var isPatching = false
    public var patchStatusPrimaryText = ""
    public var patchStatusSecondaryText = ""
    public var librarySelected = false
    public var inLibrary = false
}

public struct StoreAccountSyncingInfo: Equatable, Sendable {
    public var totalNumberOfSyncedGfnGames = 0
    public var syncState = ""
    public var syncDate = ""
}

public struct StoreAccountInfo: Equatable, Sendable {
    public var store = ""
    public var userDisplayName = ""
    public var expiresIn = ""
    public var userIdentifier = ""
    public var hasAccountLinkingData = false
    public var hasAccountSyncingData = false
    public var syncing = StoreAccountSyncingInfo()
}

public struct UserAccountInfo: Equatable, Sendable {
    public var subscriptions: [String] = []
    public var stores: [StoreAccountInfo] = []
}

public struct StoreFeatureInfo: Equatable, Sendable {
    public var type = ""
    public var displayProposition = ""
    public var supported = false
}

public struct StoreAccountLinkingMetadata: Equatable, Sendable {
    public var supportedVariantIds: [String] = []
    public var isSupported = false
    public var isRequired = false
    public var label = ""
}

public struct StoreDefinition: Equatable, Sendable {
    public var store = ""
    public var label = ""
    public var smallImageUrl = ""
    public var sortOrder = 0
    public var features: [StoreFeatureInfo] = []
    public var accountLinkingMetadata = StoreAccountLinkingMetadata()
}

public struct SubscriptionDefinition: Equatable, Sendable {
    public var subscription = ""
    public var label = ""
    public var logoURL = ""
    public var primaryStore = ""
}

public struct GameInfo: Codable, Equatable, Sendable {
    public var id = ""
    public var uuid = ""
    public var launchAppId = ""
    public var title = ""
    public var shortName = ""
    public var description = ""
    public var shortDescription = ""
    public var longDescription = ""
    public var developerName = ""
    public var publisherName = ""
    public var releaseDate = ""
    public var maxLocalPlayers = 0
    public var maxOnlinePlayers = 0
    public var playType = ""
    public var membershipTierLabel = ""
    public var playabilityState = ""
    public var imageUrl = ""
    public var heroImageUrl = ""
    public var screenshotUrls: [String] = []
    public var imageUrlsByType: [String: [String]] = [:]
    public var genres: [String] = []
    public var featureLabels: [String] = []
    public var supportedControls: [String] = []
    public var contentRatings: [String] = []
    public var ratingSystemName = ""
    public var ratingCategoryKey = ""
    public var ratingCategoryTitle = ""
    public var ratingDescriptors: [String] = []
    public var ratingInteractiveElements: [String] = []
    public var ratingImageUrl = ""
    public var nvidiaTech: [String] = []
    public var availableStores: [String] = []
    public var promoTag = ""
    public var campaignIds: [String] = []
    public var skuTags: [String] = []
    public var skuPlayabilityText = ""
    public var skuUnplayableDialogHeader = ""
    public var skuUnplayableDialogBody = ""
    public var skuUnplayableDialogBodyEcommerceRestricted = ""
    public var displaysOwnRatingDuringGameplay = false
    public var isFavorited = false
    public var isInLibrary = false
    public var isPatching = false
    public var isFreeToPlay = false
    public var patchStatusPrimaryText = ""
    public var patchStatusSecondaryText = ""
    public var variants: [GameVariant] = []
}

public struct ActiveSessionEntry: Equatable, Sendable {
    public var sessionId = ""
    public var appId = 0
    public var status = 0
    public var serverIp = ""
    public var gpuType = ""
    public var streamingBaseUrl = ""
    public var signalingUrl = ""
}

public struct PanelSection: Equatable, Sendable {
    public var id = ""
    public var title = ""
    public var typename = ""
    public var seeMoreFilterIds: [String] = []
    public var seeMoreSortId = ""
    public var seeMoreTitle = ""
    public var games: [GameInfo] = []
    public var tiles: [PanelTile] = []

    public init(id: String = "", title: String = "", typename: String = "", seeMoreFilterIds: [String] = [], seeMoreSortId: String = "", seeMoreTitle: String = "", games: [GameInfo] = [], tiles: [PanelTile] = []) {
        self.id = id
        self.title = title
        self.typename = typename
        self.seeMoreFilterIds = seeMoreFilterIds
        self.seeMoreSortId = seeMoreSortId
        self.seeMoreTitle = seeMoreTitle
        self.games = games
        self.tiles = tiles
    }
}

public struct PanelTile: Equatable, Sendable {
    public var id = ""
    public var kind = ""
    public var title = ""
    public var subtitle = ""
    public var body = ""
    public var imageUrl = ""
    public var actionUrl = ""
    public var actionLabel = ""
    public var filterIds: [String] = []
    public var sortId = ""
}

public struct PanelResult: Equatable, Sendable {
    public var id = ""
    public var title = ""
    public var typename = ""
    public var sections: [PanelSection] = []

    public init(id: String = "", title: String = "", typename: String = "", sections: [PanelSection] = []) {
        self.id = id
        self.title = title
        self.typename = typename
        self.sections = sections
    }
}

public struct CatalogFilterOption: Equatable, Sendable {
    public var id = ""
    public var rawId = ""
    public var label = ""
    public var groupId = ""
    public var groupLabel = ""
}

public struct CatalogFilterGroup: Equatable, Sendable {
    public var id = ""
    public var label = ""
    public var options: [CatalogFilterOption] = []
}

public struct CatalogSortOption: Equatable, Sendable {
    public var id = ""
    public var label = ""
    public var orderBy = ""
}

public struct CatalogBrowseResult: Equatable, Sendable {
    public var games: [GameInfo] = []
    public var numberReturned = 0
    public var numberSupported = 0
    public var totalCount = 0
    public var hasNextPage = false
    public var endCursor = ""
    public var searchQuery = ""
    public var selectedSortId = ""
    public var selectedFilterIds: [String] = []
    public var filterGroups: [CatalogFilterGroup] = []
    public var sortOptions: [CatalogSortOption] = []
}

struct CachedGameLibrary: Sendable {
    let games: [GameInfo]
    let updatedAt: Date
    let isFresh: Bool
}

@objc(CatalogFilterOptionObject)
@objcMembers
public final class CatalogFilterOptionObject: NSObject {
    public var id: String
    public var rawId: String
    public var label: String
    public var groupId: String
    public var groupLabel: String

    public override convenience init() {
        self.init(option: CatalogFilterOption())
    }

    public init(option: CatalogFilterOption) {
        id = option.id
        rawId = option.rawId
        label = option.label
        groupId = option.groupId
        groupLabel = option.groupLabel
        super.init()
    }

    public var swiftValue: CatalogFilterOption {
        CatalogFilterOption(id: id, rawId: rawId, label: label, groupId: groupId, groupLabel: groupLabel)
    }
}

@objc(CatalogFilterGroupObject)
@objcMembers
public final class CatalogFilterGroupObject: NSObject {
    public var id: String
    public var label: String
    public var options: [CatalogFilterOptionObject]

    public override convenience init() {
        self.init(group: CatalogFilterGroup())
    }

    public init(group: CatalogFilterGroup) {
        id = group.id
        label = group.label
        options = group.options.map(CatalogFilterOptionObject.init)
        super.init()
    }

    public var swiftValue: CatalogFilterGroup {
        CatalogFilterGroup(id: id, label: label, options: options.map(\.swiftValue))
    }
}

@objc(CatalogSortOptionObject)
@objcMembers
public final class CatalogSortOptionObject: NSObject {
    public var id: String
    public var label: String
    public var orderBy: String

    public override convenience init() {
        self.init(option: CatalogSortOption())
    }

    public init(option: CatalogSortOption) {
        id = option.id
        label = option.label
        orderBy = option.orderBy
        super.init()
    }

    public var swiftValue: CatalogSortOption {
        CatalogSortOption(id: id, label: label, orderBy: orderBy)
    }
}

public struct GameProviderEndpoint: Equatable, Sendable {
    public var loginProvider = ""
    public var loginProviderCode = ""
    public var loginProviderDisplayName = ""
    public var streamingServiceUrl = ""
    public var idpId = ""
    public var redeemRedirectUrl = ""
    public var priority = 0
}

public struct GameProviderInfo: Equatable, Sendable {
    public var defaultProvider = ""
    public var loggedInProvider = ""
    public var loginRequired = false
    public var loginPreferredProviders: [String] = []
    public var endpoints: [GameProviderEndpoint] = []
}

public struct FeaturedGamesResult: Equatable, Sendable {
    public var games: [GameInfo] = []
    public var usedExplicitFeaturedSection = false
}

@objc(CatalogGameVariantObject)
@objcMembers
public final class CatalogGameVariantObject: NSObject {
    public var id: String
    public var shortName: String
    public var appStore: String
    public var appStoreLabel: String
    public var appStoreSmallImageUrl: String
    public var storeUrl: String
    public var developerName: String
    public var publisherName: String
    public var releaseDate: String
    public var supportedControls: [String]
    public var serviceStatus: String
    public var libraryStatus: String
    public var libraryPlayStatus: String
    public var libraryInstalled: Bool
    public var librarySubscription: String
    public var subscriptionIds: [String]
    public var paymentModelTypes: [String]
    public var minimumSizeInBytes: Int
    public var cloudSaveSupported: Bool
    public var installTimeInMinutes: Int
    public var supportedLanguages: [String]
    public var gfnFeatureLabels: [String]
    public var isPatching: Bool
    public var patchStatusPrimaryText: String
    public var patchStatusSecondaryText: String
    public var librarySelected: Bool
    public var inLibrary: Bool

    public override convenience init() {
        self.init(variant: GameVariant())
    }

    public init(variant: GameVariant) {
        id = variant.id
        shortName = variant.shortName
        appStore = variant.appStore
        appStoreLabel = variant.appStoreLabel
        appStoreSmallImageUrl = variant.appStoreSmallImageUrl
        storeUrl = variant.storeUrl
        developerName = variant.developerName
        publisherName = variant.publisherName
        releaseDate = variant.releaseDate
        supportedControls = variant.supportedControls
        serviceStatus = variant.serviceStatus
        libraryStatus = variant.libraryStatus
        libraryPlayStatus = variant.libraryPlayStatus
        libraryInstalled = variant.libraryInstalled
        librarySubscription = variant.librarySubscription
        subscriptionIds = variant.subscriptionIds
        paymentModelTypes = variant.paymentModelTypes
        minimumSizeInBytes = variant.minimumSizeInBytes
        cloudSaveSupported = variant.cloudSaveSupported
        installTimeInMinutes = variant.installTimeInMinutes
        supportedLanguages = variant.supportedLanguages
        gfnFeatureLabels = variant.gfnFeatureLabels
        isPatching = variant.isPatching
        patchStatusPrimaryText = variant.patchStatusPrimaryText
        patchStatusSecondaryText = variant.patchStatusSecondaryText
        librarySelected = variant.librarySelected
        inLibrary = variant.inLibrary
        super.init()
    }

    public var swiftValue: GameVariant {
        GameVariant(
            id: id,
            shortName: shortName,
            appStore: appStore,
            appStoreLabel: appStoreLabel,
            appStoreSmallImageUrl: appStoreSmallImageUrl,
            storeUrl: storeUrl,
            developerName: developerName,
            publisherName: publisherName,
            releaseDate: releaseDate,
            supportedControls: supportedControls,
            serviceStatus: serviceStatus,
            libraryStatus: libraryStatus,
            libraryPlayStatus: libraryPlayStatus,
            libraryInstalled: libraryInstalled,
            librarySubscription: librarySubscription,
            subscriptionIds: subscriptionIds,
            paymentModelTypes: paymentModelTypes,
            minimumSizeInBytes: minimumSizeInBytes,
            cloudSaveSupported: cloudSaveSupported,
            installTimeInMinutes: installTimeInMinutes,
            supportedLanguages: supportedLanguages,
            gfnFeatureLabels: gfnFeatureLabels,
            isPatching: isPatching,
            patchStatusPrimaryText: patchStatusPrimaryText,
            patchStatusSecondaryText: patchStatusSecondaryText,
            librarySelected: librarySelected,
            inLibrary: inLibrary
        )
    }
}

@objc(CatalogGameObject)
@objcMembers
public final class CatalogGameObject: NSObject {
    public var id: String
    public var uuid: String
    public var launchAppId: String
    public var title: String
    public var shortName: String
    public var gameDescription: String
    public var shortDescription: String
    public var longDescription: String
    public var developerName: String
    public var publisherName: String
    public var releaseDate: String
    public var maxLocalPlayers: Int
    public var maxOnlinePlayers: Int
    public var playType: String
    public var membershipTierLabel: String
    public var playabilityState: String
    public var imageUrl: String
    public var heroImageUrl: String
    public var screenshotUrls: [String]
    public var imageUrlsByType: [String: [String]]
    public var genres: [String]
    public var featureLabels: [String]
    public var supportedControls: [String]
    public var contentRatings: [String]
    public var ratingSystemName: String
    public var ratingCategoryKey: String
    public var ratingCategoryTitle: String
    public var ratingDescriptors: [String]
    public var ratingInteractiveElements: [String]
    public var ratingImageUrl: String
    public var nvidiaTech: [String]
    public var availableStores: [String]
    public var promoTag: String
    public var campaignIds: [String]
    public var skuTags: [String]
    public var skuPlayabilityText: String
    public var skuUnplayableDialogHeader: String
    public var skuUnplayableDialogBody: String
    public var skuUnplayableDialogBodyEcommerceRestricted: String
    public var displaysOwnRatingDuringGameplay: Bool
    public var isFavorited: Bool
    public var isInLibrary: Bool
    public var isPatching: Bool
    public var isFreeToPlay: Bool
    public var patchStatusPrimaryText: String
    public var patchStatusSecondaryText: String
    public var variants: [CatalogGameVariantObject]

    public override convenience init() {
        self.init(game: GameInfo())
    }

    public init(game: GameInfo) {
        id = game.id
        uuid = game.uuid
        launchAppId = game.launchAppId
        title = game.title
        shortName = game.shortName
        gameDescription = game.description
        shortDescription = game.shortDescription
        longDescription = game.longDescription
        developerName = game.developerName
        publisherName = game.publisherName
        releaseDate = game.releaseDate
        maxLocalPlayers = game.maxLocalPlayers
        maxOnlinePlayers = game.maxOnlinePlayers
        playType = game.playType
        membershipTierLabel = game.membershipTierLabel
        playabilityState = game.playabilityState
        imageUrl = game.imageUrl
        heroImageUrl = game.heroImageUrl
        screenshotUrls = game.screenshotUrls
        imageUrlsByType = game.imageUrlsByType
        genres = game.genres
        featureLabels = game.featureLabels
        supportedControls = game.supportedControls
        contentRatings = game.contentRatings
        ratingSystemName = game.ratingSystemName
        ratingCategoryKey = game.ratingCategoryKey
        ratingCategoryTitle = game.ratingCategoryTitle
        ratingDescriptors = game.ratingDescriptors
        ratingInteractiveElements = game.ratingInteractiveElements
        ratingImageUrl = game.ratingImageUrl
        nvidiaTech = game.nvidiaTech
        availableStores = game.availableStores
        promoTag = game.promoTag
        campaignIds = game.campaignIds
        skuTags = game.skuTags
        skuPlayabilityText = game.skuPlayabilityText
        skuUnplayableDialogHeader = game.skuUnplayableDialogHeader
        skuUnplayableDialogBody = game.skuUnplayableDialogBody
        skuUnplayableDialogBodyEcommerceRestricted = game.skuUnplayableDialogBodyEcommerceRestricted
        displaysOwnRatingDuringGameplay = game.displaysOwnRatingDuringGameplay
        isFavorited = game.isFavorited
        isInLibrary = game.isInLibrary
        isPatching = game.isPatching
        isFreeToPlay = game.isFreeToPlay
        patchStatusPrimaryText = game.patchStatusPrimaryText
        patchStatusSecondaryText = game.patchStatusSecondaryText
        variants = game.variants.map(CatalogGameVariantObject.init)
        super.init()
    }

    public var swiftValue: GameInfo {
        var game = GameInfo()
        game.id = id
        game.uuid = uuid
        game.launchAppId = launchAppId
        game.title = title
        game.shortName = shortName
        game.description = gameDescription
        game.shortDescription = shortDescription
        game.longDescription = longDescription
        game.developerName = developerName
        game.publisherName = publisherName
        game.releaseDate = releaseDate
        game.maxLocalPlayers = maxLocalPlayers
        game.maxOnlinePlayers = maxOnlinePlayers
        game.playType = playType
        game.membershipTierLabel = membershipTierLabel
        game.playabilityState = playabilityState
        game.imageUrl = imageUrl
        game.heroImageUrl = heroImageUrl
        game.screenshotUrls = screenshotUrls
        game.imageUrlsByType = imageUrlsByType
        game.genres = genres
        game.featureLabels = featureLabels
        game.supportedControls = supportedControls
        game.contentRatings = contentRatings
        game.ratingSystemName = ratingSystemName
        game.ratingCategoryKey = ratingCategoryKey
        game.ratingCategoryTitle = ratingCategoryTitle
        game.ratingDescriptors = ratingDescriptors
        game.ratingInteractiveElements = ratingInteractiveElements
        game.ratingImageUrl = ratingImageUrl
        game.nvidiaTech = nvidiaTech
        game.availableStores = availableStores
        game.promoTag = promoTag
        game.campaignIds = campaignIds
        game.skuTags = skuTags
        game.skuPlayabilityText = skuPlayabilityText
        game.skuUnplayableDialogHeader = skuUnplayableDialogHeader
        game.skuUnplayableDialogBody = skuUnplayableDialogBody
        game.skuUnplayableDialogBodyEcommerceRestricted = skuUnplayableDialogBodyEcommerceRestricted
        game.displaysOwnRatingDuringGameplay = displaysOwnRatingDuringGameplay
        game.isFavorited = isFavorited
        game.isInLibrary = isInLibrary
        game.isPatching = isPatching
        game.isFreeToPlay = isFreeToPlay
        game.patchStatusPrimaryText = patchStatusPrimaryText
        game.patchStatusSecondaryText = patchStatusSecondaryText
        game.variants = variants.map(\.swiftValue)
        return game
    }

    public static func isFreeMembershipTier(_ membershipTier: String) -> Bool {
        let normalized = membershipTier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "free" || normalized == "free tier" || normalized == "free-tier"
    }

    public func freeAccountAccessBadgeLabel(isFreeTierAccount: Bool) -> String? {
        guard isFreeTierAccount else { return nil }
        let tier = membershipTierLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tier.isEmpty, !Self.isFreeMembershipTier(tier) else { return nil }
        return "Membership Required"
    }
}

@objc(CatalogPanelSectionObject)
@objcMembers
public final class CatalogPanelSectionObject: NSObject {
    public var id: String
    public var title: String
    public var typeName: String
    public var seeMoreFilterIds: [String]
    public var seeMoreSortId: String
    public var seeMoreTitle: String
    public var games: [CatalogGameObject]
    public var tiles: [CatalogPanelTileObject]

    public override convenience init() {
        self.init(section: PanelSection())
    }

    public init(section: PanelSection) {
        id = section.id
        title = section.title
        typeName = section.typename
        seeMoreFilterIds = section.seeMoreFilterIds
        seeMoreSortId = section.seeMoreSortId
        seeMoreTitle = section.seeMoreTitle
        games = section.games.map(CatalogGameObject.init)
        tiles = section.tiles.map(CatalogPanelTileObject.init)
        super.init()
    }

    public var swiftValue: PanelSection {
        PanelSection(id: id, title: title, typename: typeName, seeMoreFilterIds: seeMoreFilterIds, seeMoreSortId: seeMoreSortId, seeMoreTitle: seeMoreTitle, games: games.map(\.swiftValue), tiles: tiles.map(\.swiftValue))
    }
}

@objc(CatalogPanelTileObject)
@objcMembers
public final class CatalogPanelTileObject: NSObject {
    public var id: String
    public var kind: String
    public var title: String
    public var subtitle: String
    public var body: String
    public var imageUrl: String
    public var actionUrl: String
    public var actionLabel: String
    public var filterIds: [String]
    public var sortId: String

    public override convenience init() {
        self.init(tile: PanelTile())
    }

    public init(tile: PanelTile) {
        id = tile.id
        kind = tile.kind
        title = tile.title
        subtitle = tile.subtitle
        body = tile.body
        imageUrl = tile.imageUrl
        actionUrl = tile.actionUrl
        actionLabel = tile.actionLabel
        filterIds = tile.filterIds
        sortId = tile.sortId
        super.init()
    }

    public var swiftValue: PanelTile {
        PanelTile(id: id, kind: kind, title: title, subtitle: subtitle, body: body, imageUrl: imageUrl, actionUrl: actionUrl, actionLabel: actionLabel, filterIds: filterIds, sortId: sortId)
    }
}

@objc(CatalogPanelObject)
@objcMembers
public final class CatalogPanelObject: NSObject {
    public var id: String
    public var title: String
    public var typeName: String
    public var sections: [CatalogPanelSectionObject]

    public override convenience init() {
        self.init(panel: PanelResult())
    }

    public init(panel: PanelResult) {
        id = panel.id
        title = panel.title
        typeName = panel.typename
        sections = panel.sections.map(CatalogPanelSectionObject.init)
        super.init()
    }

    public var swiftValue: PanelResult {
        PanelResult(id: id, title: title, typename: typeName, sections: sections.map(\.swiftValue))
    }
}

@objc(CatalogBrowseResultObject)
@objcMembers
public final class CatalogBrowseResultObject: NSObject {
    public var games: [CatalogGameObject]
    public var numberReturned: Int
    public var numberSupported: Int
    public var totalCount: Int
    public var hasNextPage: Bool
    public var endCursor: String
    public var searchQuery: String
    public var selectedSortId: String
    public var selectedFilterIds: [String]
    public var filterGroups: [CatalogFilterGroupObject]
    public var sortOptions: [CatalogSortOptionObject]

    public override convenience init() {
        self.init(result: CatalogBrowseResult())
    }

    public init(result: CatalogBrowseResult) {
        games = result.games.map(CatalogGameObject.init)
        numberReturned = result.numberReturned
        numberSupported = result.numberSupported
        totalCount = result.totalCount
        hasNextPage = result.hasNextPage
        endCursor = result.endCursor
        searchQuery = result.searchQuery
        selectedSortId = result.selectedSortId
        selectedFilterIds = result.selectedFilterIds
        filterGroups = result.filterGroups.map(CatalogFilterGroupObject.init)
        sortOptions = result.sortOptions.map(CatalogSortOptionObject.init)
        super.init()
    }

    public var swiftValue: CatalogBrowseResult {
        var result = CatalogBrowseResult()
        result.games = games.map(\.swiftValue)
        result.numberReturned = numberReturned
        result.numberSupported = numberSupported
        result.totalCount = totalCount
        result.hasNextPage = hasNextPage
        result.endCursor = endCursor
        result.searchQuery = searchQuery
        result.selectedSortId = selectedSortId
        result.selectedFilterIds = selectedFilterIds
        result.filterGroups = filterGroups.map(\.swiftValue)
        result.sortOptions = sortOptions.map(\.swiftValue)
        return result
    }
}

public struct IceServer: Equatable, Sendable {
    public var urls: [String] = []
    public var username = ""
    public var credential = ""
}

public struct MediaConnectionInfo: Equatable, Sendable {
    public var ip = ""
    public var port = 0
}

public struct NegotiatedStreamProfile: Equatable, Sendable {
    public var resolution = ""
    public var fps = 0
    public var codec = ""
    public var colorQuality = ""
    public var bitDepth = -1
    public var chromaFormat = -1
    public var prefilterMode = -1
    public var prefilterSharpness = -1
    public var prefilterDenoise = -1
    public var prefilterModel = -1
}

@objcMembers
public final class ParsedNegotiatedStreamProfile: NSObject {
    public let resolution: String
    public let fps: Int
    public let codec: String
    public let colorQuality: String
    public let bitDepth: Int
    public let chromaFormat: Int
    public let prefilterMode: Int
    public let prefilterSharpness: Int
    public let prefilterDenoise: Int
    public let prefilterModel: Int

    public init(profile: NegotiatedStreamProfile) {
        resolution = profile.resolution
        fps = profile.fps
        codec = profile.codec
        colorQuality = profile.colorQuality
        bitDepth = profile.bitDepth
        chromaFormat = profile.chromaFormat
        prefilterMode = profile.prefilterMode
        prefilterSharpness = profile.prefilterSharpness
        prefilterDenoise = profile.prefilterDenoise
        prefilterModel = profile.prefilterModel
    }
}

@objcMembers
public final class ParsedSessionProgress: NSObject {
    public let queuePosition: Int
    public let seatSetupStep: Int
    public let progressState: Int
    public let remainingPlaytimeHours: Double
    public let remainingPlaytimeAvailable: Bool
    public let remainingSessionLimitSeconds: Int

    public init(queuePosition: Int, seatSetupStep: Int, progressState: SessionProgressState, remainingPlaytimeHours: Double, remainingPlaytimeAvailable: Bool, remainingSessionLimitSeconds: Int) {
        self.queuePosition = queuePosition
        self.seatSetupStep = seatSetupStep
        self.progressState = progressState.rawValue
        self.remainingPlaytimeHours = remainingPlaytimeHours
        self.remainingPlaytimeAvailable = remainingPlaytimeAvailable
        self.remainingSessionLimitSeconds = remainingSessionLimitSeconds
    }
}

@objcMembers
public final class ParsedSessionAdMediaFile: NSObject {
    public let mediaFileUrl: String
    public let encodingProfile: String

    public init(mediaFileUrl: String, encodingProfile: String) {
        self.mediaFileUrl = mediaFileUrl
        self.encodingProfile = encodingProfile
    }
}

@objcMembers
public final class ParsedSessionAd: NSObject {
    public let adId: String
    public let adState: Int
    public let adUrl: String
    public let mediaUrl: String
    public let adMediaFiles: [ParsedSessionAdMediaFile]
    public let clickThroughUrl: String
    public let adLengthInSeconds: Int
    public let durationMs: Int
    public let title: String
    public let adDescription: String

    public init(ad: SessionAdInfo) {
        adId = ad.adId
        adState = ad.adState
        adUrl = ad.adUrl
        mediaUrl = ad.mediaUrl
        adMediaFiles = ad.adMediaFiles.map { ParsedSessionAdMediaFile(mediaFileUrl: $0.mediaFileUrl, encodingProfile: $0.encodingProfile) }
        clickThroughUrl = ad.clickThroughUrl
        adLengthInSeconds = ad.adLengthInSeconds
        durationMs = ad.durationMs
        title = ad.title
        adDescription = ad.description
    }
}

@objcMembers
public final class ParsedSessionAdState: NSObject {
    public let isAdsRequired: Bool
    public let sessionAdsRequired: Bool
    public let isQueuePaused: Bool
    public let serverSentEmptyAds: Bool
    public let gracePeriodSeconds: Int
    public let message: String
    public let sessionAds: [ParsedSessionAd]

    public init(adState: SessionAdState) {
        isAdsRequired = adState.isAdsRequired
        sessionAdsRequired = adState.sessionAdsRequired
        isQueuePaused = adState.isQueuePaused
        serverSentEmptyAds = adState.serverSentEmptyAds
        gracePeriodSeconds = adState.gracePeriodSeconds
        message = adState.message
        sessionAds = adState.sessionAds.map(ParsedSessionAd.init(ad:))
    }
}

@objc(SessionJSONParser)
public final class SessionJSONParser: NSObject {
    @objc(parseNegotiatedStreamProfileFromSession:)
    public static func parseNegotiatedStreamProfile(from session: NSDictionary?) -> ParsedNegotiatedStreamProfile {
        let session = session as? [String: Any] ?? [:]
        var profile = NegotiatedStreamProfile()

        if let negotiated = session["negotiatedStreamProfile"] as? [String: Any] {
            if let resolution = nonEmptyString(negotiated["resolution"]) {
                profile.resolution = resolution
            }
            if let codec = nonEmptyString(negotiated["codec"]) {
                profile.codec = codec
            }
            if let fps = intValue(negotiated["fps"]) {
                profile.fps = fps
            }
        }

        if let features = session["finalizedStreamingFeatures"] as? [String: Any] {
            if let bitDepth = intValue(features["bitDepth"]) {
                profile.bitDepth = displayBitDepth(bitDepth)
            }
            if let chromaFormat = intValue(features["chromaFormat"]) {
                profile.chromaFormat = chromaFormat
            }
            if profile.bitDepth >= 0 || profile.chromaFormat >= 0 {
                profile.colorQuality = colorQuality(bitDepth: profile.bitDepth, chromaFormat: profile.chromaFormat)
            }
            if let prefilterMode = intValue(features["prefilterMode"]) {
                profile.prefilterMode = min(max(prefilterMode, 0), 2)
            }
            if let prefilterSharpness = intValue(features["prefilterSharpness"]) {
                profile.prefilterSharpness = min(max(prefilterSharpness, 0), 10)
            }
            if let prefilterDenoise = intValue(features["prefilterNoiseReduction"]) {
                profile.prefilterDenoise = min(max(prefilterDenoise, 0), 10)
            }
            if let prefilterModel = intValue(features["prefilterModel"]) {
                profile.prefilterModel = max(prefilterModel, 0)
            }
        }

        return ParsedNegotiatedStreamProfile(profile: profile)
    }

    @objc(parseSessionProgressFromSession:)
    public static func parseSessionProgress(from session: NSDictionary?) -> ParsedSessionProgress {
        let session = session as? [String: Any] ?? [:]
        let seatSetupInfo = dictionary(session["seatSetupInfo"])
        let sessionProgress = dictionary(session["sessionProgress"])
        let progressInfo = dictionary(session["progressInfo"])
        let controlInfo = dictionary(session["sessionControlInfo"])

        let queuePosition = positiveInt(session["queuePosition"])
            ?? positiveInt(seatSetupInfo?["queuePosition"])
            ?? positiveInt(sessionProgress?["queuePosition"])
            ?? positiveInt(progressInfo?["queuePosition"])
            ?? 0
        let seatSetupStep = intValue(seatSetupInfo?["seatSetupStep"])
            ?? intValue(sessionProgress?["seatSetupStep"])
            ?? intValue(progressInfo?["seatSetupStep"])
            ?? 0
        let timerDataContainers = [
            dictionary(session["timerData"]),
            dictionary(sessionProgress?["timerData"]),
            dictionary(progressInfo?["timerData"]),
            dictionary(controlInfo?["timerData"]),
            dictionary(dictionary(session["message"])?["timerData"]),
            dictionary(dictionary(sessionProgress?["message"])?["timerData"]),
            dictionary(dictionary(progressInfo?["message"])?["timerData"]),
            dictionary(dictionary(controlInfo?["message"])?["timerData"]),
        ]
        let containers = [session, sessionProgress, progressInfo, controlInfo] + timerDataContainers
        let remaining = remainingPlaytime(containers: containers)

        return ParsedSessionProgress(
            queuePosition: queuePosition,
            seatSetupStep: seatSetupStep,
            progressState: progressState(seatSetupStep: seatSetupStep, queuePosition: queuePosition),
            remainingPlaytimeHours: remaining.hours,
            remainingPlaytimeAvailable: remaining.available,
            remainingSessionLimitSeconds: remainingSessionLimitSeconds(containers: containers)
        )
    }

    @objc(parseSessionAdStateFromSession:)
    public static func parseSessionAdState(from session: NSDictionary?) -> ParsedSessionAdState {
        let session = session as? [String: Any] ?? [:]
        let progress = dictionary(session["sessionProgress"])
        let progressInfo = dictionary(session["progressInfo"])
        let controlInfo = dictionary(session["sessionControlInfo"])
        let containers = [session, progress, progressInfo, controlInfo].compactMap { $0 }
        let required = containers.contains { container in
            boolValue(container["sessionAdsRequired"]) || boolValue(container["isAdsRequired"])
        }

        var adState = SessionAdState()
        adState.sessionAdsRequired = required
        adState.serverSentEmptyAds = !containers.contains { !array($0["sessionAds"]).isEmpty || !array($0["ads"]).isEmpty }
        adState.sessionAds = sessionAds(from: containers)

        if let opportunity = containers.compactMap({ dictionary($0["opportunity"]) }).first {
            adState.isQueuePaused = boolValue(opportunity["queuePaused"], fallback: adState.isQueuePaused)
            adState.gracePeriodSeconds = positiveInt(opportunity["gracePeriodSeconds"]) ?? 0
            adState.message = nonEmptyString(opportunity["message"]) ?? nonEmptyString(opportunity["description"]) ?? ""
            if nonEmptyString(opportunity["state"])?.lowercased() == "graceperiodstart" {
                adState.isQueuePaused = true
            }
        }

        adState.isAdsRequired = required || !adState.sessionAds.isEmpty || adState.isQueuePaused
        return ParsedSessionAdState(adState: adState)
    }

    private static func sessionAds(from containers: [[String: Any]]) -> [SessionAdInfo] {
        let adValues = containers.compactMap { container -> [Any]? in
            let sessionAds = array(container["sessionAds"])
            if !sessionAds.isEmpty { return sessionAds }
            let ads = array(container["ads"])
            return ads.isEmpty ? nil : ads
        }.first ?? []
        return adValues.enumerated().compactMap { index, value in
            guard let ad = dictionary(value) else { return nil }
            let parsed = parseSessionAd(ad, index: index)
            guard !isTerminalAdState(parsed.adState) else { return nil }
            guard !parsed.adId.isEmpty || !parsed.mediaUrl.isEmpty || !parsed.title.isEmpty || !parsed.description.isEmpty else { return nil }
            return parsed
        }
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        return text
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let text = value as? String, let parsed = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return parsed
        }
        return nil
    }

    private static func positiveInt(_ value: Any?) -> Int? {
        guard let parsed = intValue(value), parsed > 0 else { return nil }
        return parsed
    }

    private static func dictionary(_ value: Any?) -> [String: Any]? {
        value as? [String: Any]
    }

    private static func array(_ value: Any?) -> [Any] {
        value as? [Any] ?? []
    }

    private static func boolValue(_ value: Any?, fallback: Bool = false) -> Bool {
        if let number = value as? NSNumber {
            return number.boolValue
        }
        if let text = value as? String {
            switch text.lowercased() {
            case "true", "1", "yes": return true
            case "false", "0", "no": return false
            default: return fallback
            }
        }
        return fallback
    }

    private static func adMediaProfileRank(_ profile: String) -> Int {
        switch profile {
        case "mp4deinterlaced720p": return 0
        case "hlsadaptive": return 1
        case "webm": return 2
        default: return 100
        }
    }

    private static func isTerminalAdState(_ adState: Int) -> Bool {
        adState == 5 || adState == 6
    }

    private static func parseSessionAd(_ ad: [String: Any], index: Int) -> SessionAdInfo {
        var out = SessionAdInfo()
        out.adId = nonEmptyString(ad["adId"]) ?? "ad-\(index + 1)"
        out.adState = intValue(ad["adState"]) ?? -1
        out.adUrl = nonEmptyString(ad["adUrl"]) ?? ""
        out.mediaUrl = nonEmptyString(ad["mediaUrl"]) ?? nonEmptyString(ad["videoUrl"]) ?? nonEmptyString(ad["url"]) ?? ""
        out.clickThroughUrl = nonEmptyString(ad["clickThroughUrl"]) ?? ""
        out.title = nonEmptyString(ad["title"]) ?? ""
        out.description = nonEmptyString(ad["description"]) ?? ""
        out.adLengthInSeconds = positiveInt(ad["adLengthInSeconds"]) ?? 0
        out.durationMs = out.adLengthInSeconds > 0 ? out.adLengthInSeconds * 1000 : positiveInt(ad["durationMs"]) ?? 0
        if out.durationMs == 0 {
            out.durationMs = positiveInt(ad["durationInMs"]) ?? 0
        }
        out.adMediaFiles = array(ad["adMediaFiles"]).compactMap { value in
            guard let file = dictionary(value) else { return nil }
            let mediaFileUrl = nonEmptyString(file["mediaFileUrl"]) ?? ""
            let encodingProfile = nonEmptyString(file["encodingProfile"]) ?? ""
            guard !mediaFileUrl.isEmpty || !encodingProfile.isEmpty else { return nil }
            return SessionAdMediaFile(mediaFileUrl: mediaFileUrl, encodingProfile: encodingProfile)
        }.sorted { adMediaProfileRank($0.encodingProfile) < adMediaProfileRank($1.encodingProfile) }
        if out.mediaUrl.isEmpty {
            out.mediaUrl = out.adMediaFiles.first { !$0.mediaFileUrl.isEmpty }?.mediaFileUrl ?? ""
        }
        if out.mediaUrl.isEmpty && !out.adUrl.isEmpty {
            out.mediaUrl = out.adUrl
        }
        return out
    }

    private static func firstNumber(in container: [String: Any], keys: [String]) -> Double? {
        for key in keys {
            if let number = valueAsDouble(container[key]) {
                return number
            }
        }
        return nil
    }

    private static func valueAsDouble(_ value: Any?) -> Double? {
        if let number = value as? NSNumber {
            return number.doubleValue
        }
        if let text = value as? String, let parsed = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return parsed
        }
        return nil
    }

    private static func progressState(seatSetupStep: Int, queuePosition: Int) -> SessionProgressState {
        switch seatSetupStep {
        case 0:
            return queuePosition > 0 ? .inQueue : .connecting
        case 1:
            return .inQueue
        case 5:
            return .previousSessionCleanup
        case 6:
            return .waitingForStorage
        default:
            return .settingUp
        }
    }

    private static func remainingPlaytime(containers: [[String: Any]?]) -> (hours: Double, available: Bool) {
        for container in containers.compactMap({ $0 }) {
            if let minutes = firstNumber(in: container, keys: ["remainingTimeInMinutes", "remainingSessionTimeInMinutes", "sessionTimeRemainingInMinutes", "timeRemainingInMinutes"]) {
                return (max(0.0, minutes / 60.0), true)
            }
            if let seconds = firstNumber(in: container, keys: ["remainingTimeInSeconds", "remainingSessionTimeInSeconds", "sessionTimeRemainingInSeconds", "timeRemainingInSeconds", "remainingTime", "timeRemaining"]) {
                return (max(0.0, seconds / 3600.0), true)
            }
            if let milliseconds = firstNumber(in: container, keys: ["remainingTimeInMs", "remainingTimeInMilliseconds", "remainingSessionTimeInMs", "sessionTimeRemainingInMs"]) {
                return (max(0.0, milliseconds / 3_600_000.0), true)
            }
        }
        return (0.0, false)
    }

    private static func remainingSessionLimitSeconds(containers: [[String: Any]?]) -> Int {
        for container in containers.compactMap({ $0 }) {
            if let milliseconds = firstNumber(in: container, keys: ["beforeEventMS", "remainingSessionLimitMs", "remainingSessionLimitMilliseconds", "sessionLimitRemainingMs", "sessionLimitRemainingMilliseconds"]) {
                let seconds = Int((milliseconds / 1000.0).rounded())
                if seconds > 0 && seconds <= 86_400 { return seconds }
            }
            if let seconds = firstNumber(in: container, keys: ["timeRemaining", "remainingTime", "remainingTimeInSeconds", "remainingSessionTimeInSeconds", "sessionTimeRemainingInSeconds", "timeRemainingInSeconds", "remainingSessionLimitSeconds", "sessionLimitRemainingSeconds"]) {
                let rounded = Int(seconds.rounded())
                if rounded > 0 && rounded <= 86_400 { return rounded }
            }
            if let minutes = firstNumber(in: container, keys: ["remainingTimeInMinutes", "remainingSessionTimeInMinutes", "sessionTimeRemainingInMinutes", "timeRemainingInMinutes", "remainingSessionLimitMinutes", "sessionLimitRemainingMinutes"]) {
                let seconds = Int((minutes * 60.0).rounded())
                if seconds > 0 && seconds <= 86_400 { return seconds }
            }
        }
        return 0
    }

    private static func colorQuality(bitDepth: Int, chromaFormat: Int) -> String {
        let tenBit = bitDepth >= 10
        let fourFourFour = chromaFormat == 2
        if tenBit && fourFourFour { return "10bit_444" }
        if tenBit { return "10bit_420" }
        if fourFourFour { return "8bit_444" }
        return "8bit_420"
    }

    private static func displayBitDepth(_ value: Int) -> Int {
        switch value {
        case 0: return 8
        case 1: return 10
        default: return value
        }
    }
}

public struct SessionAdMediaFile: Equatable, Sendable {
    public var mediaFileUrl = ""
    public var encodingProfile = ""
}

public struct SessionAdInfo: Equatable, Sendable {
    public var adId = ""
    public var adState = -1
    public var adUrl = ""
    public var mediaUrl = ""
    public var adMediaFiles: [SessionAdMediaFile] = []
    public var clickThroughUrl = ""
    public var adLengthInSeconds = 0
    public var durationMs = 0
    public var title = ""
    public var description = ""
}

public struct SessionAdState: Equatable, Sendable {
    public var isAdsRequired = false
    public var sessionAdsRequired = false
    public var isQueuePaused = false
    public var serverSentEmptyAds = false
    public var gracePeriodSeconds = 0
    public var message = ""
    public var sessionAds: [SessionAdInfo] = []
}

public enum SessionProgressState: Int, Sendable {
    case unknown = 0
    case connecting
    case inQueue
    case previousSessionCleanup
    case waitingForStorage
    case settingUp
}

public struct SessionInfo: Equatable, Sendable {
    public var sessionId = ""
    public var status = 0
    public var queuePosition = 0
    public var seatSetupStep = 0
    public var progressState = SessionProgressState.unknown
    public var zone = ""
    public var streamingBaseUrl = ""
    public var serverIp = ""
    public var signalingServer = ""
    public var signalingUrl = ""
    public var gpuType = ""
    public var iceServers: [IceServer] = []
    public var mediaConnectionInfo = MediaConnectionInfo()
    public var negotiatedStreamProfile = NegotiatedStreamProfile()
    public var adState = SessionAdState()
    public var remainingPlaytimeHours = 0.0
    public var remainingPlaytimeAvailable = false
    public var remainingPlaytimeUnlimited = false
    public var clientId = ""
    public var deviceId = ""
}

public struct IceCandidatePayload: Equatable, Sendable {
    public var candidate = ""
    public var sdpMid = ""
    public var sdpMLineIndex = 0
    public var usernameFragment = ""
}

public struct SendAnswerRequest: Equatable, Sendable {
    public var sdp = ""
    public var nvstSdp = ""
}
