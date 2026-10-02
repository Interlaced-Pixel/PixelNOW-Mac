import AppKit
import CryptoKit
import Darwin
import Foundation

public typealias AuthCallback = @Sendable (_ success: Bool, _ session: AuthSession, _ error: String) -> Void
typealias SimpleCallback = @Sendable (_ success: Bool, _ error: String) -> Void
public typealias DeviceCodeChallengeCallback = @Sendable (_ challenge: DeviceCodeLoginChallenge) -> Void

public struct DeviceCodeLoginChallenge: Equatable, Sendable {
    public let userCode: String
    public let verificationURI: String
    public let verificationURIComplete: String
    public let expiresAt: Date
    public let interval: TimeInterval

    public init(response: StarfleetDeviceAuthorizationResponse) {
        self.userCode = response.userCode
        self.verificationURI = response.verificationURI
        self.verificationURIComplete = response.verificationURIComplete
        self.expiresAt = response.expiresAt
        self.interval = TimeInterval(response.interval)
    }

    public var verificationURL: URL? {
        URL(string: verificationURIComplete.isEmpty ? verificationURI : verificationURIComplete)
    }
}

public final class AuthService: @unchecked Sendable {
    public static let shared = AuthService()
    private static let jarvisConfiguration = JarvisOAuthConfiguration.gfnPC
    static let jarvisAuthStatusDidChangeNotification = Notification.Name("PixelNOW.JarvisAuthStatusDidChange")

    static let oAuthAuthorizeURL = jarvisConfiguration.authorizeURLString
    static let oAuthTokenURL = jarvisConfiguration.tokenURLString
    static let oAuthClientId = jarvisConfiguration.clientId
    static let oAuthRedirectURI = "pixelnow://oauth/callback"
    static let oAuthScope = jarvisConfiguration.scope
    public static let defaultIdpId = jarvisConfiguration.defaultIdpId
    static let defaultUserAgent = jarvisConfiguration.userAgent
    static let oAuthLogoutURL = jarvisConfiguration.logoutURLString

    private static let uuidLock = NSLock()
    nonisolated(unsafe) private static var cachedUUID = ""
    private let jarvisAuthService: JarvisAuthService<JarvisURLSessionTransport>
    private let starfleetService: StarfleetService<StarfleetURLSessionTransport>
    private let statusObservationTask: Task<Void, Never>

    private init() {
        let jarvisService = JarvisAuthService(
            configuration: Self.jarvisConfiguration,
            retryPolicy: .gfnPC,
            transport: JarvisURLSessionTransport(),
            sessionStore: PersistedJarvisSessionStore.shared,
            persistenceMode: .manual
        )
        let starfleetService = StarfleetService(
            configuration: .gfnPC,
            refreshPolicy: .gfnPC,
            retryPolicy: .gfnPC,
            transport: StarfleetURLSessionTransport()
        )
        self.jarvisAuthService = jarvisService
        self.starfleetService = starfleetService
        self.statusObservationTask = Task { [jarvisService] in
            let stream = await jarvisService.monitorLoginStatus()
            for await status in stream {
                await MainActor.run {
                    NotificationCenter.default.post(
                        name: Self.jarvisAuthStatusDidChangeNotification,
                        object: nil,
                        userInfo: ["status": status.rawValue]
                    )
                }
            }
        }
    }

    public func startOAuthLogin(completion: @escaping AuthCallback) {
        startOAuthLogin(providerIdpId: Self.defaultIdpId, completion: completion)
    }

    public func startOAuthLogin(providerIdpId: String, completion: @escaping AuthCallback) {
        let port = findAvailablePort()
        guard port > 0 else {
            DispatchQueue.main.async { completion(false, AuthSession(), "No available port for OAuth callback") }
            return
        }

        let pkce = generatePKCEState()
        let deviceId = generateDeviceId()
        let redirectUri = "http://localhost:\(port)"
        let selectedProviderIdpId = providerIdpId.isEmpty ? Self.defaultIdpId : providerIdpId
        let locale = Foundation.Locale.current.identifier.replacingOccurrences(of: "-", with: "_")

        Task { [weak self] in
            guard let self else { return }
            do {
                _ = await self.jarvisAuthService.sameTabAuthStarted()
                let loginRequest = try await self.jarvisAuthService.createOAuthLoginRequest(
                    deviceId: deviceId,
                    redirectURI: redirectUri,
                    locale: locale,
                    oauthState: pkce,
                    providerIdpId: selectedProviderIdpId
                )
                self.startOAuthCallbackListener(port: port) { [weak self] result in
                    guard let self else { return }
                    switch result {
                    case .success(let query):
                        Task { [weak self] in
                            guard let self else { return }
                            do {
                                let callback = try await self.jarvisAuthService.parseCallback(query: query, expectedState: pkce.state)
                                self.doOAuthTokenExchange(
                                    authCode: callback.code,
                                    codeVerifier: pkce.codeVerifier,
                                    redirectUri: redirectUri,
                                    providerIdpId: selectedProviderIdpId,
                                    completion: completion
                                )
                            } catch {
                                _ = await self.jarvisAuthService.finishLogin(success: false)
                                DispatchQueue.main.async { completion(false, AuthSession(), error.localizedDescription) }
                            }
                        }
                    case .failure(let error):
                        Task { [weak self] in
                            guard let self else { return }
                            _ = await self.jarvisAuthService.finishLogin(success: false)
                            DispatchQueue.main.async { completion(false, AuthSession(), error.localizedDescription) }
                        }
                    }
                } readyHandler: {
                    DispatchQueue.main.async {
                        NSWorkspace.shared.open(loginRequest.url)
                    }
                }
            } catch {
                _ = await self.jarvisAuthService.finishLogin(success: false)
                DispatchQueue.main.async { completion(false, AuthSession(), error.localizedDescription) }
            }
        }
    }

    public func startStarfleetDeviceCodeLogin(providerIdpId: String = AuthService.defaultIdpId, challengeHandler: @escaping DeviceCodeChallengeCallback, completion: @escaping AuthCallback) {
        let selectedProviderIdpId = providerIdpId.isEmpty ? Self.defaultIdpId : providerIdpId
        let deviceId = generateDeviceId()
        let displayName = Host.current().localizedName ?? "PixelNOW Mac"
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = await self.jarvisAuthService.sameTabAuthStarted()
                let response = try await self.starfleetService.requestDeviceAuthorization(deviceId: deviceId, displayName: displayName, providerIdpId: selectedProviderIdpId)
                let challenge = DeviceCodeLoginChallenge(response: response)
                await MainActor.run {
                    challengeHandler(challenge)
                    if let verificationURL = challenge.verificationURL {
                        NSWorkspace.shared.open(verificationURL)
                    }
                }
                var session = Self.authSession(from: try await self.starfleetService.pollDeviceAuthorization(deviceCode: response.deviceCode, interval: challenge.interval, timeout: max(1, response.expiresAt.timeIntervalSinceNow)))
                session = await self.sessionByFillingMissingUserId(session)
                guard AccountStorageKeys.requireUserId(session.userId) != nil else {
                    _ = await self.jarvisAuthService.finishLogin(success: false)
                    DispatchQueue.main.async { completion(false, AuthSession(), "NVIDIA did not return a user id for this session.") }
                    return
                }
                await self.jarvisAuthService.setSession(session)
                self.saveSession(session)
                _ = await self.jarvisAuthService.finishLogin(success: true)
                DispatchQueue.main.async { completion(true, session, "") }
            } catch {
                _ = await self.jarvisAuthService.finishLogin(success: false)
                await self.handleStarfleetFailure(error)
                DispatchQueue.main.async { completion(false, AuthSession(), error.localizedDescription) }
            }
        }
    }

    func refreshSession(completion: @escaping AuthCallback, forceRefresh: Bool = false) {
        let session = loadSavedSession()
        guard session.isAuthenticated else {
            completion(false, AuthSession(), "No saved session available")
            return
        }

        Task { [weak self] in
            guard let self else { return }
            await self.syncBackendSessions(session)
            do {
                let refreshed = Self.authSession(from: try await self.starfleetService.refreshSession(force: forceRefresh || !session.isIdTokenValid))
                await self.jarvisAuthService.setSession(refreshed)
                self.saveSession(refreshed)
                DispatchQueue.main.async { completion(true, refreshed, "") }
            } catch {
                await self.handleStarfleetFailure(error)
                DispatchQueue.main.async { completion(false, session, error.localizedDescription) }
            }
        }
    }

    func refreshSession(forceRefresh: Bool) async throws -> AuthSession {
        try await withCheckedThrowingContinuation { continuation in
            refreshSession(completion: { success, session, message in
                if success {
                    continuation.resume(returning: session)
                } else {
                    continuation.resume(throwing: NSError(
                        domain: "PixelNOW.AuthService",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: message.isEmpty ? "Session refresh failed." : message]
                    ))
                }
            }, forceRefresh: forceRefresh)
        }
    }

    func monitorLoginStatus(replayCurrent: Bool = true) async -> AsyncStream<JarvisAuthStatus> {
        await jarvisAuthService.monitorLoginStatus(replayCurrent: replayCurrent)
    }

    func fetchStarFleetUserInfo(accessToken: String, completion: @escaping @Sendable (Bool, NSDictionary?, String) -> Void) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let userInfo = try await self.starfleetService.fetchUserInfo(accessToken: accessToken)
                let dictionary = self.dictionary(from: userInfo)
                DispatchQueue.main.async { completion(true, dictionary, "") }
            } catch {
                await self.handleStarfleetFailure(error)
                DispatchQueue.main.async { completion(false, nil, error.localizedDescription) }
            }
        }
    }

    func fetchClientToken(accessToken: String, completion: @escaping @Sendable (Bool, String, String) -> Void) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.starfleetService.fetchClientToken(accessToken: accessToken)
                DispatchQueue.main.async { completion(true, result.clientToken, result.expiresIn) }
            } catch {
                await self.handleStarfleetFailure(error)
                DispatchQueue.main.async { completion(false, "", error.localizedDescription) }
            }
        }
    }

    func serverLogout(idToken: String, locale: String, completion: @escaping SimpleCallback) {
        guard !idToken.isEmpty else {
            clearSession()
            completion(true, "")
            return
        }
        let resolvedLocale = locale.isEmpty ? Foundation.Locale.current.identifier.replacingOccurrences(of: "-", with: "_") : locale
        guard let url = StarfleetOAuthRequestFactory.logoutURL(idToken: idToken, locale: resolvedLocale, postLogoutRedirectURI: Self.oAuthRedirectURI, configuration: .gfnPC) else {
            clearSession()
            completion(false, "Invalid logout URL")
            return
        }
        let request = URLRequest(url: url, timeoutInterval: 10)
        let networkStart = NetworkLog.start(request, operation: "auth.serverLogout")
        URLSession.shared.dataTask(with: request) { data, response, error in
            NetworkLog.finish(operation: "auth.serverLogout", startedAt: networkStart, data: data, response: response, error: error)
            DispatchQueue.main.async {
                self.clearSession()
                if let error {
                    completion(false, error.localizedDescription)
                } else {
                    completion(true, "")
                }
            }
        }.resume()
    }

    static func getPersistentDeviceUUID() -> String {
        uuidLock.lock()
        defer { uuidLock.unlock() }
        if !cachedUUID.isEmpty { return cachedUUID }

        let key = "_PersistentDeviceUUID"
        let legacyKey = "GFN_PersistentDeviceUUID"
        let defaults = authUserDefaults()
        if let stored = defaults.string(forKey: key), !stored.isEmpty {
            cachedUUID = stored
            return stored
        }
        if let legacy = defaults.string(forKey: legacyKey), !legacy.isEmpty {
            defaults.set(legacy, forKey: key)
            defaults.synchronize()
            cachedUUID = legacy
            return legacy
        }
        let uuid = UUID().uuidString
        defaults.set(uuid, forKey: key)
        defaults.synchronize()
        cachedUUID = uuid
        return uuid
    }

    func saveSession(_ session: AuthSession) {
        saveSession(session, replacingIdentity: nil)
    }

    private func saveSession(_ session: AuthSession, replacingIdentity: String?) {
        guard session.isAuthenticated, !session.accessToken.isEmpty else { return }
        guard let identity = sessionIdentity(from: session) else { return }

        Task { [jarvisAuthService, starfleetService] in
            await jarvisAuthService.setSession(session)
            await starfleetService.setSession(Self.starfleetSession(from: session))
        }

        let existing = loadAccountDictionaries(activeUserId: nil)
        var accounts = existing.filter {
            let existingIdentity = sessionIdentity(from: $0)
            return existingIdentity != identity && existingIdentity != replacingIdentity
        }
        accounts.insert(dictionary(from: session), at: 0)
        saveAccountDictionaries(accounts, activeUserId: identity)

        let defaults = Self.authUserDefaults()
        defaults.set(true, forKey: "_HasSavedSession")
        defaults.set(identity, forKey: AccountStorageKeys.activeUserIdDefaultsKey)
        defaults.synchronize()
    }

    func saveUserInfo(_ userInfo: JarvisUserInfo) {
        guard userInfo.isAuthenticated else {
            clearUserInfo()
            return
        }
        var session = loadSavedSession()
        guard session.isAuthenticated else { return }
        let oldIdentity = sessionIdentity(from: session)
        if !userInfo.userId.isEmpty { session.userId = userInfo.userId }
        if !userInfo.displayName.isEmpty { session.displayName = userInfo.displayName }
        else if !userInfo.preferredUsername.isEmpty { session.displayName = userInfo.preferredUsername }
        if !userInfo.email.isEmpty { session.email = userInfo.email }
        if !userInfo.idpId.isEmpty { session.idpId = userInfo.idpId }
        saveSession(session, replacingIdentity: oldIdentity)
    }

    func clearUserInfo() {
        var session = loadSavedSession()
        guard session.isAuthenticated else { return }
        let oldIdentity = sessionIdentity(from: session)
        session.displayName = ""
        session.email = ""
        session.idpId = Self.defaultIdpId
        saveSession(session, replacingIdentity: oldIdentity)
    }

    func loadSavedSession() -> AuthSession {
        let defaults = Self.authUserDefaults()
        var storedActiveUserId: String?
        let accounts = loadAccountDictionaries(activeUserId: &storedActiveUserId)
        let preferredUserId = resolvedActiveUserId(
            preferredUserId: defaults.string(forKey: AccountStorageKeys.activeUserIdDefaultsKey) ?? storedActiveUserId,
            accounts: accounts
        )
        var fallback: NSDictionary?

        for account in accounts {
            guard let identity = sessionIdentity(from: account) else { continue }
            if fallback == nil { fallback = account }
            if let preferredUserId, identity == preferredUserId {
                let session = session(from: account)
                if session.isAuthenticated { return session }
            }
        }

        if let fallback {
            let session = session(from: fallback)
            if let identity = sessionIdentity(from: fallback) {
                defaults.set(identity, forKey: AccountStorageKeys.activeUserIdDefaultsKey)
            }
            defaults.set(true, forKey: "_HasSavedSession")
            defaults.synchronize()
            return session
        }

        if !defaults.bool(forKey: "_HasSavedSession") && !defaults.bool(forKey: "GFN_HasSavedSession") {
            return AuthSession()
        }
        let legacy = loadLegacySingleSession()
        if legacy.isAuthenticated { saveSession(legacy) }
        return legacy
    }

    func loadSavedSessions() -> [AuthSession] {
        var sessions = loadAccountDictionaries(activeUserId: nil).map(session).filter(\.isAuthenticated)
        if sessions.isEmpty {
            let legacy = loadLegacySingleSession()
            if legacy.isAuthenticated { sessions.append(legacy) }
        }
        return sessions
    }

    func loadSavedSession(forUserId userId: String) -> AuthSession {
        guard let userId = AccountStorageKeys.requireUserId(userId) else { return AuthSession() }
        for account in loadAccountDictionaries(activeUserId: nil) {
            if sessionIdentity(from: account) == userId {
                return session(from: account)
            }
        }
        return AuthSession()
    }

    func setActiveSessionUserId(_ userId: String) {
        guard let userId = AccountStorageKeys.requireUserId(userId) else { return }
        var storedActiveUserId: String?
        let accounts = loadAccountDictionaries(activeUserId: &storedActiveUserId)
        guard accounts.contains(where: { sessionIdentity(from: $0) == userId }) else { return }
        saveAccountDictionaries(accounts, activeUserId: userId)
        let defaults = Self.authUserDefaults()
        defaults.set(userId, forKey: AccountStorageKeys.activeUserIdDefaultsKey)
        defaults.set(true, forKey: "_HasSavedSession")
        defaults.synchronize()
        let session = loadSavedSession(forUserId: userId)
        guard session.isAuthenticated else { return }
        Task { [weak self] in
            await self?.syncBackendSessions(session)
        }
    }

    func removeSavedSession(userId: String) {
        guard let userId = AccountStorageKeys.requireUserId(userId) else { return }
        var storedActiveUserId: String?
        let existing = loadAccountDictionaries(activeUserId: &storedActiveUserId)
        let currentActive = resolvedActiveUserId(
            preferredUserId: AccountStorageKeys.activeUserId() ?? storedActiveUserId,
            accounts: existing
        )
        let wasActive = currentActive == userId
        let accounts = existing.filter { sessionIdentity(from: $0) != userId }
        let newActive = wasActive ? accounts.compactMap(sessionIdentity).first : currentActive
        saveAccountDictionaries(accounts, activeUserId: newActive)
        let defaults = Self.authUserDefaults()
        if let newActive, !newActive.isEmpty {
            defaults.set(newActive, forKey: AccountStorageKeys.activeUserIdDefaultsKey)
            defaults.set(true, forKey: "_HasSavedSession")
        } else {
            defaults.removeObject(forKey: AccountStorageKeys.activeUserIdDefaultsKey)
            defaults.removeObject(forKey: "_HasSavedSession")
        }
        defaults.synchronize()
    }

    func clearSession() {
        let defaults = Self.authUserDefaults()
        if let activeUserId = AccountStorageKeys.requireUserId(defaults.string(forKey: AccountStorageKeys.activeUserIdDefaultsKey) ?? "") {
            removeSavedSession(userId: activeUserId)
            Task { [jarvisAuthService, starfleetService] in
                await jarvisAuthService.clearSession()
                await starfleetService.clearSession()
            }
            return
        }
        [accountsFilePath(), sessionFilePath(), legacySessionFilePath()].forEach { path in
            if let path { try? FileManager.default.removeItem(atPath: path) }
        }
        defaults.removeObject(forKey: "_HasSavedSession")
        defaults.removeObject(forKey: "GFN_HasSavedSession")
        defaults.removeObject(forKey: AccountStorageKeys.activeUserIdDefaultsKey)
        defaults.synchronize()
        Task { [jarvisAuthService, starfleetService] in
            await jarvisAuthService.clearSession()
            await starfleetService.clearSession()
        }
    }

    func getStayLoggedIn() -> Bool {
        let defaults = Self.authUserDefaults()
        if defaults.object(forKey: "_StayLoggedIn") != nil { return defaults.bool(forKey: "_StayLoggedIn") }
        if defaults.object(forKey: "GFN_StayLoggedIn") != nil { return defaults.bool(forKey: "GFN_StayLoggedIn") }
        return true
    }

    func setStayLoggedIn(_ value: Bool) {
        let defaults = Self.authUserDefaults()
        defaults.set(value, forKey: "_StayLoggedIn")
        defaults.synchronize()
    }

    static func parseOAuthSession(json: NSDictionary) -> AuthSession {
        authSession(from: StarfleetSessionParser.parseTokenResponse(json as? [String: Any] ?? [:], defaultIdpId: defaultIdpId))
    }

    static func parseQueryString(_ query: String?) -> NSDictionary {
        let params = NSMutableDictionary()
        for (key, value) in JarvisSessionParser.parseQueryString(query) {
            params[key] = value
        }
        return params
    }

    private func doOAuthTokenExchange(
        authCode: String,
        codeVerifier: String,
        redirectUri: String,
        providerIdpId: String,
        completion: @escaping AuthCallback
    ) {
        Task { [weak self] in
            guard let self else { return }
            do {
                var session = Self.authSession(from: try await self.starfleetService.exchangeAuthorizationCode(authCode: authCode, redirectURI: redirectUri, codeVerifier: codeVerifier, providerIdpId: providerIdpId))
                session = await self.sessionByFillingMissingUserId(session)
                guard AccountStorageKeys.requireUserId(session.userId) != nil else {
                    _ = await self.jarvisAuthService.finishLogin(success: false)
                    DispatchQueue.main.async { completion(false, AuthSession(), "NVIDIA did not return a user id for this session.") }
                    return
                }
                await self.jarvisAuthService.setSession(session)
                self.saveSession(session)
                _ = await self.jarvisAuthService.finishLogin(success: true)
                DispatchQueue.main.async { completion(true, session, "") }
            } catch {
                _ = await self.jarvisAuthService.finishLogin(success: false)
                DispatchQueue.main.async { completion(false, AuthSession(), error.localizedDescription) }
            }
        }
    }

    private func syncBackendSessions(_ session: AuthSession) async {
        await jarvisAuthService.setSession(session)
        await starfleetService.setSession(Self.starfleetSession(from: session))
    }

    private func handleStarfleetFailure(_ error: Error) async {
        guard (error as? StarfleetAuthError)?.category == .authorization else { return }
        _ = await jarvisAuthService.finishLogin(success: false)
    }

    private func dictionary(from userInfo: StarfleetUserInfo) -> NSDictionary {
        let dictionary = NSMutableDictionary()
        put(userInfo.userId, key: "sub", into: dictionary)
        put(userInfo.userId, key: "userId", into: dictionary)
        put(userInfo.externalId, key: "external_id", into: dictionary)
        put(userInfo.externalId, key: "externalId", into: dictionary)
        put(userInfo.idpId, key: "idp_id", into: dictionary)
        put(userInfo.idpId, key: "idpId", into: dictionary)
        put(userInfo.preferredUsername, key: "preferred_username", into: dictionary)
        put(userInfo.displayName, key: "name", into: dictionary)
        put(userInfo.displayName, key: "displayName", into: dictionary)
        put(userInfo.email, key: "email", into: dictionary)
        return dictionary
    }

    private func startOAuthCallbackListener(
        port: Int,
        completion: @escaping @Sendable (Result<String, Error>) -> Void,
        readyHandler: @escaping @Sendable () -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let socketDescriptor = socket(AF_INET, SOCK_STREAM, 0)
            guard socketDescriptor >= 0 else {
                completion(.failure(ServiceError("Failed to create OAuth callback listener")))
                return
            }
            var reuse = Int32(1)
            setsockopt(socketDescriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_addr.s_addr = in_addr_t(INADDR_LOOPBACK).bigEndian
            address.sin_port = in_port_t(port).bigEndian
            let bindResult = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(socketDescriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bindResult == 0, listen(socketDescriptor, 1) == 0 else {
                close(socketDescriptor)
                completion(.failure(ServiceError("Failed to bind OAuth callback listener")))
                return
            }
            readyHandler()
            let clientSocket = accept(socketDescriptor, nil, nil)
            close(socketDescriptor)
            guard clientSocket >= 0 else {
                completion(.failure(ServiceError("Failed to accept OAuth callback")))
                return
            }
            var buffer = [UInt8](repeating: 0, count: 4096)
            let byteCount = recv(clientSocket, &buffer, buffer.count - 1, 0)
            let body = "<!doctype html><html><head><meta charset=\"utf-8\"><title>PixelNOW Sign In</title></head><body style=\"background:#050807;color:#f1fff7;font:16px -apple-system,BlinkMacSystemFont,sans-serif;display:grid;place-items:center;min-height:100vh;margin:0\"><main><h1>Sign in complete</h1><p>You can close this window and return to PixelNOW.</p></main><script>setTimeout(function(){window.close()},1200)</script></body></html>"
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nConnection: close\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
            _ = response.withCString { send(clientSocket, $0, strlen($0), 0) }
            close(clientSocket)

            guard byteCount > 0 else {
                completion(.failure(ServiceError("Empty OAuth callback request")))
                return
            }
            let request = String(decoding: buffer.prefix(byteCount), as: UTF8.self)
            guard let pathStart = request.range(of: "GET ")?.upperBound,
                  let pathEnd = request[pathStart...].firstIndex(of: " ") else {
                completion(.failure(ServiceError("Invalid OAuth callback request")))
                return
            }
            let path = String(request[pathStart..<pathEnd])
            let query = path.split(separator: "?", maxSplits: 1).dropFirst().first.map(String.init)
            completion(.success(query ?? ""))
        }
    }

    private func findAvailablePort() -> Int {
        for port in [2259, 6460, 7119, 8870, 9096] {
            let probeSocket = socket(AF_INET, SOCK_STREAM, 0)
            if probeSocket >= 0 {
                var address = sockaddr_in()
                address.sin_family = sa_family_t(AF_INET)
                address.sin_addr.s_addr = in_addr_t(INADDR_LOOPBACK).bigEndian
                address.sin_port = in_port_t(port).bigEndian
                let hasListener = withUnsafePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        connect(probeSocket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
                    }
                }
                close(probeSocket)
                if hasListener { continue }
            }
            let testSocket = socket(AF_INET, SOCK_STREAM, 0)
            if testSocket < 0 { continue }
            var reuse = Int32(1)
            setsockopt(testSocket, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_addr.s_addr = in_addr_t(INADDR_LOOPBACK).bigEndian
            address.sin_port = in_port_t(port).bigEndian
            let canBind = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(testSocket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
                }
            }
            close(testSocket)
            if canBind { return port }
        }
        return 0
    }

    private func generatePKCEState() -> JarvisOAuthState {
        let verifier = generateRandomString(length: 64)
        return JarvisOAuthState(
            codeVerifier: verifier,
            codeChallenge: base64URLEncodedSHA256(verifier),
            state: generateRandomString(length: 32),
            nonce: generateRandomString(length: 32)
        )
    }

    private func generateRandomString(length: Int) -> String {
        let characters = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return String((0..<length).compactMap { _ in characters.randomElement() })
    }

    private func base64URLEncodedSHA256(_ value: String) -> String {
        Data(SHA256.hash(data: Data(value.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func generateDeviceId() -> String {
        var hostnameBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let hostname = gethostname(&hostnameBuffer, hostnameBuffer.count) == 0
            ? String(decoding: hostnameBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            : "unknown"
        let user = ProcessInfo.processInfo.environment["USER"] ?? "unknown"
        return SHA256.hash(data: Data("\(hostname):\(user):pixelnow-stable".utf8)).map { String(format: "%02x", $0) }.joined()
    }

    var activeUserId: String {
        AccountStorageKeys.activeUserId() ?? ""
    }

    func applyActiveSessionToBackends() async {
        let session = loadSavedSession()
        guard session.isAuthenticated else { return }
        await syncBackendSessions(session)
    }

    func serverLogout(idToken: String, locale: String) async -> Bool {
        await withCheckedContinuation { continuation in
            serverLogout(idToken: idToken, locale: locale) { success, _ in
                continuation.resume(returning: success)
            }
        }
    }

    private static func authUserDefaults() -> UserDefaults {
        AccountStorageKeys.authUserDefaults()
    }

    private func applicationSupportBasePath() -> String? {
        let environment = ProcessInfo.processInfo.environment
        if let overridePath = environment["PIXELNOW_AUTH_APPLICATION_SUPPORT_DIR"]
            ?? environment["_AUTH_APPLICATION_SUPPORT_DIR"],
           !overridePath.isEmpty {
            return overridePath
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.path
    }

    private func sessionStorageDirectory() -> String? {
        guard let basePath = applicationSupportBasePath(), !basePath.isEmpty else { return nil }
        let directory = (basePath as NSString).appendingPathComponent("PixelNOW")
        if !FileManager.default.fileExists(atPath: directory) {
            try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        return directory
    }

    private func legacySessionFilePath() -> String? {
        guard let basePath = applicationSupportBasePath(), !basePath.isEmpty else { return nil }
        return ((basePath as NSString).appendingPathComponent("com.nvidia.geforcenow") as NSString).appendingPathComponent("session.plist")
    }

    private func sessionFilePath() -> String? {
        sessionStorageDirectory().map { ($0 as NSString).appendingPathComponent("session.plist") }
    }

    private func accountsFilePath() -> String? {
        sessionStorageDirectory().map { ($0 as NSString).appendingPathComponent("accounts.plist") }
    }

    private func sessionFilePathForRead() -> String? {
        if let path = sessionFilePath(), FileManager.default.fileExists(atPath: path) { return path }
        if let path = legacySessionFilePath(), FileManager.default.fileExists(atPath: path) { return path }
        return sessionFilePath()
    }

    private func loadLegacySingleSession() -> AuthSession {
        guard let path = sessionFilePathForRead(), let dictionary = loadPropertyListDictionary(path: path) else { return AuthSession() }
        return session(from: dictionary)
    }

    private func loadAccountDictionaries(activeUserId: UnsafeMutablePointer<String?>?) -> [NSDictionary] {
        let store = accountsFilePath().flatMap(loadPropertyListDictionary)
        activeUserId?.pointee = store?["active_user_id"] as? String
        let accounts = (store?["accounts"] as? [NSDictionary] ?? []).map(accountDictionaryByFillingMissingUserId)
        return accounts.filter { sessionIdentity(from: $0) != nil }
    }

    private func saveAccountDictionaries(_ accounts: [NSDictionary], activeUserId: String?) {
        guard let path = accountsFilePath() else { return }
        let store = NSMutableDictionary()
        store["accounts"] = accounts
        if let activeUserId, !activeUserId.isEmpty { store["active_user_id"] = activeUserId }
        guard let data = try? PropertyListSerialization.data(fromPropertyList: store, format: .xml, options: 0) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }

    private func loadPropertyListDictionary(path: String) -> NSDictionary? {
        guard FileManager.default.fileExists(atPath: path), let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? NSDictionary
    }

    private func sessionIdentity(from session: AuthSession) -> String? {
        AccountStorageKeys.requireUserId(session.userId)
    }

    private func sessionIdentity(from dictionary: NSDictionary) -> String? {
        AccountStorageKeys.requireUserId(dictionary["user_id"] as? String ?? "")
    }

    private func resolvedActiveUserId(preferredUserId: String?, accounts: [NSDictionary]) -> String? {
        if let preferredUserId, accounts.contains(where: { sessionIdentity(from: $0) == preferredUserId }) {
            return preferredUserId
        }
        if let preferredUserId {
            let normalized = preferredUserId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let match = accounts.first(where: { ($0["email"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalized }) {
                return sessionIdentity(from: match)
            }
        }
        return accounts.compactMap(sessionIdentity).first
    }

    private func accountDictionaryByFillingMissingUserId(_ dictionary: NSDictionary) -> NSDictionary {
        if sessionIdentity(from: dictionary) != nil { return dictionary }
        let idToken = dictionary["id_token"] as? String ?? ""
        let userId = (StarfleetTokenParser.jwtClaims(idToken)["sub"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !userId.isEmpty else { return dictionary }
        let updated = NSMutableDictionary(dictionary: dictionary)
        updated["user_id"] = userId
        return updated
    }

    private func sessionByFillingMissingUserId(_ session: AuthSession) async -> AuthSession {
        if AccountStorageKeys.requireUserId(session.userId) != nil { return session }
        var updated = session
        let jwtUserId = (StarfleetTokenParser.jwtClaims(session.idToken)["sub"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !jwtUserId.isEmpty {
            updated.userId = jwtUserId
            return updated
        }
        guard !session.accessToken.isEmpty else { return updated }
        do {
            let userInfo = try await starfleetService.fetchUserInfo(accessToken: session.accessToken)
            if !userInfo.userId.isEmpty { updated.userId = userInfo.userId }
            if updated.displayName.isEmpty { updated.displayName = userInfo.displayName }
            if updated.email.isEmpty { updated.email = userInfo.email }
            if updated.idpId.isEmpty { updated.idpId = userInfo.idpId }
        } catch {
            return updated
        }
        return updated
    }

    private func dictionary(from session: AuthSession) -> NSDictionary {
        let dictionary = NSMutableDictionary()
        put(session.accessToken, key: "access_token", into: dictionary)
        put(session.idToken, key: "id_token", into: dictionary)
        put(session.refreshToken, key: "refresh_token", into: dictionary)
        put(session.clientToken, key: "client_token", into: dictionary)
        put(session.userId, key: "user_id", into: dictionary)
        put(session.displayName, key: "display_name", into: dictionary)
        put(session.email, key: "email", into: dictionary)
        put(session.membershipTier, key: "membership_tier", into: dictionary)
        put(session.idpId, key: "idp_id", into: dictionary)
        dictionary["expires_at"] = session.expiresAt
        dictionary["access_token_expiry"] = session.accessTokenExpiry
        dictionary["client_token_expiry"] = session.clientTokenExpiry
        dictionary["client_token_expiry_length"] = session.clientTokenExpiryLength
        dictionary["id_token_expiry"] = session.idTokenExpiry
        return dictionary
    }

    private func session(from dictionary: NSDictionary) -> AuthSession {
        guard let accessToken = dictionary["access_token"] as? String, !accessToken.isEmpty else { return AuthSession() }
        var session = AuthSession()
        session.accessToken = accessToken
        session.idToken = dictionary["id_token"] as? String ?? ""
        session.refreshToken = dictionary["refresh_token"] as? String ?? ""
        session.clientToken = dictionary["client_token"] as? String ?? ""
        session.userId = dictionary["user_id"] as? String ?? ""
        session.displayName = dictionary["display_name"] as? String ?? ""
        session.email = dictionary["email"] as? String ?? ""
        session.membershipTier = dictionary["membership_tier"] as? String ?? "Free"
        session.idpId = dictionary["idp_id"] as? String ?? Self.defaultIdpId
        session.expiresAt = JarvisSessionParser.int64Value(dictionary["expires_at"]) ?? 0
        session.accessTokenExpiry = JarvisSessionParser.int64Value(dictionary["access_token_expiry"]) ?? 0
        session.clientTokenExpiry = JarvisSessionParser.int64Value(dictionary["client_token_expiry"]) ?? 0
        session.clientTokenExpiryLength = JarvisSessionParser.int64Value(dictionary["client_token_expiry_length"]) ?? 0
        session.idTokenExpiry = JarvisSessionParser.int64Value(dictionary["id_token_expiry"]) ?? 0
        session.isAuthenticated = true
        return session
    }

    private static func authSession(from session: StarfleetSession) -> AuthSession {
        var mapped = AuthSession()
        mapped.accessToken = session.accessToken
        mapped.idToken = session.idToken
        mapped.refreshToken = session.refreshToken
        mapped.clientToken = session.clientToken
        mapped.userId = session.userId
        mapped.displayName = session.displayName
        mapped.email = session.email
        mapped.idpId = session.idpId
        mapped.expiresAt = session.expiresAt
        mapped.isAuthenticated = session.isAuthenticated
        mapped.clientTokenExpiry = session.clientTokenExpiry
        mapped.clientTokenExpiryLength = session.clientTokenExpiryLength
        mapped.idTokenExpiry = session.idTokenExpiry
        mapped.accessTokenExpiry = session.accessTokenExpiry
        if !session.idToken.isEmpty {
            mapped.membershipTier = StarfleetTokenParser.jwtClaims(session.idToken)["membership_tier"] as? String ?? "Free"
        }
        return mapped
    }

    private static func starfleetSession(from session: AuthSession) -> StarfleetSession {
        StarfleetSession(
            accessToken: session.accessToken,
            idToken: session.idToken,
            refreshToken: session.refreshToken,
            userId: session.userId,
            displayName: session.displayName,
            email: session.email,
            idpId: session.idpId.isEmpty ? defaultIdpId : session.idpId,
            expiresAt: session.expiresAt,
            isAuthenticated: session.isAuthenticated,
            clientToken: session.clientToken,
            clientTokenExpiry: session.clientTokenExpiry,
            clientTokenExpiryLength: session.clientTokenExpiryLength,
            idTokenExpiry: session.idTokenExpiry,
            accessTokenExpiry: session.accessTokenExpiry
        )
    }

    private func put(_ value: String, key: String, into dictionary: NSMutableDictionary) {
        if !value.isEmpty { dictionary[key] = value }
    }

    private struct ServiceError: LocalizedError, Sendable {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}

@objcMembers
@objc(AuthSessionObject)
final class AuthSessionObject: NSObject {
    var accessToken: String
    var idToken: String
    var refreshToken: String
    var userId: String
    var displayName: String
    var email: String
    var membershipTier: String
    var idpId: String
    var expiresAt: Int64
    var isAuthenticated: Bool
    var clientToken: String
    var clientTokenExpiry: Int64
    var clientTokenExpiryLength: Int64
    var idTokenExpiry: Int64
    var accessTokenExpiry: Int64

    override init() {
        accessToken = ""
        idToken = ""
        refreshToken = ""
        userId = ""
        displayName = ""
        email = ""
        membershipTier = ""
        idpId = ""
        expiresAt = 0
        isAuthenticated = false
        clientToken = ""
        clientTokenExpiry = 0
        clientTokenExpiryLength = 0
        idTokenExpiry = 0
        accessTokenExpiry = 0
    }

    init(session: AuthSession) {
        accessToken = session.accessToken
        idToken = session.idToken
        refreshToken = session.refreshToken
        userId = session.userId
        displayName = session.displayName
        email = session.email
        membershipTier = session.membershipTier
        idpId = session.idpId
        expiresAt = session.expiresAt
        isAuthenticated = session.isAuthenticated
        clientToken = session.clientToken
        clientTokenExpiry = session.clientTokenExpiry
        clientTokenExpiryLength = session.clientTokenExpiryLength
        idTokenExpiry = session.idTokenExpiry
        accessTokenExpiry = session.accessTokenExpiry
    }

    var swiftValue: AuthSession {
        var session = AuthSession()
        session.accessToken = accessToken
        session.idToken = idToken
        session.refreshToken = refreshToken
        session.userId = userId
        session.displayName = displayName
        session.email = email
        session.membershipTier = membershipTier
        session.idpId = idpId
        session.expiresAt = expiresAt
        session.isAuthenticated = isAuthenticated
        session.clientToken = clientToken
        session.clientTokenExpiry = clientTokenExpiry
        session.clientTokenExpiryLength = clientTokenExpiryLength
        session.idTokenExpiry = idTokenExpiry
        session.accessTokenExpiry = accessTokenExpiry
        return session
    }
}

@objc(AuthServiceDirect)
public final class AuthServiceDirect: NSObject, @unchecked Sendable {
    @objc(shared)
    public static let shared = AuthServiceDirect()

    @objc(startOAuthLoginWithProviderIdpId:completion:)
    func startOAuthLogin(providerIdpId: String, completion: @escaping @Sendable (Bool, AuthSessionObject, String) -> Void) {
        AuthService.shared.startOAuthLogin(providerIdpId: providerIdpId) { success, session, error in
            completion(success, AuthSessionObject(session: session), error)
        }
    }

    @objc(refreshSessionForce:completion:)
    func refreshSession(force: Bool, completion: @escaping @Sendable (Bool, AuthSessionObject, String) -> Void) {
        AuthService.shared.refreshSession(completion: { success, session, error in
            completion(success, AuthSessionObject(session: session), error)
        }, forceRefresh: force)
    }

    @objc(fetchStarFleetUserInfoWithAccessToken:completion:)
    func fetchStarFleetUserInfo(accessToken: String, completion: @escaping @Sendable (Bool, NSDictionary?, String) -> Void) {
        AuthService.shared.fetchStarFleetUserInfo(accessToken: accessToken, completion: completion)
    }

    @objc(fetchClientTokenWithAccessToken:completion:)
    func fetchClientToken(accessToken: String, completion: @escaping @Sendable (Bool, String, String) -> Void) {
        AuthService.shared.fetchClientToken(accessToken: accessToken, completion: completion)
    }

    @objc(serverLogoutWithIdToken:locale:completion:)
    func serverLogout(idToken: String, locale: String, completion: @escaping @Sendable (Bool, String) -> Void) {
        AuthService.shared.serverLogout(idToken: idToken, locale: locale, completion: completion)
    }

    @objc(saveSession:)
    func saveSession(_ session: AuthSessionObject) {
        AuthService.shared.saveSession(session.swiftValue)
    }

    @objc(loadSavedSession)
    func loadSavedSession() -> AuthSessionObject {
        AuthSessionObject(session: AuthService.shared.loadSavedSession())
    }

    @objc(loadSavedSessions)
    func loadSavedSessions() -> [AuthSessionObject] {
        AuthService.shared.loadSavedSessions().map(AuthSessionObject.init(session:))
    }

    @objc(loadSavedSessionForUserId:)
    func loadSavedSession(userId: String) -> AuthSessionObject {
        AuthSessionObject(session: AuthService.shared.loadSavedSession(forUserId: userId))
    }

    @objc(setActiveSessionUserId:)
    func setActiveSessionUserId(_ userId: String) {
        AuthService.shared.setActiveSessionUserId(userId)
    }

    @objc(removeSavedSessionForUserId:)
    func removeSavedSession(userId: String) {
        AuthService.shared.removeSavedSession(userId: userId)
    }

    @objc(clearSession)
    func clearSession() {
        AuthService.shared.clearSession()
    }

    @objc(getStayLoggedIn)
    public func getStayLoggedIn() -> Bool {
        AuthService.shared.getStayLoggedIn()
    }

    @objc(setStayLoggedIn:)
    public func setStayLoggedIn(_ value: Bool) {
        AuthService.shared.setStayLoggedIn(value)
    }

    @objc(parseOAuthSession:)
    static func parseOAuthSession(_ json: NSDictionary) -> AuthSessionObject {
        AuthSessionObject(session: AuthService.parseOAuthSession(json: json))
    }

    @objc(parseQueryString:)
    static func parseQueryString(_ query: String?) -> NSDictionary {
        AuthService.parseQueryString(query)
    }

    @objc(getPersistentDeviceUUID)
    static func getPersistentDeviceUUID() -> String {
        AuthService.getPersistentDeviceUUID()
    }
}
