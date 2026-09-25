import Foundation

public actor RemoteCoOpDirectHostSessionManager {
    private let directPreferences: RemoteCoOpDirectPreferences
    private let hostSession: RemoteCoOpHostSession
    private let directSignalingSession: RemoteCoOpDirectSignalingSession
    private let bonjourAdvertiser: BonjourServiceAdvertiser
    private let upnpManager: UPnPManager
    private var isRunning = false
    
    public init(directPreferences: RemoteCoOpDirectPreferences = RemoteCoOpDirectPreferences(),
                hostSession: RemoteCoOpHostSession = RemoteCoOpHostSession(),
                directSignalingSession: RemoteCoOpDirectSignalingSession = RemoteCoOpDirectSignalingSession(hostSession: RemoteCoOpHostSession()),
                bonjourAdvertiser: BonjourServiceAdvertiser = BonjourServiceAdvertiser(),
                upnpManager: UPnPManager = UPnPManager()) {
        self.directPreferences = directPreferences
        self.hostSession = hostSession
        self.directSignalingSession = directSignalingSession
        self.bonjourAdvertiser = bonjourAdvertiser
        self.upnpManager = upnpManager
    }
    
    public func start() async throws {
        guard !isRunning else { return }
        
        isRunning = true
        
        await applyUPnPConfiguration()
        
        applyBonjourConfiguration()
        
        try await startDirectSignaling()
        
        try await startBonjourAdvertising()
        
        try await startUPnP()
    }
    
    public func stop() async {
        guard isRunning else { return }
        
        isRunning = false
        
        await stopBonjourAdvertising()
        
        await stopDirectSignaling()
        
        await clearUPnP()
    }
    
    public func generatePIN() async -> (pin: String, expiresAt: Date) {
        var pinAuthenticator = RemoteCoOpPINAuthenticator()
        let result = pinAuthenticator.generatePIN(for: UUID(), clientIP: "127.0.0.1")
        return result
    }
    
    public func validatePIN(_ pin: String, from clientIP: String) throws -> Bool {
        var pinAuthenticator = RemoteCoOpPINAuthenticator()
        return try pinAuthenticator.validate(pin, from: clientIP)
    }
    
    public func getLocalIPAddress() async -> String {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        
        guard getifaddrs(&ifaddr) == 0 else { return "127.0.0.1" }
        defer { freeifaddrs(ifaddr) }
        
        var ptr = ifaddr
        while ptr != nil {
            let interface = ptr!.pointee
            let flags = Int32(interface.ifa_flags)
            let addrFamily = interface.ifa_addr.pointee.sa_family
            
            if flags & IFF_UP != 0 && flags & IFF_LOOPBACK == 0 && addrFamily == UInt8(AF_INET) {
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                               &hostname, socklen_t(hostname.count),
                               nil, 0, NI_NUMERICHOST) == 0 {
                    address = String(cString: hostname)
                }
            }
            ptr = interface.ifa_next
        }
        
        return address ?? "127.0.0.1"
    }
    
    public func advertiseDirectSession(hostIP: String, pin: String) async throws {
        try await bonjourAdvertiser.advertise(
            hostID: UUID(),
            pin: pin,
            signalingPort: Int(directPreferences.signalingPort),
            transportMode: "direct",
            quality: "720p60",
            latency: "low"
        )
    }
    
    private func applyUPnPConfiguration() async {
        await upnpManager.setEnabled(directPreferences.enableUPnP)
    }
    
    private func applyBonjourConfiguration() {
    }
    
    private func startDirectSignaling() async throws {
        do {
            try await directSignalingSession.start()
        } catch {
            WebRTCMediaTelemetry.capture("remote.coop.direct.session.start.failed", level: .error, message: error.localizedDescription)
            throw error
        }
    }
    
    private func stopDirectSignaling() async {
        await directSignalingSession.close()
    }
    
    private func startBonjourAdvertising() async throws {
        guard directPreferences.enableBonjour else { return }
        
        let hostIP = try await getLocalIPAddress()
        let (pin, _) = await generatePIN()
        
        try await advertiseDirectSession(hostIP: hostIP, pin: pin)
    }
    
    private func stopBonjourAdvertising() async {
        guard directPreferences.enableBonjour else { return }
        
        await bonjourAdvertiser.stop()
    }
    
    private func startUPnP() async throws {
        guard directPreferences.enableUPnP else { return }
        
        do {
            try await upnpManager.discoverRouter()
            try await upnpManager.mapPort(directPreferences.signalingPort, protocol: .tcp)
            try await upnpManager.mapPort(directPreferences.signalingPort, protocol: .udp)
        } catch {
            WebRTCMediaTelemetry.capture("remote.coop.direct.upnp.start.failed", level: .warning, message: error.localizedDescription)
            throw error
        }
    }
    
    private func clearUPnP() async {
        guard directPreferences.enableUPnP else { return }
        
        await upnpManager.clearAllMappings()
    }
}
