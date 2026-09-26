import AudioUnit
import CoreAudio
import Foundation

private let coreAudioDeviceDefaultChangedCallback: AudioObjectPropertyListenerProc = { _, _, _, clientData in
    guard let clientData else { return noErr }
    let device = Unmanaged<PixelNOWCoreAudioRTCDevice>.fromOpaque(clientData).takeUnretainedValue()
    device.scheduleSelfDeviceChange()
    return noErr
}

extension PixelNOWCoreAudioRTCDevice {
    func startSelfDeviceMonitoring() {
        var outputAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let context = Unmanaged.passUnretained(self).toOpaque()
        let status = AudioObjectAddPropertyListener(AudioObjectID(kAudioObjectSystemObject), &outputAddress, coreAudioDeviceDefaultChangedCallback, context)
        WebRTCMediaTelemetry.capture("webrtc.native.audio.self_monitor.start", level: .debug, message: "CoreAudio RTC device is following the default output device.", attributes: ["status": String(status)])
    }

    func stopSelfDeviceMonitoring() {
        guard monitorsDefaultDeviceChanges else { return }
        var outputAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let context = Unmanaged.passUnretained(self).toOpaque()
        AudioObjectRemovePropertyListener(AudioObjectID(kAudioObjectSystemObject), &outputAddress, coreAudioDeviceDefaultChangedCallback, context)
    }

    func scheduleSelfDeviceChange() {

        let generation = audioQueue.sync { () -> UInt64 in
            selfDeviceChangeGeneration &+= 1
            return selfDeviceChangeGeneration
        }
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, self.isCurrentSelfDeviceChange(generation) else { return }
            self.applySelfDeviceChange(generation: generation, attempt: 0)
        }
    }

    private func isCurrentSelfDeviceChange(_ generation: UInt64) -> Bool {
        audioQueue.sync { selfDeviceChangeGeneration == generation }
    }

    private func applySelfDeviceChange(generation: UInt64, attempt: Int) {
        let current = LibWebRTCAudio.defaultAudioDevice(kAudioHardwarePropertyDefaultOutputDevice)
        guard current != AudioDeviceID(kAudioObjectUnknown) else {
            guard attempt < 10 else {
                WebRTCMediaTelemetry.capture("webrtc.native.audio.self_monitor.unavailable", level: .warning, message: "Default output device stayed unavailable after a hotplug.")
                return
            }
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, self.isCurrentSelfDeviceChange(generation) else { return }
                self.applySelfDeviceChange(generation: generation, attempt: attempt + 1)
            }
            return
        }
        guard audioQueue.sync(execute: { current != outputDevice }) else { return }
        WebRTCMediaTelemetry.capture("webrtc.native.audio.self_monitor.changed", level: .info, message: "Default output device changed; rebinding the CoreAudio RTC device.", attributes: ["outputDevice": String(current)])
        handleDefaultDeviceChange()
    }
}
