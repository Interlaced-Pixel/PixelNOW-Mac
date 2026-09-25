import Foundation

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
        case tcp
        case udp
    }
    
    private var mappedPorts: [UInt16] = []
    private var router: RouterInfo?
    private var enabled: Bool = true
    private let lock = NSLock()
    
    public init() {}
    
    public func setEnabled(_ enabled: Bool) async {
        lock.withLock { self.enabled = enabled }
    }
    
    public func isEnabled() async -> Bool {
        lock.withLock { self.enabled }
    }
    
    public func discoverRouter() async throws {
        guard await isEnabled() else { throw Error.disabledByUser }
        
        // Stub implementation for discovery
        // In production, would use SSDP to discover UPnP routers
        // For now, we'll assume router is available if network is up
        router = RouterInfo(ip: "192.168.1.1") // Default gateway
    }
    
    public func mapPort(_ port: UInt16, protocol: UPnPProtocol) async throws {
        guard await isEnabled() else { throw Error.disabledByUser }
        guard router != nil else { throw Error.noRouterFound }
        
        // Stub implementation for port mapping
        // In production, would use miniupnpc or similar to call router's UPnP API
        lock.withLock {
            mappedPorts.append(port)
        }
    }
    
    public func clearAllMappings() async {
        lock.withLock {
            mappedPorts.removeAll()
            router = nil
        }
    }
    
    public func getMappedPorts() -> [UInt16] {
        lock.withLock { mappedPorts }
    }
    
    public func isInitialized() -> Bool {
        lock.withLock { router != nil }
    }
}

public struct RouterInfo: Hashable, Codable {
    public let ip: String
    
    public init(ip: String) {
        self.ip = ip
    }
}
