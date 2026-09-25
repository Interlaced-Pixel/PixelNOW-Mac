import Foundation
import WebRTC

public actor RemoteCoOpDirectHostPeerController {
    private let signaling: any RemoteCoOpSignalingSession
    private let coordinator: RemoteCoOpHostCoordinator
    private let peerFactory: any RemoteCoOpHostPeerFactory
    private let videoRelay: RemoteCoOpHostVideoRelay?
    private let audioRelay: RemoteCoOpHostAudioRelay?
    private var networkConfiguration: RemoteCoOpNetworkConfiguration
    private var qualityPreset: RemoteCoOpQualityPreset
    private var latencyMode: RemoteCoOpLatencyMode
    private var peers: [UUID: any RemoteCoOpHostPeer] = [:]
    private let lock = NSLock()
    private var pendingInputs: [UUID: [RemoteCoOpInputPacket]] = [:]
    private var latestRoutedInput: [UUID: RemoteCoOpInputPacket] = [:]
    private var routedInputCount: UInt64 = 0
    private var supersededInputCount: UInt64 = 0
    
    public init(signaling: any RemoteCoOpSignalingSession,
                coordinator: RemoteCoOpHostCoordinator,
                networkConfiguration: RemoteCoOpNetworkConfiguration,
                qualityPreset: RemoteCoOpQualityPreset = .p720f60,
                latencyMode: RemoteCoOpLatencyMode = .quality,
                videoRelay: RemoteCoOpHostVideoRelay? = nil,
                audioRelay: RemoteCoOpHostAudioRelay? = nil,
                peerFactory: any RemoteCoOpHostPeerFactory = RemoteCoOpWebRTCHostPeerFactory()) {
        self.signaling = signaling
        self.coordinator = coordinator
        self.networkConfiguration = networkConfiguration
        self.qualityPreset = qualityPreset
        self.latencyMode = latencyMode
        self.videoRelay = videoRelay
        self.audioRelay = audioRelay
        self.peerFactory = peerFactory
    }
    
    public func updateNetworkConfiguration(_ configuration: RemoteCoOpNetworkConfiguration) {
        networkConfiguration = configuration
    }
    
    public func updateQualityPreset(_ preset: RemoteCoOpQualityPreset) {
        qualityPreset = preset
    }
    
    public func updateLatencyMode(_ mode: RemoteCoOpLatencyMode) async {
        latencyMode = mode
    }
    
    public func sync(participants: [RemoteCoOpParticipant]) async throws {
        let eligibleParticipants = participants.filter { $0.connectionState == .connected && $0.inputEnabled }
        let eligibleIDs = Set(eligibleParticipants.map(\.id))
        for (participantID, peer) in peers where !eligibleIDs.contains(participantID) {
            peers[participantID] = nil
            removePeerInternal(participantID: participantID)
            videoRelay?.remove(participantID: participantID)
            audioRelay?.remove(participantID: participantID)
            await peer.close()
        }
        for participant in eligibleParticipants where peers[participant.id] == nil {
            try await startPeer(for: participant)
        }
    }
    
    public func startPeer(for participant: RemoteCoOpParticipant) async throws {
        guard participant.connectionState == .connected, participant.inputEnabled else { return }
        guard peers[participant.id] == nil else { return }
        let participantID = participant.id
        WebRTCMediaTelemetry.capture("webrtc.remote_coop.peer.start", level: .info, message: "Starting Remote Co-Op host peer.", attributes: ["participantID": participantID.uuidString])
        let callbacks = RemoteCoOpHostPeerCallbacks(
            sendSignal: { [signaling] signal in
                WebRTCMediaTelemetry.capture("webrtc.remote_coop.peer.signal.send", level: .info, message: "Sending Remote Co-Op peer signal.", attributes: ["participantID": participantID.uuidString, "kind": signal.kind.rawValue])
                await signaling.send(.peerSignal(participantID: participantID, signal: signal))
            },
            receiveInput: { [partitionID = participantID] packet in
                await self.receiveInput(packet, expectedParticipantID: partitionID)
            }
        )
        let peer = peerFactory.makePeer(participantID: participantID, networkConfiguration: networkConfiguration, qualityPreset: qualityPreset, latencyMode: latencyMode, callbacks: callbacks)
        peers[participantID] = peer
        do {
            try await peer.start()
            WebRTCMediaTelemetry.capture("webrtc.remote_coop.peer.started", level: .info, message: "Remote Co-Op host peer started.", attributes: ["participantID": participantID.uuidString])
            if let sink = peer as? any RemoteCoOpHostVideoSink { videoRelay?.upsert(sink) }
            if let sink = peer as? any RemoteCoOpHostAudioSink { audioRelay?.upsert(sink) }
        } catch {
            WebRTCMediaTelemetry.capture("webrtc.remote_coop.peer.start.failed", level: .warning, message: error.localizedDescription, attributes: ["participantID": participantID.uuidString])
            peers[participantID] = nil
            videoRelay?.remove(participantID: participantID)
            audioRelay?.remove(participantID: participantID)
            await peer.close()
            throw error
        }
    }
    
    public func receiveSignal(participantID: UUID, signal: RemoteCoOpWirePeerSignal) async throws {
        guard let peer = peers[participantID] else { throw RemoteCoOpHostPeerError.peerNotFound }
        try await peer.apply(signal)
    }
    
    public func removePeer(participantID: UUID) async {
        removePeerInternal(participantID: participantID)
        guard let peer = peers.removeValue(forKey: participantID) else { return }
        videoRelay?.remove(participantID: participantID)
        audioRelay?.remove(participantID: participantID)
        await peer.close()
    }
    
    public func removeAll() async {
        let currentPeers = Array(peers.values)
        peers.removeAll()
        pendingInputs.removeAll()
        latestRoutedInput.removeAll()
        videoRelay?.removeAll()
        audioRelay?.removeAll()
        for peer in currentPeers { await peer.close() }
    }
    
    private func removePeerInternal(participantID: UUID) {
        pendingInputs.removeValue(forKey: participantID)
        latestRoutedInput.removeValue(forKey: participantID)
    }
    
    private func receiveInput(_ packet: RemoteCoOpInputPacket, expectedParticipantID: UUID) async {
        let receivedAtNanoseconds = DispatchTime.now().uptimeNanoseconds
        guard latencyMode == .lowLatency else {
            await route(packet, receivedAtNanoseconds: receivedAtNanoseconds)
            return
        }
        
        let participantID = packet.participantID
        if let newest = newestKnownInput(participantID: participantID), newest.sequenceNumber >= packet.sequenceNumber {
            supersededInputCount &+= 1
            return
        }
        let previous = newestKnownInput(participantID: participantID)
        pendingInputs[participantID, default: []].append(packet)
        if previous == nil || previous?.buttons != packet.buttons {
            await drainPendingInputs(shouldCancelScheduledDrain: true)
        } else {
            scheduleDrainIfNeeded()
        }
    }
    
    private func newestKnownInput(participantID: UUID) -> RemoteCoOpInputPacket? {
        let pendingNewest = pendingInputs[participantID]?.max { $0.sequenceNumber < $1.sequenceNumber }
        guard let routed = latestRoutedInput[participantID] else { return pendingNewest }
        guard let pendingNewest else { return routed }
        return pendingNewest.sequenceNumber > routed.sequenceNumber ? pendingNewest : routed
    }
    
    private func drainPendingInputs(shouldCancelScheduledDrain: Bool) async {
        var inputs: [RemoteCoOpInputPacket] = []
        if shouldCancelScheduledDrain {
            cancelScheduledDrain()
        }
        for (participantID, inputsArray) in pendingInputs {
            inputs.append(contentsOf: condensedInputs(for: participantID, inputs: inputsArray))
        }
        inputs.sort { input1, input2 in input1.sentAtNanoseconds < input2.sentAtNanoseconds }
        pendingInputs.removeAll()
        for input in inputs {
            let receivedAtNanoseconds = input.sentAtNanoseconds
            await route(input, receivedAtNanoseconds: receivedAtNanoseconds)
        }
        if !pendingInputs.isEmpty { scheduleDrainIfNeeded() }
    }
    
    private func route(_ packet: RemoteCoOpInputPacket, receivedAtNanoseconds: UInt64) async {
        let routedEvents = await coordinator.handle(.guestInput(packet))
        for routedEvent in routedEvents {
            // Note: forwardInput callback not available in this implementation
            // In production, this would call the forwardInput handler
        }
        if !routedEvents.isEmpty { latestRoutedInput[packet.participantID] = packet }
        routedInputCount &+= 1
        guard latencyMode == .lowLatency, routedInputCount.isMultiple(of: 240) else { return }
        WebRTCMediaTelemetry.capture("webrtc.remote_coop.input.coalesced", level: .debug, message: "Remote Co-Op low latency input coalescing active.", attributes: [
            "coalescingDelayMilliseconds": String(millisecondDiff(receivedAtNanoseconds)),
            "participantID": packet.participantID.uuidString,
            "routedInputs": String(routedInputCount),
            "sequenceNumber": String(packet.sequenceNumber),
            "supersededInputs": String(supersededInputCount)
        ])
    }
    
    private func condensedInputs(for participantID: UUID, inputs: [RemoteCoOpInputPacket]) -> [RemoteCoOpInputPacket] {
        let sortedInputs = inputs.sorted { $0.sequenceNumber < $1.sequenceNumber }
        var reference = latestRoutedInput[participantID]
        var latestAnalogInput: RemoteCoOpInputPacket?
        var condensed: [RemoteCoOpInputPacket] = []
        
        for input in sortedInputs {
            if let reference, reference.buttons == input.buttons {
                latestAnalogInput = input
                continue
            }
            if let analogInput = latestAnalogInput {
                condensed.append(analogInput)
                latestAnalogInput = nil
            }
            condensed.append(input)
            reference = input
        }
        if let analogInput = latestAnalogInput { condensed.append(analogInput) }
        return condensed
    }
    
    private func scheduleDrainIfNeeded() {
    }
    
    private func cancelScheduledDrain() {
    }
    
    private func millisecondDiff(_ receivedAtNanoseconds: UInt64) -> Int {
        let routedAtNanoseconds = DispatchTime.now().uptimeNanoseconds
        guard routedAtNanoseconds >= receivedAtNanoseconds else { return 0 }
        return Int((routedAtNanoseconds - receivedAtNanoseconds) / 1_000_000)
    }
}
