import AppKit
import Combine
import Foundation
import SwiftData
import SwiftUI

private final class LoginWeakObject<T: AnyObject>: @unchecked Sendable {
    weak var value: T?

    init(_ value: T) {
        self.value = value
    }
}

@MainActor
final class LoginViewModel: ObservableObject {
    @Published var email = ""
    @Published var providers = [LoginProvider.nvidia]
    @Published var selectedProvider = LoginProvider.nvidia
    @Published var rememberSession = true
    @Published var acceptedTerms = false
    @Published var isShowingAccountPicker = false
    @Published var validationMessage = ""
    @Published var successMessage = ""
    @Published var isLoadingProviders = false
    @Published var isLaunchingOAuth = false
    @Published var isAuthenticating = false
    @Published var requestedFocus: LoginField?
    @Published var currentAuthorizationURL = ""
    @Published var pendingGameShortcut: GFNGameShortcut?
    @Published var deviceCodeUserCode = ""
    @Published var deviceCodeVerificationURI = ""

    private let authService = AuthService.shared
    private var modelContext: ModelContext?
    private var accounts: [LoginAccount] = []
    private var sessions: [LoginSession] = []
    private var devices: [LoginDeviceRegistration] = []
    private var oauthRestoreUserId: String?

    var authStatusSummary: String {
        if isAuthenticating { return JarvisAuthStatus.pendingLogin.rawValue.replacingOccurrences(of: "_", with: " ") }
        if activeSession != nil { return JarvisAuthStatus.loggedIn.rawValue.replacingOccurrences(of: "_", with: " ") }
        if hasPendingOAuth { return JarvisAuthStatus.pendingLogin.rawValue.replacingOccurrences(of: "_", with: " ") }
        return JarvisAuthStatus.notLoggedIn.rawValue.replacingOccurrences(of: "_", with: " ")
    }

    var nesAuthorizationSummary: String {
        activeAccount?.authorizationState ?? NesAuth.AuthorizationState.pending.rawValue
    }

    var activeSession: LoginSession? {
        sessions.first { session in
            session.isActive && (!session.isExpired || session.canContinueOffline)
        }
    }

    var activeAccount: LoginAccount? {
        guard let activeSession else { return nil }
        if let userId = AccountStorageKeys.requireUserId(activeSession.userId) {
            if let match = accounts.first(where: { $0.userId == userId }) { return match }
        }
        return accounts.first { $0.email == activeSession.accountEmail }
    }

    var rememberedAccounts: [LoginAccount] {
        accounts.sorted { $0.lastLoginAt > $1.lastLoginAt }
    }

    var primaryDevice: LoginDeviceRegistration {
        devices.first ?? LoginDeviceRegistration()
    }

    var hasPendingOAuth: Bool {
        !primaryDevice.pendingOAuthState.isEmpty && !primaryDevice.pendingOAuthCodeVerifier.isEmpty
    }

    var canLaunchOAuth: Bool {
        acceptedTerms && !isLaunchingOAuth && !isAuthenticating
    }

    func update(modelContext: ModelContext, accounts: [LoginAccount], sessions: [LoginSession], devices: [LoginDeviceRegistration]) {
        self.modelContext = modelContext
        self.accounts = accounts
        self.sessions = sessions
        self.devices = devices
    }

    func bootstrap() {
        Log.info(.auth, "Login bootstrap started accounts=\(accounts.count) sessions=\(sessions.count) devices=\(devices.count)")
        ensureDeviceRegistration()
        hydrateAccountsFromAuthServiceIfNeeded()
        prefillLastAccount()
        refreshLoginProviders()
        Log.info(.auth, "Login bootstrap completed hasActiveSession=\(activeSession != nil) hasPendingOAuth=\(hasPendingOAuth)")
    }

    func toggleAccountPicker() {
        withAnimation(.snappy) {
            isShowingAccountPicker.toggle()
        }
    }

    func selectRememberedAccount(_ account: LoginAccount) {
        email = account.email
        selectedProvider = providerOption(idpId: account.providerIdpId, fallbackName: account.providerName)
        rememberSession = account.rememberSession
        isShowingAccountPicker = false
    }

    func showNewAccountLogin() {
        withAnimation(.snappy) {
            isShowingAccountPicker = true
        }
    }

    func showRememberedAccounts() {
        withAnimation(.snappy) {
            isShowingAccountPicker = false
        }
    }

    func canRestoreAccount(_ account: LoginAccount) -> Bool {
        storedSession(for: account) != nil || authService.loadSavedSession(forUserId: account.userId).isAuthenticated
    }

    func selectProvider(_ provider: LoginProvider) {
        selectedProvider = provider
    }

    func launchOAuth() {
        Task { await beginOAuth(preservingCurrentAccount: false) }
    }

    func addAccount() {
        if isAccountLifecycleBlocked {
            validationMessage = "End your current game session before adding an account."
            return
        }
        Task { await beginOAuth(preservingCurrentAccount: activeSession != nil) }
    }

    func launchDeviceCodeOAuth() {
        Task { await beginDeviceCodeOAuth() }
    }

    func handleOAuthCallback(_ url: URL) {
        guard url.scheme == "com.nvidia.geforcenow" || url.scheme == "pixelnow" else { return }
        Log.info(.auth, "Ignoring custom-scheme OAuth callback because browser sign-in completes through the local listener")
    }

    func handleOpenedFile(_ url: URL) {
        Log.info(.shortcut, "LoginViewModel received opened file: \(url.path)")
        guard url.pathExtension.caseInsensitiveCompare("gfnpc") == .orderedSame else {
            Log.info(.shortcut, "Ignoring non-gfnpc opened file: \(url.pathExtension)")
            return
        }
        do {
            pendingGameShortcut = try GFNGameShortcut(fileURL: url)
            if let shortcut = pendingGameShortcut {
                Log.info(.shortcut, "Parsed gfnpc shortcut cmsId=\(shortcut.cmsId) shortName=\(shortcut.shortName) parentGameId=\(shortcut.parentGameId) title=\(shortcut.lookupTitle)")
            }
            if activeSession == nil {
                Log.info(.shortcut, "Shortcut parsed but no active session is available")
                validationMessage = "Sign in to launch \(pendingGameShortcut?.lookupTitle.isEmpty == false ? pendingGameShortcut?.lookupTitle ?? "this game" : "this game") from its GeForce NOW shortcut."
            } else {
                Log.info(.shortcut, "Shortcut queued for active catalog session")
            }
        } catch {
            Log.error(.shortcut, "Failed to parse gfnpc shortcut: \(error.localizedDescription)")
            validationMessage = error.localizedDescription
        }
    }

    func activateAccount(_ account: LoginAccount) {
        if isAccountLifecycleBlocked {
            validationMessage = "End your current game session before switching accounts."
            return
        }
        if let active = activeAccount, accountsMatch(active, account) {
            return
        }
        Task { _ = await restoreAccountSession(account) }
    }

    func signOut() {
        if isAccountLifecycleBlocked {
            validationMessage = "End your current game session before signing out."
            return
        }
        Task { await signOutCurrentSession() }
    }

    func refreshActiveSession() {
        guard let activeAccount else { return }
        Task { _ = await restoreAccountSession(activeAccount) }
    }

    func refreshActiveSessionIfPossible() async -> Bool {
        guard let activeAccount else { return false }
        return await restoreAccountSession(activeAccount)
    }

    func forgetAccount(_ account: LoginAccount) {
        if isAccountLifecycleBlocked {
            validationMessage = "End your current game session before forgetting an account."
            return
        }
        Task { await forgetAccountAndRebind(account) }
    }

    private var isAccountLifecycleBlocked: Bool {
        NativeNVSTMediaStreamLifecycle.hasActiveStream
    }

    private func beginOAuth(preservingCurrentAccount: Bool) async {
        validationMessage = ""
        successMessage = ""
        let loginProvider = selectedProvider
        Log.info(.auth, "Beginning OAuth launch provider=\(loginProvider.idpId) preservingCurrent=\(preservingCurrentAccount)")

        guard acceptedTerms else {
            Log.warning(.auth, "OAuth launch blocked because terms were not accepted")
            validationMessage = "Accept account terms and local session storage before continuing."
            return
        }

        oauthRestoreUserId = preservingCurrentAccount ? AccountStorageKeys.canonicalUserId(accountUserId: activeAccount?.userId ?? "", sessionUserId: activeSession?.userId ?? "") : nil
        isLaunchingOAuth = true
        validationMessage = "Finish \(loginProvider.title) sign-in in the browser. PixelNOW will continue automatically."

        authService.startOAuthLogin(providerIdpId: loginProvider.idpId) { [weak self] success, session, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.selectedProvider = loginProvider
                self.isLaunchingOAuth = false
                self.currentAuthorizationURL = ""
                self.clearPendingOAuthState()
                let restoreUserId = self.oauthRestoreUserId
                self.oauthRestoreUserId = nil

                guard success else {
                    self.validationMessage = error.isEmpty ? "\(loginProvider.title) sign-in failed." : error
                    Log.error(.auth, "OAuth start failed provider=\(loginProvider.idpId) error=\(self.validationMessage)")
                    if let restoreUserId {
                        self.authService.setActiveSessionUserId(restoreUserId)
                        await self.authService.applyActiveSessionToBackends()
                    }
                    return
                }

                self.persistSignedInSession(session: session, userInfo: nil, authMethod: Jarvis.Operation.getSessionToken.rawValue)
                self.bindRuntimeTokens(session)
                self.validationMessage = ""
                self.successMessage = "\(loginProvider.title) account connected. Client token and session metadata are ready."
                Log.info(.auth, "OAuth start completed provider=\(loginProvider.idpId) userId=\(session.userId)")
            }
        }
    }

    private func beginDeviceCodeOAuth() async {
        Log.info(.auth, "Starfleet device-code OAuth is unavailable; launching browser OAuth instead")
        deviceCodeUserCode = ""
        deviceCodeVerificationURI = ""
        await beginOAuth(preservingCurrentAccount: false)
    }

    private func restoreAccountSession(_ account: LoginAccount) async -> Bool {
        validationMessage = ""
        successMessage = ""
        email = account.email
        selectedProvider = providerOption(idpId: account.providerIdpId, fallbackName: account.providerName)
        rememberSession = account.rememberSession

        guard let userId = AccountStorageKeys.requireUserId(account.userId) ?? AccountStorageKeys.requireUserId(storedSession(for: account)?.userId ?? "") else {
            Log.warning(.auth, "Session restore failed because no user id exists for account=\(account.email)")
            validationMessage = "No saved session exists for this account. Sign in again."
            return false
        }

        isAuthenticating = true
        defer { isAuthenticating = false }

        var jarvisSession = authService.loadSavedSession(forUserId: userId)
        var migratedFromSwiftData = false
        if !jarvisSession.isAuthenticated, let storedSession = storedSession(for: account), !storedSession.accessToken.isEmpty {
            jarvisSession = makeJarvisSession(from: storedSession, account: account)
            migratedFromSwiftData = true
        }

        guard jarvisSession.isAuthenticated, AccountStorageKeys.requireUserId(jarvisSession.userId) != nil else {
            Log.warning(.auth, "Session restore failed because no saved session exists for userId=\(userId)")
            validationMessage = "No saved session exists for this account. Sign in again."
            return false
        }

        if migratedFromSwiftData {
            authService.saveSession(jarvisSession)
        }
        authService.setActiveSessionUserId(userId)
        await authService.applyActiveSessionToBackends()

        do {
            Log.info(.auth, "Refreshing saved session userId=\(userId)")
            let refreshed = try await authService.refreshSession(forceRefresh: !jarvisSession.isIdTokenValid)
            persistSignedInSession(session: refreshed, userInfo: nil, authMethod: Jarvis.Operation.getSessionToken.rawValue)
            bindRuntimeTokens(refreshed)
            successMessage = "Session refreshed for \(account.displayName)."
            Log.info(.auth, "Session refreshed userId=\(userId)")
            return true
        } catch {
            if let storedSession = storedSession(for: account), storedSession.canContinueOffline, !storedSession.isExpired {
                markActive(userId: userId)
                bindRuntimeTokens(jarvisSession)
                trySave()
                successMessage = "Using saved offline session for \(account.displayName)."
                Log.warning(.auth, "Using offline saved session userId=\(userId) refreshError=\(error.localizedDescription)")
                return false
            } else {
                validationMessage = "Saved session expired. Sign in again."
                Log.warning(.auth, "Session restore failed userId=\(userId) error=\(error.localizedDescription)")
                return false
            }
        }
    }

    private func signOutCurrentSession() async {
        Log.info(.auth, "Signing out current session")
        let currentAccount = activeAccount
        let currentSession = activeSession
        let idToken = currentSession?.idToken ?? ""

        if let currentAccount {
            currentAccount.isActive = false
            currentAccount.authStatus = JarvisAuthStatus.notLoggedIn.rawValue
        }
        if let currentSession {
            currentSession.isActive = false
            currentSession.accessToken = ""
            currentSession.refreshToken = ""
            currentSession.idToken = ""
            currentSession.clientToken = ""
        }
        clearPendingOAuthState()
        currentAuthorizationURL = ""
        trySave()

        if idToken.isEmpty {
            authService.clearSession()
        } else {
            _ = await authService.serverLogout(idToken: idToken, locale: "")
        }
        SessionManager.shared.setAccessToken("")
        successMessage = "Signed out."
        Log.info(.auth, "Sign out completed userId=\(currentAccount?.userId ?? "")")
    }

    private func forgetAccountAndRebind(_ account: LoginAccount) async {
        guard let modelContext else { return }
        let accountSession = sessions.first { sessionBelongs($0, to: account) }
        let forgottenUserId = AccountStorageKeys.canonicalUserId(
            accountUserId: account.userId,
            sessionUserId: accountSession?.userId ?? ""
        )
        let wasActive = activeAccount.map { accountsMatch($0, account) } ?? false
        let remaining = accounts.filter { !accountsMatch($0, account) }

        for session in sessions where sessionBelongs(session, to: account) {
            modelContext.delete(session)
            sessions.removeAll { $0.id == session.id }
        }
        modelContext.delete(account)
        accounts.removeAll { accountsMatch($0, account) }
        trySave()

        if let forgottenUserId {
            authService.removeSavedSession(userId: forgottenUserId)
            GameDataCache.shared.removeLibrarySnapshotsAsync(accountIdentifier: forgottenUserId)
        }

        if wasActive {
            if let next = remaining.sorted(by: { $0.lastLoginAt > $1.lastLoginAt }).first {
                _ = await restoreAccountSession(next)
            } else {
                authService.clearSession()
                SessionManager.shared.setAccessToken("")
            }
        }
        Log.info(.auth, "Forgot account userId=\(forgottenUserId ?? "") wasActive=\(wasActive)")
    }

    private func persistSignedInSession(session: JarvisSession, userInfo: JarvisUserInfo?, authMethod: String) {
        guard let modelContext else {
            validationMessage = "SwiftData context is unavailable."
            Log.error(.auth, "Cannot persist signed-in session because SwiftData context is unavailable")
            return
        }

        guard let userId = AccountStorageKeys.requireUserId(session.userId) else {
            validationMessage = "NVIDIA did not return a user id for this session."
            Log.error(.auth, "Cannot persist signed-in session because userId is empty")
            return
        }

        let now = Date()
        let normalizedEmail = Self.normalizedEmail(session: session, userInfo: userInfo, fallbackEmail: email)
        let displayName = Self.displayName(session: session, userInfo: userInfo, email: normalizedEmail)
        let providerIdpId = session.idpId.isEmpty ? selectedProvider.idpId : session.idpId
        let resolvedProvider = providerOption(idpId: providerIdpId, fallbackName: selectedProvider.title)
        let existingSession = sessions.first { $0.userId == userId } ?? sessions.first { $0.accountEmail == normalizedEmail }

        for account in accounts { account.isActive = false }
        for storedSession in sessions { storedSession.isActive = false }

        let account: LoginAccount
        if let existingAccount = accounts.first(where: { $0.userId == userId })
            ?? accounts.first(where: { $0.userId.isEmpty && $0.email == normalizedEmail }) {
            account = existingAccount
        } else {
            account = LoginAccount(
                email: normalizedEmail,
                displayName: displayName,
                providerIdpId: providerIdpId,
                providerName: resolvedProvider.title,
                userId: userId
            )
            modelContext.insert(account)
            accounts.insert(account, at: 0)
        }

        let authorization = NesAuthorizationPolicy().result(authType: JarvisAuthType.jwtGFN.rawValue)
        account.email = normalizedEmail
        account.displayName = displayName
        account.providerIdpId = providerIdpId
        account.providerName = resolvedProvider.title
        account.membershipTier = session.membershipTier.isEmpty ? "Free" : session.membershipTier
        account.authorizationState = authorization.state.rawValue
        account.authStatus = JarvisAuthStatus.loggedIn.rawValue
        account.userId = userId
        account.externalUserId = userInfo?.externalId ?? session.userId
        account.lastLoginAt = now
        account.rememberSession = rememberSession
        account.isActive = true

        let expiry = Date(timeIntervalSince1970: TimeInterval(session.expiresAt > 0 ? session.expiresAt : Int64(now.addingTimeInterval(86_400).timeIntervalSince1970)))
        let clientExpiry = session.clientTokenExpiry > 0 ? Date(timeIntervalSince1970: TimeInterval(session.clientTokenExpiry) / 1000.0) : expiry
        let storedSession = existingSession ?? LoginSession(
            accountEmail: normalizedEmail,
            authMethod: authMethod,
            accessToken: session.accessToken,
            clientToken: session.clientToken,
            idToken: session.idToken,
            refreshToken: session.refreshToken,
            userId: session.userId,
            idpId: providerIdpId,
            deviceId: primaryDevice.deviceId,
            issuedAt: now,
            expiresAt: expiry,
            clientTokenExpiresAt: clientExpiry,
            isActive: true,
            canContinueOffline: rememberSession
        )
        storedSession.updateAuthentication(
            accountEmail: normalizedEmail,
            authMethod: authMethod,
            accessToken: session.accessToken,
            clientToken: session.clientToken,
            idToken: session.idToken,
            refreshToken: session.refreshToken,
            userId: session.userId,
            idpId: providerIdpId,
            deviceId: primaryDevice.deviceId,
            issuedAt: now,
            expiresAt: expiry,
            clientTokenExpiresAt: clientExpiry,
            isActive: true,
            canContinueOffline: rememberSession
        )
        if existingSession == nil {
            modelContext.insert(storedSession)
            sessions.insert(storedSession, at: 0)
        } else if let index = sessions.firstIndex(where: { $0.id == storedSession.id }), index > 0 {
            sessions.remove(at: index)
            sessions.insert(storedSession, at: 0)
        }
        primaryDevice.lastUsedAt = now
        trySave()
        authService.saveSession(session)
        Log.info(.auth, "Persisted signed-in session userId=\(userId) account=\(normalizedEmail) provider=\(providerIdpId) canContinueOffline=\(rememberSession)")
    }

    private func markActive(userId: String) {
        for account in accounts {
            account.isActive = account.userId == userId
            account.authStatus = account.isActive ? JarvisAuthStatus.loggedIn.rawValue : JarvisAuthStatus.notLoggedIn.rawValue
        }
        for session in sessions {
            session.isActive = session.userId == userId
        }
        authService.setActiveSessionUserId(userId)
    }

    private func bindRuntimeTokens(_ session: JarvisSession) {
        SessionManager.shared.setAccessToken(session.accessToken)
        let userId = AccountStorageKeys.requireUserId(session.userId) ?? ""
        GameServiceSwiftAdapter.configureCatalogSession(accessToken: session.accessToken, idToken: session.idToken, userId: userId)
    }

    private func storedSession(for account: LoginAccount) -> LoginSession? {
        if let userId = AccountStorageKeys.requireUserId(account.userId) {
            if let match = sessions.first(where: { $0.userId == userId && !$0.accessToken.isEmpty }) { return match }
            if let match = sessions.first(where: { $0.userId == userId }) { return match }
        }
        return sessions.first { $0.accountEmail == account.email && !$0.accessToken.isEmpty }
            ?? sessions.first { $0.accountEmail == account.email }
    }

    private func sessionBelongs(_ session: LoginSession, to account: LoginAccount) -> Bool {
        if let userId = AccountStorageKeys.requireUserId(account.userId), session.userId == userId { return true }
        return session.accountEmail == account.email
    }

    private func accountsMatch(_ lhs: LoginAccount, _ rhs: LoginAccount) -> Bool {
        if let lhsId = AccountStorageKeys.requireUserId(lhs.userId), let rhsId = AccountStorageKeys.requireUserId(rhs.userId) {
            return lhsId == rhsId
        }
        return lhs.persistentModelID == rhs.persistentModelID
    }

    private func makeJarvisSession(from storedSession: LoginSession, account: LoginAccount) -> JarvisSession {
        var session = JarvisSession(
            accessToken: storedSession.accessToken,
            idToken: storedSession.idToken,
            refreshToken: storedSession.refreshToken,
            userId: AccountStorageKeys.requireUserId(storedSession.userId) ?? account.userId,
            displayName: account.displayName,
            email: account.email,
            membershipTier: account.membershipTier,
            idpId: storedSession.idpId.isEmpty ? account.providerIdpId : storedSession.idpId,
            expiresAt: Int64(storedSession.expiresAt.timeIntervalSince1970),
            isAuthenticated: true,
            clientToken: storedSession.clientToken,
            clientTokenExpiry: Int64(storedSession.clientTokenExpiresAt.timeIntervalSince1970 * 1000.0),
            clientTokenExpiryLength: 0,
            accessTokenExpiry: Int64(storedSession.expiresAt.timeIntervalSince1970 * 1000.0)
        )
        if session.idTokenExpiry == 0 {
            session.idTokenExpiry = JarvisSessionParser.idTokenExpiry(storedSession.idToken)
        }
        return session
    }

    private func hydrateAccountsFromAuthServiceIfNeeded() {
        guard let modelContext else { return }
        let saved = authService.loadSavedSessions()
        guard !saved.isEmpty else { return }
        let existingUserIds = Set(accounts.compactMap { AccountStorageKeys.requireUserId($0.userId) })
        let now = Date()
        var inserted = false
        for session in saved {
            guard let userId = AccountStorageKeys.requireUserId(session.userId), !existingUserIds.contains(userId) else { continue }
            let email = Self.normalizedEmail(session: session, userInfo: nil, fallbackEmail: "")
            let provider = providerOption(idpId: session.idpId, fallbackName: "")
            let account = LoginAccount(
                email: email,
                displayName: Self.displayName(session: session, userInfo: nil, email: email),
                providerIdpId: session.idpId.isEmpty ? provider.idpId : session.idpId,
                providerName: provider.title,
                membershipTier: session.membershipTier.isEmpty ? "Free" : session.membershipTier,
                userId: userId,
                lastLoginAt: now,
                isActive: false
            )
            modelContext.insert(account)
            accounts.append(account)
            let expiry = Date(timeIntervalSince1970: TimeInterval(session.expiresAt > 0 ? session.expiresAt : Int64(now.addingTimeInterval(86_400).timeIntervalSince1970)))
            let clientExpiry = session.clientTokenExpiry > 0 ? Date(timeIntervalSince1970: TimeInterval(session.clientTokenExpiry) / 1000.0) : expiry
            let storedSession = LoginSession(
                accountEmail: email,
                authMethod: Jarvis.Operation.getSessionToken.rawValue,
                accessToken: session.accessToken,
                clientToken: session.clientToken,
                idToken: session.idToken,
                refreshToken: session.refreshToken,
                userId: userId,
                idpId: session.idpId,
                deviceId: primaryDevice.deviceId,
                issuedAt: now,
                expiresAt: expiry,
                clientTokenExpiresAt: clientExpiry,
                isActive: false,
                canContinueOffline: true
            )
            modelContext.insert(storedSession)
            sessions.append(storedSession)
            inserted = true
        }
        if inserted {
            trySave()
            Log.info(.auth, "Hydrated SwiftData accounts from the token vault count=\(accounts.count)")
        }
    }

    private func clearPendingOAuthState() {
        primaryDevice.pendingOAuthState = ""
        primaryDevice.pendingOAuthCodeVerifier = ""
        primaryDevice.pendingOAuthProviderIdpId = ""
        primaryDevice.pendingOAuthRedirectURI = ""
        deviceCodeUserCode = ""
        deviceCodeVerificationURI = ""
    }

    private func ensureDeviceRegistration() {
        guard devices.isEmpty, let modelContext else { return }
        let device = LoginDeviceRegistration()
        modelContext.insert(device)
        devices = [device]
        trySave()
        Log.info(.auth, "Created login device registration deviceId=\(device.deviceId)")
    }

    private func prefillLastAccount() {
        guard email.isEmpty else { return }
        let lastActiveUserId = AccountStorageKeys.activeUserId()
        let account = rememberedAccounts.first { account in
            guard let lastActiveUserId else { return false }
            return account.userId == lastActiveUserId
        } ?? rememberedAccounts.first
        guard let account else { return }
        email = account.email
        selectedProvider = providerOption(idpId: account.providerIdpId, fallbackName: account.providerName)
        rememberSession = account.rememberSession
        isShowingAccountPicker = rememberedAccounts.isEmpty
    }

    private func refreshLoginProviders() {
        guard !isLoadingProviders else { return }
        isLoadingProviders = true
        let requestedProviderIdpId = selectedProvider.idpId
        let selfBox = LoginWeakObject(self)
        GameServiceSwiftAdapter.fetchGameProviderInfo(idpId: requestedProviderIdpId) { success, info, _, error in
            Task { @MainActor in
                guard let self = selfBox.value else { return }
                self.isLoadingProviders = false
                guard success else {
                    Log.warning(.auth, "Provider discovery failed: \(error)")
                    return
                }
                self.applyProviderInfo(info)
            }
        }
    }

    private func applyProviderInfo(_ info: GameProviderInfo) {
        let discoveredProviders = Self.providerOptions(from: info)
        guard !discoveredProviders.isEmpty else { return }

        let previousProviderIdpId = selectedProvider.idpId
        providers = discoveredProviders
        if let existingProvider = providerOptionIfAvailable(idpId: previousProviderIdpId) {
            selectedProvider = existingProvider
        } else if let preferredProvider = Self.preferredProvider(in: discoveredProviders, info: info) {
            selectedProvider = preferredProvider
        } else {
            selectedProvider = discoveredProviders[0]
        }
    }

    private func providerOption(idpId: String, fallbackName: String = "") -> LoginProvider {
        if let provider = providerOptionIfAvailable(idpId: idpId) { return provider }
        if idpId.isEmpty || idpId == Jarvis.defaultIdpId { return .nvidia }
        let title = fallbackName.trimmed.isEmpty ? "Provider" : fallbackName.trimmed
        return LoginProvider(idpId: idpId, title: title, loginProvider: title, loginProviderCode: title, streamingServiceUrl: "")
    }

    private func providerOptionIfAvailable(idpId: String) -> LoginProvider? {
        guard !idpId.isEmpty else { return nil }
        return providers.first { $0.idpId == idpId }
    }

    private static func providerOptions(from info: GameProviderInfo) -> [LoginProvider] {
        var seenIdpIds = Set<String>()
        let options = info.endpoints.compactMap { endpoint -> LoginProvider? in
            guard !endpoint.idpId.isEmpty, seenIdpIds.insert(endpoint.idpId).inserted else { return nil }
            return LoginProvider(endpoint: endpoint)
        }
        return options.isEmpty ? [.nvidia] : options
    }

    private static func preferredProvider(in providers: [LoginProvider], info: GameProviderInfo) -> LoginProvider? {
        if info.loginPreferredProviders.count == 1,
           let provider = provider(matching: info.loginPreferredProviders[0], in: providers) {
            return provider
        }
        if let provider = provider(matching: info.loggedInProvider, in: providers) { return provider }
        if let provider = provider(matching: info.defaultProvider, in: providers) { return provider }
        return nil
    }

    private static func provider(matching vendorName: String, in providers: [LoginProvider]) -> LoginProvider? {
        let normalized = vendorName.trimmed.lowercased()
        guard !normalized.isEmpty else { return nil }
        return providers.first { provider in
            provider.loginProvider.lowercased() == normalized ||
            provider.loginProviderCode.lowercased() == normalized ||
            provider.title.lowercased() == normalized
        }
    }

    private func trySave() {
        do {
            try modelContext?.save()
        } catch {
            validationMessage = error.localizedDescription
            Log.error(.app, "SwiftData save failed: \(error.localizedDescription)")
        }
    }

    private static func normalizedEmail(session: JarvisSession, userInfo: JarvisUserInfo?, fallbackEmail: String) -> String {
        let candidate = userInfo?.email.trimmed ?? session.email.trimmed
        let fallback = fallbackEmail.trimmed
        let value = candidate.isEmpty ? fallback : candidate
        if !value.isEmpty { return value.lowercased() }
        if !session.userId.isEmpty { return "\(session.userId.lowercased())@pixelnow.local" }
        return "pixelnow-user@pixelnow.local"
    }

    private static func displayName(session: JarvisSession, userInfo: JarvisUserInfo?, email: String) -> String {
        let candidates = [userInfo?.displayName, userInfo?.preferredUsername, session.displayName]
        if let value = candidates.compactMap({ $0?.trimmed }).first(where: { !$0.isEmpty }) { return value }
        return email.split(separator: "@").first.map { String($0).capitalized } ?? "Player"
    }
}

struct LoginProvider: Identifiable, Hashable, Sendable {
    let idpId: String
    let title: String
    let loginProvider: String
    let loginProviderCode: String
    let streamingServiceUrl: String

    var id: String { idpId }

    init(idpId: String, title: String, loginProvider: String, loginProviderCode: String, streamingServiceUrl: String) {
        self.idpId = idpId
        self.title = title.trimmed.isEmpty ? loginProvider : title.trimmed
        self.loginProvider = loginProvider.trimmed.isEmpty ? self.title : loginProvider.trimmed
        self.loginProviderCode = loginProviderCode.trimmed.isEmpty ? self.loginProvider : loginProviderCode.trimmed
        self.streamingServiceUrl = streamingServiceUrl.trimmed
    }

    init(endpoint: GameProviderEndpoint) {
        self.init(
            idpId: endpoint.idpId,
            title: endpoint.loginProviderDisplayName,
            loginProvider: endpoint.loginProvider,
            loginProviderCode: endpoint.loginProviderCode,
            streamingServiceUrl: endpoint.streamingServiceUrl
        )
    }

    static let nvidia = LoginProvider(
        idpId: Jarvis.defaultIdpId,
        title: "NVIDIA",
        loginProvider: "NVIDIA",
        loginProviderCode: "NVIDIA",
        streamingServiceUrl: "https://prod.cloudmatchbeta.nvidiagrid.net/"
    )
}

enum LoginField: Hashable {
    case email
    case callback
}

extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
