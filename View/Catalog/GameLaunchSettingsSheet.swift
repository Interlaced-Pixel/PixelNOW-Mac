import SwiftUI

struct GameLaunchSettingsSheet: View {
    let game: CatalogGameObject
    let onDismiss: () -> Void

    @State private var isCustomEnabled: Bool = false
    @State private var profile: StreamPreferenceProfile = StreamPreferenceProfile()
    @State private var selectedRegionUrl: String = ""
    @State private var availableRegions: [StreamRegionOption] = []
    @State private var activeTab: LaunchSettingsTab = .display

    private var appId: String {
        game.launchAppId.isEmpty ? (game.uuid.isEmpty ? game.id : game.uuid) : game.launchAppId
    }

    private var deviceCapabilities: StreamDeviceCapabilities {
        StreamPreferences.loadDeviceCapabilities()
    }

    private var isQualityLocked: Bool {
        profile.streamingQualityProfileIndex != 0
    }

    private var lockedProfileSubtitle: String {
        "Managed by \(profile.streamingQualityProfileOption.label) preset. Set to Custom to edit."
    }

    enum LaunchSettingsTab: String, CaseIterable, Identifiable {
        case display = "Display & Video"
        case transport = "Server Location"
        case enhancement = "Enhancement"
        case inputAudio = "Input & Audio"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .display: return "display"
            case .transport: return "network"
            case .enhancement: return "sparkles"
            case .inputAudio: return "gamecontroller"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader
            Divider().background(Color.white.opacity(0.12))

            if !isCustomEnabled {
                unconfiguredBanner
            } else {
                tabBar
                Divider().background(Color.white.opacity(0.08))
                tabContent
            }

            Spacer(minLength: 0)
            Divider().background(Color.white.opacity(0.12))
            sheetFooter
        }
        .frame(width: 680, height: 620)
        .background(Color(red: 14 / 255, green: 16 / 255, blue: 22 / 255))
        .onAppear { loadSettings() }
    }

    private var sheetHeader: some View {
        HStack(spacing: 16) {
            CatalogRemoteImage(url: URL(string: game.bestStorePickerPosterURL), contentMode: .fill)
                .frame(width: 44, height: 60)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.white.opacity(0.16), lineWidth: 1))

            VStack(alignment: .leading, spacing: 4) {
                Text(game.title.isEmpty ? "Launch Settings" : game.title)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Text(isCustomEnabled ? "Per-game custom launch configuration active" : "Using global default streaming settings")
                    .font(.caption)
                    .foregroundStyle(isCustomEnabled ? Color.pixelNowGreen : .white.opacity(0.6))
            }

            Spacer()

            Toggle("Custom Settings", isOn: $isCustomEnabled)
                .toggleStyle(SwitchToggleStyle(tint: Color.pixelNowGreen))
                .onChange(of: isCustomEnabled) { _, enabled in
                    StreamPreferences.setProfileEnabled(forGame: appId, enabled: enabled)
                    if enabled {
                        saveCurrentProfile()
                    }
                }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(Color(red: 18 / 255, green: 20 / 255, blue: 28 / 255))
    }

    private var unconfiguredBanner: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 44))
                .foregroundStyle(Color.white.opacity(0.3))

            Text("Global Settings Active")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)

            Text("This game inherits your overall resolution, bitrate, server region, and display preferences from the main Settings menu.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

            Button {
                isCustomEnabled = true
                saveCurrentProfile()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle.fill")
                    Text("Customize for \(game.title.isEmpty ? "this game" : game.title)")
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(Color.pixelNowGreen)
            Spacer()
        }
        .padding(32)
    }

    private var tabBar: some View {
        HStack(spacing: 8) {
            ForEach(LaunchSettingsTab.allCases) { tab in
                Button {
                    activeTab = tab
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 11, weight: .semibold))
                        Text(tab.rawValue)
                            .font(.system(size: 12, weight: activeTab == tab ? .bold : .medium))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(activeTab == tab ? Color.white.opacity(0.12) : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .foregroundStyle(activeTab == tab ? .white : .white.opacity(0.6))
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(Color(red: 16 / 255, green: 18 / 255, blue: 25 / 255))
    }

    @ViewBuilder
    private var tabContent: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 18) {
                switch activeTab {
                case .display:
                    displayTabContent
                case .transport:
                    transportTabContent
                case .enhancement:
                    enhancementTabContent
                case .inputAudio:
                    inputAudioTabContent
                }
            }
            .padding(24)
        }
    }

    private var displayTabContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            settingSectionHeader("Quality Preset")
            HStack(spacing: 8) {
                ForEach(StreamPreferences.streamingQualityProfileOptions.indices, id: \.self) { idx in
                    let opt = StreamPreferences.streamingQualityProfileOptions[idx]
                    Button {
                        profile.streamingQualityProfileIndex = idx
                        profile.streamingQualityProfileOption = opt
                        profile.streamingQualityProfile = opt.value
                        if idx != 0 {
                            StreamPreferences.applyStreamingQualityPreset(idx, to: &profile)
                        }
                        saveCurrentProfile()
                    } label: {
                        Text(opt.label)
                            .font(.caption.weight(profile.streamingQualityProfileIndex == idx ? .bold : .medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(profile.streamingQualityProfileIndex == idx ? Color.pixelNowGreen.opacity(0.25) : Color.white.opacity(0.06))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(profile.streamingQualityProfileIndex == idx ? Color.pixelNowGreen : Color.white.opacity(0.12), lineWidth: 1))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .foregroundStyle(profile.streamingQualityProfileIndex == idx ? .white : .white.opacity(0.75))
                    }
                    .buttonStyle(.plain)
                }
            }

            if isQualityLocked {
                HStack(spacing: 6) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 11))
                    Text(lockedProfileSubtitle)
                        .font(.caption)
                }
                .foregroundStyle(Color.pixelNowGreen)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.pixelNowGreen.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            Divider().background(Color.white.opacity(0.08))

            settingSectionHeader("Aspect Ratio & Resolution")
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 4) {
                        Text("Aspect Ratio").font(.caption).foregroundStyle(.white.opacity(0.6))
                        if isQualityLocked {
                            Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(Color.pixelNowGreen.opacity(0.8))
                        }
                    }
                    Picker("", selection: Binding(
                        get: { profile.aspectIndex },
                        set: { newAspect in
                            guard !isQualityLocked else { return }
                            profile.aspectIndex = newAspect
                            profile.aspect = StreamPreferences.aspectOptions[newAspect]
                            let resolutions = StreamPreferences.resolutionOptions(forAspect: newAspect)
                            profile.resolutionIndex = min(profile.resolutionIndex, resolutions.count - 1)
                            profile.resolution = resolutions[profile.resolutionIndex]
                            saveCurrentProfile()
                        }
                    )) {
                        ForEach(StreamPreferences.aspectOptions.indices, id: \.self) { idx in
                            Text(StreamPreferences.aspectOptions[idx].label).tag(idx)
                        }
                    }
                    .pickerStyle(.menu)
                    .disabled(isQualityLocked)
                    .opacity(isQualityLocked ? 0.6 : 1)
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 4) {
                        Text("Resolution").font(.caption).foregroundStyle(.white.opacity(0.6))
                        if isQualityLocked {
                            Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(Color.pixelNowGreen.opacity(0.8))
                        }
                    }
                    let resolutions = StreamPreferences.resolutionOptions(forAspect: profile.aspectIndex)
                    Picker("", selection: Binding(
                        get: { min(profile.resolutionIndex, resolutions.count - 1) },
                        set: { newRes in
                            guard !isQualityLocked else { return }
                            profile.resolutionIndex = newRes
                            if resolutions.indices.contains(newRes) {
                                profile.resolution = resolutions[newRes]
                            }
                            saveCurrentProfile()
                        }
                    )) {
                        ForEach(resolutions.indices, id: \.self) { idx in
                            Text(resolutions[idx].label).tag(idx)
                        }
                    }
                    .pickerStyle(.menu)
                    .disabled(isQualityLocked)
                    .opacity(isQualityLocked ? 0.6 : 1)
                }
            }

            Divider().background(Color.white.opacity(0.08))

            settingSectionHeader("Performance")
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 4) {
                        Text("Frame Rate").font(.caption).foregroundStyle(.white.opacity(0.6))
                        if isQualityLocked {
                            Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(Color.pixelNowGreen.opacity(0.8))
                        }
                    }
                    Picker("", selection: Binding(
                        get: { profile.fpsIndex },
                        set: { newFps in
                            guard !isQualityLocked else { return }
                            profile.fpsIndex = newFps
                            profile.fps = StreamPreferences.fpsOptions[newFps]
                            saveCurrentProfile()
                        }
                    )) {
                        ForEach(StreamPreferences.fpsOptions.indices, id: \.self) { idx in
                            let fps = StreamPreferences.fpsOptions[idx]
                            let supported = StreamPreferences.fpsSupported(fps, capabilities: deviceCapabilities)
                            Text("\(fps) FPS\(supported ? "" : " (Exceeds Display)")").tag(idx)
                        }
                    }
                    .pickerStyle(.menu)
                    .disabled(isQualityLocked)
                    .opacity(isQualityLocked ? 0.6 : 1)
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 4) {
                        Text("Video Codec").font(.caption).foregroundStyle(.white.opacity(0.6))
                        if isQualityLocked {
                            Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(Color.pixelNowGreen.opacity(0.8))
                        }
                    }
                    Picker("", selection: Binding(
                        get: { profile.codecIndex },
                        set: { newCodec in
                            guard !isQualityLocked else { return }
                            profile.codecIndex = newCodec
                            profile.codec = StreamPreferences.codecOptions[newCodec]
                            saveCurrentProfile()
                        }
                    )) {
                        ForEach(StreamPreferences.codecOptions.indices, id: \.self) { idx in
                            let codec = StreamPreferences.codecOptions[idx]
                            Text(codec.label).tag(idx)
                        }
                    }
                    .pickerStyle(.menu)
                    .disabled(isQualityLocked)
                    .opacity(isQualityLocked ? 0.6 : 1)
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 4) {
                        Text("Max Bitrate").font(.caption).foregroundStyle(.white.opacity(0.6))
                        if isQualityLocked {
                            Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(Color.pixelNowGreen.opacity(0.8))
                        }
                    }
                    Picker("", selection: Binding(
                        get: { profile.bitrateIndex },
                        set: { newBitrate in
                            guard !isQualityLocked else { return }
                            profile.bitrateIndex = newBitrate
                            profile.bitrate = StreamPreferences.bitrateOptions[newBitrate]
                            profile.maxBitrateMbps = profile.bitrate.mbps
                            saveCurrentProfile()
                        }
                    )) {
                        ForEach(StreamPreferences.bitrateOptions.indices, id: \.self) { idx in
                            Text(StreamPreferences.bitrateOptions[idx].label).tag(idx)
                        }
                    }
                    .pickerStyle(.menu)
                    .disabled(isQualityLocked)
                    .opacity(isQualityLocked ? 0.6 : 1)
                }
            }
        }
    }

    private var transportTabContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            settingSectionHeader("Server Location Override")
            VStack(alignment: .leading, spacing: 8) {
                Picker("Region", selection: Binding(
                    get: { selectedRegionUrl },
                    set: { newUrl in
                        selectedRegionUrl = newUrl
                        profile.selectedRegionUrl = newUrl
                        StreamPreferences.saveSelectedRegionUrl(newUrl, forGame: appId)
                        saveCurrentProfile()
                    }
                )) {
                    Text("Automatic (Best Route)").tag("")
                    ForEach(availableRegions, id: \.url) { region in
                        Text(region.label).tag(region.url)
                    }
                }
                .pickerStyle(.menu)

                Text(selectedRegionUrl.isEmpty
                     ? "Automatic measures ping and routing quality to all available data centers prior to stream allocation."
                     : "Manually locks streaming session allocations to this specific region for \(game.title.isEmpty ? "this game" : game.title).")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.55))
            }

            Divider().background(Color.white.opacity(0.08))

            settingSectionHeader("Network Optimizations")
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Toggle("L4S Low-Latency Congestion Control", isOn: Binding(
                        get: { profile.enableL4S },
                        set: {
                            guard !isQualityLocked else { return }
                            profile.enableL4S = $0
                            saveCurrentProfile()
                        }
                    ))
                    .toggleStyle(SwitchToggleStyle(tint: Color.pixelNowGreen))
                    .disabled(isQualityLocked)
                    .opacity(isQualityLocked ? 0.6 : 1)

                    if isQualityLocked {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.pixelNowGreen.opacity(0.8))
                    }
                }

                HStack {
                    Toggle("Cloud G-Sync Variable Refresh Rate", isOn: Binding(
                        get: { profile.enableCloudGsync },
                        set: {
                            guard !isQualityLocked else { return }
                            profile.enableCloudGsync = $0
                            saveCurrentProfile()
                        }
                    ))
                    .toggleStyle(SwitchToggleStyle(tint: Color.pixelNowGreen))
                    .disabled(isQualityLocked)
                    .opacity(isQualityLocked ? 0.6 : 1)

                    if isQualityLocked {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.pixelNowGreen.opacity(0.8))
                    }
                }

                if isQualityLocked {
                    HStack(spacing: 6) {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 10))
                        Text(lockedProfileSubtitle)
                            .font(.caption2)
                    }
                    .foregroundStyle(Color.pixelNowGreen.opacity(0.85))
                }
            }
        }
    }

    private var enhancementTabContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            settingSectionHeader("MetalFX Resolution Upscaling")
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Enable MetalFX Upscaling", isOn: Binding(
                    get: { profile.upscalingMode == 3 },
                    set: { enabled in
                        profile.upscalingMode = enabled ? 3 : 0
                        profile.upscalingModeIndex = enabled ? 1 : 0
                        profile.upscalingModeOption = StreamPreferences.upscalingModeOptions[profile.upscalingModeIndex]
                        saveCurrentProfile()
                    }
                ))
                .toggleStyle(SwitchToggleStyle(tint: Color.pixelNowGreen))

                if profile.upscalingMode == 3 {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Sharpness").font(.caption).foregroundStyle(.white.opacity(0.7))
                            Spacer()
                            Text("\(profile.upscalingSharpness)").font(.caption.monospaced()).foregroundStyle(.white)
                        }
                        Slider(value: Binding(
                            get: { Double(profile.upscalingSharpness) },
                            set: { profile.upscalingSharpness = Int($0); saveCurrentProfile() }
                        ), in: 0...15, step: 1)
                        .tint(Color.pixelNowGreen)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Noise Reduction").font(.caption).foregroundStyle(.white.opacity(0.7))
                            Spacer()
                            Text("\(profile.upscalingDenoise)").font(.caption.monospaced()).foregroundStyle(.white)
                        }
                        Slider(value: Binding(
                            get: { Double(profile.upscalingDenoise) },
                            set: { profile.upscalingDenoise = Int($0); saveCurrentProfile() }
                        ), in: 0...20, step: 1)
                        .tint(Color.pixelNowGreen)
                    }
                }
            }

            Divider().background(Color.white.opacity(0.08))

            settingSectionHeader("Prefilter Image Processing")
            VStack(alignment: .leading, spacing: 8) {
                Picker("Prefilter Mode", selection: Binding(
                    get: { profile.prefilterModeIndex },
                    set: { newMode in
                        profile.prefilterModeIndex = newMode
                        profile.prefilterModeOption = StreamPreferences.prefilterModeOptions[newMode]
                        profile.prefilterMode = profile.prefilterModeOption.value
                        saveCurrentProfile()
                    }
                )) {
                    ForEach(StreamPreferences.prefilterModeOptions.indices, id: \.self) { idx in
                        Text(StreamPreferences.prefilterModeOptions[idx].label).tag(idx)
                    }
                }
                .pickerStyle(.segmented)

                if profile.prefilterModeIndex == 2 {
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Sharpness: \(profile.prefilterSharpness)").font(.caption).foregroundStyle(.white.opacity(0.7))
                            Slider(value: Binding(
                                get: { Double(profile.prefilterSharpness) },
                                set: { profile.prefilterSharpness = Int($0); saveCurrentProfile() }
                            ), in: 0...10, step: 1)
                            .tint(Color.pixelNowGreen)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Denoise: \(profile.prefilterDenoise)").font(.caption).foregroundStyle(.white.opacity(0.7))
                            Slider(value: Binding(
                                get: { Double(profile.prefilterDenoise) },
                                set: { profile.prefilterDenoise = Int($0); saveCurrentProfile() }
                            ), in: 0...10, step: 1)
                            .tint(Color.pixelNowGreen)
                        }
                    }
                }
            }

            Divider().background(Color.white.opacity(0.08))

            settingSectionHeader("Dynamic Range (HDR)")
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Toggle("High Dynamic Range (HDR)", isOn: Binding(
                        get: { profile.enableHdr },
                        set: {
                            guard !isQualityLocked else { return }
                            profile.enableHdr = $0
                            profile.colorQualityIndex = $0 ? 2 : 0
                            profile.colorQuality = StreamPreferences.colorQualityOptions[$0 ? 2 : 0]
                            saveCurrentProfile()
                        }
                    ))
                    .toggleStyle(SwitchToggleStyle(tint: Color.pixelNowGreen))
                    .disabled(isQualityLocked)
                    .opacity(isQualityLocked ? 0.6 : 1)

                    if isQualityLocked {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.pixelNowGreen.opacity(0.8))
                    }
                }

                if isQualityLocked {
                    HStack(spacing: 6) {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 10))
                        Text(lockedProfileSubtitle)
                            .font(.caption2)
                    }
                    .foregroundStyle(Color.pixelNowGreen.opacity(0.85))
                }
            }
        }
    }

    private var inputAudioTabContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            settingSectionHeader("Mouse & Window Interaction")
            Toggle("Direct Mouse Input (Relative Capture)", isOn: Binding(
                get: { profile.directMouseInput },
                set: { profile.directMouseInput = $0; saveCurrentProfile() }
            ))
            .toggleStyle(SwitchToggleStyle(tint: Color.pixelNowGreen))

            Toggle("Anti-AFK Mouse Movement", isOn: Binding(
                get: { profile.antiAFKMouseMovementEnabled },
                set: { profile.antiAFKMouseMovementEnabled = $0; saveCurrentProfile() }
            ))
            .toggleStyle(SwitchToggleStyle(tint: Color.pixelNowGreen))

            Toggle("Suppress Input When Window Inactive", isOn: Binding(
                get: { profile.suppressInputWhenInactive },
                set: { profile.suppressInputWhenInactive = $0; saveCurrentProfile() }
            ))
            .toggleStyle(SwitchToggleStyle(tint: Color.pixelNowGreen))

            Toggle("Prevent Display Sleep While Streaming", isOn: Binding(
                get: { profile.preventDisplaySleepWhileStreaming },
                set: { profile.preventDisplaySleepWhileStreaming = $0; saveCurrentProfile() }
            ))
            .toggleStyle(SwitchToggleStyle(tint: Color.pixelNowGreen))

            Divider().background(Color.white.opacity(0.08))

            settingSectionHeader("Gamepad Deadzones")
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Left Stick Deadzone").font(.caption).foregroundStyle(.white.opacity(0.7))
                    Spacer()
                    Text(String(format: "%.0f%%", profile.leftStickDeadzone * 100)).font(.caption.monospaced()).foregroundStyle(.white)
                }
                Slider(value: Binding(
                    get: { profile.leftStickDeadzone },
                    set: { profile.leftStickDeadzone = $0; saveCurrentProfile() }
                ), in: 0.0...0.5, step: 0.01)
                .tint(Color.pixelNowGreen)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Right Stick Deadzone").font(.caption).foregroundStyle(.white.opacity(0.7))
                    Spacer()
                    Text(String(format: "%.0f%%", profile.rightStickDeadzone * 100)).font(.caption.monospaced()).foregroundStyle(.white)
                }
                Slider(value: Binding(
                    get: { profile.rightStickDeadzone },
                    set: { profile.rightStickDeadzone = $0; saveCurrentProfile() }
                ), in: 0.0...0.5, step: 0.01)
                .tint(Color.pixelNowGreen)
            }

            Divider().background(Color.white.opacity(0.08))

            settingSectionHeader("Audio Levels")
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Game Volume").font(.caption).foregroundStyle(.white.opacity(0.7))
                    Spacer()
                    Text("\(Int(profile.gameVolume * 100))%").font(.caption.monospaced()).foregroundStyle(.white)
                }
                Slider(value: Binding(
                    get: { profile.gameVolume },
                    set: { profile.gameVolume = $0; saveCurrentProfile() }
                ), in: 0...1)
                .tint(Color.pixelNowGreen)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Microphone Volume").font(.caption).foregroundStyle(.white.opacity(0.7))
                    Spacer()
                    Text("\(Int(profile.microphoneVolume * 100))%").font(.caption.monospaced()).foregroundStyle(.white)
                }
                Slider(value: Binding(
                    get: { profile.microphoneVolume },
                    set: { profile.microphoneVolume = $0; saveCurrentProfile() }
                ), in: 0...1)
                .tint(Color.pixelNowGreen)
            }

            Divider().background(Color.white.opacity(0.08))

            settingSectionHeader("Microphone Mode")
            Picker("Microphone Mode", selection: Binding(
                get: { profile.microphoneMode },
                set: { profile.microphoneMode = $0; saveCurrentProfile() }
            )) {
                ForEach(StreamPreferences.microphoneModeOptions, id: \.value) { opt in
                    Text(opt.label).tag(opt.value)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private var sheetFooter: some View {
        HStack {
            if isCustomEnabled {
                Button(role: .destructive) {
                    resetToDefaults()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.counterclockwise")
                        Text("Reset to Global Defaults")
                    }
                }
                .buttonStyle(.bordered)
            }

            Spacer()

            Button("Done") {
                saveCurrentProfile()
                onDismiss()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(Color.pixelNowGreen)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(Color(red: 18 / 255, green: 20 / 255, blue: 28 / 255))
    }

    private func settingSectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 11, weight: .bold))
            .tracking(1.2)
            .foregroundStyle(.white.opacity(0.45))
    }

    private func loadSettings() {
        isCustomEnabled = StreamPreferences.profileEnabled(forGame: appId)
        if let existing = StreamPreferences.rawProfile(forGame: appId) {
            profile = existing
        } else {
            profile = StreamPreferences.loadProfile()
        }
        selectedRegionUrl = StreamPreferences.loadSelectedRegionUrl(forGame: appId)
        availableRegions = StreamPreferences.loadCachedRegions().filter { !$0.automatic }
    }

    private func saveCurrentProfile() {
        guard !appId.isEmpty else { return }
        StreamPreferences.saveProfile(forGame: appId, profile: profile, enabled: isCustomEnabled)
        if !selectedRegionUrl.isEmpty {
            StreamPreferences.saveSelectedRegionUrl(selectedRegionUrl, forGame: appId)
        }
    }

    private func resetToDefaults() {
        StreamPreferences.deleteProfile(forGame: appId)
        isCustomEnabled = false
        profile = StreamPreferences.loadProfile()
        selectedRegionUrl = ""
    }
}
