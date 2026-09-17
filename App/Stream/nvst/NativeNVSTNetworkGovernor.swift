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

    init(maximumBitrateKbps: UInt32, l4sEnabled: Bool) {
        self.maximumBitrateKbps = max(1_000, maximumBitrateKbps)
        self.configuredL4sEnabled = l4sEnabled
        self.l4sEnabled = l4sEnabled
    }

    mutating func evaluate(_ snapshot: NativeNVSTPerformanceSnapshot) -> [NativeNVSTNetworkAdjustment] {
        guard snapshot.available else { return [] }

        let currentBitrate = resolvedBitrateKbps(from: snapshot)
        let hasSeverePacketLoss = snapshot.packetLossPercent >= 10
        let hasPacketLoss = snapshot.packetLossPercent >= 0 && snapshot.packetLossPercent >= 2
        let hasCongestion = snapshot.jitterMilliseconds >= 0 && snapshot.jitterMilliseconds >= 35
        let frameRateCollapsed = snapshot.negotiatedFramesPerSecond > 0
            && snapshot.streamFramesPerSecond >= 0
            && snapshot.streamFramesPerSecond < snapshot.negotiatedFramesPerSecond * 0.8
        let bandwidthIsAvailable = snapshot.bandwidthUtilizationPercent >= 0
            && snapshot.bandwidthUtilizationPercent < 70

        var adjustments: [NativeNVSTNetworkAdjustment] = []
        if hasSeverePacketLoss {
            let reducedBitrate = max(1_000, UInt32(Double(currentBitrate) * 0.8))
            if reducedBitrate < currentBitrate {
                adjustments.append(.maximumBitrateKbps(reducedBitrate))
                currentBitrateKbps = reducedBitrate
            }
            appendMode(.preferFrameRate, to: &adjustments)
            appendL4S(false, to: &adjustments)
        } else if hasPacketLoss || hasCongestion || frameRateCollapsed {
            appendMode(.preferFrameRate, to: &adjustments)
            appendL4S(false, to: &adjustments)
        } else if bandwidthIsAvailable {
            if let active = currentBitrateKbps, active < maximumBitrateKbps {
                let recoveredBitrate = min(maximumBitrateKbps, max(active, UInt32(Double(active) * 1.1)))
                if recoveredBitrate > active {
                    adjustments.append(.maximumBitrateKbps(recoveredBitrate))
                    currentBitrateKbps = recoveredBitrate
                }
            }
            appendMode(.preferResolution, to: &adjustments)
            appendL4S(configuredL4sEnabled, to: &adjustments)
        } else {
            if currentBitrateKbps == nil {
                currentBitrateKbps = currentBitrate
            }
        }
        return adjustments
    }

    private func resolvedBitrateKbps(from snapshot: NativeNVSTPerformanceSnapshot) -> UInt32 {
        if let currentBitrateKbps {
            return min(maximumBitrateKbps, max(1_000, currentBitrateKbps))
        }
        guard snapshot.bitrateMegabitsPerSecond.isFinite, snapshot.bitrateMegabitsPerSecond > 0 else {
            return maximumBitrateKbps
        }
        let reportedBitrate = snapshot.bitrateMegabitsPerSecond * 1_000
        guard reportedBitrate.isFinite else { return maximumBitrateKbps }
        let boundedBitrate = min(Double(maximumBitrateKbps), max(1_000, reportedBitrate))
        return UInt32(boundedBitrate.rounded())
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
