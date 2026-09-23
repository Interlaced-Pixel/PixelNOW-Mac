import AppKit
import SwiftUI

struct GameCardContextMenuContent: View {
    let game: CatalogGameObject
    let isFavorite: Bool
    let onPlay: () -> Void
    let onSelectPlatform: (Int) -> Void
    let onToggleFavorite: () -> Void
    let onOpenSettings: () -> Void
    let onAddShortcut: () -> Void
    let onOpenStore: () -> Void

    @State private var isCustomSettingsEnabled: Bool = false
    @State private var profile: StreamPreferenceProfile = StreamPreferenceProfile()

    private var appId: String {
        game.launchAppId.isEmpty ? (game.uuid.isEmpty ? game.id : game.uuid) : game.launchAppId
    }

    var body: some View {
        Button {
            onPlay()
        } label: {
            Label(playActionTitle, systemImage: playActionIcon)
        }

        if game.variants.count > 1 {
            Menu {
                ForEach(Array(game.variants.enumerated()), id: \.element.id) { index, variant in
                    Button {
                        onSelectPlatform(index)
                    } label: {
                        HStack {
                            Text(platformLabel(for: variant))
                            if variant.librarySelected {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                Label("Platform / Store", systemImage: "cart.fill")
            }
        }

        Divider()

        Menu {
            Toggle("Enable Custom Game Settings", isOn: Binding(
                get: { isCustomSettingsEnabled },
                set: { enabled in
                    isCustomSettingsEnabled = enabled
                    StreamPreferences.setProfileEnabled(forGame: appId, enabled: enabled)
                    if enabled {
                        StreamPreferences.saveProfile(forGame: appId, profile: profile, enabled: true)
                    }
                }
            ))

            if isCustomSettingsEnabled {
                Divider()

                Menu {
                    ForEach(StreamPreferences.streamingQualityProfileOptions.indices, id: \.self) { idx in
                        let opt = StreamPreferences.streamingQualityProfileOptions[idx]
                        Button {
                            profile.streamingQualityProfileIndex = idx
                            profile.streamingQualityProfileOption = opt
                            profile.streamingQualityProfile = opt.value
                            if idx != 0 {
                                StreamPreferences.applyStreamingQualityPreset(idx, to: &profile)
                            }
                            saveProfile()
                        } label: {
                            HStack {
                                Text(opt.label)
                                if profile.streamingQualityProfileIndex == idx { Image(systemName: "checkmark") }
                            }
                        }
                    }
                } label: {
                    Label("Quality Preset: \(profile.streamingQualityProfileOption.label)", systemImage: "slider.horizontal.3")
                }

                Menu {
                    Button("1080p @ 60 FPS") { applyResolutionPreset(width: 1920, height: 1080, fps: 60) }
                    Button("1080p @ 120 FPS") { applyResolutionPreset(width: 1920, height: 1080, fps: 120) }
                    Button("1440p @ 60 FPS") { applyResolutionPreset(width: 2560, height: 1440, fps: 60) }
                    Button("1440p @ 120 FPS") { applyResolutionPreset(width: 2560, height: 1440, fps: 120) }
                    Button("4K @ 60 FPS") { applyResolutionPreset(width: 3840, height: 2160, fps: 60) }
                    Button("4K @ 120 FPS") { applyResolutionPreset(width: 3840, height: 2160, fps: 120) }
                } label: {
                    Label(
                        profile.streamingQualityProfileIndex == 0
                            ? "Resolution & FPS: \(profile.resolution.label) @ \(profile.fps) FPS"
                            : "Resolution & FPS: \(profile.resolution.label) @ \(profile.fps) FPS (Locked)",
                        systemImage: profile.streamingQualityProfileIndex == 0 ? "display" : "lock.fill"
                    )
                }
                .disabled(profile.streamingQualityProfileIndex != 0)

                Menu {
                    ForEach(StreamPreferences.codecOptions.indices, id: \.self) { idx in
                        let codec = StreamPreferences.codecOptions[idx]
                        Button {
                            guard profile.streamingQualityProfileIndex == 0 else { return }
                            profile.codecIndex = idx
                            profile.codec = codec
                            saveProfile()
                        } label: {
                            HStack {
                                Text(codec.label)
                                if profile.codecIndex == idx { Image(systemName: "checkmark") }
                            }
                        }
                    }
                } label: {
                    Label(
                        profile.streamingQualityProfileIndex == 0
                            ? "Codec: \(profile.codec.label)"
                            : "Codec: \(profile.codec.label) (Locked)",
                        systemImage: profile.streamingQualityProfileIndex == 0 ? "film" : "lock.fill"
                    )
                }
                .disabled(profile.streamingQualityProfileIndex != 0)

                Menu {
                    ForEach(StreamPreferences.bitrateOptions.indices, id: \.self) { idx in
                        let opt = StreamPreferences.bitrateOptions[idx]
                        Button {
                            guard profile.streamingQualityProfileIndex == 0 else { return }
                            profile.bitrateIndex = idx
                            profile.bitrate = opt
                            profile.maxBitrateMbps = opt.mbps
                            saveProfile()
                        } label: {
                            HStack {
                                Text(opt.label)
                                if profile.bitrateIndex == idx { Image(systemName: "checkmark") }
                            }
                        }
                    }
                } label: {
                    Label(
                        profile.streamingQualityProfileIndex == 0
                            ? "Max Bitrate: \(profile.maxBitrateMbps) Mbps"
                            : "Max Bitrate: \(profile.maxBitrateMbps) Mbps (Locked)",
                        systemImage: profile.streamingQualityProfileIndex == 0 ? "speedometer" : "lock.fill"
                    )
                }
                .disabled(profile.streamingQualityProfileIndex != 0)

                Divider()

                Toggle("Direct Mouse Input", isOn: Binding(
                    get: { profile.directMouseInput },
                    set: { profile.directMouseInput = $0; saveProfile() }
                ))

                Toggle("Anti-AFK Mouse Movement", isOn: Binding(
                    get: { profile.antiAFKMouseMovementEnabled },
                    set: { profile.antiAFKMouseMovementEnabled = $0; saveProfile() }
                ))

                Toggle("MetalFX Upscaling", isOn: Binding(
                    get: { profile.upscalingMode == StreamPreferences.upscalingModeValueMetalFX },
                    set: { enabled in
                        profile.upscalingMode = enabled ? StreamPreferences.upscalingModeValueMetalFX : StreamPreferences.upscalingModeValueOff
                        profile.upscalingModeIndex = enabled ? 1 : 0
                        profile.upscalingModeOption = StreamPreferences.upscalingModeOptions[profile.upscalingModeIndex]
                        saveProfile()
                    }
                ))

                Toggle("HDR", isOn: Binding(
                    get: { profile.enableHdr },
                    set: { profile.enableHdr = $0; saveProfile() }
                ))

                Toggle("L4S Congestion Control", isOn: Binding(
                    get: { profile.enableL4S },
                    set: { profile.enableL4S = $0; saveProfile() }
                ))

                Divider()

                Button("Reset Game Settings to Defaults", role: .destructive) {
                    StreamPreferences.deleteProfile(forGame: appId)
                    isCustomSettingsEnabled = false
                    profile = StreamPreferences.loadProfile()
                }
            }
        } label: {
            Label(isCustomSettingsEnabled ? "Launch Settings (Customized)" : "Launch Settings", systemImage: "slider.horizontal.3")
        }

        Button {
            onOpenSettings()
        } label: {
            Label("Configure Per-Game Settings...", systemImage: "gearshape")
        }

        Divider()

        Button {
            onToggleFavorite()
        } label: {
            Label(isFavorite ? "Remove from Favorites" : "Add to Favorites",
                  systemImage: isFavorite ? "heart.slash" : "heart")
        }

        Button {
            onAddShortcut()
        } label: {
            Label("Add Desktop Shortcut", systemImage: "arrow.up.forward.app")
        }

        if game.primaryStoreURL != nil {
            Button {
                onOpenStore()
            } label: {
                Label("Open Store Page", systemImage: "safari")
            }
        }

        Divider()

        Menu {
            Button("Copy Title") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(game.title, forType: .string)
            }
            if !appId.isEmpty {
                Button("Copy App ID (\(appId))") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(appId, forType: .string)
                }
            }
            if let storeUrl = game.primaryStoreURL?.absoluteString {
                Button("Copy Store URL") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(storeUrl, forType: .string)
                }
            }
        } label: {
            Label("Copy Information", systemImage: "doc.on.doc")
        }
        .onAppear { loadSettings() }
    }

    private var playActionTitle: String {
        if game.isLaunchPatching { return "Queue When Ready" }
        return "Play \(game.title.isEmpty ? "Game" : game.title)"
    }

    private var playActionIcon: String {
        game.isLaunchPatching ? "wrench.and.screwdriver" : "play.fill"
    }

    private func platformLabel(for variant: CatalogGameVariantObject) -> String {
        let store = variant.appStore.isEmpty ? "Store" : variant.appStore
        let owned = variant.inLibrary ? " (Owned)" : ""
        return "\(store)\(owned)"
    }

    private func loadSettings() {
        isCustomSettingsEnabled = StreamPreferences.profileEnabled(forGame: appId)
        if let existing = StreamPreferences.rawProfile(forGame: appId) {
            profile = existing
        } else {
            profile = StreamPreferences.loadProfile()
        }
    }

    private func saveProfile() {
        guard !appId.isEmpty else { return }
        StreamPreferences.saveProfile(forGame: appId, profile: profile, enabled: isCustomSettingsEnabled)
    }

    private func applyResolutionPreset(width: Int, height: Int, fps: Int) {
        guard profile.streamingQualityProfileIndex == 0 else { return }
        let aspectIndex = (width * 10 == height * 16) ? 1 : 0
        profile.aspectIndex = aspectIndex
        profile.aspect = StreamPreferences.aspectOptions[aspectIndex]
        let resolutions = StreamPreferences.resolutionOptions(forAspect: aspectIndex)
        if let foundRes = resolutions.firstIndex(where: { $0.width == width && $0.height == height }) {
            profile.resolutionIndex = foundRes
            profile.resolution = resolutions[foundRes]
        }
        if let foundFps = StreamPreferences.fpsOptions.firstIndex(of: fps) {
            profile.fpsIndex = foundFps
            profile.fps = fps
        }
        isCustomSettingsEnabled = true
        saveProfile()
    }
}

struct GameCardFloatingMenuView: View {
    let game: CatalogGameObject
    let isFavorite: Bool
    let onPlay: () -> Void
    let onSelectPlatform: (Int) -> Void
    let onToggleFavorite: () -> Void
    let onOpenSettings: () -> Void
    let onAddShortcut: () -> Void
    let onOpenStore: () -> Void
    let onDismiss: () -> Void

    @State private var isCustomSettingsEnabled: Bool = false
    @State private var profile: StreamPreferenceProfile = StreamPreferenceProfile()

    private var appId: String {
        game.launchAppId.isEmpty ? (game.uuid.isEmpty ? game.id : game.uuid) : game.launchAppId
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                CatalogRemoteImage(url: URL(string: game.bestStorePickerPosterURL), contentMode: .fill)
                    .frame(width: 36, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Color.white.opacity(0.15), lineWidth: 1))

                VStack(alignment: .leading, spacing: 3) {
                    Text(game.title.isEmpty ? "Game" : game.title)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    HStack(spacing: 6) {
                        if !game.developerName.isEmpty {
                            Text(game.developerName)
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.6))
                                .lineLimit(1)
                        }

                        if isCustomSettingsEnabled {
                            Text("CUSTOM")
                                .font(.system(size: 9, weight: .bold))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.pixelNowGreen.opacity(0.2))
                                .foregroundStyle(Color.pixelNowGreen)
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                        }
                    }
                }

                Spacer(minLength: 0)

                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white.opacity(0.5))
                        .padding(4)
                }
                .buttonStyle(.plain)
            }
            .padding(12)
            .background(Color.black.opacity(0.25))

            Divider().background(Color.white.opacity(0.10))

            VStack(spacing: 2) {
                menuActionButton(
                    icon: game.isLaunchPatching ? "wrench.and.screwdriver.fill" : "play.fill",
                    iconColor: Color.pixelNowGreen,
                    title: game.isLaunchPatching ? "Queue Launch" : "Play Game"
                ) {
                    onDismiss()
                    onPlay()
                }

                if game.variants.count > 1 {
                    Menu {
                        ForEach(Array(game.variants.enumerated()), id: \.element.id) { index, variant in
                            Button {
                                onSelectPlatform(index)
                            } label: {
                                HStack {
                                    Text(variant.appStore.isEmpty ? "Store" : variant.appStore)
                                    if variant.inLibrary { Text("(Owned)") }
                                    if variant.librarySelected { Image(systemName: "checkmark") }
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "cart.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.7))
                                .frame(width: 18)
                            Text("Select Platform")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.white)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white.opacity(0.4))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(Color.clear)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                Divider().background(Color.white.opacity(0.08)).padding(.vertical, 2)

                menuActionButton(
                    icon: "slider.horizontal.3",
                    iconColor: isCustomSettingsEnabled ? Color.pixelNowGreen : .white.opacity(0.8),
                    title: isCustomSettingsEnabled ? "Launch Settings (\(profile.streamingQualityProfileOption.label))" : "Configure Launch Settings..."
                ) {
                    onDismiss()
                    onOpenSettings()
                }

                menuActionButton(
                    icon: isFavorite ? "heart.fill" : "heart",
                    iconColor: isFavorite ? Color.red : .white.opacity(0.8),
                    title: isFavorite ? "Remove from Favorites" : "Add to Favorites"
                ) {
                    onToggleFavorite()
                    onDismiss()
                }

                menuActionButton(
                    icon: "arrow.up.forward.app",
                    iconColor: .white.opacity(0.8),
                    title: "Add Desktop Shortcut"
                ) {
                    onDismiss()
                    onAddShortcut()
                }

                if game.primaryStoreURL != nil {
                    menuActionButton(
                        icon: "safari",
                        iconColor: .white.opacity(0.8),
                        title: "Open Store Page"
                    ) {
                        onDismiss()
                        onOpenStore()
                    }
                }
            }
            .padding(6)
        }
        .frame(width: 250)
        .background(Color(red: 18 / 255, green: 20 / 255, blue: 27 / 255).opacity(0.96))
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(isCustomSettingsEnabled ? Color.pixelNowGreen.opacity(0.5) : Color.white.opacity(0.18), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.65), radius: 18, y: 10)
        .onAppear {
            isCustomSettingsEnabled = StreamPreferences.profileEnabled(forGame: appId)
            profile = StreamPreferences.rawProfile(forGame: appId) ?? StreamPreferences.loadProfile()
        }
    }

    private func menuActionButton(icon: String, iconColor: Color, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundStyle(iconColor)
                    .frame(width: 18)

                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)

                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.white.opacity(0.001))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(HoverHighlightButtonStyle())
    }
}

private struct HoverHighlightButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(isHovered ? Color.white.opacity(0.10) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .onHover { isHovered = $0 }
    }
}
