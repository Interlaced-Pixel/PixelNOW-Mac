import Foundation

public struct RemoteCoOpDirectPreferences: Codable, Equatable, Sendable {
    public var enableUPnP: Bool
    public var enableBonjour: Bool
    public var signalingPort: UInt16
    
    public var effectiveReservedGuestSlots: Int { 3 }
    public var qualityPreset: RemoteCoOpQualityPreset { .p720f60 }
    public var latencyMode: RemoteCoOpLatencyMode { .lowLatency }
    
    public init(enableUPnP: Bool = true,
                enableBonjour: Bool = true,
                signalingPort: UInt16 = 32189) {
        self.enableUPnP = enableUPnP
        self.enableBonjour = enableBonjour
        self.signalingPort = signalingPort
    }
}
