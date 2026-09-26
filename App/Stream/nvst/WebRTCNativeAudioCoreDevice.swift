import CoreAudio
import AudioUnit
import Foundation
@preconcurrency import WebRTC

private let coreAudioPlayoutCallback: AURenderCallback = { refCon, actionFlags, timestamp, busNumber, frameCount, outputData in
    let device = Unmanaged<PixelNOWCoreAudioRTCDevice>.fromOpaque(refCon).takeUnretainedValue()
    return device.renderPlayout(actionFlags: actionFlags, timestamp: timestamp, busNumber: Int(busNumber), frameCount: frameCount, outputData: outputData)
}

private let coreAudioRecordingCallback: AURenderCallback = { refCon, actionFlags, timestamp, busNumber, frameCount, _ in
    let device = Unmanaged<PixelNOWCoreAudioRTCDevice>.fromOpaque(refCon).takeUnretainedValue()
    return device.captureRecording(actionFlags: actionFlags, timestamp: timestamp, busNumber: Int(busNumber), frameCount: frameCount)
}
enum LibWebRTCAudio {
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

protocol PixelNOWCoreAudioRTCDeviceOwner: AnyObject {
    func handleGameAudioFrame(_ audioBufferList: UnsafeRawPointer?, frameCount: UInt32, sampleRate: Double, channels: UInt32)
    func handleMicrophoneAudioFrame(_ audioBufferList: UnsafeRawPointer?, frameCount: UInt32, sampleRate: Double, channels: UInt32)
    func handleCapturedMicrophoneLevel(_ level: Double)
    func isMicrophoneCaptureEnabled() -> Bool
}

final class PixelNOWCoreAudioRTCDevice: NSObject, RTCAudioDevice, @unchecked Sendable {
    weak var owner: (any PixelNOWCoreAudioRTCDeviceOwner)?

    let audioQueue = DispatchQueue(label: "com.interlacedpixel.pixelnow.webrtc.coreaudio")
    private var playoutUnit: AudioUnit?
    private var recordingUnit: AudioUnit?
    var outputDevice = AudioDeviceID(kAudioObjectUnknown)
    private var inputDevice = AudioDeviceID(kAudioObjectUnknown)
    private var recordingScratch = [Int16]()
    private let preferredInputDeviceId: String
    let monitorsDefaultDeviceChanges: Bool

    var selfDeviceChangeGeneration: UInt64 = 0
    private weak var delegate: RTCAudioDeviceDelegate?
    private var lastMicrophoneLevelReportNanoseconds: UInt64 = 0

    var isPlayoutMuted = false
    var playoutVolume = 1.0

    private(set) var deviceInputSampleRate = 48_000.0
    private(set) var inputIOBufferDuration: TimeInterval = 0.01
    private(set) var inputNumberOfChannels = 1
    private(set) var inputLatency: TimeInterval = 0
    private(set) var deviceOutputSampleRate = 48_000.0
    private(set) var outputIOBufferDuration: TimeInterval = 0.01
    private(set) var outputNumberOfChannels = 2
    private(set) var outputLatency: TimeInterval = 0
    private(set) var isInitialized = false
    private(set) var isPlayoutInitialized = false
    private(set) var isPlaying = false
    private(set) var isRecordingInitialized = false
    private(set) var isRecording = false

    var hasUsableOutputDevice: Bool {
        audioQueue.sync { outputDevice != AudioDeviceID(kAudioObjectUnknown) }
    }

    init(owner: (any PixelNOWCoreAudioRTCDeviceOwner)?, preferredInputDeviceId: String = "", monitorsDefaultDeviceChanges: Bool = false) {
        self.owner = owner
        self.preferredInputDeviceId = preferredInputDeviceId
        self.monitorsDefaultDeviceChanges = monitorsDefaultDeviceChanges
        super.init()
        updateDeviceParameters()
        if monitorsDefaultDeviceChanges { startSelfDeviceMonitoring() }
    }

    deinit {
        stopSelfDeviceMonitoring()
        _ = terminateDevice()
    }

    func initialize(with delegate: RTCAudioDeviceDelegate) -> Bool {
        audioQueue.sync {
            self.delegate = delegate
            isInitialized = true
            updateDeviceParameters()
        }
        return true
    }

    func terminateDevice() -> Bool {
        audioQueue.sync {
            stopPlayoutLocked()
            stopRecordingLocked()
            disposePlayoutUnitLocked()
            disposeRecordingUnitLocked()
            delegate = nil
            isInitialized = false
            isPlayoutInitialized = false
            isRecordingInitialized = false
        }
        return true
    }

    func initializePlayout() -> Bool {
        audioQueue.sync { initializePlayoutLocked() }
    }

    func startPlayout() -> Bool {
        audioQueue.sync { startPlayoutLocked() }
    }

    func stopPlayout() -> Bool {
        audioQueue.sync { stopPlayoutLocked() }
        return true
    }

    func initializeRecording() -> Bool {
        audioQueue.sync { initializeRecordingLocked() }
    }

    func startRecording() -> Bool {
        audioQueue.sync { startRecordingLocked() }
    }

    func stopRecording() -> Bool {
        audioQueue.sync { stopRecordingLocked() }
        return true
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
            if let delegate {
                delegate.dispatchAsync {
                    delegate.notifyAudioOutputInterrupted()
                    delegate.notifyAudioInputInterrupted()
                    delegate.notifyAudioOutputParametersChange()
                    delegate.notifyAudioInputParametersChange()
                }
            }
            if restartPlayout { _ = startPlayoutLocked() }
            if restartRecording { _ = startRecordingLocked() }
            WebRTCMediaTelemetry.capture("webrtc.native.audio.hot_swap", level: .debug, message: "CoreAudio RTC device hot-swapped.", attributes: ["inputDevice": String(inputDevice), "outputDevice": String(outputDevice), "playout": String(isPlaying), "recording": String(isRecording)])
        }
    }

    func renderPlayout(actionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>?, timestamp: UnsafePointer<AudioTimeStamp>?, busNumber: Int, frameCount: UInt32, outputData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
        guard let delegate, let actionFlags, let timestamp, let outputData else {
            clearAudioBufferList(outputData)
            return noErr
        }
        let status = delegate.getPlayoutData(actionFlags, timestamp, busNumber, frameCount, outputData)
        if status != noErr { clearAudioBufferList(outputData) }
        if status == noErr {
            owner?.handleGameAudioFrame(UnsafeRawPointer(outputData), frameCount: frameCount, sampleRate: deviceOutputSampleRate, channels: UInt32(outputNumberOfChannels))

            applyPlayoutVolume(to: outputData)
            if isPlayoutMuted { clearAudioBufferList(outputData) }
        }
        return status
    }

    func captureRecording(actionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>?, timestamp: UnsafePointer<AudioTimeStamp>?, busNumber: Int, frameCount: UInt32) -> OSStatus {
        guard let delegate, let recordingUnit, let actionFlags, let timestamp else { return noErr }
        let format = streamFormat(sampleRate: deviceInputSampleRate, channels: UInt32(inputNumberOfChannels))
        let requiredSamples = Int(frameCount) * Int(format.mChannelsPerFrame)
        let requiredBytes = requiredSamples * MemoryLayout<Int16>.size
        if recordingScratch.count < requiredSamples { recordingScratch = [Int16](unsafeUninitializedCapacity: requiredSamples) { buffer, initializedCount in initializedCount = requiredSamples } }
        return recordingScratch.withUnsafeMutableBufferPointer { scratchBuffer in
            guard let baseAddress = scratchBuffer.baseAddress else { return noErr }
            var inputData = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(mNumberChannels: UInt32(inputNumberOfChannels), mDataByteSize: UInt32(requiredBytes), mData: baseAddress)
            )
            let renderStatus = AudioUnitRender(recordingUnit, actionFlags, timestamp, 1, frameCount, &inputData)
            guard renderStatus == noErr else { return renderStatus }
            guard owner?.isMicrophoneCaptureEnabled() == true else {
                clearAudioBufferList(&inputData)
                reportMicrophoneLevelIfNeeded(inputData: &inputData)
                return delegate.deliverRecordedData(actionFlags, timestamp, busNumber, frameCount, &inputData, nil, nil)
            }
            reportMicrophoneLevelIfNeeded(inputData: &inputData)
            withUnsafePointer(to: &inputData) { pointer in
                owner?.handleMicrophoneAudioFrame(UnsafeRawPointer(pointer), frameCount: frameCount, sampleRate: deviceInputSampleRate, channels: UInt32(inputNumberOfChannels))
            }
            return delegate.deliverRecordedData(actionFlags, timestamp, busNumber, frameCount, &inputData, nil, nil)
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
        if status != noErr { WebRTCMediaTelemetry.capture("webrtc.native.audio.playout_start.error", level: .warning, message: "CoreAudio playout start failed.", attributes: ["status": String(status)]) }
        return isPlaying
    }

    private func startRecordingLocked() -> Bool {
        guard initializeRecordingLocked(), let recordingUnit else { return false }
        let status = AudioOutputUnitStart(recordingUnit)
        isRecording = status == noErr
        if status != noErr { WebRTCMediaTelemetry.capture("webrtc.native.audio.recording_start.error", level: .warning, message: "CoreAudio recording start failed.", attributes: ["status": String(status)]) }
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

    private func initializePlayoutLocked() -> Bool {
        if isPlayoutInitialized, playoutUnit != nil { return true }
        updateDeviceParameters()
        guard outputDevice != AudioDeviceID(kAudioObjectUnknown), let unit = createHALOutputUnit() else { return false }
        playoutUnit = unit
        var enable: UInt32 = 1
        var disable: UInt32 = 0
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &enable, UInt32(MemoryLayout<UInt32>.size))
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &disable, UInt32(MemoryLayout<UInt32>.size))
        var device = outputDevice
        var status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, UInt32(MemoryLayout<AudioDeviceID>.size))
        if status != noErr { WebRTCMediaTelemetry.capture("webrtc.native.audio.output_device.error", level: .warning, message: "CoreAudio set output device failed.", attributes: ["status": String(status), "device": String(outputDevice)]) }
        applyOutputBufferFrameSize(unit: unit, device: outputDevice)
        var format = streamFormat(sampleRate: deviceOutputSampleRate, channels: UInt32(outputNumberOfChannels))
        AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        var callback = AURenderCallbackStruct(inputProc: coreAudioPlayoutCallback, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        status = AudioUnitInitialize(unit)
        guard status == noErr else {
            WebRTCMediaTelemetry.capture("webrtc.native.audio.playout_initialize.error", level: .warning, message: "CoreAudio playout initialize failed.", attributes: ["status": String(status)])
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
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &disable, UInt32(MemoryLayout<UInt32>.size))
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enable, UInt32(MemoryLayout<UInt32>.size))
        var device = inputDevice
        var status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, UInt32(MemoryLayout<AudioDeviceID>.size))
        if status != noErr { WebRTCMediaTelemetry.capture("webrtc.native.audio.input_device.error", level: .warning, message: "CoreAudio set input device failed.", attributes: ["status": String(status), "device": String(inputDevice)]) }
        var format = streamFormat(sampleRate: deviceInputSampleRate, channels: UInt32(inputNumberOfChannels))
        AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &format, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        var callback = AURenderCallbackStruct(inputProc: coreAudioRecordingCallback, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        status = AudioUnitInitialize(unit)
        guard status == noErr else {
            WebRTCMediaTelemetry.capture("webrtc.native.audio.recording_initialize.error", level: .warning, message: "CoreAudio recording initialize failed.", attributes: ["status": String(status)])
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
        WebRTCMediaTelemetry.capture("webrtc.native.audio.output_buffer", level: .info, message: "CoreAudio output buffer frame size applied.", attributes: [
            "requested": String(requested), "actual": String(actual), "status": String(status),
            "range": hasRange ? "\(Int(range.mMinimum))-\(Int(range.mMaximum))" : "unknown",
            "deviceLatencyMs": String(format: "%.1f", outputLatency * 1000),
        ])
    }

    var outputPathLatencySeconds: TimeInterval { outputLatency + outputIOBufferDuration }

    private func createHALOutputUnit() -> AudioUnit? {
        var description = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput, componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else { return nil }
        var unit: AudioUnit?
        let status = AudioComponentInstanceNew(component, &unit)
        guard status == noErr else {
            WebRTCMediaTelemetry.capture("webrtc.native.audio.hal_unit.error", level: .warning, message: "CoreAudio HAL unit creation failed.", attributes: ["status": String(status)])
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
        inputDevice = LibWebRTCAudio.preferredInputDevice(preferredInputDeviceId)
        outputDevice = LibWebRTCAudio.defaultAudioDevice(kAudioHardwarePropertyDefaultOutputDevice)
        let preferredInputSampleRate = delegate?.preferredInputSampleRate ?? 0
        let preferredOutputSampleRate = delegate?.preferredOutputSampleRate ?? 0
        deviceInputSampleRate = nominalSampleRate(for: inputDevice, fallback: preferredInputSampleRate > 0 ? preferredInputSampleRate : 48_000)
        deviceOutputSampleRate = nominalSampleRate(for: outputDevice, fallback: preferredOutputSampleRate > 0 ? preferredOutputSampleRate : 48_000)
        inputNumberOfChannels = max(1, min(2, channelCount(for: inputDevice, scope: kAudioDevicePropertyScopeInput, fallback: 1)))
        outputNumberOfChannels = max(1, min(2, channelCount(for: outputDevice, scope: kAudioDevicePropertyScopeOutput, fallback: 2)))
        let preferredInputBufferDuration = delegate?.preferredInputIOBufferDuration ?? 0
        let preferredOutputBufferDuration = delegate?.preferredOutputIOBufferDuration ?? 0
        inputIOBufferDuration = preferredInputBufferDuration > 0 ? preferredInputBufferDuration : 0.01
        outputIOBufferDuration = preferredOutputBufferDuration > 0 ? preferredOutputBufferDuration : 0.01
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

    private func clearAudioBufferList(_ bufferList: UnsafeMutablePointer<AudioBufferList>?) {
        guard let bufferList else { return }
        for buffer in UnsafeMutableAudioBufferListPointer(bufferList) where buffer.mData != nil && buffer.mDataByteSize > 0 {
            memset(buffer.mData, 0, Int(buffer.mDataByteSize))
        }
    }

    private func applyPlayoutVolume(to bufferList: UnsafeMutablePointer<AudioBufferList>?) {
        guard let bufferList, playoutVolume < 1 else { return }
        let gain = min(max(playoutVolume, 0), 1)
        for buffer in UnsafeMutableAudioBufferListPointer(bufferList) {
            guard let data = buffer.mData, buffer.mDataByteSize >= 2 else { continue }
            let sampleCount = Int(buffer.mDataByteSize) / MemoryLayout<Int16>.size
            let samples = data.bindMemory(to: Int16.self, capacity: sampleCount)
            for index in 0..<sampleCount {
                let scaled = (Double(samples[index]) * gain).rounded()
                samples[index] = Int16(min(max(scaled, Double(Int16.min)), Double(Int16.max)))
            }
        }
    }
}
