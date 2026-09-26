import Foundation

public actor RemoteCoOpDirectHostSessionManager {
    private let directPreferences: RemoteCoOpDirectPreferences
    private let hostSession: RemoteCoOpHostSession
    private let directSignalingSession: RemoteCoOpDirectSignalingSession
    private let coordinator: RemoteCoOpHostCoordinator
    private let hostPeerController: RemoteCoOpHostPeerController
    private let bonjourAdvertiser: BonjourServiceAdvertiser
    private let upnpManager: UPnPManager
    private let forwardInput: @Sendable (UserInputEvent) async -> Void
    private var isRunning = false
    private var eventTask: Task<Void, Never>?
    
    public init(directPreferences: RemoteCoOpDirectPreferences = RemoteCoOpDirectPreferences(),
                hostSession: RemoteCoOpHostSession? = nil,
                directSignalingSession: RemoteCoOpDirectSignalingSession? = nil,
                peerFactory: any RemoteCoOpHostPeerFactory = RemoteCoOpWebRTCHostPeerFactory(),
                forwardInput: @escaping @Sendable (UserInputEvent) async -> Void = { _ in },
                bonjourAdvertiser: BonjourServiceAdvertiser = BonjourServiceAdvertiser(),
                upnpManager: UPnPManager = UPnPManager()) {
        let resolvedHostSession = hostSession ?? RemoteCoOpHostSession()
        let resolvedSignalingSession = directSignalingSession ?? RemoteCoOpDirectSignalingSession(port: directPreferences.signalingPort)
        self.directPreferences = directPreferences
        self.hostSession = resolvedHostSession
        self.directSignalingSession = resolvedSignalingSession
        let resolvedCoordinator = RemoteCoOpHostCoordinator(hostSession: resolvedHostSession, signaling: resolvedSignalingSession)
        self.coordinator = resolvedCoordinator
        self.hostPeerController = RemoteCoOpHostPeerController(
            signaling: resolvedSignalingSession,
            coordinator: resolvedCoordinator,
            networkConfiguration: RemoteCoOpNetworkConfiguration(latencyMode: directPreferences.latencyMode),
            qualityPreset: directPreferences.qualityPreset,
            latencyMode: directPreferences.latencyMode,
            peerFactory: peerFactory,
            forwardInput: forwardInput
        )
        self.forwardInput = forwardInput
        self.bonjourAdvertiser = bonjourAdvertiser
        self.upnpManager = upnpManager
    }
    
    public func start() async throws {
        guard !isRunning else { return }
        
        isRunning = true
        
        await applyUPnPConfiguration()
        
        try await startDirectSignaling()
        startEventLoop()
        try await startUPnP()
    }
    
    public func stop() async {
        guard isRunning else { return }
        
        isRunning = false
        eventTask?.cancel()
        eventTask = nil
        
        await stopBonjourAdvertising()
        
        _ = await coordinator.stopInvite()
        await stopDirectSignaling()
        
        await clearUPnP()
    }
    
    public func generatePIN() async -> (pin: String, expiresAt: Date) {
        guard let invite = await hostSession.snapshot().invite else { return ("", Date.distantPast) }
        return (invite.code, invite.expiresAt)
    }
    
    public func startInvite(applicationID: String = "", title: String = "") async throws -> RemoteCoOpInvite {
        let invite = try await coordinator.startInvite(applicationID: applicationID, title: title)
        if directPreferences.enableBonjour {
            let hostIP = await getLocalIPAddress()
            try await advertiseDirectSession(hostIP: hostIP, pin: invite.code)
        }
        return invite
    }
    
    public func validatePIN(_ pin: String, from _: String) async -> Bool {
        let normalizedPIN = pin.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard normalizedPIN.count == 6 else { return false }
        return await hostSession.snapshot().invite?.code == normalizedPIN
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
                    let bytes = hostname.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
                    address = String(decoding: bytes, as: UTF8.self)
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
            hostIP: hostIP,
            signalingPort: Int(directPreferences.signalingPort),
            quality: "720p60",
            latency: "low"
        )
    }
    
    private func applyUPnPConfiguration() async {
        await upnpManager.setEnabled(directPreferences.enableUPnP)
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
        
        let hostIP = await getLocalIPAddress()
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

    private func startEventLoop() {
        let events = directSignalingSession.events()
        eventTask = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                switch event {
                case .peerSignal(let participantID, let signal):
                    try? await self.hostPeerController.receiveSignal(participantID: participantID, signal: signal)
                default:
                    let routedEvents = await self.coordinator.handle(event)
                    for routedEvent in routedEvents { await self.forwardInput(routedEvent) }
                }
                let snapshot = await self.coordinator.snapshot()
                try? await self.hostPeerController.sync(participants: snapshot.participants)
            }
        }
    }

}
