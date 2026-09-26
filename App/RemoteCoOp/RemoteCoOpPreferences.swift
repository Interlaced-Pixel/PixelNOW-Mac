import Foundation

public enum RemoteCoOpPreferencesStore {
    private static let storage = AppPreferenceStorage.standard
    private static let alphaOptInKey = "PixelNOW.RemoteCoOp.AlphaOptIn"
    private static let enabledKey = "PixelNOW.RemoteCoOp.Enabled"
    private static let reservedGuestSlotsKey = "PixelNOW.RemoteCoOp.ReservedGuestSlots"
    private static let qualityPresetKey = "PixelNOW.RemoteCoOp.QualityPreset"
    private static let latencyModeKey = "PixelNOW.RemoteCoOp.LatencyMode"
    private static let hideGuestInviteDetailsKey = "PixelNOW.RemoteCoOp.HideGuestInviteDetails"

    public static var isAlphaOptedIn: Bool {
        bool(storage.object(forKey: alphaOptInKey), defaultValue: false)
    }

    public static func load() -> RemoteCoOpPreferences {
        RemoteCoOpPreferences(
            isAlphaOptedIn: isAlphaOptedIn,
            isEnabled: bool(storage.object(forKey: enabledKey), defaultValue: false),
            reservedGuestSlots: int(storage.object(forKey: reservedGuestSlotsKey), defaultValue: 1),
            qualityPreset: RemoteCoOpQualityPreset(rawValue: string(storage.object(forKey: qualityPresetKey))) ?? .p720f60,
            latencyMode: RemoteCoOpLatencyMode(rawValue: string(storage.object(forKey: latencyModeKey))) ?? .lowLatency,
            hideGuestInviteDetails: bool(storage.object(forKey: hideGuestInviteDetailsKey), defaultValue: false)
        )
    }

    public static func save(_ preferences: RemoteCoOpPreferences) {
        storage.set(preferences.isAlphaOptedIn, forKey: alphaOptInKey)
        storage.set(preferences.isEnabled, forKey: enabledKey)
        storage.set(RemoteCoOpPreferences.clampedGuestSlots(preferences.reservedGuestSlots), forKey: reservedGuestSlotsKey)
        storage.set(preferences.qualityPreset.rawValue, forKey: qualityPresetKey)
        storage.set(preferences.latencyMode.rawValue, forKey: latencyModeKey)
        storage.set(preferences.hideGuestInviteDetails, forKey: hideGuestInviteDetailsKey)
        storage.synchronize()
    }

    public static func setAlphaOptedIn(_ optedIn: Bool) {
        var preferences = load()
        preferences.isAlphaOptedIn = optedIn
        if !optedIn { preferences.isEnabled = false }
        save(preferences)
    }

    public static func setEnabled(_ enabled: Bool) {
        guard isAlphaOptedIn else { return }
        var preferences = load()
        preferences.isEnabled = enabled
        save(preferences)
    }

    public static func setReservedGuestSlots(_ slots: Int) {
        guard isAlphaOptedIn else { return }
        var preferences = load()
        preferences.reservedGuestSlots = RemoteCoOpPreferences.clampedGuestSlots(slots)
        save(preferences)
    }

    public static func setQualityPreset(_ preset: RemoteCoOpQualityPreset) {
        guard isAlphaOptedIn else { return }
        var preferences = load()
        preferences.qualityPreset = preset
        save(preferences)
    }

    public static func setLatencyMode(_ mode: RemoteCoOpLatencyMode) {
        guard isAlphaOptedIn else { return }
        var preferences = load()
        preferences.latencyMode = mode
        save(preferences)
    }

    public static func setHideGuestInviteDetails(_ hidden: Bool) {
        guard isAlphaOptedIn else { return }
        var preferences = load()
        preferences.hideGuestInviteDetails = hidden
        save(preferences)
    }

    public static func reservedControllerSlotsForLaunch() -> Int {
        load().effectiveReservedGuestSlots
    }

    private static func string(_ value: Any?) -> String {
        if let value = value as? String { return value }
        if let value = value as? NSString { return value as String }
        if let value = value as? NSNumber { return value.stringValue }
        return ""
    }

    private static func int(_ value: Any?, defaultValue: Int) -> Int {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String, let parsed = Int(value) { return parsed }
        return defaultValue
    }

    private static func bool(_ value: Any?, defaultValue: Bool) -> Bool {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        if let value = value as? String {
            return value == "1" || value.caseInsensitiveCompare("true") == .orderedSame || value.caseInsensitiveCompare("yes") == .orderedSame
        }
        return defaultValue
    }
}
