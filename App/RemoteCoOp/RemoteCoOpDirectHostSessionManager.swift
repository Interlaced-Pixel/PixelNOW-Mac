import Foundation

public actor RemoteCoOpDirectHostSessionManager {
    private let hostSession: RemoteCoOpHostSession
    private let directSignalingSession: RemoteCoOpDirectSignalingSession
    private let coordinator: RemoteCoOpHostCoordinator
    private let hostPeerController: RemoteCoOpHostPeerController
    private let forwardInput: @Sendable (UserInputEvent) async -> Void
    private var isRunning = false
    private var eventTask: Task<Void, Never>?
    
    public init(hostSession: RemoteCoOpHostSession? = nil,
                directSignalingSession: RemoteCoOpDirectSignalingSession? = nil,
                peerFactory: any RemoteCoOpHostPeerFactory = RemoteCoOpWebRTCHostPeerFactory(),
                videoRelay: RemoteCoOpHostVideoRelay? = nil,
                audioRelay: RemoteCoOpHostAudioRelay? = nil,
                forwardInput: @escaping @Sendable (UserInputEvent) async -> Void) {
        let preferences = RemoteCoOpPreferencesStore.load()
        let resolvedHostSession = hostSession ?? RemoteCoOpHostSession(preferences: preferences)
        let resolvedSignalingSession = directSignalingSession ?? RemoteCoOpDirectSignalingSession()
        self.hostSession = resolvedHostSession
        self.directSignalingSession = resolvedSignalingSession
        let resolvedCoordinator = RemoteCoOpHostCoordinator(hostSession: resolvedHostSession, signaling: resolvedSignalingSession)
        self.coordinator = resolvedCoordinator
        self.hostPeerController = RemoteCoOpHostPeerController(
            signaling: resolvedSignalingSession,
            coordinator: resolvedCoordinator,
            networkConfiguration: RemoteCoOpNetworkConfiguration(
                latencyMode: preferences.latencyMode,
                iceServers: RemoteCoOpNetworkConfiguration.directICEServers
            ),
            qualityPreset: preferences.qualityPreset,
            latencyMode: preferences.latencyMode,
            videoRelay: videoRelay,
            audioRelay: audioRelay,
            peerFactory: peerFactory,
            forwardInput: forwardInput
        )
        self.forwardInput = forwardInput
    }
    
    public func start() async throws {
        guard !isRunning else { return }
        
        isRunning = true
        
        do {
            try await startDirectSignaling()
            startEventLoop()
        } catch {
            await stop()
            throw error
        }
    }
    
    public func stop() async {
        guard isRunning else { return }
        
        isRunning = false
        let pendingEventTask = eventTask
        pendingEventTask?.cancel()
        eventTask = nil
        
        let neutralEvents = await coordinator.stopInvite()
        for event in neutralEvents { await forwardInput(event) }
        await stopDirectSignaling()
        await pendingEventTask?.value
        await hostPeerController.removeAll()
        
    }
    
    public func generatePIN() async -> (pin: String, expiresAt: Date) {
        guard let invite = await hostSession.snapshot().invite else { return ("", Date.distantPast) }
        return (invite.code, invite.expiresAt)
    }
    
    public func startInvite(applicationID: String = "", title: String = "") async throws -> RemoteCoOpInvite {
        let invite = try await coordinator.startInvite(applicationID: applicationID, title: title)
        try await directSignalingSession.waitUntilHostRegistered()
        if let configuration = directSignalingSession.latestNetworkConfiguration() {
            await hostPeerController.updateNetworkConfiguration(configuration)
        }
        var joinURL = URLComponents()
        joinURL.scheme = "https"
        joinURL.host = "jayian.dev"
        joinURL.port = 38473
        joinURL.path = "/"
        joinURL.queryItems = [URLQueryItem(name: "invite", value: invite.code)]
        return RemoteCoOpInvite(
            id: invite.id,
            code: invite.code,
            createdAt: invite.createdAt,
            expiresAt: invite.expiresAt,
            token: invite.code,
            joinURL: joinURL.url,
            applicationID: invite.applicationID,
            title: invite.title,
            hideGuestInviteDetails: invite.hideGuestInviteDetails
        )
    }
    
    public func validatePIN(_ pin: String, from _: String) async -> Bool {
        let normalizedPIN = pin.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard normalizedPIN.count == 6 else { return false }
        return await hostSession.snapshot().invite?.code == normalizedPIN
    }
    
    private func startDirectSignaling() async throws {
        do {
            try await directSignalingSession.start()
        } catch {
            WebRTCMediaLog.write("remote.coop.direct.session.start.failed", level: .error, message: error.localizedDescription)
            throw error
        }
    }
    
    private func stopDirectSignaling() async {
        await directSignalingSession.close()
    }
    
    private func startEventLoop() {
        let events = directSignalingSession.events()
        eventTask = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                switch event {
                case .peerSignal(let participantID, let signal):
                    try? await self.hostPeerController.receiveSignal(participantID: participantID, signal: signal)
                case .networkConfiguration(let configuration):
                    await self.hostPeerController.updateNetworkConfiguration(configuration)
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
