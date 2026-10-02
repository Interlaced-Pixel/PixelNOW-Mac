import Foundation


@objc(ActiveSessionObject)
@objcMembers
final class ActiveSessionObject: NSObject {
    let sessionId: String
    let appId: Int
    let status: Int
    let serverIp: String
    let streamingBaseUrl: String
    let signalingUrl: String

    var isResumable: Bool {
        CloudMatchSessionState(rawValue: status)?.isVendorResumable == true
    }

    init(sessionId: String, appId: Int, status: Int, serverIp: String, streamingBaseUrl: String, signalingUrl: String) {
        self.sessionId = sessionId
        self.appId = appId
        self.status = status
        self.serverIp = serverIp
        self.streamingBaseUrl = streamingBaseUrl
        self.signalingUrl = signalingUrl
        super.init()
    }
}

enum ActiveSessionService {
    private static let terminationPollLimit = 12
    private static let terminationPollDelay: TimeInterval = 0.25

    static func loadPersistedActiveSessionId() -> String {
        UserDefaults.standard.string(forKey: AccountStorageKeys.persistedActiveSessionIdKey()) ?? ""
    }

    static func clearPersistedActiveSessionId(_ sessionId: String = "") {
        let current = loadPersistedActiveSessionId()
        guard sessionId.isEmpty || current == sessionId else { return }
        UserDefaults.standard.removeObject(forKey: AccountStorageKeys.persistedActiveSessionIdKey())
    }

    static func fetchActiveSessions(accessToken: String, streamingBaseUrl: String = StreamPreferences.loadSelectedStreamingBaseUrl(), completion: @escaping @Sendable (Bool, [ActiveSessionObject], String) -> Void) {
        guard !accessToken.isEmpty else {
            completion(false, [], "No access token")
            return
        }
        let base = normalizedBaseURL(streamingBaseUrl)
        guard let request = CloudMatchRequestFactory.activeSessionsRequest(baseURLString: base, accessToken: accessToken, deviceId: DeviceIdentity.stableCloudmatchDeviceId()) else {
            completion(false, [], "Invalid sessions URL")
            return
        }
        let networkStart = NetworkLog.start(request, operation: "activeSession.fetch")
        URLSession.shared.dataTask(with: request) { data, response, error in
            NetworkLog.finish(operation: "activeSession.fetch", startedAt: networkStart, data: data, response: response, error: error)
            if let error {
                completion(false, [], error.localizedDescription)
                return
            }
            guard let data else {
                completion(false, [], "No active sessions response")
                return
            }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                completion(false, [], "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
                return
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion(false, [], "Failed to parse sessions response")
                return
            }
            guard CloudMatchResponseParser.requestSucceeded(json) else {
                completion(false, [], "API error from sessions endpoint")
                return
            }
            let sessions = (json["sessions"] as? [[String: Any]] ?? []).compactMap { activeSession(from: $0, streamingBaseUrl: base) }
            completion(true, sessions, "")
        }.resume()
    }

    static func stopSession(accessToken: String, sessionId: String, serverIp: String, streamingBaseUrl: String = StreamPreferences.loadSelectedStreamingBaseUrl(), completion: @escaping @Sendable (Bool, String) -> Void) {
        guard !accessToken.isEmpty else {
            completion(false, "No access token")
            return
        }
        guard !sessionId.isEmpty else {
            completion(false, "No session id")
            return
        }
        clearPersistedActiveSessionId(sessionId)
        let base = CloudMatchRequestFactory.resolvedSessionBaseURL(streamingBaseURL: streamingBaseUrl, serverIP: serverIp)
        guard let request = CloudMatchRequestFactory.stopSessionRequest(baseURLString: base, sessionId: sessionId, accessToken: accessToken, deviceId: DeviceIdentity.stableCloudmatchDeviceId()) else {
            completion(false, "Invalid stop session URL")
            return
        }
        let networkStart = NetworkLog.start(request, operation: "activeSession.stop")
        URLSession.shared.dataTask(with: request) { data, response, error in
            NetworkLog.finish(operation: "activeSession.stop", startedAt: networkStart, data: data, response: response, error: error)
            if let error {
                completion(false, error.localizedDescription)
                return
            }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                completion(false, "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0): \(body)")
                return
            }
            if let data,
               let json = CloudMatchResponseParser.jsonDictionary(data),
               json["requestStatus"] != nil,
               !CloudMatchResponseParser.requestSucceeded(json) {
                completion(false, CloudMatchResponseParser.requestStatusError(data: data, fallback: "Unable to end the active session."))
                return
            }
            waitForTermination(accessToken: accessToken, sessionId: sessionId, streamingBaseUrl: streamingBaseUrl, attempt: 0, completion: completion)
        }.resume()
    }

    private static func waitForTermination(accessToken: String, sessionId: String, streamingBaseUrl: String, attempt: Int, completion: @escaping @Sendable (Bool, String) -> Void) {
        fetchActiveSessions(accessToken: accessToken, streamingBaseUrl: streamingBaseUrl) { success, sessions, error in
            guard success else {
                completion(false, error.isEmpty ? "Unable to confirm that the active session ended." : error)
                return
            }
            guard sessions.contains(where: { $0.sessionId == sessionId }) else {
                completion(true, "")
                return
            }
            guard attempt + 1 < terminationPollLimit else {
                completion(false, "GeForce NOW is still ending the active session. Try again in a moment.")
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + terminationPollDelay) {
                waitForTermination(accessToken: accessToken, sessionId: sessionId, streamingBaseUrl: streamingBaseUrl, attempt: attempt + 1, completion: completion)
            }
        }
    }

    private static func activeSession(from dictionary: [String: Any], streamingBaseUrl: String) -> ActiveSessionObject? {
        guard let descriptor = CloudMatchActiveSessionParser.descriptor(from: dictionary, streamingBaseURL: streamingBaseUrl) else { return nil }
        return ActiveSessionObject(sessionId: descriptor.sessionId, appId: descriptor.appId, status: descriptor.status, serverIp: descriptor.resumeServer, streamingBaseUrl: descriptor.streamingBaseURL, signalingUrl: descriptor.signalingURL)
    }

    private static func normalizedBaseURL(_ value: String) -> String {
        let raw = value.isEmpty ? StreamPreferences.defaultStreamingBaseUrl : value
        var normalized = raw.hasPrefix("http://") || raw.hasPrefix("https://") ? raw : "https://\(raw)"
        if !normalized.hasSuffix("/") { normalized += "/" }
        return normalized
    }

}
