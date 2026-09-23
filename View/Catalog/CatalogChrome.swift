import CryptoKit
import SwiftData
import SwiftUI

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
            
            AccountGlassControl(
                account: viewModel.account,
                accounts: accounts,
                onSwitch: onSwitch,
                onAddAccount: onAddAccount,
                onSignOut: onSignOut,
                onForget: onForget
            )
            .padding(.top, 16)
            .padding(.trailing, 20)
        }
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
        .modifier(LiquidGlassModifier(cornerRadius: 18))
        .fixedSize()
        .frame(maxWidth: 240, alignment: .trailing)
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
