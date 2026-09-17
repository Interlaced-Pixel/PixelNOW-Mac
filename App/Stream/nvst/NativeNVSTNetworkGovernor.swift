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
        self.maximumBitrateKbps = max(10_000, maximumBitrateKbps)
        self.currentBitrateKbps = self.maximumBitrateKbps
        self.configuredL4sEnabled = l4sEnabled
        self.l4sEnabled = l4sEnabled
    }

    mutating func evaluate(_ snapshot: NativeNVSTPerformanceSnapshot) -> [NativeNVSTNetworkAdjustment] {
        guard snapshot.available else { return [] }

        let activeBitrate = currentBitrateKbps ?? maximumBitrateKbps
        let bitrateFloor = min(maximumBitrateKbps, max(15_000, maximumBitrateKbps / 3))
        let hasSeverePacketLoss = snapshot.packetLossPercent >= 10
        let hasPacketLoss = snapshot.packetLossPercent >= 2
        let hasCongestion = snapshot.jitterMilliseconds >= 35
        let bandwidthIsAvailable = snapshot.packetLossPercent < 1 && snapshot.jitterMilliseconds < 25

        var adjustments: [NativeNVSTNetworkAdjustment] = []
        if hasSeverePacketLoss {
            let reducedBitrate = max(bitrateFloor, UInt32(Double(activeBitrate) * 0.85))
            if reducedBitrate < activeBitrate {
                adjustments.append(.maximumBitrateKbps(reducedBitrate))
                currentBitrateKbps = reducedBitrate
            }
            appendMode(.preferFrameRate, to: &adjustments)
            appendL4S(false, to: &adjustments)
        } else if hasPacketLoss || hasCongestion {
            appendMode(.preferFrameRate, to: &adjustments)
            appendL4S(false, to: &adjustments)
        } else if bandwidthIsAvailable {
            if activeBitrate < maximumBitrateKbps {
                let recoveredBitrate = min(maximumBitrateKbps, max(activeBitrate, UInt32(Double(activeBitrate) * 1.15)))
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
