import Foundation

public enum RemoteCoOpConnectionMode: String, Codable, Equatable, Sendable {
    case broker
    case direct

    public var label: String {
        switch self {
        case .broker: return "Broker (Legacy)"
        case .direct: return "Direct (Recommended)"
        }
    }

    public var description: String {
        switch self {
        case .broker: return "Use remote signaling server (TURN/HMAC-based). Deprecated - will be removed in future version."
        case .direct: return "Use peer-to-peer WebRTC with local signaling. Recommended for best performance."
        }
    }
}

public struct RemoteCoOpSessionFactory {
    public static func makeSession(connectionMode: RemoteCoOpConnectionMode,
                                   preferences: RemoteCoOpPreferences,
                                   signaledPreferences: RemoteCoOpDirectPreferences = RemoteCoOpDirectPreferences(),
                                   signalingPort: UInt16 = 32189,
                                   urlSession: URLSession = .shared,
                                   peerFactory: any RemoteCoOpHostPeerFactory = RemoteCoOpWebRTCHostPeerFactory(),
                                   forwardInput: @escaping @Sendable (UserInputEvent) async -> Void = { _ in })
        -> any RemoteCoOpHostSessionProtocol {
        switch connectionMode {
        case .broker:
            let signalingSession = RemoteCoOpWebSocketSignalingSession(serverURL: RemoteCoOpSessionFactory.makeBrokerSignalingURL(signalingServerURL: preferences.signalingServerURL), urlSession: urlSession)
            let coordinator = RemoteCoOpHostCoordinator(hostSession: RemoteCoOpHostSession(preferences: preferences, isDirectMode: false), signaling: signalingSession)
            return RemoteCoOpBrokerHostSession(signalingSession: signalingSession,
                                               coordinator: coordinator,
                                               preferences: preferences,
                                               forwardInput: forwardInput)
        case .direct:
            return RemoteCoOpDirectHostSessionFactory.makeSession(preferences: preferences,
                                                                   signalingPort: signalingPort,
                                                                   urlSession: urlSession,
                                                                   signaledPreferences: signaledPreferences,
                                                                   peerFactory: peerFactory,
                                                                   forwardInput: forwardInput)
        }
    }

    private static func makeBrokerSignalingURL(signalingServerURL: String) -> URL {
        guard let url = URL(string: signalingServerURL) else {
            return URL(string: "ws://198.12.95.48:32188/remote-coop")!
        }
        return url
    }
}

public struct RemoteCoOpDirectHostSessionFactory {
    public static func makeSession(preferences: RemoteCoOpPreferences,
                                   signalingPort: UInt16 = 32189,
                                   urlSession: URLSession = .shared,
                                   signaledPreferences: RemoteCoOpDirectPreferences = RemoteCoOpDirectPreferences(),
                                   peerFactory: any RemoteCoOpHostPeerFactory = RemoteCoOpWebRTCHostPeerFactory(),
                                   forwardInput: @escaping @Sendable (UserInputEvent) async -> Void = { _ in })
        -> any RemoteCoOpHostSessionProtocol {
        let hostSession = RemoteCoOpHostSession(preferences: preferences, isDirectMode: true)
        let directSignalingSession = RemoteCoOpDirectSignalingSession(port: signalingPort, urlSession: urlSession, hostSession: hostSession)
        let coordinator = RemoteCoOpHostCoordinator(hostSession: hostSession, signaling: directSignalingSession)
        let hostPeerController = RemoteCoOpHostPeerController(signaling: directSignalingSession,
                                                               coordinator: coordinator,
                                                               networkConfiguration: RemoteCoOpNetworkConfiguration(transportMode: preferences.transportMode, latencyMode: preferences.latencyMode),
                                                               qualityPreset: preferences.qualityPreset,
                                                               latencyMode: preferences.latencyMode,
                                                               peerFactory: peerFactory,
                                                               forwardInput: forwardInput)
        return RemoteCoOpDirectHostSessionInternal(signalingPort: signalingPort,
                                                    urlSession: urlSession,
                                                    networkConfiguration: RemoteCoOpNetworkConfiguration(transportMode: preferences.transportMode, latencyMode: preferences.latencyMode),
                                                    qualityPreset: preferences.qualityPreset,
                                                    latencyMode: preferences.latencyMode,
                                                    directPreferences: signaledPreferences,
                                                    hostSession: hostSession,
                                                    directSignalingSession: directSignalingSession,
                                                    hostPeerController: hostPeerController,
                                                    bonjourAdvertiser: BonjourServiceAdvertiser(),
                                                    upnpManager: UPnPManager(),
                                                    forwardInput: forwardInput)
    }
}

public protocol RemoteCoOpHostSessionProtocol: Sendable {
    func start() async throws
    func stop() async
    func snapshot() async -> RemoteCoOpHostSnapshot
    func generatePIN() async -> (pin: String, expiresAt: Date)
    func getLocalIPAddress() async throws -> String
}

public actor RemoteCoOpBrokerHostSession: RemoteCoOpHostSessionProtocol {
    private let signalingSession: RemoteCoOpWebSocketSignalingSession
    private let coordinator: RemoteCoOpHostCoordinator
    private let preferences: RemoteCoOpPreferences
    private let forwardInput: @Sendable (UserInputEvent) async -> Void
    private var listenTask: Task<Void, Never>?

    public init(signalingSession: RemoteCoOpWebSocketSignalingSession,
                coordinator: RemoteCoOpHostCoordinator,
                preferences: RemoteCoOpPreferences,
                forwardInput: @escaping @Sendable (UserInputEvent) async -> Void) {
        self.signalingSession = signalingSession
        self.coordinator = coordinator
        self.preferences = preferences
        self.forwardInput = forwardInput
    }

    public func start() async throws {
        guard preferences.isAvailable else { return }
    }

    public func stop() async {
        listenTask?.cancel()
        listenTask = nil
        await signalingSession.close()
    }

    public func snapshot() async -> RemoteCoOpHostSnapshot {
        await coordinator.snapshot()
    }

    public func generatePIN() async -> (pin: String, expiresAt: Date) {
        var pinAuthenticator = RemoteCoOpPINAuthenticator()
        let result = pinAuthenticator.generatePIN(for: UUID(), clientIP: "127.0.0.1")
        return result
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
}

private actor RemoteCoOpDirectHostSessionInternal: RemoteCoOpHostSessionProtocol {
    private let signalingPort: UInt16
    private let urlSession: URLSession
    private let directPreferences: RemoteCoOpDirectPreferences
    private let hostSession: RemoteCoOpHostSession
    private let directSignalingSession: RemoteCoOpDirectSignalingSession
    private let hostPeerController: RemoteCoOpHostPeerController
    private let bonjourAdvertiser: BonjourServiceAdvertiser
    private let upnpManager: UPnPManager
    private let forwardInput: @Sendable (UserInputEvent) async -> Void
    private var isRunning = false

    init(signalingPort: UInt16,
         urlSession: URLSession,
         networkConfiguration: RemoteCoOpNetworkConfiguration,
         qualityPreset: RemoteCoOpQualityPreset,
         latencyMode: RemoteCoOpLatencyMode,
         directPreferences: RemoteCoOpDirectPreferences,
         hostSession: RemoteCoOpHostSession,
         directSignalingSession: RemoteCoOpDirectSignalingSession,
         hostPeerController: RemoteCoOpHostPeerController,
         bonjourAdvertiser: BonjourServiceAdvertiser,
         upnpManager: UPnPManager,
         forwardInput: @escaping @Sendable (UserInputEvent) async -> Void) {
        self.signalingPort = signalingPort
        self.urlSession = urlSession
        self.directPreferences = directPreferences
        self.hostSession = hostSession
        self.directSignalingSession = directSignalingSession
        self.hostPeerController = hostPeerController
        self.bonjourAdvertiser = bonjourAdvertiser
        self.upnpManager = upnpManager
        self.forwardInput = forwardInput
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

    public func snapshot() async -> RemoteCoOpHostSnapshot {
        await hostSession.snapshot()
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
