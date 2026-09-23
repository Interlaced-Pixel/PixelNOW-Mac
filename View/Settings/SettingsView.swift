import AppKit
import CryptoKit
import SwiftData
import SwiftUI

private enum SettingsVendorLayout {
    static let surface = Color(red: 18 / 255, green: 19 / 255, blue: 18 / 255)
    static let sidebar = Color(red: 31 / 255, green: 32 / 255, blue: 31 / 255)
    static let card = Color(red: 26 / 255, green: 27 / 255, blue: 26 / 255)
    static let cardRaised = Color(red: 34 / 255, green: 35 / 255, blue: 34 / 255)
    static let row = Color.white.opacity(0.045)
    static let textPrimary = Color.white
    static let textSecondary = Color.white.opacity(0.68)
    static let textTertiary = Color.white.opacity(0.38)
}

private extension Font {
    static func settingsNvidia(size: CGFloat, weight: NVIDIAFont.Weight = .regular) -> Font {
        NVIDIAFont.font(size: size, weight: weight)
    }
}

@MainActor private struct SettingsAccountSnapshot {
    let displayName: String
    let membershipTier: String
    let providerName: String
    let userId: String
    let authorizationState: String
    let authStatus: String
    let rememberSession: Bool

    init(viewModel: CatalogViewModel) {
        displayName = viewModel.account.displayName.isEmpty ? "Signed in" : viewModel.account.displayName
        membershipTier = Self.membershipTier(viewModel: viewModel)
        providerName = Self.providerName(viewModel.account.providerName)
        userId = viewModel.session.userId.isEmpty ? viewModel.account.userId : viewModel.session.userId
        authorizationState = SettingsFormat.normalizedState(viewModel.account.authorizationState)
        authStatus = SettingsFormat.normalizedState(viewModel.account.authStatus)
        rememberSession = viewModel.account.rememberSession
    }

    var isAuthorized: Bool {
        authorizationState.caseInsensitiveCompare("Authorized") == .orderedSame
    }

    var isLoggedIn: Bool {
        authStatus.caseInsensitiveCompare("Logged In") == .orderedSame
    }

    private static func membershipTier(viewModel: CatalogViewModel) -> String {
        if viewModel.subscriptionStatus.isAvailable { return viewModel.subscriptionStatus.membershipTier }
        if !viewModel.account.membershipTier.isEmpty { return viewModel.account.membershipTier }
        return viewModel.subscriptionStatus.membershipTier
    }

    private static func providerName(_ value: String) -> String {
        if value.isEmpty || value == "" { return "Nvidia" }
        return value
    }
}

private struct SettingsRouteSnapshot {
    let displayValue: String
    let copyValue: String
    let summary: String

    init(regionUrl: String, revealSensitive: Bool) {
        if regionUrl.isEmpty {
            displayValue = "Automatic"
            copyValue = "Automatic"
            summary = "Automatic"
        } else {
            let host = SettingsFormat.endpointHost(regionUrl)
            displayValue = revealSensitive ? regionUrl : host
            copyValue = regionUrl
            summary = host
        }
    }
}

private enum SettingsAppMetadata {
    static var displayName: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        ?? "PixelNOW Mac"
    }

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }

    static var versionWithBuild: String {
        "\(version) (\(build))"
    }
}

private enum SettingsFormat {
    static func normalizedState(_ value: String) -> String {
        let normalized = value.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? "Unknown" : normalized.capitalized
    }

    static func maskedIdentifier(_ value: String) -> String {
        guard value.count > 10 else { return value.isEmpty ? "Unavailable" : "****" }
        return "\(value.prefix(6))****\(value.suffix(4))"
    }

    static func maskedEmail(_ value: String) -> String {
        guard let atIndex = value.firstIndex(of: "@") else { return value.isEmpty ? "Unavailable" : "****" }
        let name = String(value[..<atIndex])
        let domain = String(value[value.index(after: atIndex)...])
        return "\(name.prefix(2))****@\(domain)"
    }

    static func endpointHost(_ value: String) -> String {
        URL(string: value)?.host ?? value
    }
}

struct SettingsView: View {
    @ObservedObject var viewModel: CatalogViewModel
    let accounts: [LoginAccount]
    @ObservedObject var controllerInputRouter: ControllerInputRouter
    let onSwitch: (LoginAccount) -> Void
    let onAddAccount: () -> Void
    let onSignOut: () -> Void
    let onForget: (LoginAccount) -> Void

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(viewModel: viewModel)
            SettingsContent(
                viewModel: viewModel,
                accounts: accounts,
                controllerInputRouter: controllerInputRouter,
                onSwitch: onSwitch,
                onAddAccount: onAddAccount,
                onSignOut: onSignOut,
                onForget: onForget
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SettingsSurfaceBackground())
    }
}

private struct SettingsSurfaceBackground: View {
    var body: some View {
        ZStack {
            SettingsVendorLayout.surface
            LinearGradient(colors: [Color.pixelNowGreen.opacity(0.035), .clear], startPoint: .topLeading, endPoint: .center)
            LinearGradient(colors: [.black.opacity(0.22), .clear, .black.opacity(0.18)], startPoint: .leading, endPoint: .trailing)
        }
    }
}


private struct SettingsSidebar: View {
    @ObservedObject var viewModel: CatalogViewModel
    @State private var hoveredGroup: CatalogSettingsGroup?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("SETTINGS")
                    .font(.settingsNvidia(size: 11, weight: .bold))
                    .foregroundStyle(Color.pixelNowGreen)
                    .tracking(1.5)
                Text("PixelNOW")
                    .font(.settingsNvidia(size: 22, weight: .bold))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 22)
            .padding(.top, 24)
            .padding(.bottom, 10)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(CatalogSettingsGroup.visibleCases()) { group in
                        Button { viewModel.selectedSettingsGroup = group } label: {
                            HStack(spacing: 10) {
                                let isSelected = (viewModel.selectedSettingsGroup == group)
                                let isHovered = (hoveredGroup == group)
                                
                                Image(systemName: group.icon)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .foregroundStyle(isSelected ? Color.pixelNowGreen : (isHovered ? SettingsVendorLayout.textSecondary : SettingsVendorLayout.textTertiary))
                                    .frame(width: 16, height: 16)
                                Text(group.title)
                                    .font(.settingsNvidia(size: 13, weight: isSelected ? .bold : .medium))
                                    .foregroundStyle(isSelected ? SettingsVendorLayout.textPrimary : (isHovered ? SettingsVendorLayout.textPrimary : SettingsVendorLayout.textTertiary))
                                    .lineLimit(1)
                                Spacer(minLength: 4)
                            }
                            .padding(.horizontal, 14)
                            .frame(height: 36)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                group == viewModel.selectedSettingsGroup ? Color.pixelNowGreen.opacity(0.12) :
                                (hoveredGroup == group ? Color.white.opacity(0.05) : Color.clear)
                            )
                            .overlay(alignment: .leading) {
                                Rectangle()
                                    .fill(viewModel.selectedSettingsGroup == group ? Color.pixelNowGreen : Color.clear)
                                    .frame(width: 3)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .onHover { hovering in
                            withAnimation(.easeOut(duration: 0.12)) {
                                if hovering {
                                    hoveredGroup = group
                                } else if hoveredGroup == group {
                                    hoveredGroup = nil
                                }
                            }
                        }
                    }
                }
                .padding(.vertical, 14)
            }

            Spacer(minLength: 12)
            Button { viewModel.showGames() } label: {
                Text("BACK TO GAMES")
                    .font(.settingsNvidia(size: 12, weight: .bold))
                    .foregroundStyle(.white.opacity(0.86))
                    .tracking(0.9)
                    .frame(maxWidth: .infinity)
                    .frame(height: 38)
                    .background(Color.white.opacity(0.055))
                    .overlay { Rectangle().stroke(Color.white.opacity(0.13), lineWidth: 1) }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .frame(width: 208)
        .background(SettingsVendorLayout.sidebar)
        .overlay(alignment: .trailing) {
            Rectangle().fill(Color.white.opacity(0.08)).frame(width: 1)
        }
    }
}

private struct SettingsContent: View {
    @ObservedObject var viewModel: CatalogViewModel
    let accounts: [LoginAccount]
    @ObservedObject var controllerInputRouter: ControllerInputRouter
    let onSwitch: (LoginAccount) -> Void
    let onAddAccount: () -> Void
    let onSignOut: () -> Void
    let onForget: (LoginAccount) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                SettingsHeader(title: viewModel.selectedSettingsGroup.title, subtitle: subtitle)
                if !viewModel.errorMessage.isEmpty {
                    SettingsMessageView(message: viewModel.errorMessage, systemImage: "exclamationmark.triangle.fill")
                }
                if !viewModel.actionMessage.isEmpty {
                    SettingsMessageView(message: viewModel.actionMessage, systemImage: "checkmark.circle.fill")
                }
                page
            }
            .padding(.horizontal, 52)
            .padding(.top, 38)
            .padding(.bottom, 54)
            .frame(maxWidth: 1220, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(SettingsSurfaceBackground())
    }

    @ViewBuilder private var page: some View {
        switch viewModel.selectedSettingsGroup {
        case .account:
            VStack(alignment: .leading, spacing: 20) {
                AccountSettingsPage(
                    viewModel: viewModel,
                    accounts: accounts,
                    onSwitch: onSwitch,
                    onAddAccount: onAddAccount,
                    onSignOut: onSignOut,
                    onForget: onForget
                )
                ConnectionsSettingsPage(viewModel: viewModel)
            }
        case .video:
            VideoSettingsPage(viewModel: viewModel)
        case .audio:
            AudioSettingsPage(viewModel: viewModel)
        case .input:
            InputSettingsPage(viewModel: viewModel, inputRouter: controllerInputRouter)
        case .keybindings:
            SettingsPlaceholderPage(title: "Keybindings")
        case .recording:
            RecordingSettingsPage(viewModel: viewModel)
        case .network:
            NetworkSettingsPage(viewModel: viewModel)
        case .remoteCoOp:
            RemoteCoOpSettingsPage(viewModel: viewModel)
        case .theme:
            InterfaceSettingsPage(viewModel: viewModel, inputRouter: controllerInputRouter)
        case .system:
            VStack(alignment: .leading, spacing: 20) {
                SystemSettingsPage(viewModel: viewModel)
                AboutSettingsPage(viewModel: viewModel)
            }
        case .labs:
            ExperimentalFeaturesSettingsPage(viewModel: viewModel)
        }
    }

    private var subtitle: String {
        switch viewModel.selectedSettingsGroup {
        case .account: return "NVIDIA accounts, membership tier, and active session details."
        case .video: return "Stream resolution, frame rate, codec, HDR, and MetalFX upscaling."
        case .audio: return "Volume levels, microphone routing, and voice transmission mode."
        case .input: return "Mouse capture, anti-AFK, and controller navigation mode."
        case .keybindings: return "Keyboard shortcuts and custom binding overrides."
        case .recording: return "Video and audio bitrate for session captures and highlights."
        case .network: return "Server region selection and linked game store connections."
        case .remoteCoOp: return "Host a friend in local multiplayer via streaming."
        case .theme: return "Quality profile, Cloud G-Sync, and L4S congestion control."
        case .system: return "Hardware decode, diagnostics, logs, and app information."
        case .labs: return "Preview upcoming features and early beta tools."
        }
    }
}


private struct SettingsHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .bottom, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(title.uppercased())
                        .font(.settingsNvidia(size: 12, weight: .bold))
                        .foregroundStyle(Color.pixelNowGreen)
                        .tracking(1.5)
                    Text(title)
                        .font(.settingsNvidia(size: 34, weight: .bold))
                        .foregroundStyle(.white)
                    Text(subtitle)
                        .font(.settingsNvidia(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.62))
                }
                Spacer(minLength: 24)
                Rectangle()
                    .fill(Color.pixelNowGreen.opacity(0.42))
                    .frame(width: 120, height: 2)
                    .padding(.bottom, 9)
            }
        }
    }
}

private struct AccountSettingsPage: View {
    @ObservedObject var viewModel: CatalogViewModel
    let accounts: [LoginAccount]
    let onSwitch: (LoginAccount) -> Void
    let onAddAccount: () -> Void
    let onSignOut: () -> Void
    let onForget: (LoginAccount) -> Void
    @State private var revealSensitive = false
    @State private var copiedKey = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsCard(title: "Membership") {
                HStack(alignment: .top, spacing: 20) {
                    ZStack {
                        SettingsVendorLayout.cardRaised
                            .overlay { Rectangle().stroke(Color.pixelNowGreen.opacity(0.42), lineWidth: 1) }
                        SettingsAccountAvatar(email: viewModel.account.email, size: 58)
                    }
                    .frame(width: 92, height: 92)

                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(account.displayName)
                                .font(.settingsNvidia(size: 25, weight: .bold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            Text(account.membershipTier.uppercased())
                                .font(.settingsNvidia(size: 10, weight: .bold))
                                .foregroundStyle(.black)
                                .tracking(0.8)
                                .padding(.horizontal, 8)
                                .frame(height: 20)
                                .background(Color.pixelNowGreen)
                        }
                        Text(accountSummaryText)
                            .font(.settingsNvidia(size: 13, weight: .medium))
                            .foregroundStyle(.white.opacity(0.66))
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 8) {
                            AboutStatusPill(title: "Provider", value: account.providerName)
                            AboutStatusPill(title: "Playtime", value: viewModel.subscriptionStatus.remainingPlaytimeText)
                            AboutStatusPill(title: "Region", value: route.summary)
                        }
                    }
                    Spacer(minLength: 0)
                    AccountHealthBadge(title: accountHealthTitle, subtitle: accountHealthSubtitle, positive: accountHealthPositive)
                }
            }

            SettingsCard(title: "NVIDIA Accounts") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(accounts) { savedAccount in
                        savedNVIDIAAccountRow(savedAccount)
                    }
                    HStack(spacing: 10) {
                        SettingsActionButton(title: "ADD ACCOUNT", tone: .secondary, minimumWidth: 128, action: onAddAccount)
                        SettingsActionButton(title: "SIGN OUT", tone: .secondary, minimumWidth: 110, action: onSignOut)
                        SettingsActionButton(title: "FORGET CURRENT", minimumWidth: 156) {
                            onForget(viewModel.account)
                        }
                    }
                    .padding(.top, 4)
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    profilePrivacyCard
                    sessionCard
                }
                VStack(alignment: .leading, spacing: 16) {
                    profilePrivacyCard
                    sessionCard
                }
            }

            SettingsCard(title: "Playtime Statistics") {
                if viewModel.playtimeStatistics.sessionCount == 0 {
                    AccountEmptyState(title: "No completed streams recorded yet.", subtitle: "PixelNOW will track local playtime after your next PixelNOW session ends.")
                } else {
                    SettingsFlowLayout(spacing: 10) {
                        SettingsStatisticTile(label: "Total Playtime", value: durationText(viewModel.playtimeStatistics.totalSeconds), emphasized: true)
                        if viewModel.subscriptionStatus.isAvailable {
                            SettingsStatisticTile(label: "Remaining Playtime", value: viewModel.subscriptionStatus.remainingPlaytimeText)
                        }
                        SettingsStatisticTile(label: "Sessions", value: "\(viewModel.playtimeStatistics.sessionCount)")
                        SettingsStatisticTile(label: "Last Session", value: durationText(viewModel.playtimeStatistics.lastSessionSeconds))
                        SettingsStatisticTile(label: "Average Session", value: durationText(viewModel.playtimeStatistics.averageSessionSeconds))
                        SettingsStatisticTile(label: "Longest Session", value: durationText(viewModel.playtimeStatistics.longestSessionSeconds))
                        SettingsStatisticTile(label: "Last Played", value: lastPlayedText)
                    }
                    if !viewModel.playtimeStatistics.lastPlayedTitle.isEmpty {
                        SettingsDivider()
                        AboutDetailRow(label: "Most Recent Game", value: viewModel.playtimeStatistics.lastPlayedTitle, copyValue: viewModel.playtimeStatistics.lastPlayedTitle, copiedKey: $copiedKey)
                    }
                }
            }
        }
    }

    private var profilePrivacyCard: some View {
        SettingsCard(title: "Profile & Privacy") {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Personal account details are masked by default.")
                        .font(.settingsNvidia(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                    Text("Reveal only when validating account state on your own machine.")
                        .font(.settingsNvidia(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.56))
                }
                Spacer()
                SettingsRevealButton(revealed: revealSensitive) { revealSensitive.toggle() }
            }
            SettingsDivider()
            AboutDetailRow(label: "Display Name", value: account.displayName, copyValue: account.displayName, copiedKey: $copiedKey)
            SettingsDivider()
            AboutDetailRow(label: "Email", value: displayedEmail, copyValue: viewModel.account.email, copiedKey: $copiedKey, copyDisabled: viewModel.account.email.isEmpty)
            SettingsDivider()
            AboutDetailRow(label: "User ID", value: displayedUserId, copyValue: account.userId, copiedKey: $copiedKey, copyDisabled: account.userId.isEmpty)
        }
    }

    private var sessionCard: some View {
        SettingsCard(title: "Session") {
            SettingsFlowLayout(spacing: 10) {
                AccountStatusTile(label: "Provider", value: account.providerName, positive: true)
                AccountStatusTile(label: "Authorization", value: account.authorizationState, positive: account.isAuthorized)
                AccountStatusTile(label: "Status", value: account.authStatus, positive: account.isLoggedIn)
                AccountStatusTile(label: "Remember", value: account.rememberSession ? "Enabled" : "Off", positive: account.rememberSession)
            }
            SettingsDivider()
            AboutDetailRow(label: "Preferred Region", value: route.displayValue, copyValue: route.copyValue, copiedKey: $copiedKey)
            SettingsDivider()
            AboutDetailRow(label: "Membership Usage", value: viewModel.subscriptionStatus.usageText, copyValue: viewModel.subscriptionStatus.usageText, copiedKey: $copiedKey)
            SettingsDivider()
            AboutDetailRow(label: "Last Login", value: dateText(viewModel.account.lastLoginAt), copyValue: dateText(viewModel.account.lastLoginAt), copiedKey: $copiedKey)
        }
    }

    private var account: SettingsAccountSnapshot {
        SettingsAccountSnapshot(viewModel: viewModel)
    }

    private var route: SettingsRouteSnapshot {
        SettingsRouteSnapshot(regionUrl: viewModel.selectedSettingsRegionUrl, revealSensitive: revealSensitive)
    }

    private var displayedUserId: String {
        revealSensitive ? account.userId : SettingsFormat.maskedIdentifier(account.userId)
    }

    private var displayedEmail: String {
        revealSensitive ? viewModel.account.email : SettingsFormat.maskedEmail(viewModel.account.email)
    }

    private func savedNVIDIAAccountRow(_ savedAccount: LoginAccount) -> some View {
        let isCurrent = isCurrentAccount(savedAccount)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                SettingsAccountAvatar(email: savedAccount.email, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(savedAccount.displayName)
                            .font(.settingsNvidia(size: 15, weight: .bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        if isCurrent {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Color.pixelNowGreen)
                        }
                    }
                    Text(savedAccount.providerName.isEmpty ? "NVIDIA" : savedAccount.providerName)
                        .font(.settingsNvidia(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.56))
                }
                Spacer()
                if isCurrent {
                    Text("CURRENT")
                        .font(.settingsNvidia(size: 10, weight: .bold))
                        .foregroundStyle(.black)
                        .tracking(0.8)
                        .padding(.horizontal, 8)
                        .frame(height: 20)
                        .background(Color.pixelNowGreen)
                } else {
                    HStack(spacing: 8) {
                        SettingsActionButton(title: "SWITCH", tone: .secondary, minimumWidth: 86) {
                            onSwitch(savedAccount)
                        }
                        SettingsActionButton(title: "FORGET", minimumWidth: 86) {
                            onForget(savedAccount)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func isCurrentAccount(_ savedAccount: LoginAccount) -> Bool {
        if let lhs = AccountStorageKeys.requireUserId(savedAccount.userId),
           let rhs = AccountStorageKeys.requireUserId(viewModel.account.userId) {
            return lhs == rhs
        }
        return savedAccount.persistentModelID == viewModel.account.persistentModelID
    }

    private var accountHealthPositive: Bool {
        account.isAuthorized && account.isLoggedIn
    }

    private var accountHealthTitle: String {
        accountHealthPositive ? "ACTIVE" : "ATTENTION"
    }

    private var accountHealthSubtitle: String {
        accountHealthPositive ? "Session authorized" : "Re-auth may be required"
    }

    private var accountSummaryText: String {
        let availability = viewModel.subscriptionStatus.isAvailable ? viewModel.subscriptionStatus.usageText : "subscription details are still refreshing"
        return "\(account.providerName) account on \(account.membershipTier) membership. \(availability)."
    }

    private var lastPlayedText: String {
        guard let date = viewModel.playtimeStatistics.lastPlayedAt else { return "-" }
        return dateText(date)
    }

    private func dateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func durationText(_ seconds: Double) -> String {
        let totalMinutes = max(0, Int((seconds / 60).rounded()))
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours > 0, minutes > 0 { return "\(hours)h \(minutes)m" }
        if hours > 0 { return "\(hours)h" }
        return "\(minutes)m"
    }
}

private struct AccountHealthBadge: View {
    let title: String
    let subtitle: String
    let positive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Circle()
                    .fill(positive ? Color.pixelNowGreen : Color.orange)
                    .frame(width: 7, height: 7)
                Text(title)
                    .font(.settingsNvidia(size: 12, weight: .bold))
                    .foregroundStyle(positive ? Color.pixelNowGreen : .white.opacity(0.88))
                    .tracking(1.1)
            }
            Text(subtitle)
                .font(.settingsNvidia(size: 11, weight: .bold))
                .foregroundStyle(.white.opacity(0.58))
                .lineLimit(2)
        }
        .padding(.horizontal, 14)
        .frame(width: 172, height: 64, alignment: .leading)
        .background(SettingsVendorLayout.cardRaised)
        .overlay(alignment: .leading) { Rectangle().fill(positive ? Color.pixelNowGreen : Color.orange).frame(width: 3) }
        .overlay { Rectangle().stroke(positive ? Color.pixelNowGreen.opacity(0.35) : Color.orange.opacity(0.30), lineWidth: 1) }
    }
}

private struct SettingsRevealButton: View {
    let revealed: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(revealed ? "HIDE DETAILS" : "REVEAL DETAILS")
                .font(.settingsNvidia(size: 11, weight: .bold))
                .foregroundStyle(revealed ? .black : .white.opacity(isHovering ? 0.94 : 0.82))
                .tracking(0.8)
                .padding(.horizontal, 13)
                .frame(height: 32)
                .background(revealed ? Color.pixelNowGreen.opacity(isHovering ? 0.90 : 1) : Color.white.opacity(isHovering ? 0.10 : 0.065))
                .overlay { Rectangle().stroke(revealed ? Color.pixelNowGreen : Color.white.opacity(isHovering ? 0.20 : 0.13), lineWidth: 1) }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

private struct SettingsAccountAvatar: View {
    let email: String
    let size: CGFloat

    private var gravatarURL: URL? {
        let normalizedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedEmail.isEmpty else { return nil }
        let digest = Insecure.MD5.hash(data: Data(normalizedEmail.utf8))
        let hash = digest.map { String(format: "%02x", $0) }.joined()
        return URL(string: "https://www.gravatar.com/avatar/\(hash)?s=\(Int(size * 3))&d=404")
    }

    var body: some View {
        Group {
            if let gravatarURL {
                AsyncImage(url: gravatarURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    default:
                        fallbackAvatar
                    }
                }
            } else {
                fallbackAvatar
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().stroke(.white.opacity(0.16), lineWidth: 1))
    }

    private var fallbackAvatar: some View {
        VendorResourceImage(name: "avatar_generic_118", fileExtension: "svg")
            .scaledToFill()
    }
}

private struct AccountStatusTile: View {
    let label: String
    let value: String
    let positive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label.uppercased())
                .font(.settingsNvidia(size: 10, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(.white.opacity(0.44))
            Text(value.isEmpty ? "Unknown" : value)
                .font(.settingsNvidia(size: 16, weight: .bold))
                .foregroundStyle(positive ? Color.pixelNowGreen : .white.opacity(0.78))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: 188, height: 74, alignment: .leading)
        .background(Color.white.opacity(positive ? 0.065 : 0.045))
        .overlay { Rectangle().stroke(positive ? Color.pixelNowGreen.opacity(0.32) : Color.white.opacity(0.08), lineWidth: 1) }
    }
}

private struct AccountEmptyState: View {
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 12) {
            Rectangle()
                .fill(Color.white.opacity(0.18))
                .frame(width: 4, height: 44)
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.settingsNvidia(size: 15, weight: .bold))
                    .foregroundStyle(.white.opacity(0.88))
                Text(subtitle)
                    .font(.settingsNvidia(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.58))
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color.white.opacity(0.045))
        .overlay { Rectangle().stroke(Color.white.opacity(0.08), lineWidth: 1) }
    }
}

private struct SettingsStatisticTile: View {
    let label: String
    let value: String
    var emphasized = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label.uppercased())
                .font(.settingsNvidia(size: 10, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(.white.opacity(0.44))
            Text(value.isEmpty ? "-" : value)
                .font(.settingsNvidia(size: emphasized ? 24 : 19, weight: .bold))
                .foregroundStyle(emphasized ? Color.pixelNowGreen : .white.opacity(0.90))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: emphasized ? 206 : 164, height: 78, alignment: .leading)
        .background(Color.white.opacity(emphasized ? 0.075 : 0.052))
        .overlay { Rectangle().stroke(emphasized ? Color.pixelNowGreen.opacity(0.36) : Color.white.opacity(0.08), lineWidth: 1) }
    }
}

private struct InterfaceSettingsPage: View {
    @ObservedObject var viewModel: CatalogViewModel
    @ObservedObject var inputRouter: ControllerInputRouter
    @AppStorage(InterfacePreferences.controllerModeEnabledKey) private var controllerModeEnabled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsCard(title: "Controls") {
                SettingsFlowLayout(spacing: 10) {
                    InterfaceInputLegend(title: "Move", glyphs: [inputRouter.glyphs.left, inputRouter.glyphs.up, inputRouter.glyphs.down, inputRouter.glyphs.right])
                    InterfaceInputLegend(title: "Select", glyphs: [inputRouter.glyphs.confirm])
                    InterfaceInputLegend(title: "Back", glyphs: [inputRouter.glyphs.back])
                    InterfaceInputLegend(title: "Search", glyphs: [inputRouter.glyphs.search])
                    InterfaceInputLegend(title: "Actions", glyphs: [inputRouter.glyphs.actions])
                    InterfaceInputLegend(title: "Rail", glyphs: [inputRouter.glyphs.pageLeft, inputRouter.glyphs.pageRight])
                }
                SettingsDivider()
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: inputRouter.isControllerConnected ? "gamecontroller.fill" : "keyboard")
                        .font(.settingsNvidia(size: 18, weight: .bold))
                        .foregroundStyle(Color.pixelNowGreen)
                        .frame(width: 34, height: 34)
                        .background(Color.pixelNowGreen.opacity(0.12))
                        .overlay { Rectangle().stroke(Color.pixelNowGreen.opacity(0.30), lineWidth: 1) }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(inputRouter.isControllerConnected ? "Adaptive Controller Layout" : "Keyboard Navigation Active")
                            .font(.settingsNvidia(size: 14, weight: .bold))
                            .foregroundStyle(.white.opacity(0.92))
                        Text(inputRouter.isControllerConnected ? "Input hints adapt to your connected controller." : "Connect a controller to show gamepad button hints automatically.")
                            .font(.settingsNvidia(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.58))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                SettingsDivider()
                SettingsToggleRow(
                    title: "Controller Navigation Mode",
                    subtitle: "Navigate catalog, library, and settings using connected gamepads.",
                    isOn: controllerModeEnabled,
                    action: { controllerModeEnabled = $0 }
                )
            }
        }
    }
}

private struct InterfaceInputLegend: View {
    let title: String
    let glyphs: [ControllerInputGlyph]

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title.uppercased())
                .font(.settingsNvidia(size: 10, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(.white.opacity(0.44))
            HStack(spacing: 6) {
                ForEach(Array(glyphs.enumerated()), id: \.offset) { _, glyph in
                    InterfaceGlyphPill(glyph: glyph)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .frame(minWidth: 132, minHeight: 70, alignment: .leading)
        .background(Color.white.opacity(0.045))
        .overlay { Rectangle().stroke(Color.white.opacity(0.08), lineWidth: 1) }
    }
}

private struct InterfaceGlyphPill: View {
    let glyph: ControllerInputGlyph

    var body: some View {
        HStack(spacing: 6) {
            if !glyph.symbolName.isEmpty {
                Image(systemName: glyph.symbolName)
                    .font(.settingsNvidia(size: 13, weight: .bold))
            }
            Text(glyph.fallbackText)
                .font(.settingsNvidia(size: 10, weight: .bold))
                .lineLimit(1)
        }
        .foregroundStyle(Color.pixelNowGreen)
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(Color.pixelNowGreen.opacity(0.12))
        .overlay { Rectangle().stroke(Color.pixelNowGreen.opacity(0.28), lineWidth: 1) }
        .accessibilityLabel(glyph.accessibilityLabel)
    }
}

private struct ConnectionsSettingsPage: View {
    @ObservedObject var viewModel: CatalogViewModel

    var body: some View {
        let stores = connectionStores
        SettingsCard(title: "Store Connections") {
            if stores.isEmpty {
                AccountEmptyState(title: "No store providers available.", subtitle: "PixelNOW did not return any account providers for this session.")
            } else {
                StoreConnectionsOverview(connectedCount: connectedStoreCount(in: stores), totalCount: stores.count)
                SettingsDivider()
                VStack(spacing: 8) {
                    ForEach(stores, id: \.self) { store in
                        StoreConnectionRow(viewModel: viewModel, store: store)
                    }
                }
            }
        }
    }

    private var connectionStores: [String] {
        var seen = Set<String>()
        var stores: [String] = []
        for store in viewModel.storeDefinitions.map(\.store) + viewModel.accountStores.map(\.store) where !store.isEmpty {
            let key = store.lowercased()
            guard !seen.contains(key), !isHiddenConnectionStore(store) else { continue }
            seen.insert(key)
            stores.append(store)
        }
        return stores.sorted { lhs, rhs in
            let lhsConnected = viewModel.accountStatus(forStore: lhs) != nil
            let rhsConnected = viewModel.accountStatus(forStore: rhs) != nil
            if lhsConnected != rhsConnected { return lhsConnected }
            return viewModel.displayName(forStore: lhs).localizedStandardCompare(viewModel.displayName(forStore: rhs)) == .orderedAscending
        }
    }

    private func connectedStoreCount(in stores: [String]) -> Int {
        stores.filter { viewModel.accountStatus(forStore: $0) != nil }.count
    }

    private func isHiddenConnectionStore(_ store: String) -> Bool {
        let rawKey = normalizedStoreKey(store)
        let displayKey = normalizedStoreKey(viewModel.displayName(forStore: store))
        return Self.hiddenConnectionStoreKeys.contains(rawKey) || Self.hiddenConnectionStoreKeys.contains(displayKey)
    }

    private func normalizedStoreKey(_ value: String) -> String {
        String(value.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    private static let hiddenConnectionStoreKeys: Set<String> = [
        "ea",
        "eaapp",
        "electronicarts",
        "gog",
        "gogcom",
        "none",
        "nvidia",
        "origin",
        "stove",
        "unknown"
    ]
}

private struct StoreConnectionsOverview: View {
    let connectedCount: Int
    let totalCount: Int

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Library ownership sync")
                    .font(.settingsNvidia(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                Text("Connected stores can sync library ownership before launch.")
                    .font(.settingsNvidia(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.58))
            }
            Spacer(minLength: 0)
            SettingsStatusPill(title: "CONNECTED", value: "\(connectedCount)/\(totalCount)", positive: connectedCount > 0)
        }
    }
}

private struct StoreConnectionRow: View {
    @ObservedObject var viewModel: CatalogViewModel
    let store: String

    var body: some View {
        let account = viewModel.accountStatus(forStore: store)
        let definition = viewModel.storeDefinitions.first { $0.store.caseInsensitiveCompare(store) == .orderedSame }
        let displayName = viewModel.displayName(forStore: store)
        let iconAsset = StoreIconAsset.resolve(store: store, displayName: displayName)
        let iconURL = definition?.smallImageUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        let isConnected = account != nil
        let supportsLinking = definition?.isAccountLinkingSupported == true || account?.hasAccountLinkingData == true
        HStack(alignment: .center, spacing: 16) {
            Rectangle()
                .fill(isConnected ? Color.pixelNowGreen : Color.white.opacity(0.18))
                .frame(width: 4, height: 46)
            StoreIcon(asset: iconAsset, imageURL: iconURL, connected: isConnected)
            VStack(alignment: .leading, spacing: 5) {
                Text(displayName)
                    .font(.settingsNvidia(size: 15, weight: .bold))
                    .foregroundStyle(isConnected ? .white : .white.opacity(0.86))
                Text(statusText(account))
                    .font(.settingsNvidia(size: 12, weight: .medium))
                    .foregroundStyle(isConnected ? .white.opacity(0.62) : .white.opacity(0.44))
            }
            Spacer(minLength: 12)
            SettingsStatusPill(title: isConnected ? "LINKED" : "AVAILABLE", value: isConnected ? connectionDetail(account) : "Not linked", positive: isConnected)
            if account?.hasAccountSyncingData == true {
                SettingsActionButton(title: "SYNC", tone: .secondary, minimumWidth: 86) { viewModel.syncStoreAccount(store) }
            }
            if supportsLinking {
                SettingsActionButton(title: account == nil ? "CONNECT" : "MANAGE", minimumWidth: 96) { viewModel.linkStoreAccount(store) }
            }
        }
        .padding(12)
        .background(isConnected ? Color.pixelNowGreen.opacity(0.095) : SettingsVendorLayout.row)
        .overlay { Rectangle().stroke(isConnected ? Color.pixelNowGreen.opacity(0.34) : Color.white.opacity(0.08), lineWidth: 1) }
    }

    private func statusText(_ account: CatalogStoreAccount?) -> String {
        guard let account else { return "Not connected" }
        if !account.userDisplayName.isEmpty { return "Connected as \(account.userDisplayName)" }
        if !account.userIdentifier.isEmpty { return "Connected as \(account.userIdentifier)" }
        if account.totalSyncedGames > 0 { return "\(account.totalSyncedGames) synced games" }
        if !account.syncState.isEmpty { return account.syncState.replacingOccurrences(of: "_", with: " ").capitalized }
        return "Connected"
    }

    private func connectionDetail(_ account: CatalogStoreAccount?) -> String {
        guard let account else { return "Not linked" }
        if account.totalSyncedGames > 0 { return "\(account.totalSyncedGames) games" }
        if !account.syncDate.isEmpty { return "Synced" }
        return "Ready"
    }
}

private struct StoreIcon: View {
    let asset: StoreIconAsset?
    let imageURL: String?
    let connected: Bool

    var body: some View {
        ZStack {
            Rectangle()
                .fill(connected ? Color.pixelNowGreen.opacity(0.18) : Color.white.opacity(0.075))
            if let url = resolvedImageURL {
                StoreRemoteIconImage(url: url, asset: asset, connected: connected)
            } else {
                StoreLocalIconImage(asset: asset, connected: connected)
            }
        }
        .frame(width: 42, height: 42)
        .overlay { Rectangle().stroke(connected ? Color.pixelNowGreen.opacity(0.42) : Color.white.opacity(0.12), lineWidth: 1) }
        .accessibilityHidden(true)
    }

    private var resolvedImageURL: URL? {
        guard let imageURL, !imageURL.isEmpty else { return nil }
        return URL(string: imageURL)
    }
}

private struct StoreRemoteIconImage: View {
    let url: URL
    let asset: StoreIconAsset?
    let connected: Bool

    @State private var image: NSImage?
    @State private var hasFailed = false

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(5)
                    .saturation(connected ? 1 : 0.65)
                    .opacity(connected ? 1 : 0.68)
            } else if hasFailed {
                StoreLocalIconImage(asset: asset, connected: connected)
            } else {
                StoreLocalIconImage(asset: asset, connected: connected)
                    .opacity(0.42)
            }
        }
        .task(id: url) { await loadImage() }
    }

    @MainActor
    private func loadImage() async {
        image = nil
        hasFailed = false
        guard let cached = await CatalogImageCache.shared.image(for: url), !Task.isCancelled else {
            hasFailed = !Task.isCancelled
            return
        }
        image = cached.image
        hasFailed = false
    }
}

private struct StoreLocalIconImage: View {
    let asset: StoreIconAsset?
    let connected: Bool

    var body: some View {
        if let asset, let image = StoreIconImage.loadImage(named: asset.assetName) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .padding(asset.padding)
                .saturation(connected ? 1 : 0.65)
                .opacity(connected ? 1 : 0.68)
        } else {
            Image(systemName: "link")
                .font(.settingsNvidia(size: 17, weight: .bold))
                .foregroundStyle(connected ? Color.pixelNowGreen : .white.opacity(0.56))
        }
    }
}

private enum StoreIconImage {
    @MainActor static func loadImage(named name: String) -> NSImage? {
        let cacheKey = name as NSString
        if let cached = cache.object(forKey: cacheKey) { return cached }
        guard let url = Bundle.main.url(forResource: name, withExtension: "svg", subdirectory: "StoreIcons") ?? Bundle.main.url(forResource: name, withExtension: "svg", subdirectory: "Resources/StoreIcons"),
              let image = NSImage(contentsOf: url) else { return nil }
        cache.setObject(image, forKey: cacheKey)
        return image
    }

    @MainActor private static let cache = NSCache<NSString, NSImage>()
}

private enum StoreIconAsset: CaseIterable {
    case battlenet
    case epicGames
    case steam
    case ubisoftConnect
    case xbox
    case gaijin

    var assetName: String {
        switch self {
        case .battlenet: return "store-battlenet"
        case .epicGames: return "store-epic-games"
        case .steam: return "store-steam"
        case .ubisoftConnect: return "store-ubisoft-connect"
        case .xbox: return "store-xbox"
        case .gaijin: return "store-gaijin"
        }
    }

    var padding: CGFloat {
        switch self {
        case .epicGames: return 5
        case .steam, .xbox: return 4
        default: return 6
        }
    }

    static func resolve(store: String, displayName: String) -> StoreIconAsset? {
        let key = normalized(store)
        let displayKey = normalized(displayName)
        let combined = key + displayKey
        if combined.contains("battlenet") || combined.contains("battle") || combined.contains("blizzard") { return .battlenet }
        if combined.contains("epic") { return .epicGames }
        if combined.contains("steam") { return .steam }
        if combined.contains("ubisoft") || combined.contains("uplay") { return .ubisoftConnect }
        if combined.contains("xbox") || combined.contains("microsoft") { return .xbox }
        if combined.contains("gaijin") { return .gaijin }
        return nil
    }

    private static func normalized(_ value: String) -> String {
        String(value.lowercased().filter { $0.isLetter || $0.isNumber })
    }
}

private struct ExperimentalFeaturesSettingsPage: View {
    @ObservedObject var viewModel: CatalogViewModel
    @AppStorage(RecordingEditorBetaPreference.key) private var recordingEditorEarlyBetaEnabled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsCard(title: "Alpha Access") {
                SettingsToggleRow(
                    title: "Remote Co-Op Alpha",
                    subtitle: viewModel.remoteCoOpPreferences.isAlphaOptedIn ? "Controls and host options available in Gameplay settings." : "Unlock Remote Co-Op host controls and stream HUD invites.",
                    isOn: viewModel.remoteCoOpPreferences.isAlphaOptedIn,
                    action: viewModel.setRemoteCoOpAlphaOptedIn
                )
            }

            SettingsCard(title: "Recording") {
                SettingsToggleRow(
                    title: "Recording Editor Early Beta",
                    subtitle: recordingEditorEarlyBetaEnabled ? "Editing tools unlocked in Recordings tab." : "Unlock clip trimming, arrangement, and export tools in Recordings.",
                    isOn: recordingEditorEarlyBetaEnabled,
                    action: setRecordingEditorEarlyBetaEnabled
                )
            }
        }
    }

    private func setRecordingEditorEarlyBetaEnabled(_ enabled: Bool) {
        recordingEditorEarlyBetaEnabled = enabled
    }
}

private struct GameplaySettingsPage: View {
    @ObservedObject var viewModel: CatalogViewModel

    var body: some View {
        let qualityLocked = !viewModel.streamingQualityProfileAllowsCustomization
        VStack(alignment: .leading, spacing: 16) {
            SettingsCard(title: "Quality & Network Performance") {
                SettingsOptionRow(title: "Quality Profile", subtitle: "Preconfigured streaming balance for bandwidth and latency.", options: StreamPreferences.streamingQualityProfileOptions.map(\.label), selectedIndex: viewModel.streamProfile.streamingQualityProfileIndex, action: viewModel.setStreamingQualityProfileIndex)
                SettingsDivider()
                SettingsToggleRow(title: "Cloud G-Sync", subtitle: qualityLocked ? lockedProfileSubtitle : "Sync render rate with display refresh to eliminate tearing.", isOn: viewModel.streamProfile.enableCloudGsync, isLocked: qualityLocked, action: viewModel.setCloudGsyncEnabled)
                SettingsDivider()
                SettingsToggleRow(title: "L4S Congestion Control", subtitle: qualityLocked ? lockedProfileSubtitle : "Reduce queuing delay and packet jitter on supported networks.", isOn: viewModel.streamProfile.enableL4S, isLocked: qualityLocked, action: viewModel.setL4SEnabled)
            }

            SettingsCard(title: "Display & Video") {
                SettingsOptionRow(title: "Aspect Ratio", subtitle: qualityLocked ? lockedProfileSubtitle : "Aspect ratio for available stream resolutions.", options: StreamPreferences.aspectOptions.map(\.label), selectedIndex: viewModel.streamProfile.aspectIndex, isLocked: qualityLocked, action: viewModel.setAspectIndex)
                SettingsDivider()
                SettingsOptionRow(title: "Resolution", subtitle: qualityLocked ? lockedProfileSubtitle : "Target stream resolution.", options: StreamPreferences.resolutionOptions(forAspect: viewModel.streamProfile.aspectIndex).map(\.label), selectedIndex: viewModel.streamProfile.resolutionIndex, isLocked: qualityLocked, action: viewModel.setResolutionIndex)
                SettingsDivider()
                SettingsOptionRow(title: "Frame Rate", subtitle: qualityLocked ? lockedProfileSubtitle : "Target stream FPS, capped by display refresh.", options: StreamPreferences.fpsOptions.map { "\($0) FPS" }, selectedIndex: viewModel.streamProfile.fpsIndex, enabled: StreamPreferences.fpsOptions.map { StreamPreferences.fpsSupported($0, capabilities: viewModel.streamCapabilities) }, isLocked: qualityLocked, action: viewModel.setFpsIndex)
                SettingsDivider()
                SettingsOptionRow(title: "Codec", subtitle: qualityLocked ? lockedProfileSubtitle : "Hardware video decoder (AV1, HEVC, or H.264).", options: StreamPreferences.codecOptions.map(\.label), selectedIndex: viewModel.streamProfile.codecIndex, enabled: StreamPreferences.codecOptions.map { StreamPreferences.codecSupported($0, capabilities: viewModel.streamCapabilities) }, isLocked: qualityLocked, action: viewModel.setCodecIndex)
                SettingsDivider()
                SettingsOptionRow(title: "Maximum Bitrate", subtitle: qualityLocked ? lockedProfileSubtitle : "Maximum video streaming bandwidth.", options: StreamPreferences.bitrateOptions.map(\.label), selectedIndex: viewModel.streamProfile.bitrateIndex, isLocked: qualityLocked, action: viewModel.setBitrateIndex)
                SettingsDivider()
                SettingsToggleRow(title: "HDR (High Dynamic Range)", subtitle: qualityLocked ? lockedProfileSubtitle : "10-bit Rec. 2020 color on supported displays and codecs.", isOn: viewModel.streamProfile.enableHdr, isLocked: qualityLocked, action: viewModel.setHDREnabled)
            }

            SettingsCard(title: "Mouse & Input Controls") {
                SettingsToggleRow(title: "Direct Mouse Input", subtitle: "Capture raw mouse motion. Press ⌘G or ⌘Q to release pointer.", isOn: viewModel.streamProfile.directMouseInput, action: viewModel.setDirectMouseInputEnabled)
                SettingsDivider()
                SettingsToggleRow(title: "Suppress Input When Inactive", subtitle: "Ignore inputs when PixelNOW loses window focus.", isOn: viewModel.streamProfile.suppressInputWhenInactive, action: viewModel.setSuppressInputWhenInactive)
                SettingsDivider()
                SettingsToggleRow(title: "Anti-AFK Mouse Movement", subtitle: "Periodic keep-alive motion to prevent session timeout (⌘K).", isOn: viewModel.streamProfile.antiAFKMouseMovementEnabled, action: viewModel.setAntiAFKMouseMovementEnabled)
            }

            SettingsCard(title: "Audio & Voice") {
                SettingsSliderRow(
                    title: "Game Volume",
                    valueText: percentText(viewModel.streamProfile.gameVolume),
                    value: viewModel.streamProfile.gameVolume,
                    range: 0...1,
                    step: 0.01,
                    action: viewModel.setGameVolume
                )
                SettingsDivider()
                SettingsSliderRow(title: "Microphone Volume", valueText: percentText(viewModel.streamProfile.microphoneVolume), value: viewModel.streamProfile.microphoneVolume, range: 0...1, step: 0.01, action: viewModel.setMicrophoneVolume)
                SettingsDivider()
                SettingsOptionRow(title: "Microphone Mode", subtitle: "Voice transmission mode for in-game chat.", options: StreamPreferences.microphoneModeOptions.map(\.label), selectedIndex: selectedMicrophoneModeIndex, action: { viewModel.setMicrophoneMode(StreamPreferences.microphoneModeOptions[$0].value) })
                SettingsDivider()
                SettingsOptionRow(title: "Microphone Device", subtitle: "Audio input device for voice capture.", options: viewModel.microphoneDeviceOptions.map(\.label), selectedIndex: selectedMicrophoneDeviceIndex, action: { viewModel.setMicrophoneDeviceId(viewModel.microphoneDeviceOptions[$0].uniqueId) })
                SettingsDivider()
                SettingsToggleRow(
                    title: "Microphone Shortcut",
                    subtitle: "Hotkey (\(viewModel.streamProfile.microphonePushToTalkComboLabel)) for push-to-talk or mute toggle.",
                    isOn: viewModel.microphoneShortcutEnabled,
                    action: viewModel.setMicrophoneShortcutEnabled
                )
                SettingsDivider()
                SettingsToggleRow(
                    title: "Show Stream Mic Toggle",
                    subtitle: "On-screen HUD button to mute or unmute microphone.",
                    isOn: viewModel.showStreamMicToggle,
                    action: viewModel.setShowStreamMicToggle
                )
            }

            SettingsCard(title: "Display & System Power") {
                SettingsToggleRow(title: "Prevent Display Sleep", subtitle: "Keep displays awake during active stream sessions.", isOn: viewModel.streamProfile.preventDisplaySleepWhileStreaming, action: viewModel.setPreventDisplaySleepWhileStreaming)
            }

            SettingsCard(title: "Stream Recording & Capture") {
                SettingsSliderRow(title: "Video Bitrate", valueText: recordingVideoBitrateText, value: Double(viewModel.streamProfile.recordingVideoBitrateMbps), range: 0...200, step: 1, action: viewModel.setRecordingVideoBitrateMbps)
                SettingsDivider()
                SettingsSliderRow(title: "Audio Bitrate", valueText: "\(viewModel.streamProfile.recordingAudioBitrateKbps) Kbps", value: Double(viewModel.streamProfile.recordingAudioBitrateKbps), range: 64...320, step: 16, action: viewModel.setRecordingAudioBitrateKbps)
                SettingsDivider()
                SettingsToggleRow(title: "Record Enhanced Video", subtitle: "Capture post-upscaled video when MetalFX is active.", isOn: viewModel.streamProfile.recordingEnhancedVideoEnabled, action: viewModel.setRecordingEnhancedVideoEnabled)
            }

            if viewModel.remoteCoOpPreferences.isAlphaOptedIn {
                SettingsCard(title: "Remote Co-Op") {
                    SettingsToggleRow(title: "Enable Remote Co-Op", subtitle: "Generate invite links in the stream HUD for guests.", isOn: viewModel.remoteCoOpPreferences.isEnabled, action: viewModel.setRemoteCoOpEnabled)
                    SettingsDivider()
                    SettingsOptionRow(title: "Reserved Controllers", subtitle: "Pre-allocate gamepad slots for guest players.", options: ["None", "1 Guest", "2 Guests", "3 Guests"], selectedIndex: viewModel.remoteCoOpPreferences.reservedGuestSlots, action: viewModel.setRemoteCoOpReservedGuestSlots)
                    SettingsDivider()
                    SettingsOptionRow(title: "Transport", subtitle: viewModel.remoteCoOpPreferences.transportMode.description, options: RemoteCoOpTransportMode.allCases.map(\.label), selectedIndex: selectedRemoteCoOpTransportModeIndex, action: viewModel.setRemoteCoOpTransportModeIndex)
                    SettingsDivider()
                    SettingsOptionRow(title: "Guest Quality", subtitle: "Max outbound streaming bitrate sent to guests.", options: RemoteCoOpQualityPreset.allCases.map(\.label), selectedIndex: selectedRemoteCoOpQualityPresetIndex, action: viewModel.setRemoteCoOpQualityPresetIndex)
                    SettingsDivider()
                    SettingsOptionRow(title: "Latency Mode", subtitle: viewModel.remoteCoOpPreferences.latencyMode.description, options: RemoteCoOpLatencyMode.allCases.map(\.label), selectedIndex: selectedRemoteCoOpLatencyModeIndex, action: viewModel.setRemoteCoOpLatencyModeIndex)
                    SettingsDivider()
                    SettingsToggleRow(title: "Require Host Approval", subtitle: "Require host approval before accepting guest input.", isOn: viewModel.remoteCoOpPreferences.requireHostApproval, action: viewModel.setRemoteCoOpRequireHostApproval)
                    SettingsDivider()
                    SettingsToggleRow(title: "Hide Guest Invite Details", subtitle: "Omit game title and app ID from invite links.", isOn: viewModel.remoteCoOpPreferences.hideGuestInviteDetails, action: viewModel.setRemoteCoOpHideGuestInviteDetails)
                }
            }

            SettingsCard(title: "Profile Maintenance") {
                HStack(alignment: .center, spacing: 16) {
                    Rectangle()
                        .fill(Color.white.opacity(0.18))
                        .frame(width: 4, height: 48)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Restore default streaming settings")
                            .font(.settingsNvidia(size: 15, weight: .bold))
                            .foregroundStyle(.white)
                        Text("Restore all streaming, video, audio, and input settings to default.")
                            .font(.settingsNvidia(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.56))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    SettingsActionButton(title: "RESTORE DEFAULTS", minimumWidth: 150) { viewModel.restoreStreamingProfileDefaults() }
                }
                .padding(12)
                .background(SettingsVendorLayout.row)
                .overlay { Rectangle().stroke(Color.white.opacity(0.08), lineWidth: 1) }
            }
        }
    }

    private var selectedMicrophoneModeIndex: Int {
        StreamPreferences.microphoneModeOptions.firstIndex { $0.value == viewModel.streamProfile.microphoneMode } ?? 0
    }

    private var selectedMicrophoneDeviceIndex: Int {
        viewModel.microphoneDeviceOptions.firstIndex { $0.uniqueId == viewModel.streamProfile.microphoneDeviceId } ?? 0
    }

    private var selectedRemoteCoOpTransportModeIndex: Int {
        RemoteCoOpTransportMode.allCases.firstIndex(of: viewModel.remoteCoOpPreferences.transportMode) ?? 0
    }

    private var selectedRemoteCoOpQualityPresetIndex: Int {
        RemoteCoOpQualityPreset.allCases.firstIndex(of: viewModel.remoteCoOpPreferences.qualityPreset) ?? 0
    }

    private var selectedRemoteCoOpLatencyModeIndex: Int {
        RemoteCoOpLatencyMode.allCases.firstIndex(of: viewModel.remoteCoOpPreferences.latencyMode) ?? 0
    }

    private var lockedProfileSubtitle: String {
        "Managed by \(viewModel.streamProfile.streamingQualityProfileOption.label) profile. Set to Custom to edit."
    }

    private var recordingVideoBitrateText: String {
        viewModel.streamProfile.recordingVideoBitrateMbps == 0 ? "Auto" : "\(viewModel.streamProfile.recordingVideoBitrateMbps) Mbps"
    }

    private func percentText(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }
}

private struct ServerLocationSettingsPage: View {
    @ObservedObject var viewModel: CatalogViewModel
    private let regionColumns = [GridItem(.adaptive(minimum: 138, maximum: 220), spacing: 10)]

    var body: some View {
        let selectedOption = viewModel.settingsRegionOptions.first { $0.url == viewModel.selectedSettingsRegionUrl }
        SettingsCard(title: "Server Location") {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Cloudmatch Region")
                        .font(.settingsNvidia(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                    Text("Automatic keeps NVIDIA's capacity-aware route and runs a fresh network preflight before launch.")
                        .font(.settingsNvidia(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.58))
                }
                Spacer(minLength: 12)
                SettingsStatusPill(title: "ACTIVE", value: selectedRegionTitle(selectedOption), positive: true)
                SettingsActionButton(title: viewModel.isRefreshingSettingsRegions ? "PINGING" : "REFRESH", minimumWidth: 104) { viewModel.refreshSettingsRegions() }
                    .disabled(viewModel.isRefreshingSettingsRegions)
            }
            SettingsDivider()
            if !viewModel.unavailableSettingsRegionUrl.isEmpty {
                UnavailableRegionPrompt(regionUrl: viewModel.unavailableSettingsRegionUrl, keepAction: viewModel.keepUnavailableSettingsRegion, automaticAction: viewModel.switchUnavailableSettingsRegionToAutomatic)
                SettingsDivider()
            }
            LazyVGrid(columns: regionColumns, alignment: .leading, spacing: 10) {
                ForEach(viewModel.settingsRegionOptions, id: \.url) { option in
                    SettingsRegionRow(option: option, selected: option.url == viewModel.selectedSettingsRegionUrl) {
                        viewModel.selectSettingsRegion(option.url)
                    }
                }
            }
        }
    }

    private func selectedRegionTitle(_ option: StreamRegionOption?) -> String {
        guard let option else { return "Automatic" }
        return SettingsRegionName.shortName(for: option)
    }
}

private struct UnavailableRegionPrompt: View {
    let regionUrl: String
    let keepAction: () -> Void
    let automaticAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Selected Region Unavailable")
                        .font(.settingsNvidia(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                    Text("CloudMatch no longer advertises the selected route. Keep it for one more launch attempt, or switch to Automatic.")
                        .font(.settingsNvidia(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.62))
                    Text(regionUrl)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.42))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 12)
            }
            HStack(spacing: 10) {
                SettingsActionButton(title: "KEEP", tone: .secondary, minimumWidth: 82, action: keepAction)
                SettingsActionButton(title: "AUTOMATIC", minimumWidth: 112, action: automaticAction)
            }
        }
        .padding(14)
        .background(Color.orange.opacity(0.08))
        .overlay { Rectangle().stroke(Color.orange.opacity(0.22), lineWidth: 1) }
    }
}

private struct ResolutionUpscalingSettingsPage: View {
    @ObservedObject var viewModel: CatalogViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsCard(title: "MetalFX Upscaling") {
                SettingsToggleRow(
                    title: "MetalFX Upscaling",
                    subtitle: viewModel.isMetalFXHardwareSupported ? "Spatial upscaling for Apple Silicon with automatic fallback." : "MetalFX spatial scaling is unavailable on this hardware (requires Apple Silicon / macOS 13+).",
                    isOn: viewModel.streamProfile.upscalingMode == StreamPreferences.upscalingModeValueMetalFX
                ) { enabled in viewModel.setUpscalingModeIndex(enabled ? 1 : 0) }
                SettingsDivider()
                SettingsInfoRow(label: "Hardware Status", value: viewModel.isMetalFXHardwareSupported ? "Supported (Apple Silicon)" : "Unsupported")
                SettingsDivider()
                SettingsInfoRow(label: "Target", value: "Display Native")
                SettingsDivider()
                SettingsSliderRow(title: "Clarity", valueText: "\(viewModel.streamProfile.upscalingSharpness)", value: Double(viewModel.streamProfile.upscalingSharpness), range: 0...15, action: viewModel.setUpscalingSharpness)
                SettingsDivider()
                SettingsSliderRow(title: "Noise Reduction", valueText: "\(viewModel.streamProfile.upscalingDenoise)", value: Double(viewModel.streamProfile.upscalingDenoise), range: 0...20, action: viewModel.setUpscalingDenoise)
            }

            SettingsCard(title: "Image Enhancement") {
                SettingsOptionRow(title: "Prefilter Mode", subtitle: "Hardware prefiltering applied before frame presentation.", options: StreamPreferences.prefilterModeOptions.map(\.label), selectedIndex: viewModel.streamProfile.prefilterModeIndex, action: viewModel.setPrefilterModeIndex)
                SettingsDivider()
                SettingsSliderRow(title: "Prefilter Sharpness", valueText: "\(viewModel.streamProfile.prefilterSharpness)", value: Double(viewModel.streamProfile.prefilterSharpness), range: 0...10, action: viewModel.setPrefilterSharpness)
                SettingsDivider()
                SettingsSliderRow(title: "Prefilter Denoise", valueText: "\(viewModel.streamProfile.prefilterDenoise)", value: Double(viewModel.streamProfile.prefilterDenoise), range: 0...10, action: viewModel.setPrefilterDenoise)
            }
        }
    }
}

private struct SystemSettingsPage: View {
    @ObservedObject var viewModel: CatalogViewModel
    @State private var revealSensitive = false
    @State private var copiedKey = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsCard(title: "Readiness") {
                HStack(alignment: .top, spacing: 18) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(systemSummaryTitle)
                            .font(.settingsNvidia(size: 22, weight: .bold))
                            .foregroundStyle(.white)
                        Text(systemSummaryDetail)
                            .font(.settingsNvidia(size: 13, weight: .medium))
                            .foregroundStyle(.white.opacity(0.62))
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 8) {
                            AboutStatusPill(title: "Display", value: displaySummary)
                            AboutStatusPill(title: "Decode", value: preferredDecoder)
                            AboutStatusPill(title: "MetalFX", value: viewModel.isMetalFXHardwareSupported ? "Supported" : "Unavailable")
                            AboutStatusPill(title: "Route", value: route.summary)
                        }
                    }
                    Spacer(minLength: 0)
                    SystemHealthBadge(title: systemHealthTitle, subtitle: systemHealthSubtitle, positive: systemHealthPositive)
                }
            }

            SettingsCard(title: "Display") {
                SettingsFlowLayout(spacing: 10) {
                    SettingsStatisticTile(label: "Resolution", value: displaySummary, emphasized: true)
                    SettingsStatisticTile(label: "Refresh", value: refreshRateText)
                    SettingsStatisticTile(label: "DPI", value: dpiText)
                    SettingsStatisticTile(label: "HDR", value: effectiveCapabilities.hdrDisplaySupported ? "Ready" : "Unavailable")
                }
            }

            SettingsCard(title: "Video Decode") {
                VStack(spacing: 10) {
                    SystemCapabilityRow(title: "H.264", subtitle: "Baseline stream compatibility", value: effectiveCapabilities.h264HardwareDecodeSupported ? "Hardware" : "Software", positive: effectiveCapabilities.h264HardwareDecodeSupported)
                    SystemCapabilityRow(title: "HEVC", subtitle: "Efficient high-quality streaming", value: effectiveCapabilities.h265HardwareDecodeSupported ? "Supported" : "Unavailable", positive: effectiveCapabilities.h265HardwareDecodeSupported)
                    SystemCapabilityRow(title: "AV1", subtitle: "Next-generation low-bitrate streaming", value: effectiveCapabilities.av1HardwareDecodeSupported ? "Supported" : "Unavailable", positive: effectiveCapabilities.av1HardwareDecodeSupported)
                }
            }

            SettingsCard(title: "Device & Route") {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Identifiers and endpoint paths are masked by default.")
                            .font(.settingsNvidia(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                        Text("Reveal only when collecting support information locally.")
                            .font(.settingsNvidia(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.56))
                    }
                    Spacer()
                    SettingsRevealButton(revealed: revealSensitive) { revealSensitive.toggle() }
                }
                SettingsDivider()
                AboutDetailRow(label: "Device ID", value: displayedDeviceId, copyValue: viewModel.session.deviceId, copiedKey: $copiedKey, copyDisabled: viewModel.session.deviceId.isEmpty)
                SettingsDivider()
                AboutDetailRow(label: "Current Region", value: route.displayValue, copyValue: route.copyValue, copiedKey: $copiedKey)
            }
        }
        .onAppear {
            viewModel.refreshSystemCapabilities()
        }
    }

    private var effectiveCapabilities: StreamDeviceCapabilities {
        if viewModel.streamCapabilities.maxDisplayWidth > 0 {
            return viewModel.streamCapabilities
        }
        let live = StreamPreferences.loadDeviceCapabilities()
        if live.maxDisplayWidth > 0 {
            return live
        }
        return viewModel.streamCapabilities
    }

    private var displaySummary: String {
        let caps = effectiveCapabilities
        guard caps.maxDisplayWidth > 0, caps.maxDisplayHeight > 0 else { return "Unknown" }
        return "\(caps.maxDisplayWidth) x \(caps.maxDisplayHeight)"
    }

    private var refreshRateText: String {
        let caps = effectiveCapabilities
        return caps.maxDisplayRefreshRate > 0 ? "\(caps.maxDisplayRefreshRate) Hz" : "Unknown"
    }

    private var dpiText: String {
        let caps = effectiveCapabilities
        return caps.displayDpi > 0 ? "\(caps.displayDpi)" : "Unknown"
    }

    private var preferredDecoder: String {
        let caps = effectiveCapabilities
        if caps.av1HardwareDecodeSupported { return "AV1" }
        if caps.h265HardwareDecodeSupported { return "HEVC" }
        if caps.h264HardwareDecodeSupported { return "H.264" }
        return "Software"
    }

    private var hardwareDecodeCount: Int {
        let caps = effectiveCapabilities
        return [caps.h264HardwareDecodeSupported, caps.h265HardwareDecodeSupported, caps.av1HardwareDecodeSupported].filter { $0 }.count
    }

    private var systemHealthPositive: Bool {
        effectiveCapabilities.h264HardwareDecodeSupported && displaySummary != "Unknown"
    }

    private var systemHealthTitle: String {
        systemHealthPositive ? "READY" : "LIMITED"
    }

    private var systemHealthSubtitle: String {
        systemHealthPositive ? "Hardware path available" : "Review decoder support"
    }

    private var systemSummaryTitle: String {
        systemHealthPositive ? "Streaming hardware looks ready" : "Streaming support is partially available"
    }

    private var systemSummaryDetail: String {
        "Detected \(displaySummary) at \(refreshRateText), \(hardwareDecodeCount) hardware decoder\(hardwareDecodeCount == 1 ? "" : "s"), and \(effectiveCapabilities.hdrDisplaySupported ? "HDR-capable" : "SDR") presentation."
    }

    private var route: SettingsRouteSnapshot {
        SettingsRouteSnapshot(regionUrl: viewModel.selectedSettingsRegionUrl, revealSensitive: revealSensitive)
    }

    private var displayedDeviceId: String {
        revealSensitive ? viewModel.session.deviceId : SettingsFormat.maskedIdentifier(viewModel.session.deviceId)
    }
}

private struct SystemHealthBadge: View {
    let title: String
    let subtitle: String
    let positive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.settingsNvidia(size: 12, weight: .bold))
                .foregroundStyle(positive ? .black : .white.opacity(0.88))
                .tracking(1.1)
            Text(subtitle)
                .font(.settingsNvidia(size: 11, weight: .bold))
                .foregroundStyle(positive ? .black.opacity(0.74) : .white.opacity(0.54))
                .lineLimit(2)
        }
        .padding(.horizontal, 14)
        .frame(width: 172, height: 64, alignment: .leading)
        .background(positive ? Color.pixelNowGreen : Color.white.opacity(0.07))
        .overlay { Rectangle().stroke(positive ? Color.pixelNowGreen : Color.white.opacity(0.13), lineWidth: 1) }
    }
}

private struct SystemCapabilityRow: View {
    let title: String
    let subtitle: String
    let value: String
    let positive: Bool

    var body: some View {
        HStack(spacing: 12) {
            Rectangle()
                .fill(positive ? Color.pixelNowGreen : Color.white.opacity(0.22))
                .frame(width: 4, height: 42)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.settingsNvidia(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.settingsNvidia(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.56))
            }
            Spacer(minLength: 0)
            Text(value.uppercased())
                .font(.settingsNvidia(size: 11, weight: .bold))
                .foregroundStyle(positive ? Color.pixelNowGreen : .white.opacity(0.56))
                .tracking(0.8)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(Color.white.opacity(positive ? 0.07 : 0.04))
                .overlay { Rectangle().stroke(positive ? Color.pixelNowGreen.opacity(0.38) : Color.white.opacity(0.08), lineWidth: 1) }
        }
        .padding(12)
        .background(Color.white.opacity(0.045))
        .overlay { Rectangle().stroke(Color.white.opacity(0.08), lineWidth: 1) }
    }
}

private struct AboutSettingsPage: View {
    @ObservedObject var viewModel: CatalogViewModel
    @State private var copiedKey = ""
    @State private var diagnosticsState = AboutDiagnosticsState.ready
    @State private var showingDiagnosticsUploadConfirmation = false
    @AppStorage(UpdatePreferences.automaticUpdateChecksEnabledKey) private var automaticUpdateChecksEnabled = UpdatePreferences.defaultAutomaticUpdateChecksEnabled
    @State private var telemetryDisabled = Sentry.isTelemetryDisabled()

    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 16) {
            SettingsCard(title: "Product") {
                HStack(alignment: .top, spacing: 22) {
                    ZStack {
                        Rectangle()
                            .fill(Color.black.opacity(0.22))
                            .overlay { Rectangle().stroke(Color.pixelNowGreen.opacity(0.72), lineWidth: 1) }
                        VendorResourceImage(name: "nv-gfn-logo_v3", fileExtension: "png")
                            .scaledToFit()
                            .padding(.horizontal, 14)
                    }
                    .frame(width: 180, height: 88)

                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(SettingsAppMetadata.displayName)
                                .font(.settingsNvidia(size: 25, weight: .bold))
                                .foregroundStyle(.white)
                            Text("UNOFFICIAL CLIENT SHELL")
                                .font(.settingsNvidia(size: 10, weight: .bold))
                                .foregroundStyle(.black)
                                .tracking(0.8)
                                .padding(.horizontal, 8)
                                .frame(height: 20)
                                .background(Color.pixelNowGreen)
                        }
                        Text("A macOS runtime for launching and streaming PixelNOW sessions with local catalog, account, and diagnostics surfaces.")
                            .font(.settingsNvidia(size: 13, weight: .medium))
                            .foregroundStyle(.white.opacity(0.66))
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 8) {
                            AboutStatusPill(title: "Stream", value: "WebRTC")
                            AboutStatusPill(title: "Route", value: route.summary)
                            AboutStatusPill(title: "Telemetry", value: telemetryDisabled ? "Off" : "On")
                        }
                    }
                    Spacer(minLength: 0)
                }
            }

            SettingsCard(title: "Runtime") {
                AboutDetailRow(label: "Version", value: SettingsAppMetadata.version, copyValue: SettingsAppMetadata.version, copiedKey: $copiedKey)
                SettingsDivider()
                AboutDetailRow(label: "Build", value: SettingsAppMetadata.build, copyValue: SettingsAppMetadata.build, copiedKey: $copiedKey)
                SettingsDivider()
                AboutDetailRow(label: "Bundle", value: bundleIdentifier, copyValue: bundleIdentifier, copiedKey: $copiedKey)
                SettingsDivider()
                AboutDetailRow(label: "macOS", value: operatingSystemVersion, copyValue: operatingSystemVersion, copiedKey: $copiedKey)
                SettingsDivider()
                SettingsToggleRow(title: "Automatic Update Checks", subtitle: automaticUpdateChecksSubtitle, isOn: automaticUpdateChecksEnabled) { enabled in
                    AppDelegate.setAutomaticApplicationUpdateChecksEnabled(enabled)
                }
                SettingsDivider()
                HStack(spacing: 10) {
                    SettingsActionButton(title: "CHECK FOR UPDATES") {
                        AppDelegate.requestApplicationUpdateCheck()
                    }
                    Text("Check GitHub releases for newer signed builds.")
                        .font(.settingsNvidia(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.54))
                }
            }

            SettingsCard(title: "Cache") {
                AboutDetailRow(label: "Catalog Images", value: viewModel.catalogImageCacheSummary, copyValue: viewModel.catalogImageCacheSummary, copiedKey: $copiedKey)
                SettingsDivider()
                HStack(spacing: 10) {
                    SettingsActionButton(title: "CLEAR IMAGE CACHE") {
                        viewModel.clearCatalogImageCache()
                    }
                    Text("Purge cached artwork from disk and memory.")
                        .font(.settingsNvidia(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.54))
                }
            }

            SettingsCard(title: "Privacy") {
                SettingsToggleRow(title: "Disable Telemetry", subtitle: "Disable crash reporting, telemetry metrics, and diagnostic logging.", isOn: telemetryDisabled, action: setTelemetryDisabled)
            }

            SettingsCard(title: "Support Diagnostics") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        SettingsActionButton(title: diagnosticsButtonTitle) {
                            showingDiagnosticsUploadConfirmation = true
                        }
                        .disabled(diagnosticsState.isWorking)
                        Text("Upload sanitized runtime logs and copy diagnostics link to clipboard.")
                            .font(.settingsNvidia(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.54))
                    }
                    Text(diagnosticsState.message)
                        .font(.settingsNvidia(size: 12, weight: .medium))
                        .foregroundStyle(diagnosticsState.isError ? Color(red: 1, green: 0.54, blue: 0.50) : .white.opacity(0.62))
                }
            }
        }
            .disabled(showingDiagnosticsUploadConfirmation)

            if showingDiagnosticsUploadConfirmation {
                DiagnosticsUploadConfirmationDialog(
                    cancel: { showingDiagnosticsUploadConfirmation = false },
                    upload: {
                        showingDiagnosticsUploadConfirmation = false
                        generateUploadedDiagnostics()
                    }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                .zIndex(1)
            }
        }
        .animation(.easeOut(duration: 0.16), value: showingDiagnosticsUploadConfirmation)
        .onAppear {
            viewModel.refreshCatalogImageCacheSummary()
            telemetryDisabled = Sentry.isTelemetryDisabled()
        }
    }

    private var account: SettingsAccountSnapshot {
        SettingsAccountSnapshot(viewModel: viewModel)
    }

    private var route: SettingsRouteSnapshot {
        SettingsRouteSnapshot(regionUrl: viewModel.selectedSettingsRegionUrl, revealSensitive: false)
    }

    private var bundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? "Unknown"
    }

    private var operatingSystemVersion: String {
        ProcessInfo.processInfo.operatingSystemVersionString
    }

    private var automaticUpdateChecksSubtitle: String {
        if UpdatePreferences.updateChecksAreSuspendedForDebugging {
            return "Paused during debugging. Manual checks remain available."
        }
        if automaticUpdateChecksEnabled {
            return "Automatically check for new releases on launch and hourly."
        }
        return "Manual checks only. Releases will not be checked automatically."
    }

    private var diagnosticsText: String {
        diagnosticsText(logURL: nil, uploadError: "", inlineLog: "")
    }

    private func diagnosticsText(logURL: URL?, uploadError: String, inlineLog: String) -> String {
        var lines = [
            "PixelNOW Mac Diagnostics",
            "Version: \(SettingsAppMetadata.versionWithBuild)",
            "Bundle: \(bundleIdentifier)",
            "macOS: \(operatingSystemVersion)",
            "Account: \(account.displayName)",
            "Membership: \(account.membershipTier)",
            "User ID: \(SettingsFormat.maskedIdentifier(account.userId))",
            "Streaming: WebRTC",
            "Cloudmatch: \(route.summary)",
            "Logs: \(logURL?.absoluteString ?? "Not uploaded")"
        ]
        if !uploadError.isEmpty {
            lines.append("Upload Error: \(uploadError)")
        }
        if !inlineLog.isEmpty {
            lines.append(contentsOf: ["", "--- Gathered Diagnostics Logs ---", inlineLog])
        }
        return lines.joined(separator: "\n")
    }

    private var diagnosticsButtonTitle: String {
        switch diagnosticsState {
        case .ready, .failed: return "GENERATE DIAGNOSTICS"
        case .preparing, .readingLog, .uploading, .copying: return "WORKING"
        case .copied: return "COPIED"
        }
    }

    private func setTelemetryDisabled(_ disabled: Bool) {
        telemetryDisabled = disabled
        Sentry.setTelemetryDisabled(disabled)
    }

    private func generateUploadedDiagnostics() {
        guard !diagnosticsState.isWorking else { return }
        Task { @MainActor in
            diagnosticsState = .preparing
            Sentry.logInfoMessage(Sentry.formattedLogMessage(level: "info", area: "Diagnostics", message: "Preparing user-requested diagnostics upload"))
            diagnosticsState = .readingLog
            let logText = Sentry.diagnosticsLogForUpload()
            diagnosticsState = .uploading
            do {
                let logURL = try await Sentry.uploadDiagnosticsLog(logText)
                diagnosticsState = .copying
                copy(diagnosticsText(logURL: logURL, uploadError: "", inlineLog: logText), key: "diagnostics")
                diagnosticsState = .copied(logURL.absoluteString)
                Sentry.logInfoMessage(Sentry.formattedLogMessage(level: "info", area: "Diagnostics", message: "Uploaded sanitized diagnostics log url=\(logURL.absoluteString)"))
            } catch {
                let message = error.localizedDescription.isEmpty ? String(describing: error) : error.localizedDescription
                diagnosticsState = .copying
                copy(diagnosticsText(logURL: nil, uploadError: message, inlineLog: logText), key: "diagnostics")
                diagnosticsState = .failed(message)
                Sentry.logErrorMessage(Sentry.formattedLogMessage(level: "error", area: "Diagnostics", message: "Diagnostics upload failed; copied local diagnostics with inline logs error=\(message)"))
            }
        }
    }

    private func copy(_ value: String, key: String) {
        guard !value.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
        copiedKey = key
    }

}

private struct DiagnosticsUploadConfirmationDialog: View {
    let cancel: () -> Void
    let upload: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.62)
                .onTapGesture(perform: cancel)

            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 14) {
                    ZStack {
                        Rectangle()
                            .fill(Color.pixelNowGreen.opacity(0.16))
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.settingsNvidia(size: 18, weight: .bold))
                            .foregroundStyle(Color.pixelNowGreen)
                    }
                    .frame(width: 44, height: 44)
                    .overlay { Rectangle().stroke(Color.pixelNowGreen.opacity(0.42), lineWidth: 1) }

                    VStack(alignment: .leading, spacing: 7) {
                        Text("Upload diagnostics logs?")
                            .font(.settingsNvidia(size: 19, weight: .bold))
                            .foregroundStyle(.white)
                        Text("PixelNOW will upload the recent sanitized current-run log to paste.c-net.org and copy a diagnostics summary with the public link.")
                            .font(.settingsNvidia(size: 13, weight: .medium))
                            .foregroundStyle(.white.opacity(0.72))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                HStack(alignment: .top, spacing: 10) {
                    Rectangle()
                        .fill(Color.pixelNowGreen)
                        .frame(width: 4, height: 42)
                    Text("IP addresses and location fields are redacted before upload. Only generate this when preparing support diagnostics.")
                        .font(.settingsNvidia(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.62))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .background(Color.white.opacity(0.045))
                .overlay { Rectangle().stroke(Color.white.opacity(0.08), lineWidth: 1) }

                HStack(spacing: 10) {
                    Spacer(minLength: 0)
                    SettingsDialogButton(title: "CANCEL", tone: .secondary, action: cancel)
                    SettingsDialogButton(title: "UPLOAD LOGS", tone: .primary, action: upload)
                }
            }
            .padding(22)
            .frame(width: 430, alignment: .leading)
            .background(Color(red: 24 / 255, green: 24 / 255, blue: 24 / 255))
            .overlay { Rectangle().stroke(Color.white.opacity(0.16), lineWidth: 1) }
            .shadow(color: .black.opacity(0.62), radius: 34, x: 0, y: 18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct SettingsDialogButton: View {
    enum Tone {
        case primary
        case secondary
    }

    let title: String
    let tone: Tone
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.settingsNvidia(size: 12, weight: .bold))
                .foregroundStyle(tone == .primary ? .black : .white.opacity(0.82))
                .tracking(0.8)
                .padding(.horizontal, 14)
                .frame(minWidth: 104)
                .frame(height: 34)
                .background(backgroundColor)
                .overlay { Rectangle().stroke(strokeColor, lineWidth: 1) }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }

    private var backgroundColor: Color {
        switch tone {
        case .primary: return Color.pixelNowGreen.opacity(isHovering ? 0.88 : 1)
        case .secondary: return Color.white.opacity(isHovering ? 0.10 : 0.06)
        }
    }

    private var strokeColor: Color {
        switch tone {
        case .primary: return Color.pixelNowGreen
        case .secondary: return Color.white.opacity(0.14)
        }
    }
}

private enum AboutDiagnosticsState: Equatable {
    case ready
    case preparing
    case readingLog
    case uploading
    case copying
    case copied(String)
    case failed(String)

    var message: String {
        switch self {
        case .ready: return "Ready to generate diagnostics. Confirmation is required before logs are uploaded."
        case .preparing: return "Preparing diagnostics metadata..."
        case .readingLog: return "Reading sanitized current-run log..."
        case .uploading: return "Uploading sanitized logs to paste.c-net.org..."
        case .copying: return "Copying diagnostics to clipboard..."
        case .copied(let url): return "Diagnostics and logs copied to clipboard. Uploaded link: \(url)"
        case .failed(let reason): return "Upload failed, but local diagnostics and inline logs were copied: \(reason)"
        }
    }

    var isWorking: Bool {
        switch self {
        case .preparing, .readingLog, .uploading, .copying: return true
        case .ready, .copied, .failed: return false
        }
    }

    var isError: Bool {
        if case .failed = self { return true }
        return false
    }
}

private struct AboutStatusPill: View {
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 6) {
            Text(title.uppercased())
                .font(.settingsNvidia(size: 9, weight: .bold))
                .foregroundStyle(.white.opacity(0.44))
                .tracking(0.8)
            Text(value.isEmpty ? "Unknown" : value)
                .font(.settingsNvidia(size: 11, weight: .bold))
                .foregroundStyle(.white.opacity(0.86))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(Color.white.opacity(0.065))
        .overlay { Rectangle().stroke(Color.white.opacity(0.12), lineWidth: 1) }
    }
}

private struct AboutDetailRow: View {
    let label: String
    let value: String
    let copyValue: String
    @Binding var copiedKey: String
    var copyDisabled = false

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            Text(label.uppercased())
                .font(.settingsNvidia(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(0.44))
                .tracking(0.5)
                .frame(width: 150, alignment: .leading)
            Text(value.isEmpty ? "Unavailable" : value)
                .font(.settingsNvidia(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.84))
                .lineLimit(2)
                .textSelection(.enabled)
            Spacer(minLength: 0)
            Button { copy(copyValue) } label: {
                Text(copiedKey == label ? "COPIED" : "COPY")
                    .font(.settingsNvidia(size: 10, weight: .bold))
                    .foregroundStyle(copyDisabled ? .white.opacity(0.28) : .white.opacity(0.74))
                    .tracking(0.7)
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background(Color.white.opacity(copyDisabled ? 0.03 : 0.06))
                    .overlay { Rectangle().stroke(Color.white.opacity(copyDisabled ? 0.05 : 0.12), lineWidth: 1) }
            }
            .buttonStyle(.plain)
            .disabled(copyDisabled)
        }
    }

    private func copy(_ value: String) {
        guard !value.isEmpty, !copyDisabled else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
        copiedKey = label
    }
}

private struct SettingsCard<Content: View>: View {
    let title: String
    private let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Rectangle()
                    .fill(Color.pixelNowGreen)
                    .frame(width: 4, height: 18)
                Text(title.uppercased())
                    .font(.settingsNvidia(size: 12, weight: .bold))
                    .foregroundStyle(.white.opacity(0.68))
                    .tracking(1.1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18)
            .padding(.top, 17)
            .padding(.bottom, 12)
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ZStack(alignment: .topLeading) {
                SettingsVendorLayout.card
                LinearGradient(colors: [Color.white.opacity(0.035), .clear], startPoint: .top, endPoint: .center)
                Rectangle()
                    .fill(Color.pixelNowGreen.opacity(0.10))
                    .frame(width: 1)
            }
        )
        .overlay { Rectangle().stroke(Color.white.opacity(0.115), lineWidth: 1) }
        .shadow(color: .black.opacity(0.26), radius: 16, y: 8)
    }
}

private struct SettingsDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.08))
            .frame(height: 1)
            .padding(.vertical, 14)
    }
}

private struct SettingsInfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(label.uppercased())
                .font(.settingsNvidia(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(0.44))
                .frame(width: 150, alignment: .leading)
            Text(value.isEmpty ? "-" : value)
                .font(.settingsNvidia(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.82))
                .lineLimit(2)
            Spacer(minLength: 0)
        }
    }
}

private struct SettingsOptionRow: View {
    let title: String
    let subtitle: String
    let options: [String]
    let selectedIndex: Int
    var enabled: [Bool] = []
    var isLocked = false
    let action: (Int) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.settingsNvidia(size: 15, weight: .bold))
                    .foregroundStyle(.white.opacity(isLocked ? 0.58 : 1))
                Text(subtitle)
                    .font(.settingsNvidia(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(isLocked ? 0.38 : 0.58))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 250, alignment: .leading)
            SettingsFlowLayout(spacing: 8) {
                ForEach(options.indices, id: \.self) { index in
                    let optionEnabled = !isLocked && (enabled.indices.contains(index) ? enabled[index] : true)
                    Button { action(index) } label: {
                        Text(options[index])
                            .font(.settingsNvidia(size: 12, weight: .bold))
                            .foregroundStyle(index == selectedIndex && !isLocked ? .black : .white.opacity(optionEnabled ? 0.82 : 0.34))
                            .padding(.horizontal, 12)
                            .frame(height: 32)
                            .background(index == selectedIndex ? Color.pixelNowGreen.opacity(isLocked ? 0.32 : 1) : Color.white.opacity(optionEnabled ? 0.07 : 0.035))
                            .overlay { Rectangle().stroke(index == selectedIndex ? Color.pixelNowGreen.opacity(isLocked ? 0.42 : 1) : Color.white.opacity(0.12), lineWidth: 1) }
                    }
                    .buttonStyle(.plain)
                    .disabled(!optionEnabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct SettingsToggleRow: View {
    let title: String
    let subtitle: String
    let isOn: Bool
    var isLocked = false
    let action: @MainActor @Sendable (Bool) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.settingsNvidia(size: 15, weight: .bold))
                    .foregroundStyle(.white.opacity(isLocked ? 0.58 : 1))
                Text(subtitle)
                    .font(.settingsNvidia(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(isLocked ? 0.38 : 0.58))
            }
            Spacer()
            Toggle("", isOn: Binding(get: { isOn }, set: { newValue in action(newValue) }))
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(isLocked)
                .opacity(isLocked ? 0.45 : 1)
        }
    }
}

private struct SettingsTextFieldRow: View {
    let title: String
    let subtitle: String
    let text: String
    let placeholder: String
    let action: (String) -> Void
    @State private var draft = ""

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.settingsNvidia(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.settingsNvidia(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.58))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 250, alignment: .leading)
            TextField(placeholder, text: Binding(get: { draft }, set: { newValue in updateDraft(newValue) }))
                .textFieldStyle(.plain)
                .font(.settingsNvidia(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 12)
                .frame(height: 36)
                .background(Color.white.opacity(0.07))
                .overlay { Rectangle().stroke(Color.white.opacity(0.14), lineWidth: 1) }
                .onAppear { draft = text }
                .onChange(of: text) { _, value in
                    guard value != draft else { return }
                    draft = value
                }
        }
    }

    private func updateDraft(_ value: String) {
        draft = value
        action(value)
    }
}

private struct SettingsSecureTextFieldRow: View {
    let title: String
    let subtitle: String
    @Binding var text: String
    let placeholder: String

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.settingsNvidia(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.settingsNvidia(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.58))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 250, alignment: .leading)
            SecureField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.settingsNvidia(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 12)
                .frame(height: 36)
                .background(Color.white.opacity(0.07))
                .overlay { Rectangle().stroke(Color.white.opacity(0.14), lineWidth: 1) }
        }
    }
}

private struct SettingsSliderRow: View {
    let title: String
    let valueText: String
    let value: Double
    let range: ClosedRange<Double>
    var step = 1.0
    var isLocked = false
    let action: @MainActor @Sendable (Double) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.settingsNvidia(size: 15, weight: .bold))
                    .foregroundStyle(.white.opacity(isLocked ? 0.58 : 1))
                Text(valueText)
                    .font(.settingsNvidia(size: 12, weight: .bold))
                    .foregroundStyle(Color.pixelNowGreen.opacity(isLocked ? 0.48 : 1))
            }
            .frame(width: 250, alignment: .leading)
            Slider(value: Binding(get: { value }, set: { newValue in action(newValue) }), in: range, step: step)
                .tint(Color.pixelNowGreen)
                .disabled(isLocked)
                .opacity(isLocked ? 0.45 : 1)
        }
    }
}

private struct SettingsActionButton: View {
    enum Tone {
        case primary
        case secondary
    }

    let title: String
    var tone: Tone = .primary
    var minimumWidth: CGFloat = 0
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.settingsNvidia(size: 12, weight: .bold))
                .foregroundStyle(foregroundColor)
                .tracking(0.8)
                .padding(.horizontal, 14)
                .frame(minWidth: minimumWidth)
                .frame(height: 32)
                .background(backgroundColor)
                .overlay { Rectangle().stroke(strokeColor, lineWidth: 1) }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }

    private var backgroundColor: Color {
        guard isEnabled else { return Color.white.opacity(0.045) }
        switch tone {
        case .primary: return Color.pixelNowGreen.opacity(isHovering ? 0.88 : 1)
        case .secondary: return Color.pixelNowGreen.opacity(isHovering ? 0.22 : 0.14)
        }
    }

    private var foregroundColor: Color {
        guard isEnabled else { return .white.opacity(0.32) }
        switch tone {
        case .primary: return .black
        case .secondary: return Color.pixelNowGreen
        }
    }

    private var strokeColor: Color {
        guard isEnabled else { return Color.white.opacity(0.08) }
        return tone == .primary ? Color.pixelNowGreen : Color.pixelNowGreen.opacity(0.34)
    }
}

private struct SettingsStatusPill: View {
    let title: String
    let value: String
    let positive: Bool

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            Text(title.uppercased())
                .font(.settingsNvidia(size: 9, weight: .bold))
                .foregroundStyle(.white.opacity(0.42))
                .tracking(0.8)
            Text(value.isEmpty ? "-" : value)
                .font(.settingsNvidia(size: 12, weight: .bold))
                .foregroundStyle(positive ? Color.pixelNowGreen : .white.opacity(0.66))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .padding(.horizontal, 10)
        .frame(minWidth: 94, alignment: .trailing)
        .frame(height: 40)
        .background(Color.white.opacity(positive ? 0.055 : 0.035))
        .overlay { Rectangle().stroke(positive ? Color.pixelNowGreen.opacity(0.24) : Color.white.opacity(0.08), lineWidth: 1) }
    }
}

private struct SettingsRegionRow: View {
    let option: StreamRegionOption
    let selected: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    Text(SettingsRegionName.shortName(for: option))
                        .font(.settingsNvidia(size: 13, weight: .bold))
                        .foregroundStyle(selected ? .white : .white.opacity(0.90))
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                    Spacer(minLength: 6)
                    Circle()
                        .fill(selected ? Color.pixelNowGreen : Color.white.opacity(isHovering ? 0.34 : 0.22))
                        .frame(width: 8, height: 8)
                        .padding(.top, 4)
                }
                RegionLatencyBadge(latencyMs: option.latencyMs, selected: selected)
            }
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .background(selected ? Color.pixelNowGreen.opacity(0.13) : Color.white.opacity(isHovering ? 0.065 : 0.045))
            .overlay { Rectangle().stroke(selected ? Color.pixelNowGreen.opacity(0.74) : Color.white.opacity(isHovering ? 0.16 : 0.08), lineWidth: 1) }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

private enum SettingsRegionName {
    static func shortName(for option: StreamRegionOption) -> String {
        guard !option.automatic else { return "Auto" }
        let withoutParenthetical = option.name.replacingOccurrences(of: #"\s*\([^)]*\)"#, with: "", options: .regularExpression)
        let withoutPrefixes = withoutParenthetical
            .replacingOccurrences(of: "GeForce NOW", with: "")
            .replacingOccurrences(of: "NVIDIA", with: "")
            .replacingOccurrences(of: "Cloudmatch", with: "")
        let cleaned = withoutPrefixes.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? option.name : cleaned
    }
}

private struct RegionLatencyBadge: View {
    let latencyMs: Int
    let selected: Bool

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(indicatorColor)
                .frame(width: 6, height: 6)
            Text(latencyText)
                .font(.settingsNvidia(size: 11, weight: .bold))
                .foregroundStyle(selected ? Color.pixelNowGreen : .white.opacity(0.74))
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(selected ? Color.black.opacity(0.20) : Color.white.opacity(0.045))
        .overlay { Rectangle().stroke(selected ? Color.pixelNowGreen.opacity(0.30) : Color.white.opacity(0.08), lineWidth: 1) }
    }

    private var latencyText: String {
        latencyMs >= 0 ? "\(latencyMs) ms" : "Measuring"
    }

    private var indicatorColor: Color {
        guard latencyMs >= 0 else { return .white.opacity(0.36) }
        if latencyMs <= 40 { return Color.pixelNowGreen }
        if latencyMs <= 65 { return Color(red: 1.0, green: 0.77, blue: 0.24) }
        return Color(red: 1.0, green: 0.32, blue: 0.26)
    }
}

private struct SettingsMessageView: View {
    let message: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(Color.pixelNowGreen)
            Text(message)
                .font(.settingsNvidia(size: 12, weight: .bold))
                .foregroundStyle(.white.opacity(0.78))
            Spacer()
        }
        .padding(12)
        .background(Color.white.opacity(0.07))
        .overlay { Rectangle().stroke(Color.white.opacity(0.10), lineWidth: 1) }
    }
}

private struct SettingsFlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        var size = CGSize(width: width, height: 0)
        var lineWidth: CGFloat = 0
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let subviewSize = subview.sizeThatFits(.unspecified)
            if lineWidth + subviewSize.width > width, lineWidth > 0 {
                size.height += lineHeight + spacing
                lineWidth = 0
                lineHeight = 0
            }
            lineWidth += subviewSize.width + spacing
            lineHeight = max(lineHeight, subviewSize.height)
        }
        size.height += lineHeight
        return size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let subviewSize = subview.sizeThatFits(.unspecified)
            if x + subviewSize.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(subviewSize))
            x += subviewSize.width + spacing
            lineHeight = max(lineHeight, subviewSize.height)
        }
    }
}

private struct SettingsPlaceholderPage: View {
    let title: String
    var body: some View {
        VStack {
            Spacer()
            Text(title)
                .font(.settingsNvidia(size: 24, weight: .bold))
                .foregroundStyle(SettingsVendorLayout.textSecondary)
            Text("This section is under construction.")
                .font(.settingsNvidia(size: 14))
                .foregroundStyle(SettingsVendorLayout.textTertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Focused Tab Pages

private struct VideoSettingsPage: View {
    @ObservedObject var viewModel: CatalogViewModel

    var body: some View {
        let qualityLocked = !viewModel.streamingQualityProfileAllowsCustomization
        let lockedSubtitle = "Managed by \(viewModel.streamProfile.streamingQualityProfileOption.label) profile. Set to Custom to edit."
        VStack(alignment: .leading, spacing: 16) {
            SettingsCard(title: "Quality Profile") {
                SettingsOptionRow(
                    title: "Quality Profile",
                    subtitle: "Preconfigured streaming balance for bandwidth and latency.",
                    options: StreamPreferences.streamingQualityProfileOptions.map(\.label),
                    selectedIndex: viewModel.streamProfile.streamingQualityProfileIndex,
                    action: viewModel.setStreamingQualityProfileIndex
                )
                SettingsDivider()
                SettingsToggleRow(title: "Cloud G-Sync", subtitle: qualityLocked ? lockedSubtitle : "Sync render rate with display refresh to eliminate tearing.", isOn: viewModel.streamProfile.enableCloudGsync, isLocked: qualityLocked, action: viewModel.setCloudGsyncEnabled)
                SettingsDivider()
                SettingsToggleRow(title: "L4S Congestion Control", subtitle: qualityLocked ? lockedSubtitle : "Reduce queuing delay and packet jitter on supported networks.", isOn: viewModel.streamProfile.enableL4S, isLocked: qualityLocked, action: viewModel.setL4SEnabled)
            }

            SettingsCard(title: "Display & Video") {
                SettingsOptionRow(title: "Aspect Ratio", subtitle: qualityLocked ? lockedSubtitle : "Aspect ratio for available stream resolutions.", options: StreamPreferences.aspectOptions.map(\.label), selectedIndex: viewModel.streamProfile.aspectIndex, isLocked: qualityLocked, action: viewModel.setAspectIndex)
                SettingsDivider()
                SettingsOptionRow(title: "Resolution", subtitle: qualityLocked ? lockedSubtitle : "Target stream resolution.", options: StreamPreferences.resolutionOptions(forAspect: viewModel.streamProfile.aspectIndex).map(\.label), selectedIndex: viewModel.streamProfile.resolutionIndex, isLocked: qualityLocked, action: viewModel.setResolutionIndex)
                SettingsDivider()
                SettingsOptionRow(title: "Frame Rate", subtitle: qualityLocked ? lockedSubtitle : "Target stream FPS, capped by display refresh.", options: StreamPreferences.fpsOptions.map { "\($0) FPS" }, selectedIndex: viewModel.streamProfile.fpsIndex, enabled: StreamPreferences.fpsOptions.map { StreamPreferences.fpsSupported($0, capabilities: viewModel.streamCapabilities) }, isLocked: qualityLocked, action: viewModel.setFpsIndex)
                SettingsDivider()
                SettingsOptionRow(title: "Codec", subtitle: qualityLocked ? lockedSubtitle : "Hardware video decoder (AV1, HEVC, or H.264).", options: StreamPreferences.codecOptions.map(\.label), selectedIndex: viewModel.streamProfile.codecIndex, enabled: StreamPreferences.codecOptions.map { StreamPreferences.codecSupported($0, capabilities: viewModel.streamCapabilities) }, isLocked: qualityLocked, action: viewModel.setCodecIndex)
                SettingsDivider()
                SettingsOptionRow(title: "Maximum Bitrate", subtitle: qualityLocked ? lockedSubtitle : "Maximum video streaming bandwidth.", options: StreamPreferences.bitrateOptions.map(\.label), selectedIndex: viewModel.streamProfile.bitrateIndex, isLocked: qualityLocked, action: viewModel.setBitrateIndex)
                SettingsDivider()
                SettingsToggleRow(title: "HDR (High Dynamic Range)", subtitle: qualityLocked ? lockedSubtitle : "10-bit Rec. 2020 color on supported displays and codecs.", isOn: viewModel.streamProfile.enableHdr, isLocked: qualityLocked, action: viewModel.setHDREnabled)
            }

            ResolutionUpscalingSettingsPage(viewModel: viewModel)
            
            SettingsCard(title: "Profile Maintenance") {
                HStack(alignment: .center, spacing: 16) {
                    Rectangle()
                        .fill(Color.white.opacity(0.18))
                        .frame(width: 4, height: 48)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Restore default streaming settings")
                            .font(.settingsNvidia(size: 15, weight: .bold))
                            .foregroundStyle(.white)
                        Text("Restore all streaming, video, audio, and input settings to default.")
                            .font(.settingsNvidia(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.56))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    SettingsActionButton(title: "RESTORE DEFAULTS", minimumWidth: 150) { viewModel.restoreStreamingProfileDefaults() }
                }
                .padding(12)
                .background(SettingsVendorLayout.row)
                .overlay { Rectangle().stroke(Color.white.opacity(0.08), lineWidth: 1) }
            }
        }
    }
}

private struct AudioSettingsPage: View {
    @ObservedObject var viewModel: CatalogViewModel

    private var selectedMicrophoneModeIndex: Int {
        StreamPreferences.microphoneModeOptions.firstIndex { $0.value == viewModel.streamProfile.microphoneMode } ?? 0
    }

    private var selectedMicrophoneDeviceIndex: Int {
        viewModel.microphoneDeviceOptions.firstIndex { $0.uniqueId == viewModel.streamProfile.microphoneDeviceId } ?? 0
    }

    private func percentText(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsCard(title: "Audio & Voice") {
                SettingsSliderRow(title: "Game Volume", valueText: percentText(viewModel.streamProfile.gameVolume), value: viewModel.streamProfile.gameVolume, range: 0...1, step: 0.01, action: viewModel.setGameVolume)
                SettingsDivider()
                SettingsSliderRow(title: "Microphone Volume", valueText: percentText(viewModel.streamProfile.microphoneVolume), value: viewModel.streamProfile.microphoneVolume, range: 0...1, step: 0.01, action: viewModel.setMicrophoneVolume)
                SettingsDivider()
                SettingsOptionRow(title: "Microphone Mode", subtitle: "Voice transmission mode for in-game chat.", options: StreamPreferences.microphoneModeOptions.map(\.label), selectedIndex: selectedMicrophoneModeIndex, action: { viewModel.setMicrophoneMode(StreamPreferences.microphoneModeOptions[$0].value) })
                SettingsDivider()
                SettingsOptionRow(title: "Microphone Device", subtitle: "Audio input device for voice capture.", options: viewModel.microphoneDeviceOptions.map(\.label), selectedIndex: selectedMicrophoneDeviceIndex, action: { viewModel.setMicrophoneDeviceId(viewModel.microphoneDeviceOptions[$0].uniqueId) })
                SettingsDivider()
                SettingsToggleRow(title: "Microphone Shortcut", subtitle: "Hotkey (\(viewModel.streamProfile.microphonePushToTalkComboLabel)) for push-to-talk or mute toggle.", isOn: viewModel.microphoneShortcutEnabled, action: viewModel.setMicrophoneShortcutEnabled)
                SettingsDivider()
                SettingsToggleRow(title: "Show Stream Mic Toggle", subtitle: "On-screen HUD button to mute or unmute microphone.", isOn: viewModel.showStreamMicToggle, action: viewModel.setShowStreamMicToggle)
            }
        }
    }
}

private struct InputSettingsPage: View {
    @ObservedObject var viewModel: CatalogViewModel
    @ObservedObject var inputRouter: ControllerInputRouter
    @AppStorage(InterfacePreferences.controllerModeEnabledKey) private var controllerModeEnabled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsCard(title: "Mouse & Input Controls") {
                SettingsToggleRow(title: "Direct Mouse Input", subtitle: "Capture raw mouse motion. Press ⌘G or ⌘Q to release pointer.", isOn: viewModel.streamProfile.directMouseInput, action: viewModel.setDirectMouseInputEnabled)
                SettingsDivider()
                SettingsToggleRow(title: "Suppress Input When Inactive", subtitle: "Ignore inputs when PixelNOW loses window focus.", isOn: viewModel.streamProfile.suppressInputWhenInactive, action: viewModel.setSuppressInputWhenInactive)
                SettingsDivider()
                SettingsToggleRow(title: "Anti-AFK Mouse Movement", subtitle: "Periodic keep-alive motion to prevent session timeout (⌘K).", isOn: viewModel.streamProfile.antiAFKMouseMovementEnabled, action: viewModel.setAntiAFKMouseMovementEnabled)
            }
        }
    }
}

private struct RecordingSettingsPage: View {
    @ObservedObject var viewModel: CatalogViewModel

    private var recordingVideoBitrateText: String {
        viewModel.streamProfile.recordingVideoBitrateMbps == 0 ? "Auto" : "\(viewModel.streamProfile.recordingVideoBitrateMbps) Mbps"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsCard(title: "Stream Recording & Capture") {
                SettingsSliderRow(title: "Video Bitrate", valueText: recordingVideoBitrateText, value: Double(viewModel.streamProfile.recordingVideoBitrateMbps), range: 0...200, step: 1, action: viewModel.setRecordingVideoBitrateMbps)
                SettingsDivider()
                SettingsSliderRow(title: "Audio Bitrate", valueText: "\(viewModel.streamProfile.recordingAudioBitrateKbps) Kbps", value: Double(viewModel.streamProfile.recordingAudioBitrateKbps), range: 64...320, step: 16, action: viewModel.setRecordingAudioBitrateKbps)
                SettingsDivider()
                SettingsToggleRow(title: "Record Enhanced Video", subtitle: "Capture post-upscaled video when MetalFX is active.", isOn: viewModel.streamProfile.recordingEnhancedVideoEnabled, action: viewModel.setRecordingEnhancedVideoEnabled)
            }
        }
    }
}

private struct NetworkSettingsPage: View {
    @ObservedObject var viewModel: CatalogViewModel

    var body: some View {
        let qualityLocked = !viewModel.streamingQualityProfileAllowsCustomization
        let lockedSubtitle = "Managed by \(viewModel.streamProfile.streamingQualityProfileOption.label) profile. Set to Custom to edit."
        VStack(alignment: .leading, spacing: 16) {
            ServerLocationSettingsPage(viewModel: viewModel)
            
            SettingsCard(title: "Transport & Power") {
                SettingsToggleRow(title: "L4S Congestion Control", subtitle: qualityLocked ? lockedSubtitle : "Reduce queuing delay and packet jitter on supported networks.", isOn: viewModel.streamProfile.enableL4S, isLocked: qualityLocked, action: viewModel.setL4SEnabled)
                SettingsDivider()
                SettingsToggleRow(title: "Prevent Display Sleep", subtitle: "Keep displays awake during active stream sessions.", isOn: viewModel.streamProfile.preventDisplaySleepWhileStreaming, action: viewModel.setPreventDisplaySleepWhileStreaming)
            }
        }
    }
}

private struct RemoteCoOpSettingsPage: View {
    @ObservedObject var viewModel: CatalogViewModel

    private var selectedTransportModeIndex: Int {
        RemoteCoOpTransportMode.allCases.firstIndex(of: viewModel.remoteCoOpPreferences.transportMode) ?? 0
    }

    private var selectedQualityPresetIndex: Int {
        RemoteCoOpQualityPreset.allCases.firstIndex(of: viewModel.remoteCoOpPreferences.qualityPreset) ?? 0
    }

    private var selectedLatencyModeIndex: Int {
        RemoteCoOpLatencyMode.allCases.firstIndex(of: viewModel.remoteCoOpPreferences.latencyMode) ?? 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if viewModel.remoteCoOpPreferences.isAlphaOptedIn {
                SettingsCard(title: "Remote Co-Op") {
                    SettingsToggleRow(title: "Enable Remote Co-Op", subtitle: "Generate invite links in the stream HUD for guests.", isOn: viewModel.remoteCoOpPreferences.isEnabled, action: viewModel.setRemoteCoOpEnabled)
                    SettingsDivider()
                    SettingsOptionRow(title: "Reserved Controllers", subtitle: "Pre-allocate gamepad slots for guest players.", options: ["None", "1 Guest", "2 Guests", "3 Guests"], selectedIndex: viewModel.remoteCoOpPreferences.reservedGuestSlots, action: viewModel.setRemoteCoOpReservedGuestSlots)
                    SettingsDivider()
                    SettingsOptionRow(title: "Transport", subtitle: viewModel.remoteCoOpPreferences.transportMode.description, options: RemoteCoOpTransportMode.allCases.map(\.label), selectedIndex: selectedTransportModeIndex, action: viewModel.setRemoteCoOpTransportModeIndex)
                    SettingsDivider()
                    SettingsOptionRow(title: "Guest Quality", subtitle: "Max outbound streaming bitrate sent to guests.", options: RemoteCoOpQualityPreset.allCases.map(\.label), selectedIndex: selectedQualityPresetIndex, action: viewModel.setRemoteCoOpQualityPresetIndex)
                    SettingsDivider()
                    SettingsOptionRow(title: "Latency Mode", subtitle: viewModel.remoteCoOpPreferences.latencyMode.description, options: RemoteCoOpLatencyMode.allCases.map(\.label), selectedIndex: selectedLatencyModeIndex, action: viewModel.setRemoteCoOpLatencyModeIndex)
                    SettingsDivider()
                    SettingsToggleRow(title: "Require Host Approval", subtitle: "Require host approval before accepting guest input.", isOn: viewModel.remoteCoOpPreferences.requireHostApproval, action: viewModel.setRemoteCoOpRequireHostApproval)
                    SettingsDivider()
                    SettingsToggleRow(title: "Hide Guest Invite Details", subtitle: "Omit game title and app ID from invite links.", isOn: viewModel.remoteCoOpPreferences.hideGuestInviteDetails, action: viewModel.setRemoteCoOpHideGuestInviteDetails)
                }
            } else {
                SettingsCard(title: "Remote Co-Op") {
                    AccountEmptyState(
                        title: "Alpha access required.",
                        subtitle: "Enable Remote Co-Op Alpha in Labs to unlock host controls and stream HUD invites."
                    )
                }
            }
        }
    }
}
