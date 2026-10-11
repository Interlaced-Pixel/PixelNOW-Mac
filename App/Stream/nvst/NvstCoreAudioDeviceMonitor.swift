import AudioUnit
import CoreAudio
import Foundation

private let nvstDefaultDeviceChanged: AudioObjectPropertyListenerProc = { _, _, _, context in
    guard let context else { return noErr }
    Unmanaged<NvstCoreAudioDevice>.fromOpaque(context).takeUnretainedValue().scheduleSelfDeviceChange()
    return noErr
}

extension NvstCoreAudioDevice {
    private static var monitoredSelectors: [AudioObjectPropertySelector] {
        [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDevices]
    }

    func startSelfDeviceMonitoring() {
        for selector in Self.monitoredSelectors {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            let status = AudioObjectAddPropertyListener(AudioObjectID(kAudioObjectSystemObject), &address,
                nvstDefaultDeviceChanged, Unmanaged.passUnretained(self).toOpaque())
            if status != noErr {
                NativeNVSTMediaLog.write("nvst.audio.monitor.error", level: .warning, message: "Could not monitor audio device changes.", attributes: ["status": String(status)])
            }
        }
    }

    func stopSelfDeviceMonitoring() {
        for selector in Self.monitoredSelectors {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListener(AudioObjectID(kAudioObjectSystemObject), &address,
                nvstDefaultDeviceChanged, Unmanaged.passUnretained(self).toOpaque())
        }
    }

    func scheduleSelfDeviceChange() {
        audioQueue.async { [weak self] in
            guard let self else { return }
            selfDeviceChangeGeneration &+= 1
            let generation = selfDeviceChangeGeneration
            scheduleDeviceRebind(generation: generation, attempt: 0)
        }
    }

    private func scheduleDeviceRebind(generation: UInt64, attempt: Int) {
        audioQueue.asyncAfter(deadline: .now() + .milliseconds(attempt == 0 ? 250 : 500)) { [weak self] in
            guard let self, selfDeviceChangeGeneration == generation else { return }
            let output = NvstAudioHardware.defaultAudioDevice(kAudioHardwarePropertyDefaultOutputDevice)
            if output == AudioDeviceID(kAudioObjectUnknown) {
                if attempt < 10 { scheduleDeviceRebind(generation: generation, attempt: attempt + 1) }
                else { owner?.handleAudioDeviceFailure("Audio output stayed unavailable after device change") }
                return
            }
            handleDefaultDeviceChange()
        }
    }
}
