import Foundation

public actor RemoteCoOpDirectHostSession {
    private let hostSession: RemoteCoOpHostSession
    private let directSignalingSession: RemoteCoOpDirectSignalingSession
    private let hostPeerController: RemoteCoOpHostPeerController
    private let bonjourAdvertiser: BonjourServiceAdvertiser
    private let upnpManager: UPnPManager
    private let directPreferences: RemoteCoOpDirectPreferences
    private let signalingPort: UInt16
    private var isRunning = false
    
    public init(signalingPort: UInt16 = 32189,
                urlSession: URLSession = .shared,
                networkConfiguration: RemoteCoOpNetworkConfiguration = RemoteCoOpNetworkConfiguration(transportMode: .directOnly),
                qualityPreset: RemoteCoOpQualityPreset = .p720f60,
                latencyMode: RemoteCoOpLatencyMode = .quality,
                directPreferences: RemoteCoOpDirectPreferences = RemoteCoOpDirectPreferences(),
                hostSession: RemoteCoOpHostSession = RemoteCoOpHostSession(),
                peerFactory: any RemoteCoOpHostPeerFactory = RemoteCoOpWebRTCHostPeerFactory(),
                forwardInput: @escaping @Sendable (UserInputEvent) async -> Void = { _ in }) {
        self.signalingPort = signalingPort
        self.directPreferences = directPreferences
        self.hostSession = hostSession
        directSignalingSession = RemoteCoOpDirectSignalingSession(port: signalingPort, urlSession: urlSession, hostSession: hostSession)
        hostPeerController = RemoteCoOpHostPeerController(
            signaling: directSignalingSession,
            coordinator: RemoteCoOpHostCoordinator(hostSession: hostSession, signaling: directSignalingSession),
            networkConfiguration: networkConfiguration,
            qualityPreset: qualityPreset,
            latencyMode: latencyMode,
            videoRelay: nil,
            audioRelay: nil,
            peerFactory: peerFactory,
            forwardInput: forwardInput
        )
        bonjourAdvertiser = BonjourServiceAdvertiser()
        upnpManager = UPnPManager()
    }
    
    public func updatePreferences(_ preferences: RemoteCoOpPreferences) async {
        await hostSession.updatePreferences(preferences)
    }
    
    public func snapshot() async -> RemoteCoOpHostSnapshot {
        await hostSession.snapshot()
    }
    
    public func start() async throws {
        guard !isRunning else { return }
        
        isRunning = true
        
        await upnpManager.setEnabled(directPreferences.enableUPnP)
        
        await startDirectSignaling()
        
        if directPreferences.enableBonjour {
            try await startBonjourDiscovery()
        }
        
        if directPreferences.enableUPnP {
            try await startUPnP()
        }
    }
    
    public func stop() async {
        guard isRunning else { return }
        
        isRunning = false
        
        await stopBonjourDiscovery()
        
        if directPreferences.enableUPnP {
            await upnpManager.clearAllMappings()
        }
        
        await directSignalingSession.close()
    }
    
    public func generatePIN() async -> (pin: String, expiresAt: Date) {
        await withCheckedContinuation { continuation in
            Task {
                var pinAuthenticator = RemoteCoOpPINAuthenticator()
                let result = pinAuthenticator.generatePIN(for: UUID(), clientIP: "127.0.0.1")
                continuation.resume(returning: result)
            }
        }
    }
    
    public func getLocalIPAddress() async throws -> String {
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
    
    private func startDirectSignaling() async {
        do {
            try await directSignalingSession.start()
        } catch {
            WebRTCMediaTelemetry.capture("remote.coop.direct.signaling.start.failed", level: .error, message: error.localizedDescription)
        }
    }
    
    private func startBonjourDiscovery() async throws {
        let _ = try await getLocalIPAddress()
        let (pin, _) = await generatePIN()
        
        try await bonjourAdvertiser.advertise(
            hostID: UUID(),
            pin: pin,
            signalingPort: Int(signalingPort),
            transportMode: "direct",
            quality: "720p60",
            latency: "low"
        )
    }
    
    private func stopBonjourDiscovery() async {
        await bonjourAdvertiser.stop()
    }
    
    private func startUPnP() async throws {
        do {
            try await upnpManager.discoverRouter()
            try await upnpManager.mapPort(signalingPort, protocol: .tcp)
            try await upnpManager.mapPort(signalingPort, protocol: .udp)
        } catch {
            WebRTCMediaTelemetry.capture("remote.coop.direct.upnp.start.failed", level: .warning, message: error.localizedDescription)
        }
    }
}
