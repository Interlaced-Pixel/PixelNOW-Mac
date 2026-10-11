import CoreAudio
import AudioUnit
import Foundation

private let coreAudioPlayoutCallback: AURenderCallback = { refCon, actionFlags, timestamp, busNumber, frameCount, outputData in
    let device = Unmanaged<NvstCoreAudioDevice>.fromOpaque(refCon).takeUnretainedValue()
    return device.renderPlayout(actionFlags: actionFlags, timestamp: timestamp, busNumber: Int(busNumber), frameCount: frameCount, outputData: outputData)
}

private let coreAudioRecordingCallback: AURenderCallback = { refCon, actionFlags, timestamp, busNumber, frameCount, _ in
    let device = Unmanaged<NvstCoreAudioDevice>.fromOpaque(refCon).takeUnretainedValue()
    return device.captureRecording(actionFlags: actionFlags, timestamp: timestamp, busNumber: Int(busNumber), frameCount: frameCount)
}
enum NvstAudioHardware {
    static func defaultAudioDevice(_ selector: AudioObjectPropertySelector) -> AudioDeviceID {
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else {
            return AudioDeviceID(kAudioObjectUnknown)
        }
        return device
    }

    static func preferredInputDevice(_ uniqueId: String) -> AudioDeviceID {
        let fallback = defaultAudioDevice(kAudioHardwarePropertyDefaultInputDevice)
        guard !uniqueId.isEmpty else { return fallback }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize) == noErr else { return fallback }
        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return fallback }
        var devices = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &devices) == noErr else { return fallback }
        for device in devices where deviceHasInput(device) {
            if deviceUID(device) == uniqueId { return device }
        }
        return fallback
    }

    private static func deviceHasInput(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &dataSize) == noErr && dataSize > 0
    }

    private static func deviceUID(_ device: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &dataSize, &value) == noErr,
              let value else { return nil }
        return value.takeUnretainedValue() as String
    }
}

protocol NvstCoreAudioDeviceOwner: AnyObject {
    func handleGameAudioFrame(_ audioBufferList: UnsafeRawPointer?, frameCount: UInt32, sampleRate: Double, channels: UInt32)
    func handleMicrophoneAudioFrame(_ audioBufferList: UnsafeRawPointer?, frameCount: UInt32, sampleRate: Double, channels: UInt32)
    func handleCapturedMicrophoneLevel(_ level: Double)
    func microphoneSamplesAvailable()
    func handleAudioDeviceFailure(_ message: String)
    func handleRenderReference(_ samples: UnsafePointer<Int16>, frames: Int, channels: Int)
}

final class NvstCoreAudioDevice: NSObject, @unchecked Sendable {
    weak var owner: (any NvstCoreAudioDeviceOwner)?

    let audioQueue = DispatchQueue(label: "com.interlacedpixel.pixelnow.nvst.coreaudio")
    private let audioQueueKey = DispatchSpecificKey<UInt8>()
    private var playoutUnit: AudioUnit?
    private var recordingUnit: AudioUnit?
    var outputDevice = AudioDeviceID(kAudioObjectUnknown)
    private var inputDevice = AudioDeviceID(kAudioObjectUnknown)
    private var recordingScratch = [Int16](repeating: 0, count: 4096)
    private let preferredInputDeviceId: String
    let monitorsDefaultDeviceChanges: Bool

    var selfDeviceChangeGeneration: UInt64 = 0
    private let playout: NvstPcmBuffer
    private let capture: NvstPcmBuffer
    private let requestedChannels: Int
    private var lastMicrophoneLevelReportNanoseconds: UInt64 = 0


    private(set) var deviceInputSampleRate = 48_000.0
    private(set) var inputIOBufferDuration: TimeInterval = 0.01
    private(set) var inputNumberOfChannels = 1
    private(set) var inputLatency: TimeInterval = 0
    private(set) var deviceOutputSampleRate = 48_000.0
    private(set) var outputIOBufferDuration: TimeInterval = 0.01
    private(set) var outputNumberOfChannels = 2
    private(set) var outputLatency: TimeInterval = 0
    private(set) var isPlayoutInitialized = false
    private(set) var isPlaying = false
    private(set) var isRecordingInitialized = false
    private(set) var isRecording = false


    init(owner: (any NvstCoreAudioDeviceOwner)?, playout: NvstPcmBuffer, capture: NvstPcmBuffer,
         channels: Int, preferredInputDeviceId: String = "") {
        self.owner = owner
        self.playout = playout
        self.capture = capture
        requestedChannels = channels
        self.preferredInputDeviceId = preferredInputDeviceId
        monitorsDefaultDeviceChanges = true
        super.init()
        audioQueue.setSpecific(key: audioQueueKey, value: 1)
        updateDeviceParameters()
        startSelfDeviceMonitoring()
    }

    deinit { stopSelfDeviceMonitoring(); stop() }

    func start(microphone: Bool) throws {
        try audioQueue.sync {
            guard startPlayoutLocked() else { throw NvstBundle.BundleError.transport("Could not start CoreAudio playout") }
            if microphone && !startRecordingLocked() {
                stopPlayoutLocked()
                throw NvstBundle.BundleError.transport("Could not start CoreAudio microphone capture")
            }
        }
    }

    func stop() {
        if DispatchQueue.getSpecific(key: audioQueueKey) != nil { stopLocked() }
        else { audioQueue.sync { stopLocked() } }
    }

    private func stopLocked() {
        selfDeviceChangeGeneration &+= 1
        stopPlayoutLocked()
        stopRecordingLocked()
        disposePlayoutUnitLocked()
        disposeRecordingUnitLocked()
    }

    @objc func handleDefaultDeviceChange() {
        audioQueue.async { [weak self] in
            guard let self else { return }
            let restartPlayout = isPlaying
            let restartRecording = isRecording
            stopPlayoutLocked()
            stopRecordingLocked()
            disposePlayoutUnitLocked()
            disposeRecordingUnitLocked()
            updateDeviceParameters()
            if restartPlayout && !startPlayoutLocked() { owner?.handleAudioDeviceFailure("Could not restart CoreAudio playout after device change") }
            if restartRecording && !startRecordingLocked() { owner?.handleAudioDeviceFailure("Could not restart CoreAudio capture after device change") }
            NativeNVSTMediaLog.write("nvst.native.audio.hot_swap", level: .debug, message: "CoreAudio device hot-swapped.", attributes: ["inputDevice": String(inputDevice), "outputDevice": String(outputDevice), "playout": String(isPlaying), "recording": String(isRecording)])
        }
    }

    func renderPlayout(actionFlags: UnsafeMutablePointer<UInt32>?, timestamp: UnsafePointer<AudioTimeStamp>?, busNumber: Int, frameCount: UInt32, outputData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
        guard let outputData else { return kAudio_ParamError }
        playout.render(outputData, frames: Int(frameCount), channels: outputNumberOfChannels)
        owner?.handleGameAudioFrame(UnsafeRawPointer(outputData), frameCount: frameCount, sampleRate: 48_000, channels: UInt32(outputNumberOfChannels))
        playout.applyGain(outputData)
        for buffer in UnsafeMutableAudioBufferListPointer(outputData) {
            if let data = buffer.mData {
                let samples = data.bindMemory(to: Int16.self, capacity: Int(buffer.mDataByteSize) / 2)
                owner?.handleRenderReference(samples, frames: Int(frameCount), channels: outputNumberOfChannels)
            }
        }
        return noErr
    }

    func captureRecording(actionFlags: UnsafeMutablePointer<UInt32>?, timestamp: UnsafePointer<AudioTimeStamp>?, busNumber: Int, frameCount: UInt32) -> OSStatus {
        guard let recordingUnit, let actionFlags, let timestamp, frameCount <= 4096 else { return kAudio_ParamError }
        return recordingScratch.withUnsafeMutableBufferPointer { samples in
            guard let address = samples.baseAddress else { return kAudio_ParamError }
            var inputData = AudioBufferList(mNumberBuffers: 1,
                mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: frameCount * 2, mData: address))
            let status = AudioUnitRender(recordingUnit, actionFlags, timestamp, 1, frameCount, &inputData)
            guard status == noErr else {
                owner?.handleAudioDeviceFailure("CoreAudio capture failed (status \(status))")
                return status
            }
            guard inputData.mBuffers.mDataByteSize >= frameCount * 2 else { return kAudio_ParamError }
            capture.writeCapture(address, frames: Int(frameCount), channels: 1)
            owner?.microphoneSamplesAvailable()
            reportMicrophoneLevelIfNeeded(inputData: &inputData)
            withUnsafePointer(to: &inputData) {
                owner?.handleMicrophoneAudioFrame(UnsafeRawPointer($0), frameCount: frameCount, sampleRate: 48_000, channels: 1)
            }
            return noErr
        }
    }

    private func reportMicrophoneLevelIfNeeded(inputData: UnsafeMutablePointer<AudioBufferList>) {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now - lastMicrophoneLevelReportNanoseconds >= 50_000_000 else { return }
        lastMicrophoneLevelReportNanoseconds = now
        owner?.handleCapturedMicrophoneLevel(microphoneLevel(from: inputData))
    }

    private func microphoneLevel(from inputData: UnsafeMutablePointer<AudioBufferList>) -> Double {
        var sumSquares = 0.0
        var sampleCount = 0
        for buffer in UnsafeMutableAudioBufferListPointer(inputData) {
            guard let data = buffer.mData else { continue }
            let count = Int(buffer.mDataByteSize) / MemoryLayout<Int16>.size
            guard count > 0 else { continue }
            let samples = data.bindMemory(to: Int16.self, capacity: count)
            for index in 0..<count {
                let sample = Double(samples[index]) / Double(Int16.max)
                sumSquares += sample * sample
            }
            sampleCount += count
        }
        guard sampleCount > 0 else { return 0 }
        return min(1, sqrt(sumSquares / Double(sampleCount)) * 6)
    }

    private func startPlayoutLocked() -> Bool {
        guard initializePlayoutLocked(), let playoutUnit else { return false }
        let status = AudioOutputUnitStart(playoutUnit)
        isPlaying = status == noErr
        if status != noErr { NativeNVSTMediaLog.write("nvst.native.audio.playout_start.error", level: .warning, message: "CoreAudio playout start failed.", attributes: ["status": String(status)]) }
        return isPlaying
    }

    private func startRecordingLocked() -> Bool {
        guard initializeRecordingLocked(), let recordingUnit else { return false }
        let status = AudioOutputUnitStart(recordingUnit)
        isRecording = status == noErr
        if status != noErr { NativeNVSTMediaLog.write("nvst.native.audio.recording_start.error", level: .warning, message: "CoreAudio recording start failed.", attributes: ["status": String(status)]) }
        return isRecording
    }

    private func stopPlayoutLocked() {
        if let playoutUnit, isPlaying { AudioOutputUnitStop(playoutUnit) }
        isPlaying = false
    }

    private func stopRecordingLocked() {
        if let recordingUnit, isRecording { AudioOutputUnitStop(recordingUnit) }
        isRecording = false
    }

    private func setProperty<T: BitwiseCopyable>(_ unit: AudioUnit, _ property: AudioUnitPropertyID,
                                scope: AudioUnitScope, element: AudioUnitElement, value: inout T) -> Bool {
        let status = AudioUnitSetProperty(unit, property, scope, element, &value, UInt32(MemoryLayout<T>.size))
        if status != noErr {
            NativeNVSTMediaLog.write("nvst.audio.configure.failed", level: .warning, message: "CoreAudio property rejected.",
                attributes: ["property": String(property), "scope": String(scope), "element": String(element), "status": String(status)])
        }
        return status == noErr
    }

    private func initializePlayoutLocked() -> Bool {
        if isPlayoutInitialized, playoutUnit != nil { return true }
        updateDeviceParameters()
        guard outputDevice != AudioDeviceID(kAudioObjectUnknown), let unit = createHALOutputUnit() else { return false }
        playoutUnit = unit
        var enable: UInt32 = 1
        var disable: UInt32 = 0
        var device = outputDevice
        var maximumFrames: UInt32 = 4096
        var format = streamFormat(sampleRate: 48_000, channels: UInt32(outputNumberOfChannels))
        var callback = AURenderCallbackStruct(inputProc: coreAudioPlayoutCallback, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = outputNumberOfChannels == 8 ? kAudioChannelLayoutTag_MPEG_7_1_C :
            outputNumberOfChannels == 6 ? kAudioChannelLayoutTag_MPEG_5_1_A :
            outputNumberOfChannels == 2 ? kAudioChannelLayoutTag_Stereo : kAudioChannelLayoutTag_Mono
        guard setProperty(unit, kAudioOutputUnitProperty_EnableIO, scope: kAudioUnitScope_Output, element: 0, value: &enable),
              setProperty(unit, kAudioOutputUnitProperty_EnableIO, scope: kAudioUnitScope_Input, element: 1, value: &disable),
              setProperty(unit, kAudioOutputUnitProperty_CurrentDevice, scope: kAudioUnitScope_Global, element: 0, value: &device),
              setProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, scope: kAudioUnitScope_Global, element: 0, value: &maximumFrames),
              setProperty(unit, kAudioUnitProperty_StreamFormat, scope: kAudioUnitScope_Input, element: 0, value: &format),
              setProperty(unit, kAudioUnitProperty_AudioChannelLayout, scope: kAudioUnitScope_Input, element: 0, value: &layout),
              setProperty(unit, kAudioUnitProperty_SetRenderCallback, scope: kAudioUnitScope_Input, element: 0, value: &callback) else {
            disposePlayoutUnitLocked()
            return false
        }
        applyOutputBufferFrameSize(unit: unit, device: outputDevice)
        let status = AudioUnitInitialize(unit)
        guard status == noErr else {
            NativeNVSTMediaLog.write("nvst.audio.playout.initialize.failed", level: .warning, message: "CoreAudio initialization failed.", attributes: ["status": String(status)])
            disposePlayoutUnitLocked()
            return false
        }
        isPlayoutInitialized = true
        return true
    }

    private func initializeRecordingLocked() -> Bool {
        if isRecordingInitialized, recordingUnit != nil { return true }
        updateDeviceParameters()
        guard inputDevice != AudioDeviceID(kAudioObjectUnknown), let unit = createHALOutputUnit() else { return false }
        recordingUnit = unit
        var enable: UInt32 = 1
        var disable: UInt32 = 0
        var device = inputDevice
        var maximumFrames: UInt32 = 4096
        var format = streamFormat(sampleRate: 48_000, channels: 1)
        var callback = AURenderCallbackStruct(inputProc: coreAudioRecordingCallback, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        guard setProperty(unit, kAudioOutputUnitProperty_EnableIO, scope: kAudioUnitScope_Output, element: 0, value: &disable),
              setProperty(unit, kAudioOutputUnitProperty_EnableIO, scope: kAudioUnitScope_Input, element: 1, value: &enable),
              setProperty(unit, kAudioOutputUnitProperty_CurrentDevice, scope: kAudioUnitScope_Global, element: 0, value: &device),
              setProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, scope: kAudioUnitScope_Global, element: 0, value: &maximumFrames),
              setProperty(unit, kAudioUnitProperty_StreamFormat, scope: kAudioUnitScope_Output, element: 1, value: &format),
              setProperty(unit, kAudioOutputUnitProperty_SetInputCallback, scope: kAudioUnitScope_Global, element: 0, value: &callback) else {
            disposeRecordingUnitLocked()
            return false
        }
        let status = AudioUnitInitialize(unit)
        guard status == noErr else {
            NativeNVSTMediaLog.write("nvst.audio.capture.initialize.failed", level: .warning, message: "CoreAudio initialization failed.", attributes: ["status": String(status)])
            disposeRecordingUnitLocked()
            return false
        }
        isRecordingInitialized = true
        return true
    }

    static let preferredOutputBufferSeconds = 0.005

    private func applyOutputBufferFrameSize(unit: AudioUnit, device: AudioDeviceID) {
        guard device != AudioDeviceID(kAudioObjectUnknown), deviceOutputSampleRate > 0 else { return }
        var range = AudioValueRange(mMinimum: 0, mMaximum: 0)
        var rangeSize = UInt32(MemoryLayout<AudioValueRange>.size)
        var rangeAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyBufferFrameSizeRange, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        let hasRange = AudioObjectGetPropertyData(device, &rangeAddress, 0, nil, &rangeSize, &range) == noErr && range.mMaximum >= range.mMinimum && range.mMaximum > 0
        var frames = UInt32(max(1, (Self.preferredOutputBufferSeconds * deviceOutputSampleRate).rounded()))
        if hasRange { frames = min(max(frames, UInt32(range.mMinimum)), UInt32(range.mMaximum)) }
        let requested = frames
        let status = AudioUnitSetProperty(unit, kAudioDevicePropertyBufferFrameSize, kAudioUnitScope_Global, 0, &frames, UInt32(MemoryLayout<UInt32>.size))
        var actual: UInt32 = 0
        var actualSize = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyBufferFrameSize, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        if AudioObjectGetPropertyData(device, &address, 0, nil, &actualSize, &actual) == noErr, actual > 0 {
            outputIOBufferDuration = Double(actual) / deviceOutputSampleRate
        }
        NativeNVSTMediaLog.write("nvst.native.audio.output_buffer", level: .info, message: "CoreAudio output buffer frame size applied.", attributes: [
            "requested": String(requested), "actual": String(actual), "status": String(status),
            "range": hasRange ? "\(Int(range.mMinimum))-\(Int(range.mMaximum))" : "unknown",
            "deviceLatencyMs": String(format: "%.1f", outputLatency * 1000),
        ])
    }

    var outputPathLatencySeconds: TimeInterval { audioQueue.sync { outputLatency + outputIOBufferDuration } }
    var echoPathLatencySeconds: TimeInterval { audioQueue.sync { outputLatency + outputIOBufferDuration + inputLatency + inputIOBufferDuration } }

    private func createHALOutputUnit() -> AudioUnit? {
        var description = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput, componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else { return nil }
        var unit: AudioUnit?
        let status = AudioComponentInstanceNew(component, &unit)
        guard status == noErr else {
            NativeNVSTMediaLog.write("nvst.native.audio.hal_unit.error", level: .warning, message: "CoreAudio HAL unit creation failed.", attributes: ["status": String(status)])
            return nil
        }
        return unit
    }

    private func disposePlayoutUnitLocked() {
        guard let playoutUnit else { return }
        AudioUnitUninitialize(playoutUnit)
        AudioComponentInstanceDispose(playoutUnit)
        self.playoutUnit = nil
        isPlayoutInitialized = false
    }

    private func disposeRecordingUnitLocked() {
        guard let recordingUnit else { return }
        AudioUnitUninitialize(recordingUnit)
        AudioComponentInstanceDispose(recordingUnit)
        self.recordingUnit = nil
        isRecordingInitialized = false
    }

    private func updateDeviceParameters() {
        inputDevice = NvstAudioHardware.preferredInputDevice(preferredInputDeviceId)
        outputDevice = NvstAudioHardware.defaultAudioDevice(kAudioHardwarePropertyDefaultOutputDevice)
        deviceInputSampleRate = nominalSampleRate(for: inputDevice, fallback: 48_000)
        deviceOutputSampleRate = nominalSampleRate(for: outputDevice, fallback: 48_000)
        inputNumberOfChannels = 1
        let available = channelCount(for: outputDevice, scope: kAudioDevicePropertyScopeOutput, fallback: 2)
        outputNumberOfChannels = requestedChannels >= 8 && available >= 8 ? 8 : requestedChannels >= 6 && available >= 6 ? 6 : min(max(available, 1), 2)
        inputIOBufferDuration = 0.01
        outputIOBufferDuration = 0.005
        inputLatency = latency(for: inputDevice, scope: kAudioDevicePropertyScopeInput)
        outputLatency = latency(for: outputDevice, scope: kAudioDevicePropertyScopeOutput)
    }

    private func nominalSampleRate(for device: AudioDeviceID, fallback: Double) -> Double {
        guard device != AudioDeviceID(kAudioObjectUnknown) else { return fallback }
        var rate = Float64(fallback)
        var size = UInt32(MemoryLayout<Float64>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate) == noErr, rate > 0 else { return fallback }
        return rate
    }

    private func channelCount(for device: AudioDeviceID, scope: AudioObjectPropertyScope, fallback: Int) -> Int {
        guard device != AudioDeviceID(kAudioObjectUnknown) else { return fallback }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size >= UInt32(MemoryLayout<AudioBufferList>.size) else { return fallback }
        let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        let bufferList = storage.bindMemory(to: AudioBufferList.self, capacity: 1)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, bufferList) == noErr else { return fallback }
        var channels: UInt32 = 0
        for buffer in UnsafeMutableAudioBufferListPointer(bufferList) {
            channels += buffer.mNumberChannels
        }
        return channels > 0 ? Int(channels) : fallback
    }

    private func latency(for device: AudioDeviceID, scope: AudioObjectPropertyScope) -> TimeInterval {
        guard device != AudioDeviceID(kAudioObjectUnknown) else { return 0 }
        var latencyFrames: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyLatency, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &latencyFrames) == noErr else { return 0 }
        let rate = scope == kAudioDevicePropertyScopeInput ? deviceInputSampleRate : deviceOutputSampleRate
        return rate > 0 ? Double(latencyFrames) / rate : 0
    }

    private func streamFormat(sampleRate: Double, channels: UInt32) -> AudioStreamBasicDescription {
        let channelCount = max(1, channels)
        return AudioStreamBasicDescription(
            mSampleRate: sampleRate > 0 ? sampleRate : 48_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: channelCount * UInt32(MemoryLayout<Int16>.size),
            mFramesPerPacket: 1,
            mBytesPerFrame: channelCount * UInt32(MemoryLayout<Int16>.size),
            mChannelsPerFrame: channelCount,
            mBitsPerChannel: 16,
            mReserved: 0
        )
    }

}
