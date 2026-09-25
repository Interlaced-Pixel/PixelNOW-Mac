import Foundation
import Network

public actor BonjourServiceAdvertiser {
    private var service: NWBrowser?
    private let lock = NSLock()
    private var advertised = false
    
    public init() {}
    
    public func advertise(hostID: UUID, pin: String, signalingPort: Int, transportMode: String, quality: String, latency: String) async throws {
        guard !advertised else { return }
        
        // In production, use NSNetServiceAdvertiser for macOS Bonjour
        // For now, this is a stub that would broadcast the service
        advertised = true
    }
    
    public func stop() {
        lock.withLock { advertised = false }
        service?.cancel()
        service = nil
    }
}

public struct BonjourService: Hashable, Identifiable {
    public let id: UUID
    public let hostID: UUID
    public let pin: String
    public let signalingPort: Int
    public let transportMode: String
    public let quality: String
    public let latency: String
    public let hostIP: String
    
    public init(id: UUID = UUID(), hostID: UUID, pin: String, signalingPort: Int, transportMode: String, quality: String, latency: String, hostIP: String) {
        self.id = id
        self.hostID = hostID
        self.pin = pin
        self.signalingPort = signalingPort
        self.transportMode = transportMode
        self.quality = quality
        self.latency = latency
        self.hostIP = hostIP
    }
}
