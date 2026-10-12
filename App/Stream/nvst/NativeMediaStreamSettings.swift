import Foundation

public struct NativeMediaResolution: Equatable, Sendable {
    public var width: Int
    public var height: Int

    public var value: String { "\(width)x\(height)" }

    public init(width: Int, height: Int) {
        self.width = max(1, width)
        self.height = max(1, height)
    }
}

public struct NativeMediaDeviceCapabilities: Equatable, Sendable {
    public var h264HardwareDecodeSupported: Bool
    public var h265HardwareDecodeSupported: Bool
    public var av1HardwareDecodeSupported: Bool
    public var hdrDisplaySupported: Bool
    public var maxDisplayWidth: Int
    public var maxDisplayHeight: Int
    public var maxDisplayRefreshRate: Int
    public var displayDpi: Int
    public var connectedGamepadCount: Int

    public init(h264HardwareDecodeSupported: Bool = true,
                h265HardwareDecodeSupported: Bool = false,
                av1HardwareDecodeSupported: Bool = false,
                hdrDisplaySupported: Bool = false,
                maxDisplayWidth: Int = 0,
                maxDisplayHeight: Int = 0,
                maxDisplayRefreshRate: Int = 0,
                displayDpi: Int = 100,
                connectedGamepadCount: Int = 0) {
        self.h264HardwareDecodeSupported = h264HardwareDecodeSupported
        self.h265HardwareDecodeSupported = h265HardwareDecodeSupported
        self.av1HardwareDecodeSupported = av1HardwareDecodeSupported
        self.hdrDisplaySupported = hdrDisplaySupported
        self.maxDisplayWidth = max(0, maxDisplayWidth)
        self.maxDisplayHeight = max(0, maxDisplayHeight)
        self.maxDisplayRefreshRate = max(0, maxDisplayRefreshRate)
        self.displayDpi = max(0, displayDpi)
        self.connectedGamepadCount = max(0, min(4, connectedGamepadCount))
    }
}

public struct NativeMediaCloudVariables: Equatable, Sendable {
    public var fetched: Bool
    public var allowH265: Bool
    public var allowAV1: Bool
    public var allowHDR: Bool
    public var allowL4S: Bool
    public var allowReflex: Bool
    public var allowPrefilter: Bool
    public var supportedPrefilterModes: [Int]
    public var maxBitrateMbps: Int

    public init(fetched: Bool = false,
                allowH265: Bool = true,
                allowAV1: Bool = true,
                allowHDR: Bool = true,
                allowL4S: Bool = true,
                allowReflex: Bool = true,
                allowPrefilter: Bool = true,
                supportedPrefilterModes: [Int] = [],
                maxBitrateMbps: Int = 0) {
        self.fetched = fetched
        self.allowH265 = allowH265
        self.allowAV1 = allowAV1
        self.allowHDR = allowHDR
        self.allowL4S = allowL4S
        self.allowReflex = allowReflex
        self.allowPrefilter = allowPrefilter
        self.supportedPrefilterModes = supportedPrefilterModes.filter { $0 >= 0 && $0 <= 2 }.sorted()
        self.maxBitrateMbps = max(0, maxBitrateMbps)
    }
}

public struct NativeMediaStreamProfile: Equatable, Sendable {
    public var resolution: NativeMediaResolution
    public var fps: Int
    public var codec: String
    public var colorQuality: String
    public var maxBitrateMbps: Int
    public var prefilterMode: Int
    public var prefilterSharpness: Int
    public var prefilterDenoise: Int
    public var prefilterModel: Int
    public var enableL4S: Bool
    public var enableHdr: Bool
    public var transportMode: String
    public var streamingQualityProfile: Int
    public var enableCloudGsync: Bool
    public var fallbackToLogicalResolution: Bool
    public var hudStreamingMode: Int
    public var sdrColorSpace: Int
    public var hdrColorSpace: Int
    public var enablePowerSaver: Bool
    public var microphoneMode: String
    public var microphoneDeviceId: String
    public var microphonePushToTalkKeyCode: Int
    public var microphonePushToTalkModifierMask: Int
    public var gameVolume: Double
    public var microphoneVolume: Double
    public var streamMicrophoneEnabled: Bool
    public var showStreamMicToggle: Bool
    public var microphoneShortcutEnabled: Bool
    public var upscalingMode: Int
    public var suppressInputWhenInactive: Bool
    public var directMouseInput: Bool
    public var antiAFKMouseMovementEnabled: Bool
    public var preventDisplaySleepWhileStreaming: Bool
    public var recordingVideoBitrateMbps: Int
    public var recordingAudioBitrateKbps: Int
    public var recordingEnhancedVideoEnabled: Bool
    public var leftStickDeadzone: Double
    public var rightStickDeadzone: Double

    public init(resolution: NativeMediaResolution = NativeMediaResolution(width: 1920, height: 1080),
                fps: Int = 60,
                codec: String = "H264",
                colorQuality: String = "8bit_420",
                maxBitrateMbps: Int = 50,
                prefilterMode: Int = 0,
                prefilterSharpness: Int = 0,
                prefilterDenoise: Int = 0,
                prefilterModel: Int = 0,
                enableL4S: Bool = false,
                enableHdr: Bool = false,
                transportMode: String = "nvst",
                streamingQualityProfile: Int = 0,
                enableCloudGsync: Bool = false,
                fallbackToLogicalResolution: Bool = false,
                hudStreamingMode: Int = 0,
                sdrColorSpace: Int = 2,
                hdrColorSpace: Int = 0,
                enablePowerSaver: Bool = false,
                microphoneMode: String = "disabled",
                microphoneDeviceId: String = "",
                microphonePushToTalkKeyCode: Int = 9,
                microphonePushToTalkModifierMask: Int = 0,
                gameVolume: Double = 1,
                microphoneVolume: Double = 1,
                streamMicrophoneEnabled: Bool = true,
                showStreamMicToggle: Bool = true,
                microphoneShortcutEnabled: Bool = true,
                upscalingMode: Int = 0,
                suppressInputWhenInactive: Bool = true,
                directMouseInput: Bool = true,
                antiAFKMouseMovementEnabled: Bool = false,
                preventDisplaySleepWhileStreaming: Bool = true,
                recordingVideoBitrateMbps: Int = 0,
                recordingAudioBitrateKbps: Int = 160,
                recordingEnhancedVideoEnabled: Bool = true,
                leftStickDeadzone: Double = 0.12,
                rightStickDeadzone: Double = 0.13) {
        self.resolution = resolution
        self.fps = fps
        self.codec = codec
        self.colorQuality = colorQuality
        self.maxBitrateMbps = maxBitrateMbps
        self.prefilterMode = prefilterMode
        self.prefilterSharpness = prefilterSharpness
        self.prefilterDenoise = prefilterDenoise
        self.prefilterModel = prefilterModel
        self.enableL4S = enableL4S
        self.enableHdr = enableHdr
        self.transportMode = transportMode
        self.streamingQualityProfile = streamingQualityProfile
        self.enableCloudGsync = enableCloudGsync
        self.fallbackToLogicalResolution = fallbackToLogicalResolution
        self.hudStreamingMode = hudStreamingMode
        self.sdrColorSpace = sdrColorSpace
        self.hdrColorSpace = hdrColorSpace
        self.enablePowerSaver = enablePowerSaver
        self.microphoneMode = microphoneMode
        self.microphoneDeviceId = microphoneDeviceId
        self.microphonePushToTalkKeyCode = microphonePushToTalkKeyCode
        self.microphonePushToTalkModifierMask = microphonePushToTalkModifierMask
        self.gameVolume = min(max(gameVolume, 0), 1)
        self.microphoneVolume = min(max(microphoneVolume, 0), 1)
        self.streamMicrophoneEnabled = streamMicrophoneEnabled
        self.showStreamMicToggle = showStreamMicToggle
        self.microphoneShortcutEnabled = microphoneShortcutEnabled
        self.upscalingMode = upscalingMode
        self.suppressInputWhenInactive = suppressInputWhenInactive
        self.directMouseInput = directMouseInput
        self.antiAFKMouseMovementEnabled = antiAFKMouseMovementEnabled
        self.preventDisplaySleepWhileStreaming = preventDisplaySleepWhileStreaming
        self.recordingVideoBitrateMbps = max(0, min(recordingVideoBitrateMbps, 200))
        self.recordingAudioBitrateKbps = max(64, min(recordingAudioBitrateKbps, 320))
        self.recordingEnhancedVideoEnabled = recordingEnhancedVideoEnabled
        self.leftStickDeadzone = min(max(leftStickDeadzone, 0.0), 0.5)
        self.rightStickDeadzone = min(max(rightStickDeadzone, 0.0), 0.5)
    }
}

public struct NativeMediaResolvedStreamSettings: Equatable, Sendable {
    public var resolution: String
    public var fps: Int
    public var codec: String
    public var colorQuality: String
    public var maxBitrateMbps: Int
    public var prefilterMode: Int
    public var prefilterSharpness: Int
    public var prefilterDenoise: Int
    public var prefilterModel: Int
    public var enableL4S: Bool
    public var enableHdr: Bool
    public var enableReflex: Bool
    public var transportMode: String
    public var streamingQualityProfile: Int
    public var enableCloudGsync: Bool
    public var fallbackToLogicalResolution: Bool
    public var hudStreamingMode: Int
    public var sdrColorSpace: Int
    public var hdrColorSpace: Int
    public var microphoneMode: String
    public var microphoneDeviceId: String
    public var microphonePushToTalkKeyCode: Int
    public var microphonePushToTalkModifierMask: Int
    public var gameVolume: Double
    public var microphoneVolume: Double
    public var leftStickDeadzone: Double
    public var rightStickDeadzone: Double
    public var streamMicrophoneEnabled: Bool
    public var showStreamMicToggle: Bool
    public var microphoneShortcutEnabled: Bool
    public var upscalingMode: Int
    public var suppressInputWhenInactive: Bool
    public var directMouseInput: Bool
    public var antiAFKMouseMovementEnabled: Bool
    public var preventDisplaySleepWhileStreaming: Bool
    public var recordingVideoBitrateMbps: Int
    public var recordingAudioBitrateKbps: Int
    public var recordingEnhancedVideoEnabled: Bool
    public var remoteControllersBitmap: UInt32
    public var supportedHidDevices: UInt32
    public var availableSupportedControllers: [String]

    public func dictionary(gameLanguage: String, accountLinked: Bool, selectedStore: String) -> [String: Any] {
        [
            "resolution": resolution,
            "fps": fps,
            "codec": codec,
            "colorQuality": colorQuality,
            "maxBitrateMbps": maxBitrateMbps,
            "prefilterMode": prefilterMode,
            "prefilterSharpness": prefilterSharpness,
            "prefilterDenoise": prefilterDenoise,
            "prefilterModel": prefilterModel,
            "enableL4S": enableL4S,
            "enableHdr": enableHdr,
            "enableReflex": enableReflex,
            "transportMode": transportMode,
            "streamingQualityProfile": streamingQualityProfile,
            "enableCloudGsync": enableCloudGsync,
            "fallbackToLogicalResolution": fallbackToLogicalResolution,
            "hudStreamingMode": hudStreamingMode,
            "sdrColorSpace": sdrColorSpace,
            "hdrColorSpace": hdrColorSpace,
            "microphoneMode": microphoneMode,
            "microphoneDeviceId": microphoneDeviceId,
            "microphonePushToTalkKeyCode": microphonePushToTalkKeyCode,
            "microphonePushToTalkModifierMask": microphonePushToTalkModifierMask,
            "gameVolume": gameVolume,
            "microphoneVolume": microphoneVolume,
            "streamMicrophoneEnabled": streamMicrophoneEnabled,
            "showStreamMicToggle": showStreamMicToggle,
            "microphoneShortcutEnabled": microphoneShortcutEnabled,
            "upscalingMode": upscalingMode,
            "suppressInputWhenInactive": suppressInputWhenInactive,
            "directMouseInput": directMouseInput,
            "antiAFKMouseMovementEnabled": antiAFKMouseMovementEnabled,
            "preventDisplaySleepWhileStreaming": preventDisplaySleepWhileStreaming,
            "recordingVideoBitrateMbps": recordingVideoBitrateMbps,
            "recordingAudioBitrateKbps": recordingAudioBitrateKbps,
            "recordingEnhancedVideoEnabled": recordingEnhancedVideoEnabled,
            "gameLanguage": gameLanguage,
            "accountLinked": accountLinked,
            "selectedStore": selectedStore,
            "remoteControllersBitmap": Int(remoteControllersBitmap),
            "supportedHidDevices": Int(supportedHidDevices),
            "availableSupportedControllers": availableSupportedControllers,
        ]
    }
}

public enum NativeMediaStreamSettingsResolver {
    public static func resolve(profile: NativeMediaStreamProfile,
                               capabilities: NativeMediaDeviceCapabilities,
                               cloudVariables: NativeMediaCloudVariables = NativeMediaCloudVariables()) -> NativeMediaResolvedStreamSettings {
        var codec = resolvedCodec(profile: profile, capabilities: capabilities)
        if !cloudVariables.allowH265, codec == "H265" { codec = "H264" }
        if !cloudVariables.allowAV1, codec == "AV1" { codec = "H264" }
        let enableHdr = cloudVariables.allowHDR && capabilities.hdrDisplaySupported && profile.enableHdr && codec == "H265"
        let colorQuality = resolvedColorQuality(profile: profile, enableHdr: enableHdr, codec: codec)
        let controllerCount = capabilities.connectedGamepadCount
        let prefilterMode = resolvedPrefilterMode(profile: profile, cloudVariables: cloudVariables)
        let upscalingMode = normalizedUpscalingMode(profile.upscalingMode)
        let requestedMaxBitrateMbps = profile.maxBitrateMbps
        return NativeMediaResolvedStreamSettings(
            resolution: profile.resolution.value,
            fps: profile.fps,
            codec: codec,
            colorQuality: colorQuality,
            maxBitrateMbps: max(1, min(requestedMaxBitrateMbps, cloudVariables.maxBitrateMbps > 0 ? cloudVariables.maxBitrateMbps : Int.max)),
            prefilterMode: prefilterMode,
            prefilterSharpness: prefilterMode == 0 ? 0 : profile.prefilterSharpness,
            prefilterDenoise: prefilterMode == 0 ? 0 : profile.prefilterDenoise,
            prefilterModel: prefilterMode == 0 ? 0 : profile.prefilterModel,
            enableL4S: cloudVariables.allowL4S && profile.enableL4S,
            enableHdr: enableHdr,
            enableReflex: cloudVariables.allowReflex,
            transportMode: "nvst",
            streamingQualityProfile: min(max(profile.streamingQualityProfile, 0), 4),
            enableCloudGsync: profile.fps > 60 && capabilities.maxDisplayRefreshRate > 60 && profile.enableCloudGsync,
            fallbackToLogicalResolution: profile.fallbackToLogicalResolution,
            hudStreamingMode: profile.hudStreamingMode,
            sdrColorSpace: profile.sdrColorSpace,
            hdrColorSpace: profile.hdrColorSpace,
            microphoneMode: profile.microphoneMode,
            microphoneDeviceId: profile.microphoneDeviceId,
            microphonePushToTalkKeyCode: profile.microphonePushToTalkKeyCode,
            microphonePushToTalkModifierMask: profile.microphonePushToTalkModifierMask,
            gameVolume: profile.gameVolume,
            microphoneVolume: profile.microphoneVolume,
            leftStickDeadzone: profile.leftStickDeadzone,
            rightStickDeadzone: profile.rightStickDeadzone,
            streamMicrophoneEnabled: profile.streamMicrophoneEnabled,
            showStreamMicToggle: profile.showStreamMicToggle,
            microphoneShortcutEnabled: profile.microphoneShortcutEnabled,
            upscalingMode: upscalingMode,
            suppressInputWhenInactive: profile.suppressInputWhenInactive,
            directMouseInput: profile.directMouseInput,
            antiAFKMouseMovementEnabled: profile.antiAFKMouseMovementEnabled,
            preventDisplaySleepWhileStreaming: profile.preventDisplaySleepWhileStreaming,
            recordingVideoBitrateMbps: profile.recordingVideoBitrateMbps,
            recordingAudioBitrateKbps: profile.recordingAudioBitrateKbps,
            recordingEnhancedVideoEnabled: profile.recordingEnhancedVideoEnabled,
            remoteControllersBitmap: controllerBitmap(count: controllerCount),
            supportedHidDevices: 0,
            availableSupportedControllers: []
        )
    }

    private static func resolvedPrefilterMode(profile: NativeMediaStreamProfile, cloudVariables: NativeMediaCloudVariables) -> Int {
        guard !(cloudVariables.fetched && !cloudVariables.allowPrefilter) else { return 0 }
        let mode = max(0, min(profile.prefilterMode, 2))
        guard cloudVariables.supportedPrefilterModes.isEmpty || cloudVariables.supportedPrefilterModes.contains(mode) else { return 0 }
        return mode
    }

    private static func normalizedUpscalingMode(_ mode: Int) -> Int {
        mode == StreamPreferences.upscalingModeValueMetalFX
            ? StreamPreferences.upscalingModeValueMetalFX
            : StreamPreferences.upscalingModeValueOff
    }

    private static func resolvedCodec(profile: NativeMediaStreamProfile, capabilities: NativeMediaDeviceCapabilities) -> String {
        let requested = normalizedCodec(profile.codec)
        if requested != "AUTO" { return codecSupported(requested, capabilities: capabilities) ? requested : "H264" }
        let pixels = max(1, profile.resolution.width) * max(1, profile.resolution.height)
        let prefersVeryHighResolution = pixels >= 3840 * 2160
        let highFps = profile.fps >= 144
        if profile.enableHdr && capabilities.h265HardwareDecodeSupported { return "H265" }
        if !highFps, prefersVeryHighResolution, capabilities.av1HardwareDecodeSupported { return "AV1" }
        if (profile.colorQuality.hasPrefix("10bit") || profile.colorQuality.hasSuffix("444")), capabilities.h265HardwareDecodeSupported { return "H265" }
        return "H264"
    }

    private static func normalizedCodec(_ codec: String) -> String {
        let requested = codec.isEmpty ? "H264" : codec.uppercased()
        return requested == "HEVC" ? "H265" : requested
    }

    private static func resolvedColorQuality(profile: NativeMediaStreamProfile, enableHdr: Bool, codec: String) -> String {
        let requested = profile.colorQuality.lowercased()
        let chroma = requested.hasSuffix("444") && (codec == "H265" || codec == "AV1") ? "444" : "420"
        let tenBit = (enableHdr || requested.hasPrefix("10bit")) && (codec == "H265" || codec == "AV1")
        return "\(tenBit ? 10 : 8)bit_\(chroma)"
    }

    private static func codecSupported(_ codec: String, capabilities: NativeMediaDeviceCapabilities) -> Bool {
        switch codec {
        case "AUTO", "H264": true
        case "H265", "HEVC": capabilities.h265HardwareDecodeSupported
        case "AV1": capabilities.av1HardwareDecodeSupported
        default: false
        }
    }

    private static func controllerBitmap(count: Int) -> UInt32 {
        guard count > 0 else { return 0 }
        return (0..<min(4, count)).reduce(UInt32(0)) { partial, index in partial | (1 << UInt32(index)) }
    }
}
