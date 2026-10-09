import AppKit
import CoreImage
import CoreMedia
import CoreVideo
import Foundation

public enum PixelNOWVideoPresentationMode: Int, Sendable {
    case balanced = 0
    case smooth = 1
    case lowestLatency = 2

    public var label: String {
        switch self {
        case .balanced: "balanced"
        case .smooth: "smooth"
        case .lowestLatency: "lowest latency"
        }
    }

    public var djbConfiguration: NvstClientDJBConfig {
        switch self {
        case .balanced: NvstClientDJBConfig()
        case .smooth: NvstClientDJBConfig(minimumDepthMicroseconds: 32_000,
            maximumDepthMicroseconds: 32_000, pinned: true)
        case .lowestLatency: NvstClientDJBConfig(mode: .fixed,
            minimumDepthMicroseconds: 0, maximumDepthMicroseconds: 0)
        }
    }
}

public struct PixelNOWVideoRenderDiagnosticsSnapshot: Equatable, Sendable {
    public var pixelFormat = ""
    public var outputFormat = ""
    public var renderPath = ""
    public var activeTier = ""
    public var fallback = ""
    public var isHDR = false
    public var frameIntervalMs = -1.0
    public var maxFrameIntervalMs = -1.0
    public var framesReceived: UInt64 = 0
    public var framesDrawn: UInt64 = 0
    public var presentationMode = ""
    public var presentLatencyMs = -1.0
    public var presentLatencyMaxMs = -1.0
    public var presentJitterMs = -1.0
    public var contentLeft = 0.0
    public var contentRight = 1.0
    public var presentationSamples = 0
    public var intervalP50Ms = -1.0
    public var intervalP95Ms = -1.0
    public var intervalP99Ms = -1.0
    public var latencyP50Ms = -1.0
    public var latencyP95Ms = -1.0
    public var latencyP99Ms = -1.0
    public var queueP50Ms = -1.0
    public var queueP95Ms = -1.0
    public var queueP99Ms = -1.0
    public var queuedFrames = 0
    public var inFlightFrames = 0
    public var discardedFrames: UInt64 = 0
    public var repeatedSubmissions: UInt64 = 0

    public init() {}
}

@MainActor
public final class NVSTCoreVideoRenderer {
    private let videoView: NVSTMetalVideoView
    private let sink: NVSTCoreVideoSink
    private var isMetalFXConfiguredByUser: Bool = false
    private var currentPresentationMode: PixelNOWVideoPresentationMode = .balanced

    public final class NVSTCoreVideoSink: @unchecked Sendable {
        private weak var videoView: NVSTMetalVideoView?
        let lock = NSLock()
        private var lastSize = CGSize.zero
        private var renderedFrames: UInt64 = 0
        private var previousPresentation: UInt64?
        private var presentationJitter = 0.0
        private var intervalSamples: [Double] = []
        private var latencySamples: [Double] = []
        private var queueSamples: [Double] = []
        private var lastPresentationLogAt: UInt64?
        private var lastPresentationLogFrames: UInt64 = 0
        private var latestRenderDiagnostics = PixelNOWVideoRenderDiagnosticsSnapshot()

        private let contentDetector = PixelNOWPillarboxDetector()

        private var latestPixelBuffer: CVPixelBuffer?
        private let snapshotTransfer = PixelNOWPixelBufferTransfer()

        init(videoView: NVSTMetalVideoView) {
            self.videoView = videoView
        }

        public var renderedFrameCount: UInt64 { lock.lock(); defer { lock.unlock() }; return renderedFrames }

        var renderDiagnostics: PixelNOWVideoRenderDiagnosticsSnapshot {
            lock.lock()
            defer { lock.unlock() }
            var snapshot = latestRenderDiagnostics
            snapshot.contentLeft = contentDetector.contentRect.left
            snapshot.contentRight = contentDetector.contentRect.right
            snapshot.presentationSamples = latencySamples.count
            (snapshot.intervalP50Ms, snapshot.intervalP95Ms, snapshot.intervalP99Ms) = Self.percentiles(intervalSamples)
            (snapshot.latencyP50Ms, snapshot.latencyP95Ms, snapshot.latencyP99Ms) = Self.percentiles(latencySamples)
            (snapshot.queueP50Ms, snapshot.queueP95Ms, snapshot.queueP99Ms) = Self.percentiles(queueSamples)
            if let queue = videoView?.renderQueueCounters {
                snapshot.queuedFrames = queue.queuedFrames
                snapshot.inFlightFrames = queue.inFlightFrames
                snapshot.discardedFrames = queue.discardedFrames
                snapshot.repeatedSubmissions = queue.repeatedSubmissions
            }
            return snapshot
        }

        private static func percentiles(_ values: [Double]) -> (Double, Double, Double) {
            guard !values.isEmpty else { return (-1, -1, -1) }
            let sorted = values.sorted()
            let value: (Double) -> Double = { fraction in
                sorted[max(0, min(sorted.count - 1, Int(ceil(Double(sorted.count) * fraction)) - 1))]
            }
            return (value(0.5), value(0.95), value(0.99))
        }

        private static func append(_ value: Double, to samples: inout [Double]) {
            samples.append(value)
            if samples.count > 1200 { samples.removeFirst() }
        }

        func writeLatestFrameJPEG(to url: URL) -> CGSize? {
            lock.lock()
            let buffer = latestPixelBuffer
            lock.unlock()
            guard let buffer,
                  let nv12 = snapshotTransfer.convert(buffer, to: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) else { return nil }
            let image = CIImage(cvPixelBuffer: nv12)
            let context = CIContext(options: [.cacheIntermediates: false])
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
            guard let data = context.jpegRepresentation(of: image, colorSpace: colorSpace, options: [:]) else { return nil }
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                return nil
            }
            return image.extent.size
        }

        func noteRenderDiagnostics(_ snapshot: PixelNOWVideoRenderDiagnosticsSnapshot) {
            lock.lock()
            latestRenderDiagnostics = snapshot
            lock.unlock()
        }

        func setPresentationMode(_ mode: PixelNOWVideoPresentationMode) {
            lock.lock()
            latestRenderDiagnostics.presentationMode = mode.label
            lock.unlock()
        }

        func notePresentation(lifecycle: NvstVideoFrameLifecycle, presentedAt: UInt64) {
            lock.lock()
            defer { lock.unlock() }
            renderedFrames &+= 1
            latestRenderDiagnostics.framesDrawn = renderedFrames
            if let previousPresentation, presentedAt >= previousPresentation {
                let interval = Double(presentedAt - previousPresentation) / 1_000_000
                Self.append(interval, to: &intervalSamples)
                if latestRenderDiagnostics.frameIntervalMs >= 0 {
                    presentationJitter += (abs(interval - latestRenderDiagnostics.frameIntervalMs) - presentationJitter) / 16
                }
                latestRenderDiagnostics.frameIntervalMs = interval
                latestRenderDiagnostics.maxFrameIntervalMs = max(latestRenderDiagnostics.maxFrameIntervalMs, interval)
                latestRenderDiagnostics.presentJitterMs = presentationJitter
            }
            previousPresentation = presentedAt
            let receivedAt = lifecycle.unit.receivedAtNanoseconds
            if presentedAt >= receivedAt {
                let latency = Double(presentedAt - receivedAt) / 1_000_000
                Self.append(latency, to: &latencySamples)
                latestRenderDiagnostics.presentLatencyMs = latency
                latestRenderDiagnostics.presentLatencyMaxMs = max(latestRenderDiagnostics.presentLatencyMaxMs, latency)
            }
            if let residence = lifecycle.renderQueueDurationMilliseconds {
                Self.append(residence, to: &queueSamples)
            }
            if let lastPresentationLogAt, presentedAt >= lastPresentationLogAt,
               presentedAt - lastPresentationLogAt >= 5_000_000_000 {
                let seconds = Double(presentedAt - lastPresentationLogAt) / 1_000_000_000
                let intervals = Self.percentiles(intervalSamples)
                let latency = Self.percentiles(latencySamples)
                let queue = Self.percentiles(queueSamples)
                NSLog("NVST presentation mode=%@ uniqueFps=%.2f n=%d interval[p50=%.2f p95=%.2f p99=%.2f]ms rxPresent[p50=%.2f p95=%.2f p99=%.2f]ms queue[p50=%.2f p95=%.2f p99=%.2f]ms",
                    latestRenderDiagnostics.presentationMode,
                    Double(renderedFrames - lastPresentationLogFrames) / seconds,
                    latencySamples.count, intervals.0, intervals.1, intervals.2,
                    latency.0, latency.1, latency.2, queue.0, queue.1, queue.2)
                self.lastPresentationLogAt = presentedAt
                lastPresentationLogFrames = renderedFrames
            } else if lastPresentationLogAt == nil {
                lastPresentationLogAt = presentedAt
                lastPresentationLogFrames = renderedFrames
            }
        }

        public func render(pixelBuffer: CVPixelBuffer, presentationTime: CMTime, isKeyframe: Bool, lifecycle: NvstVideoFrameLifecycle) {
            lock.lock()
            _ = contentDetector.update(with: pixelBuffer)
            latestPixelBuffer = pixelBuffer
            latestRenderDiagnostics.framesReceived &+= 1
            lock.unlock()

            guard let videoView else { lifecycle.discard(decoded: true); return }
            let size = CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
            lock.lock()
            let sizeChanged = size != lastSize
            if sizeChanged { lastSize = size }
            lock.unlock()

            if sizeChanged {
                Task { @MainActor in
                    videoView.setSize(size)
                }
            }

            videoView.renderPixelBuffer(pixelBuffer, presentationTime: presentationTime, lifecycle: lifecycle)
        }
    }

    public init(parentView: NSView, targetFps: Int32) {
        let videoView = NVSTMetalVideoView(frame: parentView.bounds, targetFps: targetFps)
        videoView.autoresizingMask = [.width, .height]
        videoView.wantsLayer = true
        videoView.layer?.backgroundColor = NSColor.black.cgColor
        parentView.addSubview(videoView)
        self.videoView = videoView
        let sink = NVSTCoreVideoSink(videoView: videoView)
        self.sink = sink
        videoView.onFramePresented = { [weak sink] lifecycle, presentedAt in
            sink?.notePresentation(lifecycle: lifecycle, presentedAt: presentedAt)
        }

        videoView.onMetalFXStateChanged = { [weak sink] state in
            guard let sink else { return }
            var snapshot = sink.renderDiagnostics
            switch state {
            case .active(let input, let output):
                snapshot.renderPath = "MetalFXSpatialScaler"
                snapshot.activeTier = "MetalFX"
                snapshot.fallback = ""
                snapshot.pixelFormat = "\(Int(input.width))x\(Int(input.height))"
                snapshot.outputFormat = "\(Int(output.width))x\(Int(output.height))"
            case .standby(let input, let output):
                snapshot.renderPath = "CoreImageDirect"
                snapshot.activeTier = "Native"
                snapshot.fallback = "1:1 passthrough"
                snapshot.pixelFormat = "\(Int(input.width))x\(Int(input.height))"
                snapshot.outputFormat = "\(Int(output.width))x\(Int(output.height))"
            case .disabled:
                snapshot.renderPath = "CoreImageDirect"
                snapshot.activeTier = "Off"
                snapshot.fallback = "Disabled by user"
            case .unsupported(let reason):
                snapshot.renderPath = "CoreImageDirect"
                snapshot.activeTier = "Native"
                snapshot.fallback = reason
            case .fallback(let reason):
                snapshot.renderPath = "CoreImageDirect"
                snapshot.activeTier = "Native"
                snapshot.fallback = reason
            }
            sink.noteRenderDiagnostics(snapshot)
        }
    }

    var renderDiagnostics: PixelNOWVideoRenderDiagnosticsSnapshot { sink.renderDiagnostics }


    func writeLatestFrameJPEG(to url: URL) -> CGSize? { sink.writeLatestFrameJPEG(to: url) }

    public var frameSink: NVSTCoreVideoSink { sink }

    public var isSurfaceReady: Bool {
        videoView.window != nil && !videoView.isHidden && videoView.bounds.width >= 1 && videoView.bounds.height >= 1
    }

    public var renderedFrameCount: UInt64 { sink.renderedFrameCount }

    public var isMetalFXActivelyScaling: Bool {
        videoView.metalFXState.isActive
    }

    public var metalFXState: NVSTMetalFXState {
        videoView.metalFXState
    }

    public var metalFXStatusDescription: String {
        videoView.metalFXState.description
    }

    public func setEnhancedFrameSink(_ sink: (@Sendable (CVPixelBuffer, CMTime) -> Void)?) {
        videoView.enhancedFrameSink = sink
    }

    public func setDisplayTimingHandler(_ handler: @escaping (UInt32) -> Void) {
        videoView.onDisplayTiming = handler
    }

    public func setVideoVisible(_ visible: Bool) {
        videoView.isHidden = !visible
    }

    private func applyMetalFXState() {
        videoView.isMetalFXEnabled = isMetalFXConfiguredByUser && (currentPresentationMode != .lowestLatency)
    }

    public func setMetalFXEnabled(_ enabled: Bool) {
        isMetalFXConfiguredByUser = enabled
        applyMetalFXState()
    }

    public func layoutVideoView() {
        guard let superview = videoView.superview else { return }
        if videoView.frame != superview.bounds {
            videoView.frame = superview.bounds
        }
    }

    public func setVideoEnhancement(mode: Int,
                                    sharpness: Int,
                                    denoise: Int,
                                    targetHeight: Int,
                                    pillarboxFillMode: Int,
                                    pillarboxFillDim: Int,
                                    pillarboxFillColor: Int) {
        videoView.configureEnhancement(sharpness: sharpness, denoise: denoise)
        setMetalFXEnabled(mode == StreamPreferences.upscalingModeValueMetalFX)
    }

    func writeOffscreenRenderSnapshot(to url: URL) -> CGSize? {
        sink.writeLatestFrameJPEG(to: url)
    }

    func requestRenderSnapshot(to url: URL) {
        _ = writeOffscreenRenderSnapshot(to: url)
    }

    func setPresentationMode(_ mode: PixelNOWVideoPresentationMode) {
        currentPresentationMode = mode
        sink.setPresentationMode(mode)
        videoView.configurePresentation(mode: mode)
        applyMetalFXState()
    }

    public func detach() {
        videoView.detach()
    }
}

public typealias NVSTCoreVideoSink = NVSTCoreVideoRenderer.NVSTCoreVideoSink
public typealias NvstBifrostFreeVideoRenderer = NVSTCoreVideoRenderer
public typealias NvstBifrostFreeVideoSink = NVSTCoreVideoRenderer.NVSTCoreVideoSink
