import CxxStdlib
import Darwin
import Foundation
import NVSTNative

public final class NvstBundle: @unchecked Sendable {
    public struct Identity: Equatable, Sendable {
        public let bundlePort: UInt16
        public let localAddress: String?
        public let dtlsFingerprint: String
    }

    public struct MicrophoneSetup: Equatable, Sendable {
        public let volume: Double
        public let deviceId: String
        public let initiallyEnabled: Bool
        public init(volume: Double, deviceId: String = "", initiallyEnabled: Bool) {
            self.volume = min(max(volume.isFinite ? volume : 1, 0), 1)
            self.deviceId = deviceId
            self.initiallyEnabled = initiallyEnabled
        }
    }

    public enum BundleError: LocalizedError, Equatable, Sendable {
        case transport(String)
        public var errorDescription: String? {
            switch self { case .transport(let reason): "NVST bundle: \(reason)" }
        }
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

    struct ControlCommandCounters {
        var messagesSent: UInt64 = 0
        var messagesFailed: UInt64 = 0
        var aggregatedBytes: UInt64 = 0
    }

    static let channelLabels = [
        "control_channel_reliable", "custom_message_on_sctp_private_reliable",
        "custom_message_on_sctp_private_partially_reliable", "control_channel_partially_reliable",
        "control_channel_unreliable", "input_channel_partially_reliable",
        "cursor_channel", "rtcp_on_sctp_private"
    ]
    public static let feedbackChannelLabel = NvstFeedbackSender.channelLabel
    public static var sendsFeedback: Bool { ProcessInfo.processInfo.environment["PIXELNOW_NVST_FEEDBACK"] != "0" }
    let handoff: NVSTVideoHandoff
    let preferredLocalAddress: String?
    let logger: (@Sendable (String) -> Void)?
    let queue: DispatchQueue
    let queueKey = DispatchSpecificKey<UInt8>()
    var descriptor: Int32
    var readSource: DispatchSourceRead?
    var writeSource: DispatchSourceWrite?
    var deadlineTimer: DispatchSourceTimer?
    var microphoneSignal: DispatchSourceUserDataAdd?
    var dtls: pixelnow.DtlsTransport?
    var sctp: pixelnow.SctpTransport?
    var audio: NvstBundleAudio?
    var audioDevice: NvstCoreAudioDevice?
    let playout = NvstPcmBuffer()
    let capture = NvstPcmBuffer()
    let renderReference = NvstPcmBuffer()
    var microphoneProcessor: pixelnow.AudioProcessor?
    var outgoing: [Data] = []
    var outgoingHead = 0
    var outgoingBytes = 0
    var receiveBuffer = [UInt8](repeating: 0, count: 65_536)
    var pendingChecks: [Data: UInt64] = [:]
    var started = false
    var closed = false
    var associationStarted = false
    var advancingTransport = false
    var advanceTransportAgain = false
    var dtlsStartNanoseconds: UInt64?
    var nextPunchNanoseconds: UInt64?
    var nextHeartbeatNanoseconds: UInt64?
    var handshakeDeadlineNanoseconds: UInt64?
    var lastRoundTripMilliseconds = -1.0
    var openStreams = Set<UInt16>()
    var negotiatedInputProtocolVersion: UInt16?
    var trackedRemoteAudioCount = 0
    var currentAudioSurroundInfo: NvstAudioSurroundInfo?
    var microphoneNegotiated = false
    var microphoneSenderSsrc: UInt32?
    var microphoneCaptureEnabled = false
    var microphoneVolume = 1.0
    var microphoneSentDataBytes: UInt64 = 0
    var microphoneSeatReportedPackets: UInt64 = 0
    var microphoneEncoder: pixelnow.OpusEncoder?
    var microphoneSequence: UInt16 = UInt16.random(in: .min ... .max)
    var microphoneInitialSequence: UInt16?
    var microphoneTimestamp: UInt32 = UInt32.random(in: .min ... .max)
    var previousMicrophonePayloads: [(timestamp: UInt32, payload: Data)] = []
    var lastMicrophoneReportNanoseconds: UInt64 = 0
    var microphonePacketCount: UInt32 = 0
    var microphonePayloadBytes: UInt32 = 0
    var microphoneClockNanoseconds: UInt64?
    var microphoneClockTimestamp: UInt32 = 0
    var nextAudioReportNanoseconds: UInt64?
    var lastAudioSenderReport: UInt32 = 0
    var lastAudioSenderReportNanoseconds: UInt64 = 0
    var controlCommandStats: [UInt16: ControlCommandCounters] = [:]
    var controlMessagesSent = 0
    var controlSendFailures = 0
    var inputMessagesSent = 0
    var inputSendFailures = 0
    var feedbackSendFailures = 0
    var inboundFeedbackBytes = 0
    var inboundMessagesByLabel: [String: Int] = [:]
    var loggedInboundMessages = 0
    var hapticCommandCount = 0
    var hapticEventCount = 0
    var hapticChangeCount = 0
    var lastHapticSignature = ""
    var lastCursorNotification: String?
    var lastUnparsedCursorPayload: String?
    var cursorNotificationCount = 0
    var terminalFailure: String?
    var lifecycleEventCount: UInt64 = 0
    var expiredMessageCount: UInt64 = 0

    public var onFeedbackChannelOpen: (@Sendable () -> Void)?
    public var onControlChannelOpen: (@Sendable () -> Void)?
    public var onPartiallyReliableControlOpen: (@Sendable () -> Void)?
    public var onInputProtocolNegotiated: (@Sendable (UInt16) -> Void)?
    public var onRemoteCursor: (@Sendable (NvstRemoteCursor) -> Void)?
    public var onSeatStats: (@Sendable (NvstSeatStats) -> Void)?
    public var onHapticEvents: (@Sendable ([NvstHapticEvent]) -> Void)?
    public var onHdrMode: (@Sendable (NvstHdrModeNotification) -> Void)?
    public var onAudioSurroundInfo: (@Sendable (NvstAudioSurroundInfo) -> Void)?
    public var onSeatTermination: (@Sendable (NvstTerminationPayload?, String) -> Void)?
    public var onSeatTerminationTimer: (@Sendable (UInt16, Data) -> Void)?
    public var onHidChangeResponse: (@Sendable (UInt8, UInt8) -> Void)?
    public var onRemoteAudio: (@Sendable (Int) -> Void)?
    public var onGameAudioFrame: (@Sendable (UnsafeRawPointer?, UInt32, Double, UInt32) -> Void)?
    public var onMicrophoneAudioFrame: (@Sendable (UnsafeRawPointer?, UInt32, Double, UInt32) -> Void)?
    public var onMicrophoneLevel: (@Sendable (Double) -> Void)?
    public var onTransportFailure: (@Sendable (NativeNVSTTransportFailure) -> Void)?

    public init(handoff: NVSTVideoHandoff, descriptor: Int32 = -1,
                preferredLocalAddress: String? = NvstRoutedIPv4.discover(),
                logger: (@Sendable (String) -> Void)? = nil) {
        self.handoff = handoff
        self.descriptor = descriptor
        self.preferredLocalAddress = preferredLocalAddress
        self.logger = logger
        self.queue = DispatchQueue(label: "com.interlacedpixel.pixelnow.nvst.bundle",
                                    qos: Self.dispatchQoS(for: handoff.sctpConfiguration.timerThreadPriority))
        queue.setSpecific(key: queueKey, value: 1)
        logger?("NVST SCTP timer priority=\(handoff.sctpConfiguration.timerThreadPriority) dispatchQoS=\(Self.dispatchQoSName(for: handoff.sctpConfiguration.timerThreadPriority))")
    }

    private static func dispatchQoS(for vendorPriority: Int32) -> DispatchQoS {
        switch vendorPriority {
        case 1: .utility
        case 2: .userInitiated
        case 3: .userInitiated
        case 4: .userInteractive
        default: .default
        }
    }

    private static func dispatchQoSName(for vendorPriority: Int32) -> String {
        switch vendorPriority {
        case 1: "utility"
        case 2, 3: "userInitiated"
        case 4: "userInteractive"
        default: "default"
        }
    }

    deinit { close() }

    func synchronized<T>(_ operation: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil { return try operation() }
        return try queue.sync(execute: operation)
    }

    public var remoteAudioTrackCount: Int { synchronized { trackedRemoteAudioCount } }
    public var audioSurroundInfo: NvstAudioSurroundInfo? { synchronized { currentAudioSurroundInfo } }
    public var audioOutputLatencySeconds: Double? { synchronized { audioDevice?.outputPathLatencySeconds } }
    public var microphoneNegotiation: (negotiated: Bool, senderSsrc: UInt32?) {
        synchronized { (microphoneNegotiated, microphoneSenderSsrc) }
    }
    public var microphoneSentBytes: UInt64 { synchronized { microphoneSentDataBytes } }
    public var roundTripMilliseconds: Double { synchronized { lastRoundTripMilliseconds } }
    public var inputProtocolVersion: UInt16? { synchronized { negotiatedInputProtocolVersion } }
    public var isInputChannelOpen: Bool { synchronized { openStreams.contains(10) } }
    public var isInputReady: Bool { synchronized { openStreams.contains(0) && negotiatedInputProtocolVersion != nil } }
    public var isControlChannelOpen: Bool { synchronized { openStreams.contains(0) } }
    public var isFeedbackChannelOpen: Bool { synchronized { openStreams.contains(14) } }
    public var hapticCounters: (commands: Int, events: Int) { synchronized { (hapticCommandCount, hapticEventCount) } }

    public func setRemoteAudioMuted(_ muted: Bool) { playout.setMuted(muted) }
    public func setRemoteAudioVolume(_ volume: Double) { playout.setVolume(volume) }
    public func setMicrophoneCaptureEnabled(_ enabled: Bool) {
        synchronized {
            microphoneCaptureEnabled = enabled
            capture.setMuted(!enabled)
            if !enabled {
                capture.discardPending()
                renderReference.discardPending()
                previousMicrophonePayloads.removeAll(keepingCapacity: true)
            }
        }
    }
    public func setMicrophoneVolume(_ volume: Double) {
        synchronized { microphoneVolume = min(max(volume.isFinite ? volume : 1, 0), 1) }
    }
    public func audioReception() async -> AudioReception? { synchronized { audio?.reception } }
    public func refreshTransportStatistics() { synchronized { updateMetrics() } }

    public var controlChannelStats: (totalSent: UInt32, totalFailed: UInt32, totalBytes: UInt64, commands: [NvstControlChannelCommandStats]) {
        synchronized {
            let commands = controlCommandStats.sorted { $0.key < $1.key }.map {
                NvstControlChannelCommandStats(commandCode: $0.key, messagesSent: UInt32(clamping: $0.value.messagesSent),
                    messagesFailed: UInt32(clamping: $0.value.messagesFailed), aggregatedBytes: $0.value.aggregatedBytes)
            }
            return (UInt32(clamping: controlMessagesSent), UInt32(clamping: controlSendFailures),
                commands.reduce(0) { $0 &+ $1.aggregatedBytes }, commands)
        }
    }
    public var diagnosticSummary: String {
        synchronized {
            let metrics = sctp?.metrics()
            let authentication = dtls?.counters()
            return "native=true dtls=\(dtls?.connected() == true) channels=\(openStreams.sorted()) sctpSrttMs=\(lastRoundTripMilliseconds) cwnd=\(metrics?.congestionWindowBytes ?? 0) retransmits=\(metrics?.retransmittedPackets ?? 0) pendingUdpBytes=\(outgoingBytes) authFailures=\(authentication?.authenticationFailures ?? 0) replayFailures=\(authentication?.replayFailures ?? 0) controlOut=\(controlMessagesSent) controlFailed=\(controlSendFailures) inputOut=\(inputMessagesSent) inputFailed=\(inputSendFailures) feedbackFailed=\(feedbackSendFailures) lifecycleEvents=\(lifecycleEventCount) expiredMessages=\(expiredMessageCount) micPackets=\(microphonePacketCount) micSeatPackets=\(microphoneSeatReportedPackets) micBitrate=\(handoff.microphoneBitrate) micRedundancy=\(handoff.microphoneRedundancyPackets) micBytes=\(microphoneSentDataBytes) audio=[\(audio?.summary ?? "unprepared")] failure=\(terminalFailure ?? "none")"
        }
    }
}
