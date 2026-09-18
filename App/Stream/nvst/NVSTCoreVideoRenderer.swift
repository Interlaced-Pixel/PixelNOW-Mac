import AppKit
import CoreImage
import CoreMedia
import CoreVideo
import Foundation

public enum OPNVideoPresentationMode: Int, Sendable {
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
}

public struct OPNVideoRenderDiagnosticsSnapshot: Equatable, Sendable {
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

    public init() {}
}

@MainActor
public final class NVSTCoreVideoRenderer {
    private let videoView: NVSTMetalVideoView
    private let sink: NVSTCoreVideoSink
    private var isMetalFXConfiguredByUser: Bool = false
    private var currentPresentationMode: OPNVideoPresentationMode = .balanced

    public final class NVSTCoreVideoSink: @unchecked Sendable {
        private weak var videoView: NVSTMetalVideoView?
        let lock = NSLock()
        private var lastSize = CGSize.zero
        private var renderedFrames: UInt64 = 0
        private var latestRenderDiagnostics = OPNVideoRenderDiagnosticsSnapshot()

        private let contentDetector = OPNPillarboxDetector()

        private var latestPixelBuffer: CVPixelBuffer?
        private let snapshotTransfer = OPNPixelBufferTransfer()

        init(videoView: NVSTMetalVideoView) {
            self.videoView = videoView
        }

        public var renderedFrameCount: UInt64 { lock.lock(); defer { lock.unlock() }; return renderedFrames }

        var renderDiagnostics: OPNVideoRenderDiagnosticsSnapshot {
            lock.lock()
            defer { lock.unlock() }
            var snapshot = latestRenderDiagnostics
            snapshot.contentLeft = contentDetector.contentRect.left
            snapshot.contentRight = contentDetector.contentRect.right
            return snapshot
        }

        func writeLatestFrameJPEG(to url: URL) -> CGSize? {
            lock.lock()
            let buffer = latestPixelBuffer
            lock.unlock()
            guard let buffer,
                  let nv12 = snapshotTransfer.convert(buffer, to: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) else { return nil }
            let image = CIImage(cvPixelBuffer: nv12)
            let context = CIContext(options: [.cacheIntermediates: false])
            guard let data = context.jpegRepresentation(of: image, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, options: [:]) else { return nil }
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                return nil
            }
            return image.extent.size
        }

        func noteRenderDiagnostics(_ snapshot: OPNVideoRenderDiagnosticsSnapshot) {
            lock.lock()
            latestRenderDiagnostics = snapshot
            lock.unlock()
        }

        func setPresentationMode(_ mode: OPNVideoPresentationMode) {
            lock.lock()
            latestRenderDiagnostics.presentationMode = mode.label
            lock.unlock()
        }

        public func render(pixelBuffer: CVPixelBuffer, presentationTime: CMTime, isKeyframe: Bool) {
            lock.lock()
            _ = contentDetector.update(with: pixelBuffer)
            latestPixelBuffer = pixelBuffer
            renderedFrames &+= 1
            lock.unlock()

            guard let videoView else { return }
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

            videoView.renderPixelBuffer(pixelBuffer, presentationTime: presentationTime)
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

    var renderDiagnostics: OPNVideoRenderDiagnosticsSnapshot { sink.renderDiagnostics }

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
        setMetalFXEnabled(mode == 3)
    }

    func writeOffscreenRenderSnapshot(to url: URL) -> CGSize? {
        sink.writeLatestFrameJPEG(to: url)
    }

    func requestRenderSnapshot(to url: URL) {
        _ = writeOffscreenRenderSnapshot(to: url)
    }

    func setPresentationMode(_ mode: OPNVideoPresentationMode) {
        currentPresentationMode = mode
        sink.setPresentationMode(mode)
        applyMetalFXState()
    }

    public func detach() {
        videoView.detach()
    }
}

public typealias NVSTCoreVideoSink = NVSTCoreVideoRenderer.NVSTCoreVideoSink
public typealias NvstBifrostFreeVideoRenderer = NVSTCoreVideoRenderer
public typealias NvstBifrostFreeVideoSink = NVSTCoreVideoRenderer.NVSTCoreVideoSink
