import Foundation

public struct NetworkLogContext: Sendable {
    public let startedAt: Date
    public let requestSummary: String

    fileprivate init(startedAt: Date, requestSummary: String) {
        self.startedAt = startedAt
        self.requestSummary = requestSummary
    }

    fileprivate var durationMilliseconds: Int {
        max(0, Int(Date().timeIntervalSince(startedAt) * 1_000))
    }
}

public enum NetworkLog {
    public static func start(_ request: URLRequest, operation: String) -> NetworkLogContext {
        startContext(request, operation: operation)
    }

    public static func finish(operation: String, startedAt context: NetworkLogContext, data: Data?, response: URLResponse?, error: Error?) {
        let durationMilliseconds = context.durationMilliseconds
        let byteCount = data?.count ?? 0
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        let outcome = httpOutcome(statusCode: statusCode, error: error)

        if let error {
            let level = failureLogLevel(operation: operation, error: error)
            let message = logMessage(area: "Network", message: "HTTP request failed operation=\(operation) request=\(context.requestSummary) status=\(statusText(statusCode)) duration=\(durationMilliseconds)ms bytes=\(byteCount) error=\(error.localizedDescription)")
            if level == "error" {
                Log.error(.app, message)
            } else {
                Log.warning(.app, message)
            }
            return
        }

        let message = logMessage(area: "Network", message: "HTTP request finished operation=\(operation) request=\(context.requestSummary) status=\(statusText(statusCode)) duration=\(durationMilliseconds)ms bytes=\(byteCount)")
        guard outcome != "success" || shouldLogSuccessfulFinish(operation: operation, durationMilliseconds: durationMilliseconds) else { return }
        if outcome == "success" {
            Log.info(.app, message)
        } else {
            Log.warning(.app, message)
        }
    }

    public static func graphQLStart(_ request: URLRequest, operationName: String, queryHash: String, variables: NSDictionary?) -> NetworkLogContext {
        graphQLStartContext(request, operationName: operationName, queryHash: queryHash, variables: variables)
    }

    public static func graphQLFinish(operationName: String, queryHash: String, startedAt context: NetworkLogContext, data: Data?, response: URLResponse?, error: Error?, responseMessage: String) {
        let durationMilliseconds = context.durationMilliseconds
        let byteCount = data?.count ?? 0
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        let responseDetail = graphQLErrorDetail(data: data)
        let hasGraphQLError = !responseMessage.isEmpty || !responseDetail.isEmpty
        let outcome = error == nil && !hasGraphQLError && ((200..<400).contains(statusCode) || statusCode == -1) ? "success" : (error == nil ? "graphql_error" : "network_error")

        if let error {
            let level = failureLogLevel(operation: "graphql.\(operationName)", error: error)
            let message = logMessage(area: "GraphQL", message: "Request failed operation=\(operationName) hash=\(queryHash) request=\(context.requestSummary) status=\(statusText(statusCode)) duration=\(durationMilliseconds)ms bytes=\(byteCount) error=\(error.localizedDescription)")
            if level == "error" {
                Log.error(.app, message)
            } else {
                Log.warning(.app, message)
            }
            return
        }

        let detailText = responseDetail.isEmpty ? "" : " detail=\(responseDetail)"
        let message = logMessage(area: "GraphQL", message: "Request finished operation=\(operationName) hash=\(queryHash) request=\(context.requestSummary) status=\(statusText(statusCode)) duration=\(durationMilliseconds)ms bytes=\(byteCount) message=\(responseMessage.isEmpty ? "ok" : responseMessage)\(detailText)")
        if outcome == "success" {
            Log.info(.app, message)
        } else {
            Log.warning(.app, message)
        }
    }

    public static func webSocketEvent(_ event: String, url: URL?, detail: String = "") {
        guard shouldLogWebSocketEvent(event) else { return }
        let detailText = detail.isEmpty ? "" : " detail=\(sanitizedDetail(detail))"
        Log.info(.app, logMessage(area: "WebSocket", message: "Event \(event) url=\(sanitizedURL(url))\(detailText)"))
    }

    public static func webSocketError(_ event: String, url: URL?, error: Error?) {
        let level = failureLogLevel(operation: "websocket.\(event)", error: error)
        let message = logMessage(area: "WebSocket", message: "Event \(event) failed url=\(sanitizedURL(url)) error=\(error?.localizedDescription ?? "unknown")")
        if level == "error" {
            Log.error(.app, message)
        } else {
            Log.warning(.app, message)
        }
    }

    private static func startContext(_ request: URLRequest, operation: String) -> NetworkLogContext {
        let context = NetworkLogContext(startedAt: Date(), requestSummary: requestSummary(request))
        if shouldLogStart(operation: operation) {
            Log.info(.app, logMessage(area: "Network", message: "HTTP request started operation=\(operation) request=\(context.requestSummary)"))
        }
        return context
    }

    private static func graphQLStartContext(_ request: URLRequest, operationName: String, queryHash: String, variables: NSDictionary?) -> NetworkLogContext {
        let context = NetworkLogContext(startedAt: Date(), requestSummary: requestSummary(request))
        if shouldLogGraphQLStart(operationName: operationName) {
            Log.info(.app, logMessage(area: "GraphQL", message: "Request started operation=\(operationName) hash=\(queryHash) variableKeys=\(sortedKeys(in: variables)) request=\(context.requestSummary)"))
        }
        return context
    }

    private static func requestSummary(_ request: URLRequest) -> String {
        let method = request.httpMethod?.isEmpty == false ? request.httpMethod ?? "GET" : "GET"
        return "\(method) \(sanitizedURL(request.url))"
    }

    static func sanitizedURL(_ url: URL?) -> String {
        guard let url else { return "unknown-url" }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.host ?? "unknown-url" }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        return Log.sanitizedMessage(components.string ?? url.host ?? "unknown-url")
    }

    private static func sortedKeys(in dictionary: NSDictionary?) -> String {
        guard let dictionary else { return "[]" }
        let keys = dictionary.allKeys.compactMap { $0 as? String }.sorted()
        return "[\(keys.joined(separator: ","))]"
    }

    private static func shouldLogStart(operation: String) -> Bool {
        !["stream.measureRegion", "catalog.image"].contains(operation)
    }

    private static func shouldLogSuccessfulFinish(operation: String, durationMilliseconds: Int) -> Bool {
        if operation == "stream.measureRegion" { return durationMilliseconds >= 1_000 }
        if operation == "catalog.image" { return false }
        return true
    }

    private static func failureLogLevel(operation: String, error: Error?) -> String {
        if operation == "stream.measureRegion" { return "warning" }
        guard let error else { return "warning" }
        let urlErrorCode = (error as? URLError)?.code
        if urlErrorCode == .cancelled { return "warning" }
        if urlErrorCode == .timedOut { return "warning" }
        if urlErrorCode == .cannotFindHost { return "warning" }
        if urlErrorCode == .cannotConnectToHost { return "warning" }
        if urlErrorCode == .networkConnectionLost { return "warning" }
        if urlErrorCode == .notConnectedToInternet { return "warning" }
        if urlErrorCode == .serverCertificateUntrusted { return "warning" }
        if urlErrorCode == .serverCertificateHasBadDate { return "warning" }
        if urlErrorCode == .serverCertificateHasUnknownRoot { return "warning" }
        if urlErrorCode == .serverCertificateNotYetValid { return "warning" }
        if urlErrorCode == .secureConnectionFailed { return "warning" }
        if urlErrorCode == .badURL { return "warning" }
        return "error"
    }

    private static func shouldLogGraphQLStart(operationName: String) -> Bool {
        operationName != "appMetaData"
    }

    private static func shouldLogWebSocketEvent(_ event: String) -> Bool {
        if ["iceCandidateReceived", "receiveStopped"].contains(event) {
            return ProcessInfo.processInfo.environment["PIXELNOW_VERBOSE_LOGS"] == "1"
        }
        return true
    }

    private static func sanitizedDetail(_ detail: String) -> String {
        Log.sanitizedMessage(detail.replacingOccurrences(
            of: #"(?i)(x-nv-sessionid[.=])[^\s,;]+"#,
            with: "$1[redacted-secret]",
            options: [.regularExpression]
        ))
    }

    private static func graphQLErrorDetail(data: Data?) -> String {
        guard let data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let errors = json["errors"] as? [[String: Any]],
              !errors.isEmpty,
              let errorData = try? JSONSerialization.data(withJSONObject: ["errors": errors]),
              let text = String(data: errorData, encoding: .utf8) else { return "" }
        let singleLine = text.replacingOccurrences(of: #"\s+"#, with: " ", options: [.regularExpression])
        return String(Log.sanitizedMessage(singleLine).prefix(500))
    }

    private static func httpOutcome(statusCode: Int, error: Error?) -> String {
        if error != nil { return "network_error" }
        if statusCode == -1 || (200..<400).contains(statusCode) { return "success" }
        return "http_error"
    }

    private static func statusText(_ statusCode: Int) -> String {
        statusCode >= 0 ? String(statusCode) : "unknown"
    }

    private static func logMessage(area: String, message: String) -> String {
        "[\(area)] \(message)"
    }
}
