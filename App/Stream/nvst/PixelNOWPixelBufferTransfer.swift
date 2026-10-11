import CoreVideo
import Foundation
import VideoToolbox

final class PixelNOWPixelBufferTransfer: @unchecked Sendable {
    private let lock = NSLock()
    private var session: VTPixelTransferSession?
    private var pool: CVPixelBufferPool?
    private var poolKey: (width: Int, height: Int, format: OSType) = (0, 0, 0)

    /// `source` itself when it already has `format`, else a converted copy, or nil if the
    /// transfer fails.
    func convert(_ source: CVPixelBuffer, to format: OSType) -> CVPixelBuffer? {
        guard CVPixelBufferGetPixelFormatType(source) != format else { return source }
        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        guard width > 0, height > 0 else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard let session = ensureSession(), let pool = ensurePool(width: width, height: height, format: format) else { return nil }
        var destination: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &destination) == kCVReturnSuccess, let destination else { return nil }
        guard VTPixelTransferSessionTransferImage(session, from: source, to: destination) == noErr else { return nil }
        // Colour tags travel with the frame; the destination pool knows nothing about them.
        CVBufferPropagateAttachments(source, destination)
        return destination
    }

    private func ensureSession() -> VTPixelTransferSession? {
        if let session { return session }
        var created: VTPixelTransferSession?
        guard VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &created) == noErr, let created else { return nil }
        VTSessionSetProperty(created, key: kVTPixelTransferPropertyKey_RealTime, value: kCFBooleanTrue)
        session = created
        return created
    }

    private func ensurePool(width: Int, height: Int, format: OSType) -> CVPixelBufferPool? {
        if let pool, poolKey == (width, height, format) { return pool }
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: NSNumber(value: format),
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        let poolAttributes: [CFString: Any] = [kCVPixelBufferPoolMinimumBufferCountKey: 3]
        var created: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(kCFAllocatorDefault, poolAttributes as CFDictionary, attributes as CFDictionary, &created) == kCVReturnSuccess else { return nil }
        pool = created
        poolKey = (width, height, format)
        return created
    }

}
