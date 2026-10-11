import CxxStdlib
import Foundation
import NVSTNative

extension NvstBundle {
    func processSctpEvents() {
        while let event = sctp?.nextEvent(), event.available {
            switch event.kind {
            case .connected:
                logger?("NVST SCTP association connected")
            case .channelOpened:
                let isNew = openStreams.insert(event.stream).inserted
                logger?("NVST SCTP channel opened id=\(event.stream) label=\(String(event.description))")
                if isNew {
                    if event.stream == 0 { onControlChannelOpen?() }
                    if event.stream == 6 { onPartiallyReliableControlOpen?() }
                    if event.stream == 14 { onFeedbackChannelOpen?() }
                }
            case .channelClosed:
                openStreams.remove(event.stream)
                logger?("NVST SCTP channel closed id=\(event.stream)")
            case .message:
                receiveMessage(Data(event.payload), stream: event.stream)
            case .aborted:
                fail("SCTP aborted: " + String(event.description))
                return
            case .closed:
                fail("SCTP association closed")
                return
            case .restarted:
                openStreams.removeAll()
                negotiatedInputProtocolVersion = nil
                nextHeartbeatNanoseconds = nil
                logger?("NVST SCTP association restarted")
            case .error:
                logger?("NVST SCTP error stream=\(event.stream): \(String(event.description))")
            case .bufferedAmountLow:
                flushSocket()
            case .fullySent, .expired, .delivered, .lifecycleEnded:
                lifecycleEventCount &+= 1
                if event.kind == .expired { expiredMessageCount &+= 1 }
            default:
                logger?("NVST SCTP unexpected event=\(event.kind.rawValue)")
            }
            if closed { return }
        }
    }

    func receiveMessage(_ data: Data, stream: UInt16) {
        let label = stream % 2 == 0 && Int(stream / 2) < Self.channelLabels.count
            ? Self.channelLabels[Int(stream / 2)] : "input_channel_v1"
        inboundFeedbackBytes += data.count
        inboundMessagesByLabel[label, default: 0] += 1
        if let version = NvstRemoteInput.protocolVersion(in: data), negotiatedInputProtocolVersion == nil {
            negotiatedInputProtocolVersion = version
            _ = sendPayload(data, stream: stream)
            nextHeartbeatNanoseconds = DispatchTime.now().uptimeNanoseconds &+ 2_000_000_000
            onInputProtocolNegotiated?(version)
        }
        let (commands, trailing) = NvstStreamingCommand.parse(data)
        for command in commands { dispatchInboundCommand(command, label: label) }
        if loggedInboundMessages < Self.maxLoggedInboundMessages {
            loggedInboundMessages += 1
            logger?("NVST SCTP inbound stream=\(stream) bytes=\(data.count) commands=[\(commands.map(\.summary).joined(separator: " | "))] trailing=\(trailing.count)")
        }
    }

    private func dispatchInboundCommand(_ command: NvstStreamingCommand, label: String) {
        if command.code == .termination || command.terminationReason != nil {
            let reason = command.terminationReason
            let reasonDesc = reason.map { NvstResult.describe($0) } ?? "unspecified"
            let hex = command.payload.map { String(format: "%02x", $0) }.joined()
            logger?("NVST bundle seat terminated the session (channel=\(label)): \(command.summary) reason=\(reasonDesc) payload=\(hex)")
            onSeatTermination?(reason, command.summary)
            return
        }
        if command.code == .terminationTimer || command.code == 0x0104 || command.code == 0x0105 {
            let hex = command.payload.map { String(format: "%02x", $0) }.joined()
            logger?("NVST bundle seat termination timer warning (channel=\(label)): code=\(command.code.description) len=\(command.payload.count) payload=\(hex)")
            onSeatTerminationTimer?(command.code.rawValue, command.payload)
            return
        }
        if command.isTextual {
            logger?("NVST bundle inbound text (channel=\(label)) \(String(format: "0x%04x", command.code.rawValue)): \(command.text(limit: 600))")
        }
        if command.code == .inputProtocolVersion, command.payload.count >= 2 {
            var payload = NvstByteReader(command.payload)
            if let version = try? payload.u16LE() {
                let isNew: Bool = synchronized {
                    guard negotiatedInputProtocolVersion == nil else { return false }
                    negotiatedInputProtocolVersion = version
                    return true
                }
                if isNew {
                    logger?("NVST bundle input protocol version \(version) from inbound command")
                    if let encoded = try? command.encoded { _ = sendPayload(encoded, stream: 0) }
                    nextHeartbeatNanoseconds = DispatchTime.now().uptimeNanoseconds &+ 2_000_000_000
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
            do { try audio?.configure(surround) }
            catch { fail("Invalid seat audio layout: \(error.localizedDescription)"); return }
            currentAudioSurroundInfo = surround
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

    static let maxLoggedInboundMessages = 40

    static let maxLoggedHapticChanges = 400

    func describeHapticCommand(_ command: NvstStreamingCommand, events: [NvstHapticEvent]) {
        let signature = events.map { "\($0.gamepadIndex):\($0.leftMotor):\($0.rightMotor)" }.joined(separator: ",")
        let (shouldLog, ordinal): (Bool, Int) = synchronized {
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

    func describeCursorCommand(_ command: NvstStreamingCommand, decision: Bool) {
        let hex = command.payload.prefix(16).map { String(format: "%02x", $0) }.joined()
        let key = "\(command.code.rawValue)/\(hex)/\(decision)"
        let shouldLog: Bool = synchronized {
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
        let shouldLog: Bool = synchronized {
            guard hex != lastUnparsedCursorPayload else { return false }
            lastUnparsedCursorPayload = hex
            return true
        }
        guard shouldLog else { return }
        logger?(String(format: "NVST cursor unparsed code=0x%04x len=%d payload=%@",
                       command.code.rawValue, command.payload.count, hex))
    }

}
