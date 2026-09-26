import Foundation
import Network

public actor UPnPManager {
    public enum Error: Swift.Error, LocalizedError {
        case noRouterFound
        case portMappingFailed(externalPort: UInt16, `protocol`: UPnPProtocol, message: String)
        case routerNotUPnPCompliant
        case networkUnavailable
        case disabledByUser

        public var errorDescription: String? {
            switch self {
            case .noRouterFound:
                return "No UPnP-capable router found on the network."
            case .portMappingFailed(let port, let `protocol`, let message):
                return "Failed to map port \(port)/\(`protocol`.rawValue): \(message)"
            case .routerNotUPnPCompliant:
                return "Router does not support UPnP port mapping."
            case .networkUnavailable:
                return "Network is unavailable."
            case .disabledByUser:
                return "UPnP is disabled in settings."
            }
        }
    }

    public enum UPnPProtocol: String, Codable, Sendable {
        case tcp = "TCP"
        case udp = "UDP"
    }

    private struct Mapping: Hashable, Sendable {
        let port: UInt16
        let `protocol`: UPnPProtocol
    }

    private var mappedPorts: Set<Mapping> = []
    private var router: RouterInfo?
    private var enabled = true

    public init() {}

    public func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
    }

    public func isEnabled() -> Bool {
        enabled
    }

    public func discoverRouter() async throws {
        guard enabled else { throw Error.disabledByUser }
        guard let location = try await discoverDeviceDescriptionLocation() else { throw Error.noRouterFound }
        guard let response = try? await URLSession.shared.data(from: location) else { throw Error.routerNotUPnPCompliant }
        let description = response.0
        guard let discovered = RouterInfo(description: description, location: location) else { throw Error.routerNotUPnPCompliant }
        router = discovered
    }

    public func mapPort(_ port: UInt16, protocol: UPnPProtocol) async throws {
        guard enabled else { throw Error.disabledByUser }
        guard let router else { throw Error.noRouterFound }
        let localAddress = localIPv4Address()
        let body = soapBody(
            action: "AddPortMapping",
            serviceType: router.serviceType,
            values: [
                "NewRemoteHost": "",
                "NewExternalPort": String(port),
                "NewProtocol": `protocol`.rawValue,
                "NewInternalPort": String(port),
                "NewInternalClient": localAddress,
                "NewEnabled": "1",
                "NewPortMappingDescription": "PixelNOW Remote Co-Op",
                "NewLeaseDuration": "0"
            ]
        )
        do {
            try await sendSOAP(body: body, action: "AddPortMapping", serviceType: router.serviceType, to: router.controlURL)
            mappedPorts.insert(Mapping(port: port, protocol: `protocol`))
        } catch {
            throw Error.portMappingFailed(externalPort: port, protocol: `protocol`, message: error.localizedDescription)
        }
    }

    public func clearAllMappings() async {
        guard let router else {
            mappedPorts.removeAll()
            return
        }
        for mapping in mappedPorts {
            let body = soapBody(
                action: "DeletePortMapping",
                serviceType: router.serviceType,
                values: [
                    "NewRemoteHost": "",
                    "NewExternalPort": String(mapping.port),
                    "NewProtocol": mapping.protocol.rawValue
                ]
            )
            try? await sendSOAP(body: body, action: "DeletePortMapping", serviceType: router.serviceType, to: router.controlURL)
        }
        mappedPorts.removeAll()
        self.router = nil
    }

    public func getMappedPorts() -> [UInt16] {
        mappedPorts.map(\.port).sorted()
    }

    public func isInitialized() -> Bool {
        router != nil
    }

    private func discoverDeviceDescriptionLocation() async throws -> URL? {
        let connection = NWConnection(host: "239.255.255.250", port: 1900, using: .udp)
        let request = "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 2\r\nST: urn:schemas-upnp-org:device:InternetGatewayDevice:1\r\n\r\n"
        return try await withCheckedThrowingContinuation { continuation in
            let state = UPnPDiscoveryState(continuation: continuation, connection: connection)
            connection.stateUpdateHandler = { newState in
                switch newState {
                case .ready:
                    connection.send(content: Data(request.utf8), completion: .contentProcessed { error in
                        if let error { state.finish(.failure(error)); return }
                        state.receiveNext()
                    })
                case .failed(let error):
                    state.finish(.failure(error))
                case .cancelled:
                    state.finish(.failure(UPnPManager.Error.networkUnavailable))
                default:
                    break
                }
            }
            connection.start(queue: DispatchQueue.global(qos: .utility))
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 4) {
                state.finish(.success(nil))
            }
        }
    }

    private func sendSOAP(body: Data, action: String, serviceType: String, to url: URL) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("\"\(serviceType)#\(action)\"", forHTTPHeaderField: "SOAPAction")
        request.httpBody = body
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
            throw Error.routerNotUPnPCompliant
        }
    }

    private func soapBody(action: String, serviceType: String, values: [String: String]) -> Data {
        let arguments = values.sorted { $0.key < $1.key }.map { "<\($0.key)>\(xmlEscape($0.value))</\($0.key)>" }.joined()
        let body = "<?xml version=\"1.0\"?><s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\"><s:Body><u:\(action) xmlns:u=\"\(serviceType)\">\(arguments)</u:\(action)></s:Body></s:Envelope>"
        return Data(body.utf8)
    }

    private func xmlEscape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private func localIPv4Address() -> String {
        var address: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&address) == 0 else { return "127.0.0.1" }
        defer { freeifaddrs(address) }
        var cursor = address
        while let current = cursor {
            let interface = current.pointee
            let flags = Int32(interface.ifa_flags)
            if flags & IFF_UP != 0,
               flags & IFF_LOOPBACK == 0,
               let socketAddress = interface.ifa_addr,
               socketAddress.pointee.sa_family == UInt8(AF_INET) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(socketAddress, socklen_t(socketAddress.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let bytes = host.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
                    return String(decoding: bytes, as: UTF8.self)
                }
            }
            cursor = interface.ifa_next
        }
        return "127.0.0.1"
    }
}

private final class UPnPDiscoveryState: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    private let continuation: CheckedContinuation<URL?, any Swift.Error>
    private let connection: NWConnection

    init(continuation: CheckedContinuation<URL?, any Swift.Error>, connection: NWConnection) {
        self.continuation = continuation
        self.connection = connection
    }

    func receiveNext() {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let error {
                self.finish(.failure(error))
                return
            }
            if let data,
               let text = String(data: data, encoding: .utf8),
               let locationLine = text.components(separatedBy: "\r\n").first(where: { $0.lowercased().hasPrefix("location:") }),
               let location = URL(string: String(locationLine.dropFirst("location:".count)).trimmingCharacters(in: .whitespacesAndNewlines)) {
                finish(.success(location))
            } else {
                receiveNext()
            }
        }
    }

    func finish(_ result: Result<URL?, any Swift.Error>) {
        let shouldFinish = lock.withLock {
            guard !completed else { return false }
            completed = true
            return true
        }
        guard shouldFinish else { return }
        connection.cancel()
        continuation.resume(with: result)
    }
}

public struct RouterInfo: Hashable, Codable, Sendable {
    public let ip: String
    public let controlURL: URL
    public let serviceType: String

    public init(ip: String, controlURL: URL = URL(fileURLWithPath: "/"), serviceType: String = "urn:schemas-upnp-org:service:WANIPConnection:1") {
        self.ip = ip
        self.controlURL = controlURL
        self.serviceType = serviceType
    }

    init?(description: Data, location: URL) {
        guard let xml = String(data: description, encoding: .utf8),
              let serviceRange = xml.range(of: "urn:schemas-upnp-org:service:WANIPConnection", options: .caseInsensitive),
              let controlPath = RouterInfo.value(after: "<controlURL>", before: "</controlURL>", in: xml, near: serviceRange.lowerBound),
              let controlURL = URL(string: controlPath, relativeTo: location)?.absoluteURL,
              let host = location.host else { return nil }
        let serviceType = RouterInfo.value(after: "<serviceType>", before: "</serviceType>", in: xml, near: serviceRange.lowerBound) ?? "urn:schemas-upnp-org:service:WANIPConnection:1"
        self.init(ip: host, controlURL: controlURL, serviceType: serviceType)
    }

    private static func value(after opening: String, before closing: String, in text: String, near index: String.Index) -> String? {
        guard let start = text.range(of: opening, options: .caseInsensitive, range: index..<text.endIndex)?.upperBound,
              let end = text.range(of: closing, options: .caseInsensitive, range: start..<text.endIndex)?.lowerBound else { return nil }
        return String(text[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
