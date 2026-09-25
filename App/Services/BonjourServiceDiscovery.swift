import Foundation

public actor BonjourServiceDiscovery {
    public var onServiceFound: ((BonjourService) -> Void)?
    public var onDiscoveryComplete: (() -> Void)?
    
    private var services: [BonjourService] = []
    private let lock = NSLock()
    private var discoveryActive = false
    
    public init() {}
    
    public func startDiscovery(timeout: TimeInterval = 5.0) async {
        guard !discoveryActive else { return }
        
        discoveryActive = true
        
        // In production, use Network Framework's NWBrowser or dns-sd.js for browser
        // This is a stub that would discover Bonjour services on the network
        
        lock.withLock { discoveryActive = false }
        lock.withLock { onDiscoveryComplete?() }
    }
    
    public func stopDiscovery() {
        lock.withLock { discoveryActive = false }
        services.removeAll()
    }
    
    public func getServices() -> [BonjourService] {
        lock.withLock { services }
    }
    
    public func addService(_ service: BonjourService) {
        lock.withLock {
            services.append(service)
        }
        onServiceFound?(service)
    }
}

extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

public extension BonjourServiceDiscovery {
    func discoverServices() async -> [BonjourService] {
        await startDiscovery()
        return getServices()
    }
}
