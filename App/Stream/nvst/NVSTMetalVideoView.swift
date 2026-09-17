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
    private var neutralMotionTexture: (any MTLTexture)?
    private var disabledByCaptureScaler = false
    private static let setMotionTextureSelector = NSSelectorFromString("setMotionTexture:")
    private static let motionTextureFormatSelector = NSSelectorFromString("motionTextureFormat")
    private static let motionTextureUsageSelector = NSSelectorFromString("motionTextureUsage")

    init(device: (any MTLDevice)?) {
        self.device = device
        super.init()
    }

    var isAvailable: Bool {
#if canImport(MetalFX)
        guard !disabledByCaptureScaler, let device, NSClassFromString("MTLFXSpatialScalerDescriptor") != nil else { return false }
        if #available(macOS 13.0, *) {
            return MTLFXSpatialScalerDescriptor.supportsDevice(device)
        }
        return false
#else
        return false
#endif
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
                neutralMotionTexture = nil
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
            guard configureMotionTextureIfNeeded(for: scaler, fallback: fallback) else {
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

#if canImport(MetalFX)
    @available(macOS 13.0, *)
    private func configureMotionTextureIfNeeded(
        for scaler: any MTLFXSpatialScaler,
        fallback: AutoreleasingUnsafeMutablePointer<NSString?>?
    ) -> Bool {
        guard let scalerObject = scaler as AnyObject as? NSObject,
              scalerObject.responds(to: Self.setMotionTextureSelector) else { return true }
        let rawPixelFormat = Self.unsignedIntegerValue(from: scalerObject, selector: Self.motionTextureFormatSelector)
        let pixelFormat = rawPixelFormat.flatMap { MTLPixelFormat(rawValue: $0) } ?? .rg16Float
        let rawUsage = Self.unsignedIntegerValue(from: scalerObject, selector: Self.motionTextureUsageSelector) ?? MTLTextureUsage.shaderRead.rawValue
        let usage = MTLTextureUsage(rawValue: rawUsage).union(.shaderRead)
        guard let motionTexture = reusableNeutralMotionTexture(width: inputWidth, height: inputHeight, pixelFormat: pixelFormat, usage: usage) else {
            fallback?.pointee = "MetalFX motion texture allocation failed"
            return false
        }
        Self.setObjectValue(motionTexture as AnyObject, on: scalerObject, selector: Self.setMotionTextureSelector)
        return true
    }

    private static func unsignedIntegerValue(from object: NSObject, selector: Selector) -> UInt? {
        guard object.responds(to: selector), let method = object.method(for: selector) else { return nil }
        typealias Getter = @convention(c) (AnyObject, Selector) -> UInt
        return unsafeBitCast(method, to: Getter.self)(object, selector)
    }

    private static func setObjectValue(_ value: AnyObject, on object: NSObject, selector: Selector) {
        guard object.responds(to: selector), let method = object.method(for: selector) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
        unsafeBitCast(method, to: Setter.self)(object, selector, value)
    }

    private func reusableNeutralMotionTexture(
        width: Int,
        height: Int,
        pixelFormat: MTLPixelFormat,
        usage: MTLTextureUsage
    ) -> (any MTLTexture)? {
        guard let device, width > 0, height > 0, let bytesPerPixel = Self.bytesPerPixel(for: pixelFormat) else { return nil }
        let requiredUsage = usage.union(.shaderRead)
        if neutralMotionTexture == nil ||
            neutralMotionTexture?.width != width ||
            neutralMotionTexture?.height != height ||
            neutralMotionTexture?.pixelFormat != pixelFormat ||
            neutralMotionTexture?.usage.isSuperset(of: requiredUsage) != true {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: pixelFormat, width: width, height: height, mipmapped: false)
            descriptor.usage = requiredUsage
            descriptor.storageMode = .shared
            guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
            let bytesPerRow = width * bytesPerPixel
            let zeroBytes = [UInt8](repeating: 0, count: bytesPerRow * height)
            zeroBytes.withUnsafeBytes { bytes in
                if let baseAddress = bytes.baseAddress {
                    texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: baseAddress, bytesPerRow: bytesPerRow)
                }
            }
            texture.label = "PixelNOW MetalFX neutral motion"
            neutralMotionTexture = texture
        }
        return neutralMotionTexture
    }

    private static func bytesPerPixel(for pixelFormat: MTLPixelFormat) -> Int? {
        switch pixelFormat {
        case .r8Unorm, .r8Snorm, .r8Uint, .r8Sint:
            return 1
        case .r16Unorm, .r16Snorm, .r16Uint, .r16Sint, .r16Float, .rg8Unorm, .rg8Snorm, .rg8Uint, .rg8Sint:
            return 2
        case .r32Uint, .r32Sint, .r32Float, .rg16Unorm, .rg16Snorm, .rg16Uint, .rg16Sint, .rg16Float, .rgba8Unorm, .rgba8Unorm_srgb, .rgba8Snorm, .rgba8Uint, .rgba8Sint, .bgra8Unorm, .bgra8Unorm_srgb:
            return 4
        case .rg32Uint, .rg32Sint, .rg32Float, .rgba16Unorm, .rgba16Snorm, .rgba16Uint, .rgba16Sint, .rgba16Float:
            return 8
        case .rgba32Uint, .rgba32Sint, .rgba32Float:
            return 16
        default:
            return nil
        }
    }
#endif
}

final class NVSTPixelBufferHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: CVPixelBuffer?
    private var time: CMTime = .invalid
    private var hasNew = false

    func set(_ pixelBuffer: CVPixelBuffer, time: CMTime) {
        lock.lock()
        buffer = pixelBuffer
        self.time = time
        hasNew = true
        lock.unlock()
    }

    func get() -> (CVPixelBuffer, CMTime)? {
        lock.lock()
        defer { lock.unlock() }
        guard let buffer else { return nil }
        return (buffer, time)
    }

    func consumeIfNew() -> (CVPixelBuffer, CMTime)? {
        lock.lock()
        defer { lock.unlock() }
        guard hasNew, let buffer else { return nil }
        hasNew = false
        return (buffer, time)
    }

    func clear() {
        lock.lock()
        buffer = nil
        time = .invalid
        hasNew = false
        lock.unlock()
    }
}

@MainActor
public final class NVSTMetalVideoView: NSView, MTKViewDelegate {
    private let metalView: MTKView
    private let targetFps: Int
    private var commandQueue: (any MTLCommandQueue)?
    private var ciContext: CIContext?
    private let upscaler: NVSTMetalFXUpscaler
    private let bufferHolder = NVSTPixelBufferHolder()
    private var drawnFrames = 0
    private var uniqueFramesDrawn = 0
    private var lastDrawLogTime = Date()
    private var lastDrawnTime: CMTime?
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    private var intermediateSourceTexture: (any MTLTexture)?
    private var intermediateOutputTexture: (any MTLTexture)?

    public var isMetalFXEnabled = true
    private var enhancementSharpness = 10
    private var enhancementDenoise = 0

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
        metalView.isPaused = false
        metalView.enableSetNeedsDisplay = false
        metalView.delegate = self
        metalView.layerContentsPlacement = .scaleProportionallyToFit

        if let metalLayer = metalView.layer as? CAMetalLayer {
            metalLayer.presentsWithTransaction = false
            metalLayer.allowsNextDrawableTimeout = false
            if #available(macOS 10.13, *) {
                metalLayer.maximumDrawableCount = 3
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
        updateDrawableSize()
    }

    private func updateDrawableSize() {
        guard let window, bounds.width >= 1, bounds.height >= 1 else { return }
        let scale = window.backingScaleFactor
        let width = max(1, Int(bounds.width * scale))
        let height = max(1, Int(bounds.height * scale))
        metalView.drawableSize = CGSize(width: width, height: height)
    }

    public nonisolated func renderPixelBuffer(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        bufferHolder.set(pixelBuffer, time: presentationTime)
    }

    public func setSize(_ size: CGSize) {
        guard size.width >= 1, size.height >= 1 else { return }
        updateDrawableSize()
    }

    public func configureEnhancement(sharpness: Int, denoise: Int) {
        enhancementSharpness = min(max(sharpness, 0), 15)
        enhancementDenoise = min(max(denoise, 0), 20)
    }

    public func detach() {
        bufferHolder.clear()
        metalView.isPaused = true
        metalView.delegate = nil
        intermediateSourceTexture = nil
        intermediateOutputTexture = nil
        removeFromSuperview()
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
        guard let (pixelBuffer, time) = bufferHolder.get(),
              let currentDrawable = metalView.currentDrawable,
              let commandBuffer = commandQueue?.makeCommandBuffer(),
              let ciContext else {
            return
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
            NSLog("NVSTMetalVideoView draw() FPS: %.1f, Unique frames FPS: %.1f", fps, uniqueFps)
            drawnFrames = 0
            uniqueFramesDrawn = 0
            lastDrawLogTime = now
        }

        let image = enhancedImage(CIImage(cvPixelBuffer: pixelBuffer))
        let sourceWidth = CVPixelBufferGetWidth(pixelBuffer)
        let sourceHeight = CVPixelBufferGetHeight(pixelBuffer)
        let outputWidth = currentDrawable.texture.width
        let outputHeight = currentDrawable.texture.height

        guard sourceWidth > 0, sourceHeight > 0, outputWidth > 0, outputHeight > 0 else { return }

        let shouldUpscale = isMetalFXEnabled &&
            upscaler.isAvailable &&
            outputWidth > sourceWidth &&
            outputHeight > sourceHeight

        if shouldUpscale,
           let sourceTexture = reusableTexture(
               &intermediateSourceTexture,
               width: sourceWidth,
               height: sourceHeight,
               pixelFormat: .bgra8Unorm,
               usage: [.shaderRead, .shaderWrite, .renderTarget],
               label: "NVSTMetalVideoView Source"
           ),
           let outputTexture = reusableTexture(
               &intermediateOutputTexture,
               width: outputWidth,
               height: outputHeight,
               pixelFormat: .bgra8Unorm,
               usage: [.shaderRead, .shaderWrite, .renderTarget],
               label: "NVSTMetalVideoView Output"
           ) {
            ciContext.render(
                image,
                to: sourceTexture,
                commandBuffer: commandBuffer,
                bounds: CGRect(x: 0, y: 0, width: sourceWidth, height: sourceHeight),
                colorSpace: colorSpace
            )
            var fallback: NSString?
            if upscaler.encodeTexture(sourceTexture, toTexture: outputTexture, commandBuffer: commandBuffer, fallback: &fallback) {
                copyTexture(from: outputTexture, to: currentDrawable.texture, commandBuffer: commandBuffer)
                commandBuffer.present(currentDrawable)
                commandBuffer.commit()
                return
            }
        }

        let bounds = CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight)
        let scaleX = CGFloat(outputWidth) / CGFloat(sourceWidth)
        let scaleY = CGFloat(outputHeight) / CGFloat(sourceHeight)
        let scaledImage = image.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        ciContext.render(scaledImage, to: currentDrawable.texture, commandBuffer: commandBuffer, bounds: bounds, colorSpace: colorSpace)
        commandBuffer.present(currentDrawable)
        commandBuffer.commit()
    }

    private func enhancedImage(_ image: CIImage) -> CIImage {
        var result = image
        if enhancementDenoise > 0, let filter = CIFilter(name: "CINoiseReduction") {
            filter.setValue(result, forKey: kCIInputImageKey)
            filter.setValue(Float(enhancementDenoise) / 20 * 0.04, forKey: "inputNoiseLevel")
            filter.setValue(Float(1 - enhancementDenoise / 20) * 0.5, forKey: "inputSharpness")
            if let output = filter.outputImage { result = output }
        }
        if enhancementSharpness > 0, let filter = CIFilter(name: "CISharpenLuminance") {
            filter.setValue(result, forKey: kCIInputImageKey)
            filter.setValue(Float(enhancementSharpness) / 15 * 2, forKey: "inputSharpness")
            if let output = filter.outputImage { result = output }
        }
        return result
    }
}
