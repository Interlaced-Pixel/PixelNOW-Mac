import CxxStdlib
import Darwin
import Foundation
import NVSTNative

extension NvstBundle {
    public func prepare(microphone: MicrophoneSetup? = nil, channelCount: Int = 2) async throws -> Identity {
        try synchronized {
            guard !closed, dtls == nil, let credentials = handoff.iceCredentials,
                  let fingerprint = credentials.remoteDTLSFingerprint,
                  !credentials.localUsernameFragment.isEmpty, !credentials.remoteUsernameFragment.isEmpty,
                  !credentials.localPassword.isEmpty, !credentials.remotePassword.isEmpty else {
                throw BundleError.transport("Missing credentials, certificate fingerprint, or invalid lifecycle")
            }
            do {
                dtls = pixelnow.DtlsTransport(std.string(fingerprint), handoff.sctpConfiguration.mtu)
                sctp = pixelnow.SctpTransport(nativeSctpConfiguration())
                guard dtls?.valid() == true, sctp?.valid() == true else {
                    throw BundleError.transport(String(dtls?.errorDescription() ?? std.string()) + " " + String(sctp?.errorDescription() ?? std.string()))
                }
                if descriptor < 0 {
                    let reservation = try NvstUdpPortReservation.bindEphemeral()
                    descriptor = reservation.takeDescriptor()
                }
                guard let peerAddress = NVSTWireReceiver.inetAddr(handoff.videoPeerIP) else { throw BundleError.transport("Invalid peer address") }
                var peer = sockaddr_in()
                peer.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                peer.sin_family = sa_family_t(AF_INET)
                peer.sin_port = handoff.videoPeerPort.bigEndian
                peer.sin_addr.s_addr = peerAddress
                let connected = withUnsafePointer(to: &peer) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
                }
                let flags = fcntl(descriptor, F_GETFL, 0)
                guard connected == 0, flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
                    throw BundleError.transport(String(cString: strerror(errno)))
                }
                var socketBuffer: Int32 = 1_048_576
                _ = setsockopt(descriptor, SOL_SOCKET, SO_RCVBUF, &socketBuffer, socklen_t(MemoryLayout<Int32>.size))
                var local = sockaddr_in()
                var length = socklen_t(MemoryLayout<sockaddr_in>.size)
                let named = withUnsafeMutablePointer(to: &local) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
                }
                guard named == 0 else { throw BundleError.transport(String(cString: strerror(errno))) }
                audio = try NvstBundleAudio(channels: channelCount, playout: playout)
                audio?.onFailure = { [weak self] reason in
                    guard let self else { return }
                    self.queue.async { [weak self] in self?.fail("Audio decoder failed: \(reason)") }
                }
                if let microphone {
                    microphoneVolume = microphone.volume
                    microphoneCaptureEnabled = microphone.initiallyEnabled
                    capture.setMuted(!microphone.initiallyEnabled)
                    var configuration = pixelnow.OpusEncoderConfiguration()
                    configuration.channels = 1
                    configuration.bitrate = handoff.microphoneBitrate
                    microphoneEncoder = pixelnow.OpusEncoder(configuration)
                    microphoneProcessor = pixelnow.AudioProcessor()
                    guard microphoneEncoder?.valid() == true else {
                        throw BundleError.transport(String(microphoneEncoder?.errorDescription() ?? std.string()))
                    }
                    guard microphoneProcessor?.valid() == true else {
                        throw BundleError.transport(String(microphoneProcessor?.errorDescription() ?? std.string()))
                    }
                    microphoneSenderSsrc = 1
                    microphoneNegotiated = true
                }
                let device = NvstCoreAudioDevice(owner: self, playout: playout, capture: capture,
                    channels: channelCount, preferredInputDeviceId: microphone?.deviceId ?? "")
                audioDevice = device
                let signal = DispatchSource.makeUserDataAddSource(queue: queue)
                signal.setEventHandler { [weak self] in self?.drainMicrophone() }
                signal.resume()
                microphoneSignal = signal
                let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
                let ownedDescriptor = descriptor
                source.setCancelHandler { Darwin.close(ownedDescriptor) }
                source.setEventHandler { [weak self] in self?.drainSocket() }
                source.resume()
                readSource = source
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.setEventHandler { [weak self] in self?.processDeadlines() }
                timer.schedule(deadline: .distantFuture)
                timer.resume()
                deadlineTimer = timer
                return Identity(bundlePort: UInt16(bigEndian: local.sin_port), localAddress: preferredLocalAddress,
                    dtlsFingerprint: String(dtls?.localFingerprint() ?? std.string()))
            } catch {
                closeLocked()
                throw error
            }
        }
    }

    func nativeSctpConfiguration() -> pixelnow.SctpConfiguration {
        let source = handoff.sctpConfiguration
        var configuration = pixelnow.SctpConfiguration()
        configuration.streams = source.streams
        configuration.mtu = source.mtu
        configuration.initialRtoMilliseconds = source.initialRtoMilliseconds
        configuration.minimumRtoMilliseconds = source.minimumRtoMilliseconds
        configuration.maximumRtoMilliseconds = source.maximumRtoMilliseconds
        configuration.maximumRttMilliseconds = source.maximumRttMilliseconds
        configuration.minimumRttVariance = source.minimumRttVariance
        configuration.initTimeoutMilliseconds = source.initTimeoutMilliseconds
        configuration.cookieTimeoutMilliseconds = source.cookieTimeoutMilliseconds
        configuration.shutdownTimeoutMilliseconds = source.shutdownTimeoutMilliseconds
        configuration.heartbeatIntervalMilliseconds = source.heartbeatIntervalMilliseconds
        configuration.delayedAckMilliseconds = source.delayedAckMilliseconds
        configuration.maximumRetransmissions = source.maximumRetransmissions
        configuration.maximumInitRetransmissions = source.maximumInitRetransmissions
        configuration.initialCongestionWindowMtus = source.initialCongestionWindowMtus
        configuration.minimumCongestionWindowMtus = source.minimumCongestionWindowMtus
        configuration.avoidFragmentationWindowMtus = source.avoidFragmentationWindowMtus
        configuration.maximumBurstPackets = source.maximumBurstPackets
        configuration.maximumTimerBackoffMilliseconds = source.maximumTimerBackoffMilliseconds
        configuration.nackRetransmissionThreshold = source.nackRetransmissionThreshold
        configuration.timeoutCongestionWindowMtus = source.timeoutCongestionWindowMtus
        return configuration
    }

    public func start() throws {
        try synchronized {
            guard !closed, dtls != nil, sctp != nil, descriptor >= 0 else { throw BundleError.transport("Cannot start an unprepared or closed bundle") }
            guard !started else { return }
            try audioDevice?.start(microphone: microphoneNegotiated)
            audio?.start()
            started = true
            let now = DispatchTime.now().uptimeNanoseconds
            handshakeDeadlineNanoseconds = now &+ min(handoff.timeoutMilliseconds, 120_000) * 1_000_000
            dtlsStartNanoseconds = now &+ 30_000_000
            nextPunchNanoseconds = now
            processDeadlines()
        }
    }

    public func close() { synchronized { closeLocked() } }

    func closeLocked() {
        guard !closed else { return }
        closed = true
        audio?.stop()
        audioDevice?.stop()
        audioDevice = nil
        microphoneSignal?.cancel()
        microphoneSignal = nil
        deadlineTimer?.cancel()
        deadlineTimer = nil
        sctp?.close()
        dtls?.close()
        flushDtlsDatagrams()
        writeSource?.cancel()
        writeSource = nil
        if let readSource { readSource.cancel() }
        else if descriptor >= 0 { Darwin.close(descriptor) }
        readSource = nil
        descriptor = -1
        outgoing.removeAll()
        outgoingBytes = 0
        openStreams.removeAll()
        sctp = nil
        dtls = nil
        audio = nil
        microphoneEncoder = nil
        microphoneProcessor = nil
        microphoneNegotiated = false
        microphoneCaptureEnabled = false
        capture.setMuted(true)
        lastRoundTripMilliseconds = -1
    }

    func fail(_ reason: String) {
        guard terminalFailure == nil, !closed else { return }
        terminalFailure = reason
        logger?("NVST native transport failed: \(reason)")
        closeLocked()
        onTransportFailure?(reason)
    }

    func drainSocket() {
        guard started, !closed else { return }
        var drained = 0
        while drained < 512 {
            let count = receiveBuffer.withUnsafeMutableBytes { recv(descriptor, $0.baseAddress, $0.count, 0) }
            if count < 0 {
                if errno == EINTR { continue }
                if errno != EAGAIN && errno != EWOULDBLOCK { fail(String(cString: strerror(errno))) }
                break
            }
            if count == 0 { break }
            drained += 1
            let packet = Data(receiveBuffer.prefix(count))
            let first = receiveBuffer[0]
            let now = DispatchTime.now().uptimeNanoseconds
            if first <= 3 { receiveStun(packet, at: now) }
            else if (20...63).contains(first) {
                packet.withUnsafeBytes { dtls?.receive($0.bindMemory(to: UInt8.self).baseAddress, $0.count) }
                advanceTransport()
            } else if first >> 6 == 2 {
                let rtcp = count > 1 && (192...223).contains(receiveBuffer[1])
                let plain = packet.withUnsafeBytes { dtls?.unprotect($0.bindMemory(to: UInt8.self).baseAddress, $0.count, rtcp) }
                if let plain, !plain.empty() {
                    let authenticated = Data(plain)
                    if rtcp { receiveRtcp(authenticated) }
                    else {
                        audio?.receive(authenticated, at: now)
                        if trackedRemoteAudioCount == 0 { trackedRemoteAudioCount = 1; onRemoteAudio?(1) }
                    }
                }
            }
            if closed { return }
        }
        processDeadlines()
    }

    func receiveStun(_ packet: Data, at now: UInt64) {
        guard let credentials = handoff.iceCredentials else { return }
        let username = "\(credentials.localUsernameFragment):\(credentials.remoteUsernameFragment)"
        if let transaction = NvstStunHolePunch.authenticatedBindingRequestTransactionID(packet,
            integrityKey: Data(credentials.localPassword.utf8), username: username),
           let response = NvstStunHolePunch.buildBindingSuccess(transactionID: transaction,
            mappedHost: handoff.videoPeerIP, mappedPort: handoff.videoPeerPort, integrityKey: Data(credentials.localPassword.utf8)) {
            enqueueDatagram(response)
        } else {
            for (transaction, _) in pendingChecks {
                if NvstStunHolePunch.validateBindingResponse(packet, integrityKey: Data(credentials.remotePassword.utf8), transactionID: transaction) {
                    pendingChecks.removeValue(forKey: transaction)
                    break
                }
            }
        }
        pendingChecks = pendingChecks.filter { now &- $0.value < 10_000_000_000 }
    }

    func sendPunch(at now: UInt64) {
        guard let credentials = handoff.iceCredentials else { return }
        for index in 0..<4 {
            let transaction = Data((0..<12).map { _ in UInt8.random(in: .min ... .max) })
            let username = index == 3 ? "PING:\(credentials.localUsernameFragment)" : "\(credentials.remoteUsernameFragment):\(credentials.localUsernameFragment)"
            if let packet = NvstStunHolePunch.buildBindingRequest(transactionID: transaction, username: username,
                integrityKey: Data(credentials.remotePassword.utf8)) {
                pendingChecks[transaction] = now
                enqueueDatagram(packet)
            }
        }
        pendingChecks = pendingChecks.filter { now &- $0.value < 10_000_000_000 }
        nextPunchNanoseconds = now &+ (dtls?.connected() == true ? 1_000_000_000 : 100_000_000)
    }

    func enqueueDatagram(_ packet: Data) {
        guard descriptor >= 0, !packet.isEmpty else { return }
        guard outgoingBytes + packet.count <= 5 * 1024 * 1024, outgoing.count - outgoingHead < 4096 else {
            fail("UDP send queue exhausted")
            return
        }
        outgoing.append(packet)
        outgoingBytes += packet.count
        flushSocket()
    }

    func flushSocket() {
        guard descriptor >= 0 else { return }
        while outgoingHead < outgoing.count {
            let packet = outgoing[outgoingHead]
            let result = packet.withUnsafeBytes { Darwin.send(descriptor, $0.baseAddress, $0.count, 0) }
            if result < 0 && errno == EINTR { continue }
            if result < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                if writeSource == nil {
                    let source = DispatchSource.makeWriteSource(fileDescriptor: descriptor, queue: queue)
                    source.setEventHandler { [weak self] in self?.flushSocket() }
                    source.resume()
                    writeSource = source
                }
                return
            }
            guard result == packet.count else { fail("UDP send failed: " + String(cString: strerror(errno))); return }
            outgoingHead += 1
            outgoingBytes -= packet.count
        }
        outgoing.removeAll(keepingCapacity: true)
        outgoingHead = 0
        writeSource?.cancel()
        writeSource = nil
    }

    func flushDtlsDatagrams() {
        while let packet = dtls?.nextDatagram(), !packet.empty() { enqueueDatagram(Data(packet)) }
    }

    func advanceTransport() {
        guard !closed else { return }
        guard !advancingTransport else { advanceTransportAgain = true; return }
        advancingTransport = true
        defer { advancingTransport = false }
        repeat {
            advanceTransportAgain = false
            flushDtlsDatagrams()
            if dtls?.connected() == true && !associationStarted {
                associationStarted = true
                nextAudioReportNanoseconds = DispatchTime.now().uptimeNanoseconds &+ 1_000_000_000
                sctp?.connect()
                logger?("NVST native DTLS authenticated profile=\(String(dtls?.srtpProfile() ?? std.string()))")
            }
            while let packet = dtls?.nextApplicationPacket(), !packet.empty() {
                Data(packet).withUnsafeBytes { sctp?.receive($0.bindMemory(to: UInt8.self).baseAddress, $0.count) }
            }
            while let packet = sctp?.nextPacket(), !packet.empty() {
                let sent = Data(packet).withUnsafeBytes { dtls?.sendApplication($0.bindMemory(to: UInt8.self).baseAddress, $0.count) == true }
                guard sent else { fail("DTLS rejected SCTP packet"); return }
                flushDtlsDatagrams()
            }
            processSctpEvents()
            updateMetrics()
            if let dtls, !dtls.valid() { fail(String(dtls.errorDescription())) }
            else if let sctp, !sctp.valid() { fail(String(sctp.errorDescription())) }
        } while advanceTransportAgain && !closed
    }

    func updateMetrics() {
        if let metrics = sctp?.metrics(), metrics.available { lastRoundTripMilliseconds = Double(metrics.srttMilliseconds) }
    }

    func processDeadlines() {
        guard started, !closed else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        if let due = dtlsStartNanoseconds, due <= now { dtlsStartNanoseconds = nil; dtls?.start() }
        if let due = nextPunchNanoseconds, due <= now { sendPunch(at: now) }
        dtls?.processTimeout()
        sctp?.processTimeouts()
        advanceTransport()
        guard !closed else { return }
        if let due = handshakeDeadlineNanoseconds, due <= now {
            guard Set((0..<8).map { UInt16($0 * 2) }).isSubset(of: openStreams) else { fail("DTLS/SCTP channel establishment timed out"); return }
            handshakeDeadlineNanoseconds = nil
        }
        if let due = nextHeartbeatNanoseconds, due <= now {
            let stream = sctp?.reliableInputStream() ?? -1
            _ = sendPayload(NvstRemoteInput.heartbeat, stream: stream >= 0 ? UInt16(stream) : 0)
            nextHeartbeatNanoseconds = now &+ 2_000_000_000
        }
        if let due = nextAudioReportNanoseconds, due <= now {
            sendAudioReports(at: now)
            nextAudioReportNanoseconds = now &+ 1_000_000_000
        }
        scheduleDeadline()
    }

    func scheduleDeadline() {
        guard !closed else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        var deadlines = [dtlsStartNanoseconds, nextPunchNanoseconds, nextHeartbeatNanoseconds,
                         handshakeDeadlineNanoseconds, nextAudioReportNanoseconds].compactMap { $0 }
        for milliseconds in [dtls?.nextTimeoutMilliseconds() ?? -1, sctp?.nextTimeoutMilliseconds() ?? -1] where milliseconds >= 0 {
            deadlines.append(now &+ UInt64(milliseconds) * 1_000_000)
        }
        guard let earliest = deadlines.min() else { deadlineTimer?.schedule(deadline: .distantFuture); return }
        deadlineTimer?.schedule(deadline: DispatchTime(uptimeNanoseconds: max(now &+ 100_000, earliest)), leeway: .microseconds(100))
    }

    func sendPayload(_ payload: Data, stream: UInt16) -> Bool {
        guard !closed, openStreams.contains(stream) else { return false }
        let sent = payload.withUnsafeBytes { sctp?.send(stream, $0.bindMemory(to: UInt8.self).baseAddress, $0.count) == true }
        advanceTransport()
        scheduleDeadline()
        return sent && !closed
    }

    public func sendFeedback(_ payload: Data) -> Bool {
        synchronized {
            let sent = Self.sendsFeedback && sendPayload(payload, stream: 14)
            if !sent { feedbackSendFailures += 1 }
            return sent
        }
    }
    public func sendControl(_ command: NvstStreamingCommand) -> Bool {
        synchronized {
            let encoded = try? command.encoded
            let sent = encoded.map { sendPayload($0, stream: 0) } ?? false
            if sent { controlMessagesSent += 1 } else { controlSendFailures += 1 }
            var counters = controlCommandStats[command.code.rawValue] ?? ControlCommandCounters()
            if sent { counters.messagesSent &+= 1 } else { counters.messagesFailed &+= 1 }
            counters.aggregatedBytes &+= UInt64(encoded?.count ?? command.payload.count + NvstStreamingCommand.headerLength)
            controlCommandStats[command.code.rawValue] = counters
            return sent
        }
    }
    public func sendPartiallyReliableControl(_ command: NvstStreamingCommand) -> Bool {
        synchronized { (try? command.encoded).map { sendPayload($0, stream: 6) } ?? false }
    }
    public func sendInput(_ payload: Data) -> Bool { synchronized { sendInputPayload(payload, stream: 10) } }
    public func sendReliableInput(_ payload: Data) -> Bool {
        synchronized {
            let stream = sctp?.reliableInputStream() ?? -1
            guard stream >= 0 else { inputSendFailures += 1; return false }
            return sendInputPayload(payload, stream: UInt16(stream))
        }
    }
    func sendInputPayload(_ payload: Data, stream: UInt16) -> Bool {
        let sent = sendPayload(payload, stream: stream)
        if sent { inputMessagesSent += 1 } else { inputSendFailures += 1 }
        return sent
    }
    public func sendCustomMessage(_ payload: Data, partiallyReliable: Bool) -> Bool {
        synchronized { sendPayload(payload, stream: partiallyReliable ? 4 : 2) }
    }
}
