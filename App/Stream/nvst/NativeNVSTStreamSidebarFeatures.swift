import Foundation

enum NativeNVSTStreamSidebarFeature: String, CaseIterable, Hashable, Sendable {
    case microphone
    case recording
    case antiAFK
    case floatingStats
    case networkHealth
    case sessionLimit
    case remoteCoOp
    case videoEnhancement
}

struct NativeNVSTStreamSidebarCapabilities: Equatable, Sendable {
    let availableFeatures: Set<NativeNVSTStreamSidebarFeature>

    static let standard: NativeNVSTStreamSidebarCapabilities = {
        var features: Set<NativeNVSTStreamSidebarFeature> = [
            .microphone,
            .recording,
            .antiAFK,
            .floatingStats,
            .networkHealth,
            .sessionLimit,
        ]
        if NVSTMetalFXUpscaler.isSupportedOnCurrentDevice {
            features.insert(.videoEnhancement)
        }
        return NativeNVSTStreamSidebarCapabilities(availableFeatures: features)
    }()

    var visibleFeatures: [NativeNVSTStreamSidebarFeature] {
        NativeNVSTStreamSidebarFeature.allCases
    }

    func supports(_ feature: NativeNVSTStreamSidebarFeature) -> Bool {
        availableFeatures.contains(feature)
    }
}
