import Foundation

public enum URLSessionHTTPTransport {
    public static func send(_ request: URLRequest, operation: String, invalidHTTPResponseError: any Error) async throws -> (Data, HTTPURLResponse) {
        let networkStart = NetworkLog.start(request, operation: operation)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            NetworkLog.finish(operation: operation, startedAt: networkStart, data: nil, response: nil, error: error)
            throw error
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            NetworkLog.finish(operation: operation, startedAt: networkStart, data: data, response: response, error: invalidHTTPResponseError)
            throw invalidHTTPResponseError
        }
        NetworkLog.finish(operation: operation, startedAt: networkStart, data: data, response: response, error: nil)
        return (data, httpResponse)
    }
}
