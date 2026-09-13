import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation

extension NVSTCoreTransport {

    public func send(_ event: UserInputEvent) async throws {
        guard let bundle, bundle.isInputReady else {
            throw NativeNVSTError.transportFailed("NVST input is not negotiated yet (channels open: \(bundle?.isInputChannelOpen == true), protocol: \(bundle?.inputProtocolVersion.map(String.init) ?? "none")).")
        }

        if case .gamepad(let state) = event {

            let padIndex = state.playerIndex
            guard (0..<4).contains(padIndex) else {
                throw NativeNVSTError.transportFailed("NVST has no gamepad slot \(padIndex); the seat allows 0...3.")
            }

            guard connectedGamepadIndices.contains(padIndex) else {
                gamepadPacketsDroppedForUnannouncedPad += 1
                return
            }
            let bitmap = NvstGamepadEvent.connectedBitmap(for: connectedGamepadIndices)
            if registeredGamepadBitmap != bitmap {
                sendGamepadRegistration(bitmap: bitmap, bundle: bundle, reason: "pad \(padIndex) input")
            }
            let sequence = (gamepadSequences[UInt16(padIndex)] ?? 0) &+ 1
            gamepadSequences[UInt16(padIndex)] = sequence

            let (lx, ly) = Self.deadzoned(state.leftStickX, state.leftStickY, Self.leftStickDeadzone)
            let (rx, ry) = Self.deadzoned(state.rightStickX, state.rightStickY, Self.rightStickDeadzone)
            let packet = NvstGamepadEvent(
                sequence: sequence,
                timestampMicroseconds: sessionElapsedMicroseconds(),
                buttons: Self.wireButtons(state.buttons),
                leftTrigger: NvstGamepadEvent.trigger(state.leftTrigger),
                rightTrigger: NvstGamepadEvent.trigger(state.rightTrigger),
                leftStickX: NvstGamepadEvent.axis(lx),
                leftStickY: NvstGamepadEvent.axis(ly),
                rightStickX: NvstGamepadEvent.axis(rx),
                rightStickY: NvstGamepadEvent.axis(ry),
                gamepadIndex: UInt16(padIndex),
                connectedBitmap: bitmap
            )

            let padSendStart = DispatchTime.now().uptimeNanoseconds
            let delivered = (try? packet.command.encoded).map(bundle.sendInput) ?? false
            noteInputSend(from: padSendStart)
            if delivered { gamepadPacketsSent += 1 } else { gamepadSendFailures += 1 }
            guard delivered else {
                throw NativeNVSTError.transportFailed("The NVST input channel rejected the gamepad state.")
            }
            inputEventsSent += 1
            return
        }

        if case .text(_, let value, _) = event {
            try sendAsUtf8Text(value)
            return
        }
        guard let packet = Self.remoteInputPacket(for: event) else {

            throw NativeNVSTError.transportFailed("No NVST remote-input encoding for \(event) yet.")
        }
        try sendFramedRemoteInput(packet)
    }

    public nonisolated func sendNow(_ event: UserInputEvent) {
        guard let bundle = activeBundleHolder.get(), bundle.isInputReady else { return }
        if case .gamepad(let state) = event {
            let padIndex = state.playerIndex
            guard (0..<4).contains(padIndex) else { return }
            let sequence = inputState.nextGamepadSequence(padIndex: UInt16(padIndex))
            let (lx, ly) = Self.deadzoned(state.leftStickX, state.leftStickY, Self.leftStickDeadzone)
            let (rx, ry) = Self.deadzoned(state.rightStickX, state.rightStickY, Self.rightStickDeadzone)
            let bitmap: UInt8 = 1 << padIndex
            let packet = NvstGamepadEvent(
                sequence: sequence,
                timestampMicroseconds: clock.elapsedMicroseconds(),
                buttons: Self.wireButtons(state.buttons),
                leftTrigger: NvstGamepadEvent.trigger(state.leftTrigger),
                rightTrigger: NvstGamepadEvent.trigger(state.rightTrigger),
                leftStickX: NvstGamepadEvent.axis(lx),
                leftStickY: NvstGamepadEvent.axis(ly),
                rightStickX: NvstGamepadEvent.axis(rx),
                rightStickY: NvstGamepadEvent.axis(ry),
                gamepadIndex: UInt16(padIndex),
                connectedBitmap: UInt16(bitmap)
            )
            let sendStart = DispatchTime.now().uptimeNanoseconds
            if let encoded = try? packet.command.encoded {
                let sent = bundle.sendInput(encoded)
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds &- sendStart) / 1_000_000
                if sent { inputState.noteSend(durationMs: elapsed) }
            }
            return
        }
        if case .text(_, let value, _) = event {
            Task { try? await self.sendAsUtf8Text(value) }
            return
        }
        guard let packet = Self.remoteInputPacket(for: event) else { return }
        sendFramedRemoteInputNow(packet, bundle: bundle)
    }

    public nonisolated func sendAbsoluteMouseMoveNow(_ event: NativeNVSTAbsoluteMouseEvent) {
        guard let bundle = activeBundleHolder.get(), bundle.isInputReady else { return }
        let packet = NvstRemoteInput.absoluteMouseMove(
            x: UInt16(clamping: event.x),
            y: UInt16(clamping: event.y),
            viewportWidth: UInt16(clamping: event.viewportWidth),
            viewportHeight: UInt16(clamping: event.viewportHeight)
        )
        sendFramedRemoteInputNow(packet, bundle: bundle)
    }

    private nonisolated func sendFramedRemoteInputNow(_ packet: Data, bundle: NvstWebRtcBundle) {
        let sequence = inputState.nextSequence()
        let elapsed = clock.elapsedMicroseconds()
        let framed = NvstRemoteInput.framed(packet,
                                            framing: .enveloped,
                                            sequence: UInt16(truncatingIfNeeded: sequence),
                                            timestampMicroseconds: elapsed)
        let sendStart = DispatchTime.now().uptimeNanoseconds
        let accepted = bundle.sendControl(NvstStreamingCommand(code: NvstRemoteInput.commandCode, payload: framed))
        let duration = Double(DispatchTime.now().uptimeNanoseconds &- sendStart) / 1_000_000
        if accepted {
            inputState.noteSend(durationMs: duration)
        }
    }

    func sendFramedRemoteInput(_ packet: Data) throws {
        guard let bundle, bundle.isInputReady else {
            throw NativeNVSTError.transportFailed("NVST input is not negotiated yet.")
        }
        inputSequence &+= 1
        let framed = NvstRemoteInput.framed(packet,
                                            framing: .enveloped,
                                            sequence: inputSequence,
                                            timestampMicroseconds: sessionElapsedMicroseconds())
        let sendStart = DispatchTime.now().uptimeNanoseconds
        let accepted = bundle.sendControl(NvstStreamingCommand(code: NvstRemoteInput.commandCode, payload: framed))
        noteInputSend(from: sendStart)
        guard accepted else {
            throw NativeNVSTError.transportFailed("The NVST control channel rejected the input packet.")
        }
        inputEventsSent += 1
    }

    func noteInputSend(from start: UInt64) {
        let end = DispatchTime.now().uptimeNanoseconds
        let milliseconds = end > start ? Double(end - start) / 1_000_000 : 0
        inputSendTotalMs += milliseconds
        if milliseconds > inputSendPeakMs { inputSendPeakMs = milliseconds }
    }

    enum InputDestination: String, CaseIterable {
        case control
    }

    public func setMaximumBitrateKbps(_ bitrateKbps: UInt32) async throws {
        guard let bundle else { throw NativeNVSTError.notRunning }
        var writer = NvstByteWriter(capacity: 8)
        writer.u32LE(0)
        writer.u32LE(bitrateKbps)
        let command = NvstStreamingCommand(code: .maxBitrateChange, payload: writer.data)
        guard bundle.sendControl(command) else {
            throw NativeNVSTError.transportFailed(
                "Failed to send maximum bitrate change (\(bitrateKbps) kbps) over control channel")
        }
        logger?("NVST sent maximum bitrate change: \(bitrateKbps) kbps")
    }

    private func sampleAudioJitterBufferMilliseconds() async -> Double {
        var milliseconds = -1.0
        if let audio = await bundle?.audioReception() {
            if let previous = lastAudioJitterSample, audio.jitterBufferEmitted > previous.emitted {
                milliseconds = (audio.jitterBufferDelaySeconds - previous.delaySeconds) / Double(audio.jitterBufferEmitted - previous.emitted) * 1000
            }
            lastAudioJitterSample = (audio.jitterBufferDelaySeconds, audio.jitterBufferEmitted)
        }
        lastAudioJitterBufferMilliseconds = milliseconds
        return milliseconds
    }

    private func lossPercentSinceLastSnapshot(packetsNow: UInt64, lostNow: UInt64) -> Double {
        let packetsDelta = packetsNow >= lastSnapshotPackets ? packetsNow - lastSnapshotPackets : 0
        let lostDelta = lostNow >= lastSnapshotLost ? lostNow - lastSnapshotLost : 0
        lastSnapshotPackets = packetsNow
        lastSnapshotLost = lostNow
        return packetsDelta + lostDelta > 0 ? Double(lostDelta) * 100 / Double(packetsDelta + lostDelta) : 0
    }

    public func performanceSnapshot() async -> NativeNVSTPerformanceSnapshot? {
        guard let receiver, let started = sessionStartedAt else { return nil }
        let counters = receiver.feedbackCounters
        let now = Date()
        let elapsed = max(0.001, now.timeIntervalSince(started))

        let interval = lastSnapshotAt.map { max(0.001, now.timeIntervalSince($0)) } ?? elapsed
        let audioJitterBufferMilliseconds = await sampleAudioJitterBufferMilliseconds()
        let framesSinceLast = counters.framesEmitted &- lastSnapshotFrames
        let bytesSinceLast = counters.bytesReceived &- lastSnapshotBytes
        let instantFps = Double(framesSinceLast) / interval
        let instantMbps = Double(bytesSinceLast) * 8 / interval / 1_000_000
        lastSnapshotAt = now
        lastSnapshotFrames = counters.framesEmitted
        lastSnapshotBytes = counters.bytesReceived

        let stats = receiver.stats
        let lossPercent = lossPercentSinceLastSnapshot(packetsNow: UInt64(stats.authenticatedPackets), lostNow: UInt64(stats.lastCumulativeLost))

        bundle?.refreshTransportStatistics()
        let roundTrip = bundle?.roundTripMilliseconds ?? -1
        let video = videoPipeline?.snapshot
        let decodeMilliseconds = (video?.framesHandled ?? 0) > 0
            ? (video?.total.decode ?? 0) / Double(video?.framesHandled ?? 1)
            : -1

        let seatStats = latestSeatStats

        var mjolnirRoundTrip = receiver.roundTripMilliseconds
        if mjolnirRoundTrip < 0, let session {
            mjolnirRoundTrip = await session.controlRoundTripMilliseconds()
        }
        return NativeNVSTPerformanceSnapshot(
            available: counters.framesEmitted > 0,
            gameFramesPerSecond: seatStats?.gameFramesPerSecond ?? -1,
            streamFramesPerSecond: instantFps,

            latencyMilliseconds: roundTrip >= 0 ? roundTrip : mjolnirRoundTrip,
            jitterMilliseconds: Double(stats.lastJitter) * 1000 / Double(NvstVideoToolboxDecoder.clockRate),
            frameLoss: stats.abandonedFrames,
            totalFrameLoss: stats.abandonedFrames + UInt64(video?.missingParameterSetFrames ?? 0),
            packetLoss: UInt64(stats.lastCumulativeLost),
            totalPacketLoss: stats.droppedPackets,
            packetLossPercent: lossPercent,
            decodeMilliseconds: decodeMilliseconds,
            decodedFrameCount: decoder?.decodedFrameCount ?? 0,
            bitrateMegabitsPerSecond: instantMbps,
            bandwidthUtilizationPercent: 0,

            resolution: decoder?.decodedResolution ?? negotiatedResolution ?? "",
            codec: negotiatedCodec ?? lastHandoff.map { String(describing: $0.codec) } ?? "",

            serverLocation: sessionServerLocation ?? lastHandoff?.videoPeerIP ?? "",
            negotiatedFramesPerSecond: negotiatedFps.map(Double.init) ?? -1,
            decoderIsHardware: decoder?.isHardwareAccelerated ?? true,
            bitstreamFormat: decoder?.bitstreamFormat?.summary ?? "",
            decoderOutputFormat: decoder?.outputPixelFormatName ?? "",
            targetBitrateMegabitsPerSecond: configuredMaxBitrateKbps.map { Double($0) / 1000 } ?? -1,
            serverGPU: sessionGPUType ?? "",
            audioJitterBufferMilliseconds: audioJitterBufferMilliseconds,
            audioOutputLatencyMilliseconds: bundle?.audioOutputLatencySeconds.map { $0 * 1000 } ?? -1
        )
    }

    public func setDynamicStreamingMode(_ mode: NativeNVSTDynamicStreamingMode) async throws {
        guard let bundle else { throw NativeNVSTError.notRunning }
        var writer = NvstByteWriter(capacity: 8)
        writer.u32LE(0)
        writer.u32LE(UInt32(mode.rawValue))
        let command = NvstStreamingCommand(code: .qosPreferenceChange, payload: writer.data)
        guard bundle.sendControl(command) else {
            throw NativeNVSTError.transportFailed(
                "Failed to send dynamic streaming mode change (\(mode)) over control channel")
        }
        logger?("NVST sent dynamic streaming mode change: \(mode)")
    }

    public func setL4SEnabled(_ enabled: Bool) async throws {
        guard let bundle else { throw NativeNVSTError.notRunning }
        var writer = NvstByteWriter(capacity: 8)
        writer.u32LE(0)
        writer.u32LE(enabled ? 1 : 0)
        let command = NvstStreamingCommand(code: .l4sStateChange, payload: writer.data)
        guard bundle.sendControl(command) else {
            throw NativeNVSTError.transportFailed(
                "Failed to send L4S state change (\(enabled)) over control channel")
        }
        logger?("NVST sent L4S state change: \(enabled)")
    }

    public func updateGamepadTopology(_ topology: NativeNVSTGamepadTopology) async throws {
        let indices = Set(topology.playerIndices).isEmpty ? Set([0]) : Set(topology.playerIndices)
        connectedGamepadIndices = indices

        gamepadSequences = gamepadSequences.filter { indices.contains(Int($0.key)) }
        guard let bundle, bundle.isInputReady else {
            throw NativeNVSTError.transportFailed("NVST input is not negotiated yet.")
        }
        let bitmap = NvstGamepadEvent.connectedBitmap(for: indices)
        guard registeredGamepadBitmap != bitmap else { return }
        sendGamepadRegistration(bitmap: bitmap, bundle: bundle, reason: "topology \(indices.sorted())")
    }

    func sendGamepadRegistration(bitmap: UInt16, bundle: NvstWebRtcBundle, reason: String) {
        let registered = bundle.sendControl(NvstInputActivation.deviceDescriptor(
            timestampMicroseconds: sessionElapsedMicroseconds(),
            connectedBitmap: bitmap))
        registeredGamepadBitmap = bitmap
        logger?("NVST gamepad registration bitmap=0x\(String(bitmap, radix: 16)) reason=\(reason) sent=\(registered) inputReady=\(bundle.isInputReady) inputChannelOpen=\(bundle.isInputChannelOpen)")
    }

    public func setMicrophoneConfiguration(_ configuration: NativeNVSTMicrophoneConfiguration) async throws {
        microphoneConfiguration = configuration
    }

    public func pause() async throws {
        recorder.stop()
        await teardown(reason: "pause")
    }

    func sendAsUtf8Text(_ text: String) throws {
        let (packets, droppedBytes) = NvstRemoteInput.utf8TextPackets(forText: text)
        guard !packets.isEmpty else {
            throw NativeNVSTError.transportFailed(
                "No NVST encoding for text \"\(text.prefix(16))\": it produced no UTF-8 bytes.")
        }
        if droppedBytes > 0 {
            textBytesDropped += droppedBytes
            logger?("NVST text dropped \(droppedBytes) unchunkable UTF-8 byte(s); sending the rest")
        }
        for packet in packets {
            try sendFramedRemoteInput(packet)
        }
        textCharactersTyped += text.count
    }

    public func sendAbsoluteMouseMove(_ event: NativeNVSTAbsoluteMouseEvent) async throws {
        guard let bundle, bundle.isInputReady else {
            throw NativeNVSTError.transportFailed("NVST input is not negotiated yet.")
        }
        let packet = NvstRemoteInput.absoluteMouseMove(
            x: UInt16(clamping: event.x),
            y: UInt16(clamping: event.y),
            viewportWidth: UInt16(clamping: event.viewportWidth),
            viewportHeight: UInt16(clamping: event.viewportHeight)
        )
        try sendFramedRemoteInput(packet)
    }

    static let leftStickDeadzone: Float = 0.2395
    static let rightStickDeadzone: Float = 0.2651

    static func deadzoned(_ x: Float, _ y: Float, _ deadzone: Float) -> (Float, Float) {
        let magnitude = (x * x + y * y).squareRoot()
        guard magnitude > deadzone else { return (0, 0) }
        let scale = ((magnitude - deadzone) / (1 - deadzone)) / magnitude
        return (x * scale, y * scale)
    }

    static func wireButtons(_ buttons: GamepadButtons) -> UInt16 {
        var mask: UInt16 = 0
        let mapping: [(GamepadButtons, UInt16)] = [
            (.south, NvstGamepadEvent.Button.a),
            (.east, NvstGamepadEvent.Button.b),
            (.west, NvstGamepadEvent.Button.x),
            (.north, NvstGamepadEvent.Button.y),
            (.leftShoulder, NvstGamepadEvent.Button.leftShoulder),
            (.rightShoulder, NvstGamepadEvent.Button.rightShoulder),
            (.select, NvstGamepadEvent.Button.back),
            (.start, NvstGamepadEvent.Button.start),
            (.dpadUp, NvstGamepadEvent.Button.dPadUp),
            (.dpadDown, NvstGamepadEvent.Button.dPadDown),
            (.dpadLeft, NvstGamepadEvent.Button.dPadLeft),
            (.dpadRight, NvstGamepadEvent.Button.dPadRight),
            (.leftStick, NvstGamepadEvent.Button.leftThumb),
            (.rightStick, NvstGamepadEvent.Button.rightThumb),

            (.mode, NvstGamepadEvent.Button.guide),
        ]
        for (ours, theirs) in mapping where buttons.contains(ours) { mask |= theirs }
        return mask
    }

    static func remoteInputPacket(for event: UserInputEvent) -> Data? {
        switch event {
        case .mouse(.moved(_, let deltaX, let deltaY, _)):
            NvstRemoteInput.mouseMove(deltaX: deltaX, deltaY: deltaY)
        case .mouse(.button(_, let button, let isPressed, _)):
            NvstRemoteInput.mouseButton(Self.wireButton(button), isPressed: isPressed)
        case .keyboard(let event):
            NvstRemoteInput.keyboard(
                virtualKey: keyboardCodes(forMacKeyCode: event.keyCode).keyCode,
                modifiers: event.modifiers.rawValue & 0x000f,
                isPressed: event.isPressed
            )
        case .mouse(.wheel(_, let delta, _)):
            NvstRemoteInput.mouseWheel(delta: delta)
        case .text, .gamepad:
            nil
        }
    }

    static func keyboardCodes(forMacKeyCode macKeyCode: UInt16) -> (keyCode: UInt16, scanCode: UInt16) {
        keyboardCodeMap[macKeyCode] ?? (macKeyCode, macKeyCode)
    }

    private static let keyboardCodeMap: [UInt16: (keyCode: UInt16, scanCode: UInt16)] = [
        0: (65, 0x1e),
        1: (83, 0x1f),
        2: (68, 0x20),
        3: (70, 0x21),
        4: (72, 0x23),
        5: (71, 0x22),
        6: (90, 0x2c),
        7: (88, 0x2d),
        8: (67, 0x2e),
        9: (86, 0x2f),
        10: (192, 0x29),
        11: (66, 0x30),
        12: (81, 0x10),
        13: (87, 0x11),
        14: (69, 0x12),
        15: (82, 0x13),
        16: (89, 0x15),
        17: (84, 0x14),
        18: (49, 0x02),
        19: (50, 0x03),
        20: (51, 0x04),
        21: (52, 0x05),
        22: (54, 0x07),
        23: (53, 0x06),
        24: (187, 0x0d),
        25: (57, 0x0a),
        26: (55, 0x08),
        27: (189, 0x0c),
        28: (56, 0x09),
        29: (48, 0x0b),
        30: (221, 0x1b),
        31: (79, 0x18),
        32: (85, 0x16),
        33: (219, 0x1a),
        34: (73, 0x17),
        35: (80, 0x19),
        36: (13, 0x1c),
        37: (76, 0x26),
        38: (74, 0x24),
        39: (222, 0x28),
        40: (75, 0x25),
        41: (186, 0x27),
        42: (220, 0x2b),
        43: (188, 0x33),
        44: (191, 0x35),
        45: (78, 0x31),
        46: (77, 0x32),
        47: (190, 0x34),
        48: (9, 0x0f),
        49: (32, 0x39),
        50: (192, 0x29),
        51: (8, 0x0e),
        53: (27, 0x01),
        54: (0xa2, 0x1d),
        55: (0xa2, 0x1d),
        56: (0xa0, 0x2a),
        57: (0x14, 0x3a),
        58: (0xa4, 0x38),
        59: (0xa2, 0x1d),
        60: (0xa1, 0x36),
        61: (0xa5, 0x38),
        62: (0xa3, 0x1d),
        65: (110, 0x53),
        67: (106, 0x37),
        69: (107, 0x4e),
        71: (12, 0x45),
        75: (111, 0x35),
        76: (13, 0x1c),
        78: (109, 0x4a),
        81: (187, 0x0d),
        82: (96, 0x52),
        83: (97, 0x4f),
        84: (98, 0x50),
        85: (99, 0x51),
        86: (100, 0x4b),
        87: (101, 0x4c),
        88: (102, 0x4d),
        89: (103, 0x47),
        91: (104, 0x48),
        92: (105, 0x49),
        96: (116, 0x3f),
        97: (117, 0x40),
        98: (118, 0x41),
        99: (114, 0x3d),
        100: (119, 0x42),
        101: (120, 0x43),
        103: (122, 0x44),
        105: (124, 0x64),
        106: (127, 0x6a),
        107: (145, 0x46),
        109: (121, 0x44),
        111: (123, 0x58),
        114: (45, 0x52),
        115: (36, 0x47),
        116: (33, 0x49),
        117: (46, 0x53),
        118: (115, 0x3e),
        119: (35, 0x4f),
        120: (113, 0x3c),
        121: (34, 0x51),
        122: (112, 0x3b),
        123: (37, 0x4b),
        124: (39, 0x4d),
        125: (40, 0x50),
        126: (38, 0x48)
    ]

    static func wireButton(_ button: MouseButton) -> NvstRemoteInput.Button {
        switch button {
        case .left: .left
        case .right: .right
        case .middle: .middle
        case .back: .extra1
        case .forward: .extra2
        }
    }

    public func setMicrophoneEnabled(_ enabled: Bool) async throws {
        guard let bundle else { throw NativeNVSTError.notRunning }
        guard microphoneNegotiated else {
            guard enabled else { return }

            if microphoneOfferedOnBundle {
                throw NativeNVSTError.transportFailed("The NVST bundle negotiated no microphone channel, so capture cannot start.")
            }
            throw NativeNVSTError.transportFailed(
                "This seat streams the microphone over its legacy transport, which is currently unavailable.")
        }
        bundle.setMicrophoneCaptureEnabled(enabled)
        logger?("NVST microphone \(enabled ? "enabled" : "disabled")")
    }

    public func microphoneStatus() async -> NativeNVSTMicrophoneStatus {
        guard bundle != nil else { return .disabled }
        return microphoneNegotiated ? .available : .capturerUnavailable
    }

    public func togglePerformanceOverlay() async throws {
        throw NativeNVSTError.notRunning
    }

    public func setLocalAudioPlaybackMuted(_ muted: Bool) async throws {
        guard let bundle else { throw NativeNVSTError.notRunning }
        bundle.setRemoteAudioMuted(muted)
    }

    public func setLocalAudioPlaybackVolume(_ volume: Double) async throws {
        guard let bundle else { throw NativeNVSTError.notRunning }
        bundle.setRemoteAudioVolume(volume)
    }
}
