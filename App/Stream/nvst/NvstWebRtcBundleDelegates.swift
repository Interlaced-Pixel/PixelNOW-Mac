import Foundation
@preconcurrency import WebRTC

extension NvstWebRtcBundle {

    public func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        guard candidate.sdp.contains("typ host"), candidate.sdp.lowercased().contains(" udp ") else { return }
        lock.withLock { hostCandidates.append(candidate) }
    }

    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        lock.lock()
        iceStateDescription = String(newState.rawValue)
        lock.unlock()
        logger?("NVST bundle ICE state \(newState.rawValue)")
    }

    public func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        dataChannel.delegate = self
        logger?("NVST bundle inbound data channel '\(dataChannel.label)' id=\(dataChannel.channelId)")
        adopt(dataChannel)
    }

    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}

    public func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        logger?("NVST bundle remote stream '\(stream.streamId)' audio=\(stream.audioTracks.count) video=\(stream.videoTracks.count)")
        for track in stream.audioTracks {
            track.isEnabled = true

            lock.lock()
            remoteAudioTracks.append(track)
            trackedRemoteAudioCount += 1
            lock.unlock()
            logger?("NVST bundle remote audio track '\(track.trackId)' enabled")
        }
        onRemoteAudio?(stream.audioTracks.count)
    }
    public func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    public func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        guard newState == .complete else { return }
        lock.withLock { gatheringComplete = true }
        finishHostCandidateWait()
    }
    public func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}

    public func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        logger?("NVST bundle channel '\(dataChannel.label)' id=\(dataChannel.channelId) state=\(dataChannel.readyState.rawValue)")
        adopt(dataChannel)
    }

    public func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        let shouldLog: Bool = lock.withLock {
            inboundFeedbackBytes += buffer.data.count
            inboundMessagesByLabel[dataChannel.label, default: 0] += 1
            guard loggedInboundMessages < Self.maxLoggedInboundMessages else { return false }
            loggedInboundMessages += 1
            return true
        }

        if let version = NvstRemoteInput.protocolVersion(in: buffer.data) {
            let isNew: Bool = lock.withLock {
                guard negotiatedInputProtocolVersion == nil else { return false }
                negotiatedInputProtocolVersion = version
                return true
            }
            if isNew {
                logger?("NVST bundle input protocol version \(version) from '\(dataChannel.label)'")
                _ = dataChannel.sendData(buffer)
                startInputHeartbeat()
                onInputProtocolNegotiated?(version)
            }
        }
        let (parsedCommands, trailing) = NvstStreamingCommand.parse(buffer.data)
        for command in parsedCommands {
            dispatchInboundCommand(command, on: dataChannel)
        }

        if !trailing.isEmpty, dataChannel.label == "control_channel_reliable" {
            let hex = [UInt8](trailing.prefix(32)).map { String(format: "%02x", $0) }.joined()
            logger?("NVST bundle control channel unparsed trailing bytes=\(trailing.count) hex=\(hex)")
        } else if parsedCommands.isEmpty, dataChannel.label == "control_channel_reliable", !buffer.data.isEmpty {
            let hex = [UInt8](buffer.data.prefix(32)).map { String(format: "%02x", $0) }.joined()
            logger?("NVST bundle control channel unparsed buffer bytes=\(buffer.data.count) hex=\(hex)")
        }

        guard shouldLog else { return }
        logInboundMessage(buffer, on: dataChannel)
    }

    private func dispatchInboundCommand(_ command: NvstStreamingCommand, on dataChannel: RTCDataChannel) {
        if command.code == .termination || command.terminationReason != nil {
            let reason = command.terminationReason
            let reasonDesc = reason.map { NvstResult.describe($0) } ?? "unspecified"
            let hex = command.payload.map { String(format: "%02x", $0) }.joined()
            logger?("NVST bundle seat terminated the session (channel=\(dataChannel.label)): \(command.summary) reason=\(reasonDesc) payload=\(hex)")
            onSeatTermination?(reason, command.summary)
            return
        }
        if command.code == .terminationTimer || command.code == 0x0104 || command.code == 0x0105 {
            let hex = command.payload.map { String(format: "%02x", $0) }.joined()
            logger?("NVST bundle seat termination timer warning (channel=\(dataChannel.label)): code=\(command.code.description) len=\(command.payload.count) payload=\(hex)")
            onSeatTerminationTimer?(command.code.rawValue, command.payload)
            return
        }
        if command.isTextual {
            logger?("NVST bundle inbound text (channel=\(dataChannel.label)) \(String(format: "0x%04x", command.code.rawValue)): \(command.text(limit: 600))")
        }
        if command.code == .inputProtocolVersion, command.payload.count >= 2 {
            var payload = NvstByteReader(command.payload)
            if let version = try? payload.u16LE() {
                let isNew: Bool = lock.withLock {
                    guard negotiatedInputProtocolVersion == nil else { return false }
                    negotiatedInputProtocolVersion = version
                    return true
                }
                if isNew {
                    logger?("NVST bundle input protocol version \(version) from inbound command")
                    if let control = openControlChannel, control.readyState == .open, let encoded = try? command.encoded {
                        _ = control.sendData(RTCDataBuffer(data: encoded, isBinary: true))
                    }
                    startInputHeartbeat()
                    onInputProtocolNegotiated?(version)
                }
                return
            }
        }
        if let stats = NvstSeatStats.from(command) {
            onSeatStats?(stats)
            return
        }
        if let haptics = NvstHapticEvent.parse(command) {
            describeHapticCommand(command, events: haptics)
            if !haptics.isEmpty { onHapticEvents?(haptics) }
            return
        }
        if let hdrMode = NvstHdrModeNotification.parse(command) {
            logger?("NVST hdr-mode notification \(hdrMode.summary) payload=\(command.payload.prefix(16).map { String(format: "%02x", $0) }.joined())")
            onHdrMode?(hdrMode)
            return
        }
        if let surround = NvstAudioSurroundInfo.parse(command) {
            logger?("NVST audio surround info \(surround.summary) payload=\(command.payload.prefix(16).map { String(format: "%02x", $0) }.joined())")
            lock.withLock { currentAudioSurroundInfo = surround }
            onAudioSurroundInfo?(surround)
            return
        }
        if let response = NvstHidPassthrough.ChangeResponse.parse(command) {
            logger?("NVST bundle HID change response deviceId=\(response.deviceId) status=\(response.status) requestId=\(response.requestId)")
            onHidChangeResponse?(response.deviceId, response.status)
            return
        }
        guard let cursor = NvstRemoteCursor.from(command) else {
            describeCursorCommandIfUnparsed(command)
            return
        }

        describeCursorCommand(command, decision: cursor.isVisible)
        onRemoteCursor?(cursor)
    }

    private func logInboundMessage(_ buffer: RTCDataBuffer, on dataChannel: RTCDataChannel) {

        let (commands, trailing) = NvstStreamingCommand.parse(buffer.data)
        let decoded = commands.map(\.summary).joined(separator: " | ")

        for command in commands where command.isTextual {
            logger?("NVST bundle inbound text \(String(format: "0x%04x", command.code.rawValue)): \(command.text(limit: 600))")
        }

        let hexLimit = commands.contains { $0.code == 0x0101 || $0.code == 0x0111 } ? buffer.data.count : 32
        let hex = [UInt8](buffer.data.prefix(hexLimit)).map { String(format: "%02x", $0) }.joined()
        var line = "NVST bundle inbound '\(dataChannel.label)' id=\(dataChannel.channelId)"
        line += " bytes=\(buffer.data.count) binary=\(buffer.isBinary) cmds=[\(decoded)]"
        if !trailing.isEmpty { line += " unparsed=\(trailing.count)" }
        line += " hex=\(hex)"
        logger?(line)
        for command in commands where command.terminationReason != nil {
            logger?("NVST bundle seat terminated the session: \(command.summary)")
        }
    }

    static let maxLoggedInboundMessages = 40

    static let maxLoggedHapticChanges = 400

    func describeHapticCommand(_ command: NvstStreamingCommand, events: [NvstHapticEvent]) {
        let signature = events.map { "\($0.gamepadIndex):\($0.leftMotor):\($0.rightMotor)" }.joined(separator: ",")
        let (shouldLog, ordinal): (Bool, Int) = lock.withLock {
            hapticCommandCount += 1
            hapticEventCount += events.count
            let changed = signature != lastHapticSignature
            if changed { lastHapticSignature = signature; hapticChangeCount += 1 }
            return ((changed && hapticChangeCount <= Self.maxLoggedHapticChanges) || hapticCommandCount % 2000 == 0, hapticCommandCount)
        }
        guard shouldLog else { return }
        let hex = command.payload.prefix(24).map { String(format: "%02x", $0) }.joined()
        let records = events.isEmpty ? "unparsed" : events.map(\.summary).joined(separator: " | ")
        logger?("NVST haptic #\(ordinal) len=\(command.payload.count) \(records) payload=\(hex)")
    }

    public var hapticCounters: (commands: Int, events: Int) {
        lock.withLock { (hapticCommandCount, hapticEventCount) }
    }

    func adopt(_ dataChannel: RTCDataChannel) {
        adoptControl(dataChannel)
        adoptInput(dataChannel)
        adoptCustom(dataChannel)
        adoptPartiallyReliableControl(dataChannel)

        guard dataChannel.label.lowercased().contains("rtcp"), dataChannel.readyState == .open else { return }
        lock.lock()
        let alreadyOpen = openFeedbackChannel != nil
        if !alreadyOpen { openFeedbackChannel = dataChannel }
        lock.unlock()
        guard !alreadyOpen else { return }
        logger?("NVST bundle feedback channel open id=\(dataChannel.channelId)")
        onFeedbackChannelOpen?()
    }

    func adoptPartiallyReliableControl(_ dataChannel: RTCDataChannel) {
        guard dataChannel.label == "control_channel_partially_reliable", dataChannel.readyState == .open else { return }
        lock.lock()
        let isNew = openPartiallyReliableControlChannel == nil
        if isNew { openPartiallyReliableControlChannel = dataChannel }
        lock.unlock()
        guard isNew else { return }
        logger?("NVST bundle partially-reliable control channel open id=\(dataChannel.channelId)")
        onPartiallyReliableControlOpen?()
    }

    func currentPeerConnection() -> RTCPeerConnection? {
        lock.lock()
        defer { lock.unlock() }
        return peerConnection
    }

    func describeCursorCommand(_ command: NvstStreamingCommand, decision: Bool) {
        let hex = command.payload.prefix(16).map { String(format: "%02x", $0) }.joined()
        let key = "\(command.code.rawValue)/\(hex)/\(decision)"
        let shouldLog: Bool = lock.withLock {
            cursorNotificationCount += 1
            guard key != lastCursorNotification else { return false }
            lastCursorNotification = key
            return true
        }
        guard shouldLog else { return }
        logger?(String(format: "NVST cursor notify code=0x%04x len=%d visible=%@ payload=%@ seen=%d",
                       command.code.rawValue, command.payload.count, decision ? "y" : "n", hex, cursorNotificationCount))
    }

    func describeCursorCommandIfUnparsed(_ command: NvstStreamingCommand) {
        guard command.code == NvstRemoteCursor.bitmapCursorCode else { return }
        let hex = command.payload.prefix(16).map { String(format: "%02x", $0) }.joined()
        let shouldLog: Bool = lock.withLock {
            guard hex != lastUnparsedCursorPayload else { return false }
            lastUnparsedCursorPayload = hex
            return true
        }
        guard shouldLog else { return }
        logger?(String(format: "NVST cursor unparsed code=0x%04x len=%d payload=%@",
                       command.code.rawValue, command.payload.count, hex))
    }

    public struct AudioReception: Sendable {
        public var packets: UInt64 = 0

        public var ssrc: UInt32?
        public var bytes: UInt64 = 0
        public var samples: UInt64 = 0
        public var concealed: UInt64 = 0
        public var discarded: UInt64 = 0

        public var jitterBufferDelaySeconds: Double = 0
        public var jitterBufferEmitted: UInt64 = 0
    }

    public func audioReception() async -> AudioReception? {
        guard let connection = currentPeerConnection() else { return nil }
        guard connection.signalingState != .closed else { return nil }
        return await withCheckedContinuation { continuation in
            let box = StatisticsContinuationBox(continuation)
            connection.statistics { rtcReport in
                box.resume(returning: Self.parseAudioReception(from: rtcReport))
            }
            Task {
                try? await Task.sleep(nanoseconds: 500_000_000)
                box.resume(returning: nil)
            }
        }
    }

    private static func parseAudioReception(from report: RTCStatisticsReport) -> AudioReception? {
        var reception = AudioReception()
        var sawAudio = false
        for (_, statistics) in report.statistics
        where statistics.type == "inbound-rtp" && (statistics.values["kind"] as? String) == "audio" {
            sawAudio = true
            func number(_ key: String) -> UInt64 { (statistics.values[key] as? NSNumber)?.uint64Value ?? 0 }
            reception.packets += number("packetsReceived")
            reception.bytes += number("bytesReceived")
            reception.samples += number("totalSamplesReceived")
            reception.concealed += number("concealedSamples")
            reception.discarded += number("packetsDiscarded")
            reception.jitterBufferDelaySeconds += (statistics.values["jitterBufferDelay"] as? NSNumber)?.doubleValue ?? 0
            reception.jitterBufferEmitted += number("jitterBufferEmittedCount")
            if let ssrc = statistics.values["ssrc"] as? NSNumber { reception.ssrc = ssrc.uint32Value }
        }
        return sawAudio ? reception : nil
    }

    func adoptCustom(_ dataChannel: RTCDataChannel) {
        guard dataChannel.label.hasPrefix("custom_message_on_sctp_private"), dataChannel.readyState == .open else { return }
        lock.lock()
        let isNew = openCustomChannels[dataChannel.label] == nil
        if isNew { openCustomChannels[dataChannel.label] = dataChannel }
        lock.unlock()
        guard isNew else { return }
        logger?("NVST bundle custom channel open '\(dataChannel.label)' id=\(dataChannel.channelId)")
    }

    func adoptInput(_ dataChannel: RTCDataChannel) {
        guard dataChannel.readyState == .open else { return }
        let isReliable = dataChannel.label == "input_channel_v1"
        guard isReliable || dataChannel.label == "input_channel_partially_reliable" else { return }
        lock.lock()
        let alreadyOpen = isReliable ? openReliableInputChannel != nil : openInputChannel != nil
        if !alreadyOpen {
            if isReliable { openReliableInputChannel = dataChannel } else { openInputChannel = dataChannel }
        }
        lock.unlock()
        guard !alreadyOpen else { return }
        logger?("NVST bundle input channel open '\(dataChannel.label)' id=\(dataChannel.channelId)")
    }

    func adoptControl(_ dataChannel: RTCDataChannel) {
        guard dataChannel.label == "control_channel_reliable", dataChannel.readyState == .open else { return }
        lock.lock()
        let alreadyOpen = openControlChannel != nil
        if !alreadyOpen { openControlChannel = dataChannel }
        lock.unlock()
        guard !alreadyOpen else { return }
        logger?("NVST bundle control channel open id=\(dataChannel.channelId)")
        onControlChannelOpen?()
    }
}

private final class StatisticsContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<NvstWebRtcBundle.AudioReception?, Never>?

    init(_ continuation: CheckedContinuation<NvstWebRtcBundle.AudioReception?, Never>) {
        self.continuation = continuation
    }

    func resume(returning value: NvstWebRtcBundle.AudioReception?) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}
