import CryptoKit
import SwiftData
import SwiftUI

private enum CatalogChromeLayout {
    static let accountPillWidth: CGFloat = 220
}

struct CatalogChrome: View {
    @ObservedObject var viewModel: CatalogViewModel
    let accounts: [LoginAccount]
    let onSwitch: (LoginAccount) -> Void
    let onAddAccount: () -> Void
    let onSignOut: () -> Void
    let onForget: (LoginAccount) -> Void

    var body: some View {
        HStack(alignment: .top) {
            TopNavigationGlassBar(
                viewModel: viewModel,
                accounts: accounts,
                onSwitch: onSwitch,
                onAddAccount: onAddAccount,
                onSignOut: onSignOut,
                onForget: onForget
            )
            .padding(.top, 16)
            .padding(.leading, 72) // Clear macOS traffic lights
            
            Spacer(minLength: 20)
            
            VStack(alignment: .trailing, spacing: 8) {
                AccountGlassControl(
                    account: viewModel.account,
                    accounts: accounts,
                    onSwitch: onSwitch,
                    onAddAccount: onAddAccount,
                    onSignOut: onSignOut,
                    onForget: onForget
                )
                MonthlyUsageProgressBar(
                    subscriptionStatus: viewModel.subscriptionStatus,
                    width: CatalogChromeLayout.accountPillWidth
                )
            }
            .padding(.top, 16)
            .padding(.trailing, 20)
        }
    }
}

private struct MonthlyUsageProgressBar: View {
    let subscriptionStatus: CatalogSubscriptionStatus
    let width: CGFloat

    private var usageProgress: Double {
        guard subscriptionStatus.totalHours > 0,
              subscriptionStatus.isAvailable,
              !subscriptionStatus.isUnlimited else { return 0 }
        return min(subscriptionStatus.usedHours / subscriptionStatus.totalHours, 1)
    }

    var body: some View {
        let usageValue = CatalogSubscriptionStatus.hoursText(subscriptionStatus.usedHours)
        let totalValue = CatalogSubscriptionStatus.hoursText(subscriptionStatus.totalHours)
        let usageLabel = subscriptionStatus.totalHours > 0
            ? "\(usageValue) / \(totalValue)"
            : subscriptionStatus.usageText
        let usageTint = usageProgress >= 0.9 ? Color.red : usageProgress >= 0.7 ? Color.orange : Color.blue

        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Color.black.opacity(0.72))

                Capsule(style: .continuous)
                    .fill(usageTint.opacity(0.78))
                    .frame(width: geometry.size.width * usageProgress)

                HStack(spacing: 4) {
                    Label("Monthly Usage", systemImage: "calendar.circle.fill")
                        .font(.system(size: 10, weight: .medium))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)

                    Spacer(minLength: 2)

                    Text(usageLabel)
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
            }
            .clipShape(Capsule(style: .continuous))
            .overlay {
                Capsule(style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            }
        }
        .frame(width: width, height: 30)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Monthly Usage")
        .accessibilityValue(usageLabel)
    }
}

private struct TopNavigationGlassBar: View {
    @ObservedObject var viewModel: CatalogViewModel
    let accounts: [LoginAccount]
    let onSwitch: (LoginAccount) -> Void
    let onAddAccount: () -> Void
    let onSignOut: () -> Void
    let onForget: (LoginAccount) -> Void

    var body: some View {
        HStack(spacing: 18) {
            Button("Home") { viewModel.showGames() }
            Button("Library") { viewModel.showCatalogDestination(.library) }
            Button("Recordings") { viewModel.showRecordings() }
            Button("Settings") { viewModel.showSettings() }
            Button { viewModel.refresh() } label: { Image(systemName: "arrow.clockwise") }
                .disabled(viewModel.isCatalogRefreshInProgress)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
        .modifier(LiquidGlassModifier(cornerRadius: 24))
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct AccountGlassControl: View {
    let account: LoginAccount
    let accounts: [LoginAccount]
    let onSwitch: (LoginAccount) -> Void
    let onAddAccount: () -> Void
    let onSignOut: () -> Void
    let onForget: (LoginAccount) -> Void

    var body: some View {
        Menu {
            ForEach(accounts, id: \.persistentModelID) { candidate in
                Button("Switch to \(candidate.displayName)") { onSwitch(candidate) }
            }
            Divider()
            Button("Add Account", action: onAddAccount)
            Button("Forget Account", role: .destructive) { onForget(account) }
            Button("Sign Out", role: .destructive, action: onSignOut)
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(account.displayName.isEmpty ? "Account" : account.displayName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(account.membershipTier)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.68))
                }
                GravatarView(account: account, size: 34)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
        .frame(width: CatalogChromeLayout.accountPillWidth)
        .modifier(LiquidGlassModifier(cornerRadius: 18))
    }
}

private struct GravatarView: View {
    let account: LoginAccount
    let size: CGFloat

    private var url: URL? {
        let email = account.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !email.isEmpty else { return nil }
        let hash = Insecure.MD5.hash(data: Data(email.utf8)).map { String(format: "%02x", $0) }.joined()
        return URL(string: "https://www.gravatar.com/avatar/\(hash)?s=\(Int(size * 3))&d=404")
    }

    var body: some View {
        ZStack {
            Circle().fill(Color.white.opacity(0.18))
            if let url {
                CatalogRemoteImage(url: url, contentMode: .fill)
                    .clipShape(Circle())
            } else {
                Text(String(account.displayName.prefix(1)).uppercased())
                    .font(.headline)
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

struct LiquidGlassModifier: ViewModifier {
    let cornerRadius: CGFloat

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }
}
