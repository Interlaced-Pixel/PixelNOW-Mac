import AVFoundation
import CoreMedia
import Foundation
import QuartzCore

public final class StreamRecordingMicrophoneCapturer: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let captureSession = AVCaptureSession()
    private let captureQueue = DispatchQueue(label: "io.opencg.pixelnow.recording.mic.capture", qos: .userInitiated)
    private var isRunning = false
    private let preferredDeviceId: String
    public var onAudioSample: (@Sendable (CMSampleBuffer) -> Void)?

    public init(preferredDeviceId: String = "") {
        self.preferredDeviceId = preferredDeviceId
        super.init()
    }

    public func start() {
        captureQueue.async { [weak self] in
            guard let self, !self.isRunning else { return }
            self.setupAndStartSession()
        }
    }

    public func stop() {
        captureQueue.async { [weak self] in
            guard let self, self.isRunning else { return }
            self.captureSession.stopRunning()
            for input in self.captureSession.inputs {
                self.captureSession.removeInput(input)
            }
            for output in self.captureSession.outputs {
                self.captureSession.removeOutput(output)
            }
            self.isRunning = false
        }
    }

    private func setupAndStartSession() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            startSessionWithSelectedDevice()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                guard granted, let self else { return }
                self.captureQueue.async {
                    self.startSessionWithSelectedDevice()
                }
            }
        case .denied, .restricted:
            break
        @unknown default:
            break
        }
    }

    private func startSessionWithSelectedDevice() {
        guard !isRunning else { return }
        let device = selectAudioDevice()
        guard let device else { return }
        do {
            let input = try AVCaptureDeviceInput(device: device)
            captureSession.beginConfiguration()
            if captureSession.canAddInput(input) {
                captureSession.addInput(input)
            }
            let output = AVCaptureAudioDataOutput()
            output.setSampleBufferDelegate(self, queue: captureQueue)
            if captureSession.canAddOutput(output) {
                captureSession.addOutput(output)
            }
            captureSession.commitConfiguration()
            captureSession.startRunning()
            isRunning = true
        } catch {
            captureSession.commitConfiguration()
        }
    }

    private func selectAudioDevice() -> AVCaptureDevice? {
        if !preferredDeviceId.isEmpty {
            let discovery = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.microphone, .external],
                mediaType: .audio,
                position: .unspecified
            )
            if let matched = discovery.devices.first(where: { $0.uniqueID == preferredDeviceId }) {
                return matched
            }
        }
        return AVCaptureDevice.default(for: .audio)
    }

    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard isRunning else { return }
        onAudioSample?(sampleBuffer)
    }
}

final class MicrophoneAudioConverter {
    private var converter: AVAudioConverter?
    private var cachedInputFormat: AVAudioFormat?
    private let targetFormat: AVAudioFormat

    init(targetFormat: AVAudioFormat) {
        self.targetFormat = targetFormat
    }

    func convert(sampleBuffer: CMSampleBuffer) -> Data? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else { return nil }
        let numSamples = CMSampleBufferGetNumSamples(sampleBuffer)
        guard numSamples > 0 else { return nil }

        guard let inputFormat = AVAudioFormat(streamDescription: asbd) else { return nil }
        if converter == nil || cachedInputFormat != inputFormat {
            guard let newConverter = AVAudioConverter(from: inputFormat, to: targetFormat) else { return nil }
            converter = newConverter
            cachedInputFormat = inputFormat
        }
        guard let converter else { return nil }

        let frameCapacity = AVAudioFrameCount(numSamples)
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frameCapacity) else { return nil }
        inputBuffer.frameLength = frameCapacity

        let copyStatus = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCapacity),
            into: inputBuffer.mutableAudioBufferList
        )
        guard copyStatus == noErr else { return nil }

        let sampleRateRatio = targetFormat.sampleRate / max(1.0, inputFormat.sampleRate)
        let outputFrameCapacity = AVAudioFrameCount(Double(frameCapacity) * sampleRateRatio + 32)
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrameCapacity) else { return nil }

        var error: NSError?
        var didProvideInput = false
        let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if !didProvideInput {
                didProvideInput = true
                outStatus.pointee = .haveData
                return inputBuffer
            } else {
                outStatus.pointee = .noDataNow
                return nil
            }
        }
        guard (status == .haveData || status == .inputRanDry), outputBuffer.frameLength > 0, let channelData = outputBuffer.int16ChannelData else {
            return nil
        }
        let byteCount = Int(outputBuffer.frameLength) * 2 * MemoryLayout<Int16>.size
        return Data(bytes: channelData[0], count: byteCount)
    }
}

final class GameAudioConverter {
    private var converter: AVAudioConverter?
    private var cachedInputFormat: AVAudioFormat?
    private let targetFormat: AVAudioFormat

    init(targetFormat: AVAudioFormat) {
        self.targetFormat = targetFormat
    }

    func normalize(data: Data, frameCount: UInt32, sampleRate: Double, channels: UInt32) -> Data {
        let actualSampleRate = sampleRate > 0 ? sampleRate : 48_000
        let actualChannels = max(1, channels)
        if actualSampleRate == 48_000 && actualChannels == 2 {
            return data
        }
        guard let inputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: actualSampleRate, channels: AVAudioChannelCount(actualChannels), interleaved: true) else {
            return data
        }
        if converter == nil || cachedInputFormat != inputFormat {
            guard let newConverter = AVAudioConverter(from: inputFormat, to: targetFormat) else { return data }
            converter = newConverter
            cachedInputFormat = inputFormat
        }
        guard let converter else { return data }

        let inputFrameCount = AVAudioFrameCount(frameCount > 0 ? frameCount : UInt32(data.count / (Int(actualChannels) * 2)))
        guard inputFrameCount > 0,
              let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: inputFrameCount) else { return data }
        inputBuffer.frameLength = inputFrameCount
        data.withUnsafeBytes { raw in
            if let src = raw.baseAddress, let dest = inputBuffer.int16ChannelData?[0] {
                memcpy(dest, src, min(data.count, Int(inputFrameCount) * Int(actualChannels) * 2))
            }
        }

        let ratio = targetFormat.sampleRate / actualSampleRate
        let outputFrameCapacity = AVAudioFrameCount(Double(inputFrameCount) * ratio + 32)
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrameCapacity) else { return data }

        var error: NSError?
        var didProvideInput = false
        let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if !didProvideInput {
                didProvideInput = true
                outStatus.pointee = .haveData
                return inputBuffer
            } else {
                outStatus.pointee = .noDataNow
                return nil
            }
        }
        guard (status == .haveData || status == .inputRanDry), outputBuffer.frameLength > 0, let channelData = outputBuffer.int16ChannelData else {
            return data
        }
        let byteCount = Int(outputBuffer.frameLength) * 2 * MemoryLayout<Int16>.size
        return Data(bytes: channelData[0], count: byteCount)
    }
}

public final class StreamRecordingAudioMixer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "io.opencg.pixelnow.recording.mixer", qos: .userInitiated)
    private let targetFormat: AVAudioFormat
    private let micConverter: MicrophoneAudioConverter
    private let gameConverter: GameAudioConverter
    private let microphoneVolume: Double
    private let microphoneEnabled: Bool
    private var gameBuffer = Data()
    private var micBuffer = Data()
    private var totalFramesEmitted: Int64 = 0
    private var isStarted = false
    private var lastGameAudioTimestamp: CFTimeInterval = 0
    private let maxBufferedBytes = 48_000 * 4
    private let maxMicLatencyBytes = 12_000 * 4

    public var onMixedAudioBuffer: (@Sendable (CMSampleBuffer) -> Void)?

    private static let formatDescription: CMAudioFormatDescription? = {
        var description = AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        var formatDesc: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &description,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDesc
        ) == noErr else { return nil }
        return formatDesc
    }()

    public init(microphoneVolume: Double, microphoneEnabled: Bool) {
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48_000, channels: 2, interleaved: true)!
        self.targetFormat = format
        self.micConverter = MicrophoneAudioConverter(targetFormat: format)
        self.gameConverter = GameAudioConverter(targetFormat: format)
        self.microphoneVolume = min(max(microphoneVolume, 0.0), 2.0)
        self.microphoneEnabled = microphoneEnabled
    }

    public func start() {
        queue.async {
            self.isStarted = true
            self.totalFramesEmitted = 0
            self.lastGameAudioTimestamp = CACurrentMediaTime()
            if self.gameBuffer.count > 24_000 {
                self.gameBuffer = self.gameBuffer.suffix(24_000)
            }
            if self.micBuffer.count > 24_000 {
                self.micBuffer = self.micBuffer.suffix(24_000)
            }
            self.drainBuffers()
        }
    }

    public func appendGameAudio(data: Data, frameCount: UInt32, sampleRate: Double, channels: UInt32) {
        guard !data.isEmpty else { return }
        queue.async {
            let normalized = self.gameConverter.normalize(data: data, frameCount: frameCount, sampleRate: sampleRate, channels: channels)
            guard !normalized.isEmpty else { return }
            self.lastGameAudioTimestamp = CACurrentMediaTime()
            self.gameBuffer.append(normalized)
            if self.gameBuffer.count > self.maxBufferedBytes {
                self.gameBuffer.removeFirst(self.gameBuffer.count - self.maxBufferedBytes)
            }
            if self.isStarted {
                self.drainBuffers()
            }
        }
    }

    public func appendMicrophoneAudio(sampleBuffer: CMSampleBuffer) {
        guard microphoneEnabled else { return }
        let retainedPtr = UInt(bitPattern: Unmanaged.passRetained(sampleBuffer).toOpaque())
        queue.async {
            let buffer = Unmanaged<CMSampleBuffer>.fromOpaque(UnsafeRawPointer(bitPattern: retainedPtr)!).takeRetainedValue()
            guard let micData = self.micConverter.convert(sampleBuffer: buffer), !micData.isEmpty else { return }
            self.micBuffer.append(micData)
            if self.micBuffer.count > self.maxMicLatencyBytes {
                self.micBuffer.removeFirst(self.micBuffer.count - self.maxMicLatencyBytes)
            }
            if self.isStarted {
                if self.gameBuffer.isEmpty, CACurrentMediaTime() - self.lastGameAudioTimestamp > 0.15 {
                    self.drainMicOnly()
                } else {
                    self.drainBuffers()
                }
            }
        }
    }

    public func flush() {
        queue.sync {
            guard self.isStarted else { return }
            self.drainAllRemaining()
        }
    }

    public func stop() {
        queue.async {
            guard self.isStarted else { return }
            self.drainAllRemaining()
            self.isStarted = false
            self.gameBuffer.removeAll()
            self.micBuffer.removeAll()
        }
    }

    private func drainBuffers() {
        guard isStarted else { return }
        if !microphoneEnabled {
            while gameBuffer.count >= 4 {
                let chunkBytes = min(gameBuffer.count, 4096)
                let frameCount = UInt32(chunkBytes / 4)
                let validBytes = Int(frameCount * 4)
                let chunkData = gameBuffer.prefix(validBytes)
                gameBuffer.removeFirst(validBytes)
                emitSampleBuffer(data: chunkData, frameCount: frameCount)
            }
            return
        }

        while gameBuffer.count >= 4 {
            let chunkBytes = min(gameBuffer.count, 4096)
            let frameCount = UInt32(chunkBytes / 4)
            let validBytes = Int(frameCount * 4)
            let gameChunk = gameBuffer.prefix(validBytes)
            gameBuffer.removeFirst(validBytes)

            let micBytesToTake = min(micBuffer.count, validBytes)
            let micChunk = micBuffer.prefix(micBytesToTake)
            if micBytesToTake > 0 {
                micBuffer.removeFirst(micBytesToTake)
            }

            let mixedData = mixAudioChunks(gameData: gameChunk, micData: micChunk, frameCount: frameCount)
            emitSampleBuffer(data: mixedData, frameCount: frameCount)
        }
    }

    private func drainMicOnly() {
        guard isStarted, microphoneEnabled else { return }
        while micBuffer.count >= 4 {
            let chunkBytes = min(micBuffer.count, 4096)
            let frameCount = UInt32(chunkBytes / 4)
            let validBytes = Int(frameCount * 4)
            let micChunk = micBuffer.prefix(validBytes)
            micBuffer.removeFirst(validBytes)

            let mixedData = mixAudioChunks(gameData: Data(), micData: micChunk, frameCount: frameCount)
            emitSampleBuffer(data: mixedData, frameCount: frameCount)
        }
    }

    private func drainAllRemaining() {
        drainBuffers()
        if microphoneEnabled, !micBuffer.isEmpty {
            drainMicOnly()
        }
    }

    private func mixAudioChunks(gameData: Data, micData: Data, frameCount: UInt32) -> Data {
        var output = Data(count: Int(frameCount) * 4)
        output.withUnsafeMutableBytes { outRaw in
            guard let outPtr = outRaw.bindMemory(to: Int16.self).baseAddress else { return }
            gameData.withUnsafeBytes { gameRaw in
                micData.withUnsafeBytes { micRaw in
                    let gamePtr = gameRaw.bindMemory(to: Int16.self).baseAddress
                    let micPtr = micRaw.bindMemory(to: Int16.self).baseAddress
                    let totalSamples = Int(frameCount) * 2
                    let gameSampleCount = gameData.count / 2
                    let micSampleCount = micData.count / 2
                    for i in 0..<totalSamples {
                        let gameSample = (gamePtr != nil && i < gameSampleCount) ? gamePtr![i] : 0
                        let micSample = (micPtr != nil && i < micSampleCount) ? micPtr![i] : 0
                        let scaledMic = Int32((Double(micSample) * self.microphoneVolume).rounded())
                        let mixed = Int32(gameSample) + scaledMic
                        outPtr[i] = Int16(clamping: mixed)
                    }
                }
            }
        }
        return output
    }

    private func emitSampleBuffer(data: Data, frameCount: UInt32) {
        let presentationTime = CMTime(value: totalFramesEmitted, timescale: 48_000)
        totalFramesEmitted += Int64(frameCount)
        guard let sampleBuffer = Self.createAudioSampleBuffer(data: data, frameCount: frameCount, presentationTime: presentationTime) else { return }
        onMixedAudioBuffer?(sampleBuffer)
    }

    private static func createAudioSampleBuffer(data: Data, frameCount: UInt32, presentationTime: CMTime) -> CMSampleBuffer? {
        guard let formatDesc = formatDescription else { return nil }
        var blockBuffer: CMBlockBuffer?
        let byteCount = data.count
        let status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: nil,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr, let blockBuffer else { return nil }
        let replaceStatus = data.withUnsafeBytes { raw in
            guard let ptr = raw.baseAddress else { return kCMBlockBufferBadPointerParameterErr }
            return CMBlockBufferReplaceDataBytes(with: ptr, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: byteCount)
        }
        guard replaceStatus == noErr else { return nil }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 48_000),
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        let bufferStatus = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDesc,
            sampleCount: CMItemCount(frameCount),
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )
        guard bufferStatus == noErr else { return nil }
        return sampleBuffer
    }
}
