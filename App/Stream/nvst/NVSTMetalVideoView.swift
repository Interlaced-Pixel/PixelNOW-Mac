import AppKit
import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import Metal
import MetalKit
import QuartzCore
#if canImport(MetalFX)
import MetalFX
#endif

public enum NVSTMetalFXState: Equatable, Sendable {
    case disabled
    case unsupported(reason: String)
    case standby(input: CGSize, output: CGSize)
    case active(input: CGSize, output: CGSize)
    case fallback(reason: String)

    public var isActive: Bool {
        if case .active = self { return true }
        return false
    }

    public var description: String {
        switch self {
        case .disabled:
            return "Off"
        case .unsupported(let reason):
            return "Unsupported (\(reason))"
        case .standby(let input, _):
            return "Standby (1:1 Native \(Int(input.width))x\(Int(input.height)))"
        case .active(let input, let output):
            return "Active (\(Int(input.width))x\(Int(input.height)) → \(Int(output.width))x\(Int(output.height)))"
        case .fallback(let reason):
            return "Fallback (\(reason))"
        }
    }
}

public struct NvstRenderQueueCounters: Equatable, Sendable {
    public let queuedFrames: Int
    public let inFlightFrames: Int
    public let discardedFrames: UInt64
    public let repeatedSubmissions: UInt64
}

@objc(NVSTMetalFXUpscaler)
final class NVSTMetalFXUpscaler: NSObject {
    private let device: (any MTLDevice)?
    private var spatialScaler: AnyObject?
    private var inputWidth = 0
    private var inputHeight = 0
    private var outputWidth = 0
    private var outputHeight = 0
    private var inputPixelFormat: MTLPixelFormat = .invalid
    private var outputPixelFormat: MTLPixelFormat = .invalid
    private var disabledByCaptureScaler = false
    private let deviceSupportFailure: String?

    public static var isSupportedOnCurrentDevice: Bool {
        isDeviceSupported(MTLCreateSystemDefaultDevice())
    }

    public static func isDeviceSupported(_ device: (any MTLDevice)? = MTLCreateSystemDefaultDevice()) -> Bool {
        availabilityFailure(for: device) == nil
    }

    private static func availabilityFailure(for device: (any MTLDevice)?) -> String? {
#if canImport(MetalFX)
        guard let device else { return "Metal device unavailable" }
        if #available(macOS 13.0, *) {
            return MTLFXSpatialScalerDescriptor.supportsDevice(device)
                ? nil
                : "\(device.name) does not support MetalFX spatial scaling"
        }
        return "MetalFX requires macOS 13 or later"
#else
        return "MetalFX framework unavailable in this build"
#endif
    }

    init(device: (any MTLDevice)?) {
        self.device = device
        deviceSupportFailure = Self.availabilityFailure(for: device)
        super.init()
    }

    var unavailableReason: String? {
        if disabledByCaptureScaler { return "MetalFX disabled under Xcode Metal capture" }
        return deviceSupportFailure
    }

    var isAvailable: Bool {
        unavailableReason == nil
    }

    func encodeTexture(
        _ sourceTexture: (any MTLTexture)?,
        toTexture destinationTexture: (any MTLTexture)?,
        commandBuffer: (any MTLCommandBuffer)?,
        fallback: AutoreleasingUnsafeMutablePointer<NSString?>?
    ) -> Bool {
#if canImport(MetalFX)
        guard isAvailable, let device, let sourceTexture, let destinationTexture, let commandBuffer else {
            fallback?.pointee = "MetalFX unavailable"
            return false
        }
        if #available(macOS 13.0, *) {
            let dimensionsChanged = spatialScaler == nil ||
                inputWidth != sourceTexture.width ||
                inputHeight != sourceTexture.height ||
                outputWidth != destinationTexture.width ||
                outputHeight != destinationTexture.height ||
                inputPixelFormat != sourceTexture.pixelFormat ||
                outputPixelFormat != destinationTexture.pixelFormat
            if dimensionsChanged {
                let descriptor = MTLFXSpatialScalerDescriptor()
                descriptor.colorTextureFormat = sourceTexture.pixelFormat
                descriptor.outputTextureFormat = destinationTexture.pixelFormat
                descriptor.inputWidth = sourceTexture.width
                descriptor.inputHeight = sourceTexture.height
                descriptor.outputWidth = destinationTexture.width
                descriptor.outputHeight = destinationTexture.height
                descriptor.colorProcessingMode = .perceptual
                spatialScaler = descriptor.makeSpatialScaler(device: device) as AnyObject?
                inputWidth = sourceTexture.width
                inputHeight = sourceTexture.height
                outputWidth = destinationTexture.width
                outputHeight = destinationTexture.height
                inputPixelFormat = sourceTexture.pixelFormat
                outputPixelFormat = destinationTexture.pixelFormat
            }
            guard let scaler = spatialScaler as? MTLFXSpatialScaler else {
                fallback?.pointee = "MetalFX scaler creation failed"
                return false
            }
            let scalerClassName = String(describing: type(of: scaler as AnyObject))
            if scalerClassName.contains("CaptureMTLFXSpatialScaler") {
                disabledByCaptureScaler = true
                spatialScaler = nil
                inputWidth = 0
                inputHeight = 0
                outputWidth = 0
                outputHeight = 0
                inputPixelFormat = .invalid
                outputPixelFormat = .invalid
                fallback?.pointee = "MetalFX disabled under Xcode Metal capture"
                return false
            }
            guard sourceTexture.usage.isSuperset(of: scaler.colorTextureUsage) else {
                fallback?.pointee = "MetalFX source texture usage unsupported"
                return false
            }
            guard destinationTexture.usage.isSuperset(of: scaler.outputTextureUsage) else {
                fallback?.pointee = "MetalFX output texture usage unsupported"
                return false
            }
            scaler.colorTexture = sourceTexture
            scaler.outputTexture = destinationTexture
            scaler.inputContentWidth = sourceTexture.width
            scaler.inputContentHeight = sourceTexture.height
            scaler.encode(commandBuffer: commandBuffer)
            return true
        }
        fallback?.pointee = "MetalFX requires macOS 13"
        return false
#else
        fallback?.pointee = "MetalFX headers unavailable"
        return false
#endif
    }

}

private enum NVSTMetalFXOutputResolution {
    static let width = 3840
    static let height = 2160
}

final class NVSTPixelBufferHolder: @unchecked Sendable {
    fileprivate static let unpresentedFrameGracePeriod = DispatchTimeInterval.seconds(1)
    private enum QueueMode {
        case immediate, fixed, timestamp, adaptive, variableRefresh
    }
    private struct Entry {
        let buffer: CVPixelBuffer
        let time: CMTime
        let deadline: UInt64
        let frameIndex: UInt32
        var lifecycle: NvstVideoFrameLifecycle?
    }
    private let lock = NSLock()
    private var frames: [Entry] = []
    private var inFlight: [UInt64: NvstVideoFrameLifecycle?] = [:]
    private var nextTicket: UInt64 = 0
    private var presentationMode = PixelNOWVideoPresentationMode.balanced
    private var displayIntervalSeconds = 1 / 60.0
    private var variableRefreshSupported = false
    private var currentQueueMode: QueueMode?
    private var serverFrameIntervals: [Double] = []
    private var serverFrameIntervalSeconds = 1 / 60.0
    private var adaptiveDepth = 1
    private var adaptiveSamples = 0
    private var stableWindows = 0
    private var adjustmentWindows = 0
    private var minimumResidenceMicroseconds = Double.greatestFiniteMagnitude
    private var maximumGpuMicroseconds = 0.0
    private var maximumJitterMicroseconds = 0.0
    private var adaptiveSkip = false
    private var variableRefreshResidenceMilliseconds = 0.0
    private var lastRepeatedFrame: UInt32 = 0
    private var lateWindows = 0
    private var discardedFrames: UInt64 = 0
    private var repeatedSubmissions: UInt64 = 0

    var counters: NvstRenderQueueCounters {
        lock.lock()
        defer { lock.unlock() }
        return NvstRenderQueueCounters(queuedFrames: frames.filter { $0.lifecycle != nil }.count,
            inFlightFrames: inFlight.count, discardedFrames: discardedFrames,
            repeatedSubmissions: repeatedSubmissions)
    }

    func configure(mode: PixelNOWVideoPresentationMode) {
        lock.lock()
        if presentationMode != mode {
            presentationMode = mode
            resetAdaptiveLocked()
        }
        lock.unlock()
    }

    func configureDisplay(intervalSeconds: Double, variableRefreshSupported: Bool) {
        guard intervalSeconds.isFinite, intervalSeconds > 0 else { return }
        lock.lock()
        if self.variableRefreshSupported != variableRefreshSupported ||
            abs(displayIntervalSeconds - intervalSeconds) > 0.001 {
            resetAdaptiveLocked()
        }
        self.displayIntervalSeconds = intervalSeconds
        self.variableRefreshSupported = variableRefreshSupported
        lock.unlock()
    }

    private func resetAdaptiveLocked() {
        adaptiveDepth = 1
        adaptiveSamples = 0
        stableWindows = 0
        adjustmentWindows = 0
        minimumResidenceMicroseconds = .greatestFiniteMagnitude
        maximumGpuMicroseconds = 0
        maximumJitterMicroseconds = 0
        adaptiveSkip = false
        variableRefreshResidenceMilliseconds = 0
        serverFrameIntervals.removeAll()
        serverFrameIntervalSeconds = displayIntervalSeconds
    }

    private func queueModeLocked(for lifecycle: NvstVideoFrameLifecycle) -> QueueMode {
        let schedule = lifecycle.presentationSchedule
        guard presentationMode != .lowestLatency else { return .immediate }
        if lifecycle.unit.dynamicFrameRateLimitHonored { return .fixed }
        guard !schedule.pinnedQueue else { return .timestamp }
        if variableRefreshSupported { return .variableRefresh }
        let frameInterval = serverFrameIntervalSeconds
        guard frameInterval >= displayIntervalSeconds * 0.75,
              frameInterval <= displayIntervalSeconds * 1.5 else { return .immediate }
        return presentationMode == .balanced ? .adaptive : .timestamp
    }

    func minimumPresentDuration(for lifecycle: NvstVideoFrameLifecycle?) -> Double? {
        guard let lifecycle else { return nil }
        let schedule = lifecycle.presentationSchedule
        lock.lock()
        defer { lock.unlock() }
        guard queueModeLocked(for: lifecycle) == .variableRefresh else { return nil }
        let duration = schedule.variableRefreshDurationSeconds
        let excess = variableRefreshResidenceMilliseconds / 1000 - schedule.arrivalJitterSeconds
        return max(0, duration - min(max(0, excess) * 0.01, duration * 0.01))
    }

    func usesTimestampScheduling(for lifecycle: NvstVideoFrameLifecycle?) -> Bool {
        guard let lifecycle else { return false }
        lock.lock()
        defer { lock.unlock() }
        return queueModeLocked(for: lifecycle) == .timestamp
    }

    func noteGpuDuration(milliseconds: Double?, lifecycle: NvstVideoFrameLifecycle) {
        guard let milliseconds, milliseconds.isFinite, milliseconds >= 0 else { return }
        lock.lock()
        if queueModeLocked(for: lifecycle) == .adaptive {
            maximumGpuMicroseconds = max(maximumGpuMicroseconds, milliseconds * 1000)
        }
        lock.unlock()
    }

    func notePresented(_ lifecycle: NvstVideoFrameLifecycle) {
        guard let residence = lifecycle.presentationQueueDurationMicroseconds else { return }
        lock.lock()
        defer { lock.unlock() }
        switch queueModeLocked(for: lifecycle) {
        case .variableRefresh:
            variableRefreshResidenceMilliseconds += (Double(residence) / 1000 -
                variableRefreshResidenceMilliseconds) * (2 / 61)
        case .adaptive:
            if residence > 0 {
                minimumResidenceMicroseconds = min(minimumResidenceMicroseconds, Double(residence))
            }
            adaptiveSamples += 1
            guard adaptiveSamples >= 181 else { return }
            let target = Double(adaptiveDepth + 1) * serverFrameIntervalSeconds * 1_000_000 + 2000
            if minimumResidenceMicroseconds - maximumGpuMicroseconds > target, stableWindows >= 4 {
                adaptiveSkip = true
                stableWindows = 0
            } else {
                stableWindows += 1
            }
            if adjustmentWindows < 4 {
                adjustmentWindows += 1
            } else {
                switch adaptiveDepth {
                case 0: if maximumJitterMicroseconds > 24_000 { adaptiveDepth = 1 }
                case 1:
                    if maximumJitterMicroseconds < 16_000 { adaptiveDepth = 0 }
                    else if maximumJitterMicroseconds > 40_000 { adaptiveDepth = 2 }
                default: if maximumJitterMicroseconds < 32_000 { adaptiveDepth = 1 }
                }
                maximumJitterMicroseconds = 0
                adjustmentWindows = 0
            }
            adaptiveSamples = 0
            minimumResidenceMicroseconds = .greatestFiniteMagnitude
            maximumGpuMicroseconds = 0
        case .fixed, .timestamp, .immediate: break
        }
    }

    func set(_ pixelBuffer: CVPixelBuffer, time: CMTime, lifecycle: NvstVideoFrameLifecycle) {
        lock.lock()
        var discarded: [NvstVideoFrameLifecycle] = []
        let schedule = lifecycle.presentationSchedule
        if schedule.frameDurationSeconds.isFinite, schedule.frameDurationSeconds > 0 {
            serverFrameIntervals.append(schedule.frameDurationSeconds)
            if serverFrameIntervals.count > 11 { serverFrameIntervals.removeFirst() }
            let sorted = serverFrameIntervals.sorted()
            serverFrameIntervalSeconds = sorted[sorted.count / 2]
        }
        let mode = queueModeLocked(for: lifecycle)
        if let previous = currentQueueMode, previous != mode {
            discarded.append(contentsOf: frames.compactMap(\.lifecycle))
            frames.removeAll()
        }
        currentQueueMode = mode
        frames.removeAll { $0.lifecycle == nil }
        var retainedFrames = lifecycle.maximumQueuedFrames - 1
        switch mode {
        case .immediate: retainedFrames = 0
        case .variableRefresh:
            retainedFrames = schedule.variableRefreshDurationSeconds >= displayIntervalSeconds * 1.05 ? 1 : 0
        case .adaptive:
            retainedFrames = min(retainedFrames, 3)
            maximumJitterMicroseconds = max(maximumJitterMicroseconds, schedule.arrivalJitterSeconds * 1_000_000)
        case .fixed, .timestamp: break
        }
        while frames.count > retainedFrames {
            if let context = frames.removeFirst().lifecycle { discarded.append(context) }
        }
        if mode == .fixed, let capture = lifecycle.unit.captureTimestampMicroseconds,
           let limit = lifecycle.maximumPresentationCaptureSpanMicroseconds {
            while frames.count > 1,
                  let previous = frames.first?.lifecycle?.unit.captureTimestampMicroseconds,
                  capture > previous, UInt64(capture - previous) > limit {
                if let context = frames.removeFirst().lifecycle { discarded.append(context) }
            }
        }
        frames.append(Entry(buffer: pixelBuffer, time: time,
            deadline: lifecycle.presentationDeadlineNanoseconds,
            frameIndex: lifecycle.unit.frameIndex, lifecycle: lifecycle))
        while frames.count > lifecycle.maximumQueuedFrames {
            if let context = frames.removeFirst().lifecycle { discarded.append(context) }
        }
        discardedFrames += UInt64(discarded.count)
        lock.unlock()
        for context in discarded { context.discard(decoded: true) }
    }

    func get() -> (CVPixelBuffer, CMTime, NvstVideoFrameLifecycle?, UInt64)? {
        lock.lock()
        guard canSubmitFrameLocked() else { lock.unlock(); return nil }
        let now = DispatchTime.now().uptimeNanoseconds
        let mode = frames.compactMap(\.lifecycle).first.map { queueModeLocked(for: $0) }
        var discarded: [NvstVideoFrameLifecycle] = []
        if mode == .adaptive {
            let retained = adaptiveSkip ? 1 : max(1, adaptiveDepth)
            adaptiveSkip = false
            while frames.count > retained {
                if let context = frames.removeFirst().lifecycle { discarded.append(context) }
            }
        }
        var selected = frames.count - 1
        var candidate: Int?
        var late = false
        for index in frames.indices where frames[index].lifecycle != nil {
            if mode != .timestamp { selected = index; break }
            guard let previous = candidate else { candidate = index; selected = index; continue }
            if frames[index].deadline >= now { selected = previous; break }
            if frames[index].frameIndex &- lastRepeatedFrame >= 61 {
                if lateWindows >= 10 { candidate = index } else { late = true }
            } else {
                selected = previous
                break
            }
            selected = candidate ?? index
        }
        if frames.count == 1, frames[0].lifecycle == nil { lastRepeatedFrame = frames[0].frameIndex }
        lateWindows = late ? lateWindows + 1 : 0
        let entry = frames[selected]
        if entry.lifecycle == nil { repeatedSubmissions &+= 1 }
        frames[selected].lifecycle = nil
        var selectedIndex = selected
        while frames.count > 1,
              selectedIndex >= 0 || (mode == .timestamp && (frames[0].lifecycle == nil || frames[0].deadline <= now)) {
            if let context = frames.removeFirst().lifecycle { discarded.append(context) }
            selectedIndex -= 1
        }
        nextTicket &+= 1
        let ticket = nextTicket
        inFlight.updateValue(entry.lifecycle, forKey: ticket)
        discardedFrames += UInt64(discarded.count)
        lock.unlock()
        for context in discarded { context.discard(decoded: true) }
        return (entry.buffer, entry.time, entry.lifecycle, ticket)
    }

    var canSubmitFrame: Bool {
        lock.lock()
        defer { lock.unlock() }
        return canSubmitFrameLocked()
    }

    var nextPixelFormat: OSType? {
        lock.lock()
        defer { lock.unlock() }
        return frames.first.map { CVPixelBufferGetPixelFormatType($0.buffer) }
    }

    private func canSubmitFrameLocked() -> Bool {
        guard !frames.isEmpty, inFlight.count < 2 else { return false }
        return frames.contains(where: { $0.lifecycle != nil }) || !inFlight.values.contains(where: { $0 != nil })
    }

    func finish(_ ticket: UInt64) {
        lock.lock()
        if let context = inFlight[ticket], context == nil || context?.isTerminal == true {
            inFlight.removeValue(forKey: ticket)
        }
        lock.unlock()
    }

    func retireUnpresentedFrame(_ ticket: UInt64, lifecycle: NvstVideoFrameLifecycle) {
        lifecycle.discard(decoded: true)
        finish(ticket)
    }

    func clear() {
        lock.lock()
        let discarded = frames.compactMap(\.lifecycle) + inFlight.values.compactMap { $0 }
        frames.removeAll()
        inFlight.removeAll()
        currentQueueMode = nil
        resetAdaptiveLocked()
        lastRepeatedFrame = 0
        lateWindows = 0
        discardedFrames += UInt64(discarded.filter { !$0.isTerminal }.count)
        lock.unlock()
        for context in discarded { context.discard(decoded: true) }
    }
}

@MainActor
public final class NVSTMetalVideoView: NSView, MTKViewDelegate {
    private static let tenBitPixelFormats: Set<OSType> = [
        kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
        kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
        kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
        kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange,
    ]
    private static let sRGBColorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    private static let extendedLinearColorSpace = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020) ?? CGColorSpaceCreateDeviceRGB()

    private let metalView: MTKView
    private let targetFps: Int
    private var displayLink: CADisplayLink?
    private var displayLinkNotificationTokens: [(NotificationCenter, NSObjectProtocol)] = []
    private var lastDisplayIntervalMicroseconds: UInt32 = 0
    private var commandQueue: (any MTLCommandQueue)?
    private var ciContext: CIContext?
    private let upscaler: NVSTMetalFXUpscaler
    private let bufferHolder = NVSTPixelBufferHolder()
    public nonisolated var renderQueueCounters: NvstRenderQueueCounters { bufferHolder.counters }
    private var drawnFrames = 0
    private var uniqueFramesDrawn = 0
    private var lastDrawLogTime = Date()
    private var lastDrawnTime: CMTime?
    private var colorSpace = NVSTMetalVideoView.sRGBColorSpace
    public var onFramePresented: (@Sendable (NvstVideoFrameLifecycle, UInt64) -> Void)?
    public var onDisplayTiming: ((UInt32) -> Void)?
    public var onPresentationFormat: ((OSType, String, Bool) -> Void)?

    private var intermediateSourceTexture: (any MTLTexture)?
    private var intermediateUpscaledTexture: (any MTLTexture)?

    public var isMetalFXEnabled = false {
        didSet {
            guard isMetalFXEnabled != oldValue else { return }
            if !isMetalFXEnabled {
                updateMetalFXState(.disabled)
            }
            // Transitioning to enabled: active/standby state is resolved on the
            // next draw(in:) invocation so diagnostics update with real dimensions.
        }
    }
    public private(set) var metalFXState: NVSTMetalFXState = .disabled
    public var onMetalFXStateChanged: ((NVSTMetalFXState) -> Void)?
    public var enhancedFrameSink: (@Sendable (CVPixelBuffer, CMTime) -> Void)?
    private var enhancedPixelBufferPool: CVPixelBufferPool?
    private var enhancedPixelBufferPoolWidth = 0
    private var enhancedPixelBufferPoolHeight = 0
    private var enhancedPixelBufferPoolFormat: OSType = 0

    public init(frame frameRect: NSRect, targetFps: Int32) {
        self.targetFps = min(max(Int(targetFps), 30), 240)
        let device = MTLCreateSystemDefaultDevice()
        metalView = MTKView(frame: frameRect, device: device)
        upscaler = NVSTMetalFXUpscaler(device: device)
        super.init(frame: frameRect)

        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        metalView.frame = bounds
        metalView.autoresizingMask = [.width, .height]
        metalView.framebufferOnly = false
        metalView.colorPixelFormat = .bgra8Unorm
        metalView.depthStencilPixelFormat = .invalid
        metalView.sampleCount = 1
        metalView.autoResizeDrawable = false
        metalView.preferredFramesPerSecond = self.targetFps
        metalView.isPaused = true
        metalView.enableSetNeedsDisplay = false
        metalView.delegate = self
        metalView.layerContentsPlacement = .scaleProportionallyToFit

        if let metalLayer = metalView.layer as? CAMetalLayer {
            metalLayer.presentsWithTransaction = false
            metalLayer.allowsNextDrawableTimeout = true
            if #available(macOS 10.13, *) {
                metalLayer.maximumDrawableCount = 2
            }
        }

        addSubview(metalView)

        if let device {
            commandQueue = device.makeCommandQueue()
            ciContext = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    public override func layout() {
        super.layout()
        metalView.frame = bounds
        updateDrawableSize()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installDisplayLinkNotifications()
        restartDisplayLink()
        updateDrawableSize()
    }

    private func restartDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
        guard let window else { return }
        let link = displayLink(target: self, selector: #selector(displayTick(_:)))
        configureDisplayLink(link, for: window.screen)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func installDisplayLinkNotifications() {
        removeDisplayLinkNotifications()
        guard let window else { return }
        let refresh: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshDisplayLinkForCurrentWindow() }
        }
        let applicationCenter = NotificationCenter.default
        for name in [NSWindow.didChangeScreenNotification, NSWindow.didChangeBackingPropertiesNotification,
                     NSWindow.didBecomeKeyNotification] {
            displayLinkNotificationTokens.append((applicationCenter,
                applicationCenter.addObserver(forName: name, object: window, queue: .main, using: refresh)))
        }
        displayLinkNotificationTokens.append((applicationCenter,
            applicationCenter.addObserver(forName: NSApplication.didBecomeActiveNotification,
                object: NSApplication.shared, queue: .main, using: refresh)))
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        displayLinkNotificationTokens.append((workspaceCenter,
            workspaceCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                object: nil, queue: .main, using: refresh)))
    }

    private func removeDisplayLinkNotifications() {
        for (center, token) in displayLinkNotificationTokens {
            center.removeObserver(token)
        }
        displayLinkNotificationTokens.removeAll()
    }

    private func refreshDisplayLinkForCurrentWindow() {
        guard window != nil else { return }
        restartDisplayLink()
        updateDrawableSize()
        metalView.draw()
    }

    private func configureDisplayLink(_ link: CADisplayLink, for screen: NSScreen?) {
        let screenMaximum = max(1, screen?.maximumFramesPerSecond ?? targetFps)
        let frameRate = Float(min(targetFps, screenMaximum))
        let currentRange = link.preferredFrameRateRange
        guard currentRange.minimum != frameRate || currentRange.maximum != frameRate
            || currentRange.preferred != frameRate else { return }
        link.preferredFrameRateRange = CAFrameRateRange(
            minimum: frameRate,
            maximum: frameRate,
            preferred: frameRate
        )
    }

    @objc private func displayTick(_ link: CADisplayLink) {
        configureDisplayLink(link, for: window?.screen)
        let duration = link.targetTimestamp - link.timestamp
        if duration.isFinite, duration > 0 {
            let screen = window?.screen
            let supportsVariableRefresh = screen.map { $0.minimumRefreshInterval < $0.maximumRefreshInterval } ?? false
            bufferHolder.configureDisplay(intervalSeconds: duration, variableRefreshSupported: supportsVariableRefresh)
            let microseconds = UInt32(min(Double(UInt32.max), duration * 1_000_000))
            if microseconds != lastDisplayIntervalMicroseconds {
                lastDisplayIntervalMicroseconds = microseconds
                onDisplayTiming?(microseconds)
            }
        }
        metalView.draw()
    }

    private func updateDrawableSize() {
        guard let window, bounds.width >= 1, bounds.height >= 1 else { return }
        let scale = window.backingScaleFactor
        let width = max(1, Int(bounds.width * scale))
        let height = max(1, Int(bounds.height * scale))
        metalView.drawableSize = CGSize(width: width, height: height)
    }

    public nonisolated func renderPixelBuffer(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime, lifecycle: NvstVideoFrameLifecycle) {
        lifecycle.noteRenderPresent(at: DispatchTime.now().uptimeNanoseconds)
        bufferHolder.set(pixelBuffer, time: presentationTime, lifecycle: lifecycle)
    }

    public func setSize(_ size: CGSize) {
        guard size.width >= 1, size.height >= 1 else { return }
        updateDrawableSize()
    }

    public func configurePresentation(mode: PixelNOWVideoPresentationMode) {
        bufferHolder.configure(mode: mode)
    }

    public func detach() {
        displayLink?.invalidate()
        displayLink = nil
        removeDisplayLinkNotifications()
        bufferHolder.clear()
        metalView.isPaused = true
        metalView.delegate = nil
        intermediateSourceTexture = nil
        intermediateUpscaledTexture = nil
        enhancedPixelBufferPool = nil
        enhancedFrameSink = nil
        onMetalFXStateChanged = nil
        onFramePresented = nil
        onDisplayTiming = nil
        removeFromSuperview()
    }

    private func updateMetalFXState(_ newState: NVSTMetalFXState) {
        guard metalFXState != newState else { return }
        metalFXState = newState
        onMetalFXStateChanged?(newState)
    }

    private func makeEnhancedPixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        guard width > 0, height > 0 else { return nil }
        let format = metalView.colorPixelFormat == .rgba16Float ? kCVPixelFormatType_64RGBAHalf : kCVPixelFormatType_32BGRA
        if enhancedPixelBufferPool == nil || enhancedPixelBufferPoolWidth != width || enhancedPixelBufferPoolHeight != height || enhancedPixelBufferPoolFormat != format {
            let poolAttributes: [String: Any] = [
                kCVPixelBufferPoolMinimumBufferCountKey as String: 2
            ]
            let pixelBufferAttributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: format,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
            var pool: CVPixelBufferPool?
            guard CVPixelBufferPoolCreate(kCFAllocatorDefault, poolAttributes as CFDictionary, pixelBufferAttributes as CFDictionary, &pool) == kCVReturnSuccess else {
                return nil
            }
            enhancedPixelBufferPool = pool
            enhancedPixelBufferPoolWidth = width
            enhancedPixelBufferPoolHeight = height
            enhancedPixelBufferPoolFormat = format
        }
        guard let pool = enhancedPixelBufferPool else { return nil }
        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer) == kCVReturnSuccess else {
            return nil
        }
        if let pixelBuffer { CVBufferSetAttachment(pixelBuffer, kCVImageBufferCGColorSpaceKey, colorSpace, .shouldPropagate) }
        return pixelBuffer
    }

    private func reusableTexture(
        _ storage: inout (any MTLTexture)?,
        width: Int,
        height: Int,
        pixelFormat: MTLPixelFormat,
        usage: MTLTextureUsage,
        label: String
    ) -> (any MTLTexture)? {
        if let existing = storage,
           existing.width == width,
           existing.height == height,
           existing.pixelFormat == pixelFormat,
           existing.usage.isSuperset(of: usage) {
            return existing
        }
        guard let device = metalView.device, width > 0, height > 0 else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = usage
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        texture.label = label
        storage = texture
        return texture
    }

    private func copyTexture(
        from source: any MTLTexture,
        to destination: any MTLTexture,
        commandBuffer: any MTLCommandBuffer
    ) {
        guard let blit = commandBuffer.makeBlitCommandEncoder() else { return }
        let width = min(source.width, destination.width)
        let height = min(source.height, destination.height)
        blit.copy(
            from: source,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: width, height: height, depth: 1),
            to: destination,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        blit.endEncoding()
    }

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
    }

    public func draw(in view: MTKView) {
        guard bufferHolder.canSubmitFrame else { return }
        let extendedRange = metalView.layer?.wantsExtendedDynamicRangeContent == true
        let highPrecision = extendedRange || bufferHolder.nextPixelFormat.map(Self.tenBitPixelFormats.contains) == true
        let desiredFormat: MTLPixelFormat = highPrecision ? .rgba16Float : .bgra8Unorm
        if metalView.colorPixelFormat != desiredFormat { metalView.colorPixelFormat = desiredFormat }
        colorSpace = extendedRange ? Self.extendedLinearColorSpace : Self.sRGBColorSpace
        (metalView.layer as? CAMetalLayer)?.colorspace = colorSpace
        guard bufferHolder.canSubmitFrame,
              let currentDrawable = metalView.currentDrawable,
              let commandBuffer = commandQueue?.makeCommandBuffer(),
              let ciContext, let (pixelBuffer, time, lifecycle, ticket) = bufferHolder.get() else {
            return
        }

        lifecycle?.noteRenderStarted(at: DispatchTime.now().uptimeNanoseconds)
        onPresentationFormat?(CVPixelBufferGetPixelFormatType(pixelBuffer), highPrecision ? "RGBA16Float" : "BGRA8Unorm", extendedRange)
        let holder = bufferHolder
        let presented = onFramePresented
        if let lifecycle {
            currentDrawable.addPresentedHandler { drawable in
                guard drawable.presentedTime.isFinite, drawable.presentedTime > 0 else {
                    lifecycle.discard(decoded: true)
                    holder.finish(ticket)
                    return
                }
                let timestamp = UInt64(drawable.presentedTime * 1_000_000_000)
                if lifecycle.notePresented(at: timestamp) {
                    holder.notePresented(lifecycle)
                    presented?(lifecycle, timestamp)
                }
                holder.finish(ticket)
            }
            commandBuffer.addCompletedHandler { buffer in
                let duration = buffer.gpuEndTime > buffer.gpuStartTime
                    ? (buffer.gpuEndTime - buffer.gpuStartTime) * 1000 : nil
                let completedAt = buffer.gpuEndTime.isFinite && buffer.gpuEndTime > 0
                    ? UInt64(buffer.gpuEndTime * 1_000_000_000) : DispatchTime.now().uptimeNanoseconds
                let succeeded = buffer.status == .completed
                lifecycle.noteGpuCompleted(at: completedAt,
                    durationMilliseconds: duration, success: succeeded)
                holder.noteGpuDuration(milliseconds: duration, lifecycle: lifecycle)
                holder.finish(ticket)
                if succeeded, !lifecycle.isTerminal {
                    DispatchQueue.global(qos: .utility).asyncAfter(
                        deadline: .now() + NVSTPixelBufferHolder.unpresentedFrameGracePeriod
                    ) {
                        holder.retireUnpresentedFrame(ticket, lifecycle: lifecycle)
                    }
                }
            }
        } else {
            commandBuffer.addCompletedHandler { _ in holder.finish(ticket) }
        }
        drawnFrames += 1
        if lastDrawnTime != time {
            uniqueFramesDrawn += 1
            lastDrawnTime = time
        }
        let now = Date()
        let elapsed = now.timeIntervalSince(lastDrawLogTime)
        if elapsed >= 5.0 {
            let fps = Double(drawnFrames) / elapsed
            let uniqueFps = Double(uniqueFramesDrawn) / elapsed
            NSLog("NVST Metal submissions/s: %.1f, unique submitted buffers/s: %.1f", fps, uniqueFps)
            drawnFrames = 0
            uniqueFramesDrawn = 0
            lastDrawLogTime = now
        }

        let sourceImage = CIImage(cvPixelBuffer: pixelBuffer)
        let sourceWidth = CVPixelBufferGetWidth(pixelBuffer)
        let sourceHeight = CVPixelBufferGetHeight(pixelBuffer)
        let drawableWidth = currentDrawable.texture.width
        let drawableHeight = currentDrawable.texture.height

        guard sourceWidth > 0, sourceHeight > 0, drawableWidth > 0, drawableHeight > 0 else {
            lifecycle?.discard(decoded: true)
            holder.finish(ticket)
            return
        }

        let targetWidth = NVSTMetalFXOutputResolution.width
        let targetHeight = NVSTMetalFXOutputResolution.height
        let isScalingUp = sourceWidth <= targetWidth && sourceHeight <= targetHeight
            && (sourceWidth < targetWidth || sourceHeight < targetHeight)
        let shouldUpscale = isMetalFXEnabled && upscaler.isAvailable && isScalingUp
        let usesDrawableForUpscaling = shouldUpscale && drawableWidth == targetWidth && drawableHeight == targetHeight
        let upscaledTexture: (any MTLTexture)?
        if shouldUpscale {
            upscaledTexture = usesDrawableForUpscaling
                ? currentDrawable.texture
                : reusableTexture(
                    &intermediateUpscaledTexture,
                    width: targetWidth,
                    height: targetHeight,
                    pixelFormat: desiredFormat,
                    usage: [.shaderRead, .shaderWrite, .renderTarget],
                    label: "NVSTMetalVideoView 4K Output"
                )
        } else {
            upscaledTexture = nil
        }

        if shouldUpscale,
           let sourceTexture = reusableTexture(
               &intermediateSourceTexture,
               width: sourceWidth,
               height: sourceHeight,
               pixelFormat: desiredFormat,
               usage: [.shaderRead, .shaderWrite, .renderTarget],
               label: "NVSTMetalVideoView Source"
           ),
           let outputTexture = upscaledTexture,
           outputTexture.pixelFormat == desiredFormat {
            let flippedImage = sourceImage
                .transformed(by: CGAffineTransform(scaleX: 1, y: -1))
                .transformed(by: CGAffineTransform(translationX: 0, y: CGFloat(sourceHeight)))
            ciContext.render(
                flippedImage,
                to: sourceTexture,
                commandBuffer: commandBuffer,
                bounds: CGRect(x: 0, y: 0, width: sourceWidth, height: sourceHeight),
                colorSpace: colorSpace
            )
            var fallback: NSString?
            if upscaler.encodeTexture(sourceTexture, toTexture: outputTexture, commandBuffer: commandBuffer, fallback: &fallback) {
                if let enhancedSink = enhancedFrameSink,
                   let device = metalView.device,
                   let enhancedBuffer = makeEnhancedPixelBuffer(width: targetWidth, height: targetHeight),
                   let ioSurface = CVPixelBufferGetIOSurface(enhancedBuffer) {
                    let textureDesc = MTLTextureDescriptor.texture2DDescriptor(
                        pixelFormat: desiredFormat,
                        width: targetWidth,
                        height: targetHeight,
                        mipmapped: false
                    )
                    textureDesc.usage = [.shaderRead, .shaderWrite, .renderTarget]
                    if let ioTexture = device.makeTexture(descriptor: textureDesc, iosurface: ioSurface.takeUnretainedValue(), plane: 0) {
                        copyTexture(from: outputTexture, to: ioTexture, commandBuffer: commandBuffer)
                        final class SendableBufferHolder: @unchecked Sendable {
                            let buffer: CVPixelBuffer
                            init(_ buffer: CVPixelBuffer) { self.buffer = buffer }
                        }
                        let holder = SendableBufferHolder(enhancedBuffer)
                        commandBuffer.addCompletedHandler { _ in
                            enhancedSink(holder.buffer, time)
                        }
                    }
                }

                updateMetalFXState(.active(
                    input: CGSize(width: sourceWidth, height: sourceHeight),
                    output: CGSize(width: targetWidth, height: targetHeight)
                ))

                if !usesDrawableForUpscaling {
                    guard let upscaledImage = CIImage(mtlTexture: outputTexture, options: [.colorSpace: colorSpace]) else {
                        updateMetalFXState(.fallback(reason: "4K output texture could not be displayed"))
                        let fallbackImage = sourceImage.transformed(by: CGAffineTransform(
                            scaleX: CGFloat(drawableWidth) / CGFloat(sourceWidth),
                            y: CGFloat(drawableHeight) / CGFloat(sourceHeight)
                        ))
                        ciContext.render(
                            fallbackImage,
                            to: currentDrawable.texture,
                            commandBuffer: commandBuffer,
                            bounds: CGRect(x: 0, y: 0, width: drawableWidth, height: drawableHeight),
                            colorSpace: colorSpace
                        )
                        present(currentDrawable, with: commandBuffer, lifecycle: lifecycle)
                        commandBuffer.commit()
                        return
                    }
                    let displayedImage = upscaledImage.transformed(by: CGAffineTransform(
                        scaleX: CGFloat(drawableWidth) / CGFloat(targetWidth),
                        y: CGFloat(drawableHeight) / CGFloat(targetHeight)
                    ))
                    ciContext.render(
                        displayedImage,
                        to: currentDrawable.texture,
                        commandBuffer: commandBuffer,
                        bounds: CGRect(x: 0, y: 0, width: drawableWidth, height: drawableHeight),
                        colorSpace: colorSpace
                    )
                }

                present(currentDrawable, with: commandBuffer, lifecycle: lifecycle)
                commandBuffer.commit()
                return
            } else {
                let reason = (fallback as? String) ?? "MetalFX encode failed"
                updateMetalFXState(.fallback(reason: reason))
            }
        } else {
            if !isMetalFXEnabled {
                updateMetalFXState(.disabled)
            } else if !upscaler.isAvailable {
                updateMetalFXState(.unsupported(reason: upscaler.unavailableReason ?? "MetalFX unavailable"))
            } else if isScalingUp {
                updateMetalFXState(.fallback(reason: "4K MetalFX output texture unavailable"))
            } else if sourceWidth == targetWidth && sourceHeight == targetHeight {
                updateMetalFXState(.standby(
                    input: CGSize(width: sourceWidth, height: sourceHeight),
                    output: CGSize(width: targetWidth, height: targetHeight)
                ))
            } else {
                updateMetalFXState(.fallback(reason: "Source resolution exceeds 4K target"))
            }
        }

        let renderBounds = CGRect(x: 0, y: 0, width: drawableWidth, height: drawableHeight)
        let scaleX = CGFloat(drawableWidth) / CGFloat(sourceWidth)
        let scaleY = CGFloat(drawableHeight) / CGFloat(sourceHeight)
        let scaledImage = (scaleX == 1.0 && scaleY == 1.0)
            ? sourceImage
            : sourceImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        ciContext.render(scaledImage, to: currentDrawable.texture, commandBuffer: commandBuffer, bounds: renderBounds, colorSpace: colorSpace)
        present(currentDrawable, with: commandBuffer, lifecycle: lifecycle)
        commandBuffer.commit()
    }

    private func present(_ drawable: any CAMetalDrawable, with commandBuffer: any MTLCommandBuffer,
                         lifecycle: NvstVideoFrameLifecycle?) {
        if let duration = bufferHolder.minimumPresentDuration(for: lifecycle) {
            commandBuffer.present(drawable, afterMinimumDuration: duration)
        } else if bufferHolder.usesTimestampScheduling(for: lifecycle), let lifecycle {
            commandBuffer.present(drawable, atTime: Double(lifecycle.presentationDeadlineNanoseconds) / 1_000_000_000)
        } else {
            commandBuffer.present(drawable)
        }
    }

}
