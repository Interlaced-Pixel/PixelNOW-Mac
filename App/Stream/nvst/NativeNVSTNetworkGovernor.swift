import Foundation

enum NativeNVSTNetworkAdjustment: Equatable, Sendable {
    case maximumBitrateKbps(UInt32)
    case dynamicStreamingMode(NativeNVSTDynamicStreamingMode)
    case l4sEnabled(Bool)
}

struct NativeNVSTNetworkGovernor: Equatable, Sendable {
    private let maximumBitrateKbps: UInt32
    private let configuredL4sEnabled: Bool
    private var currentBitrateKbps: UInt32?
    private var streamingMode: NativeNVSTDynamicStreamingMode = .on
    private var l4sEnabled: Bool
    private var stableTicks: Int = 0

    private static let requiredStableTicks = 5

    init(maximumBitrateKbps: UInt32, l4sEnabled: Bool) {
        self.maximumBitrateKbps = max(10_000, maximumBitrateKbps)
        self.currentBitrateKbps = self.maximumBitrateKbps
        self.configuredL4sEnabled = l4sEnabled
        self.l4sEnabled = l4sEnabled
    }

    /// Evaluates the current performance snapshot and returns any adjustments to apply.
    ///
    /// - Parameters:
    ///   - snapshot: The latest performance metrics from the transport.
    ///   - decodeBudgetOver: True when the client's mean decode time exceeds the frame interval.
    ///     When the decoder is over-budget the governor switches to `preferFrameRate` and reduces
    ///     bitrate even on a healthy link, preventing the seat's own DFC from reacting first.
    mutating func evaluate(_ snapshot: NativeNVSTPerformanceSnapshot,
                           decodeBudgetOver: Bool) -> [NativeNVSTNetworkAdjustment] {
        guard snapshot.available else { return [] }

        let activeBitrate = currentBitrateKbps ?? maximumBitrateKbps
        let bitrateFloor = resolvedBitrateFloor(snapshot: snapshot)
        let hasSeverePacketLoss = snapshot.packetLossPercent >= 10
        let hasPacketLoss = snapshot.packetLossPercent >= 2
        let hasCongestion = snapshot.jitterMilliseconds >= 35
        let bandwidthIsAvailable = snapshot.packetLossPercent < 1 && snapshot.jitterMilliseconds < 25
                                   && !decodeBudgetOver

        var adjustments: [NativeNVSTNetworkAdjustment] = []
        if hasSeverePacketLoss {
            let reducedBitrate = max(bitrateFloor, UInt32(Double(activeBitrate) * 0.75))
            if reducedBitrate < activeBitrate {
                adjustments.append(.maximumBitrateKbps(reducedBitrate))
                currentBitrateKbps = reducedBitrate
            }
            stableTicks = 0
            appendMode(.preferFrameRate, to: &adjustments)
            appendL4S(false, to: &adjustments)
        } else if hasPacketLoss || hasCongestion || decodeBudgetOver {
            if decodeBudgetOver {
                let reducedBitrate = max(bitrateFloor, UInt32(Double(activeBitrate) * 0.90))
                if reducedBitrate < activeBitrate {
                    adjustments.append(.maximumBitrateKbps(reducedBitrate))
                    currentBitrateKbps = reducedBitrate
                }
            }
            stableTicks = 0
            appendMode(.preferFrameRate, to: &adjustments)
            appendL4S(false, to: &adjustments)
        } else if bandwidthIsAvailable {
            stableTicks += 1
            guard stableTicks >= Self.requiredStableTicks else { return adjustments }
            if activeBitrate < maximumBitrateKbps {
                let recoveredBitrate = min(maximumBitrateKbps, max(activeBitrate, UInt32(Double(activeBitrate) * 1.12)))
                if recoveredBitrate > activeBitrate {
                    adjustments.append(.maximumBitrateKbps(recoveredBitrate))
                    currentBitrateKbps = recoveredBitrate
                }
            }
            appendMode(.preferResolution, to: &adjustments)
            appendL4S(configuredL4sEnabled, to: &adjustments)
        }
        return adjustments
    }

    /// Computes a resolution-aware bitrate floor.
    ///
    /// The previous fixed floor (`max(15_000, maximumBitrate / 3)`) could fall to 15 Mbps on a
    /// 45 Mbps cap — an insufficient floor for 4K content. The floor now scales with both the
    /// configured cap and the stream's negotiated resolution, capping how far the governor will
    /// reduce bitrate before preferring to cut frame rate instead.
    private func resolvedBitrateFloor(snapshot: NativeNVSTPerformanceSnapshot) -> UInt32 {
        let resolutionFloor = minimumBitrateKbps(forResolution: snapshot.resolution)
        let proportionalFloor = max(15_000, maximumBitrateKbps / 3)
        return max(resolutionFloor, min(maximumBitrateKbps, proportionalFloor))
    }

    /// Returns the minimum acceptable bitrate in kbps for a given resolution string,
    /// e.g. "3840x2160" or "2560x1440". Falls back to 15 Mbps for unknown or empty strings.
    private func minimumBitrateKbps(forResolution resolution: String) -> UInt32 {
        let components = resolution.split(separator: "x").compactMap { Int($0) }
        guard components.count >= 2 else { return 15_000 }
        let pixelCount = components[0] * components[1]
        switch pixelCount {
        case _ where pixelCount >= 8_294_400: return 30_000  // 4K (3840×2160) and above
        case _ where pixelCount >= 3_686_400: return 20_000  // 1440p (2560×1440)
        case _ where pixelCount >= 2_073_600: return 10_000  // 1080p (1920×1080)
        default:                              return 6_000   // 720p and below
        }
    }

    private mutating func appendMode(_ mode: NativeNVSTDynamicStreamingMode,
                                     to adjustments: inout [NativeNVSTNetworkAdjustment]) {
        guard streamingMode != mode else { return }
        streamingMode = mode
        adjustments.append(.dynamicStreamingMode(mode))
    }

    private mutating func appendL4S(_ enabled: Bool,
                                    to adjustments: inout [NativeNVSTNetworkAdjustment]) {
        guard l4sEnabled != enabled else { return }
        l4sEnabled = enabled
        adjustments.append(.l4sEnabled(enabled))
    }
}
