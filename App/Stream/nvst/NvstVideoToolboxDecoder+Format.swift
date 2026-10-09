//  What the bitstream declares about itself and which output surface to ask VideoToolbox for.
//

import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

extension NvstVideoToolboxDecoder {

    /// What the bitstream's parameter sets declare about sample depth and chroma layout. Read from
    /// the `hvcC` record VideoToolbox builds out of the SPS, so it is the decoder's own view of the
    /// stream rather than what the session negotiation asked for.
    public struct BitstreamFormat: Equatable, Sendable {
        public enum Chroma: Int, Sendable {
            case monochrome = 0
            case yuv420 = 1
            case yuv422 = 2
            case yuv444 = 3
        }
        public var bitDepth = 8
        public var chroma = Chroma.yuv420

        public var isTenBit: Bool { bitDepth > 8 }
        public var summary: String {
            let layout: String = switch chroma {
            case .monochrome: "4:0:0"
            case .yuv420: "4:2:0"
            case .yuv422: "4:2:2"
            case .yuv444: "4:4:4"
            }
            return "\(bitDepth)-bit \(layout)"
        }
    }

    /// Reads depth and chroma layout out of the HEVC decoder configuration record (`hvcC`, ISO
    /// 14496-15 §8.3.3.1): byte 16 carries `chromaFormat` in its low two bits and byte 17
    /// `bitDepthLumaMinus8` in its low three. H.264 sessions on this service are 8-bit 4:2:0 —
    /// the 10-bit and 4:4:4 tiers are only offered on HEVC and AV1 — so `avcC` is not parsed.
    static func bitstreamFormat(from description: CMFormatDescription, codec: NVSTVideoCodec) -> BitstreamFormat {
        if codec == .hevc {
            guard let atoms = CMFormatDescriptionGetExtension(description, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String: Any],
                  let record = atoms["hvcC"] as? Data else {
                return BitstreamFormat()
            }
            return bitstreamFormat(hvcC: record)
        } else if codec == .av1 {
            guard let atoms = CMFormatDescriptionGetExtension(description, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String: Any],
                  let record = atoms["av1C"] as? Data else {
                return BitstreamFormat()
            }
            return bitstreamFormat(av1C: record)
        }
        return BitstreamFormat()
    }

    static func bitstreamFormat(hvcC record: Data) -> BitstreamFormat {
        guard record.count >= 19 else { return BitstreamFormat() }
        let bytes = [UInt8](record)
        var format = BitstreamFormat()
        format.chroma = BitstreamFormat.Chroma(rawValue: Int(bytes[16] & 0x3)) ?? .yuv420
        format.bitDepth = 8 + Int(bytes[17] & 0x7)
        return format
    }

    static func bitstreamFormat(av1C record: Data) -> BitstreamFormat {
        guard record.count >= 4 else { return BitstreamFormat() }
        let bytes = [UInt8](record)
        let b2 = bytes[2]
        let high = (b2 & 0x40) != 0
        let twelve = (b2 & 0x20) != 0
        let mono = (b2 & 0x10) != 0
        let subX = (b2 & 0x08) != 0
        let subY = (b2 & 0x04) != 0
        var format = BitstreamFormat()
        format.bitDepth = high ? (twelve ? 12 : 10) : 8
        if mono {
            format.chroma = .monochrome
        } else if subX && subY {
            format.chroma = .yuv420
        } else if subX && !subY {
            format.chroma = .yuv422
        } else if !subX && !subY {
            format.chroma = .yuv444
        }
        return format
    }

    /// The `CVPixelBuffer` formats to ask VideoToolbox for, best first. Every entry is video range
    /// and bi-planar, matching the vendor client's `VTDecoder::defaultPixelFormat` in `libGeronimo.dylib`.
    /// The Metal path samples luma and interleaved chroma as two textures with the
    /// same normalised coordinates, so 4:2:2 and 4:4:4 chroma planes of any size bind unchanged.
    /// A 10-bit stream asks for the matching 10-bit surface so the decoder no longer truncates every
    /// frame to 8 bits before the renderer sees it. The 8-bit 4:2:0 surface is always the last resort,
    /// because VideoToolbox will convert down to it from anything.
    static func preferredOutputPixelFormats(for format: BitstreamFormat) -> [OSType] {
        let fallback = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        var preferred: [OSType] = []
        switch (format.chroma, format.isTenBit) {
        case (.yuv444, true): preferred = [kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange]
        case (.yuv444, false): preferred = [kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange]
        case (.yuv422, true): preferred = [kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange]
        case (.yuv422, false): preferred = [kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange]
        case (_, true): preferred = [kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange]
        default: preferred = []
        }
        return preferred + [fallback]
    }

    static func pixelFormatName(_ format: OSType) -> String {
        guard format != 0 else { return "-" }
        let bytes = [UInt8((format >> 24) & 0xff), UInt8((format >> 16) & 0xff), UInt8((format >> 8) & 0xff), UInt8(format & 0xff)]
        return String(bytes: bytes, encoding: .ascii) ?? String(format: "0x%08x", format)
    }

    func makeFormatDescription(_ sets: NvstElementaryStream.ParameterSets) throws -> CMVideoFormatDescription {
        if codec == .av1 {
            guard let seqHeaderOBU = sets.sequenceParameterSets.first, !seqHeaderOBU.isEmpty else {
                throw DecoderError.missingParameterSets
            }
            return try makeAV1FormatDescription(sequenceHeaderOBU: seqHeaderOBU)
        }
        let ordered = sets.ordered
        guard !ordered.isEmpty else { throw DecoderError.missingParameterSets }
        // One contiguous allocation so the pointer array stays valid for the whole call;
        // taking addresses out of per-element `withUnsafeBufferPointer` closures would dangle.
        let sizes = ordered.map(\.count)
        let total = sizes.reduce(0, +)
        let storage = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: total)
        defer { storage.deallocate() }
        var offset = 0
        var pointers: [UnsafePointer<UInt8>] = []
        for set in ordered {
            set.copyBytes(to: storage.baseAddress!.advanced(by: offset), count: set.count)
            pointers.append(UnsafePointer(storage.baseAddress!.advanced(by: offset)))
            offset += set.count
        }

        var description: CMFormatDescription?
        let status: OSStatus = pointers.withUnsafeBufferPointer { pointerBuffer in
            sizes.withUnsafeBufferPointer { sizeBuffer in
                switch codec {
                case .hevc:
                    CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                        allocator: kCFAllocatorDefault,
                        parameterSetCount: pointerBuffer.count,
                        parameterSetPointers: pointerBuffer.baseAddress!,
                        parameterSetSizes: sizeBuffer.baseAddress!,
                        nalUnitHeaderLength: 4,
                        extensions: nil,
                        formatDescriptionOut: &description
                    )
                default:
                    CMVideoFormatDescriptionCreateFromH264ParameterSets(
                        allocator: kCFAllocatorDefault,
                        parameterSetCount: pointerBuffer.count,
                        parameterSetPointers: pointerBuffer.baseAddress!,
                        parameterSetSizes: sizeBuffer.baseAddress!,
                        nalUnitHeaderLength: 4,
                        formatDescriptionOut: &description
                    )
                }
            }
        }
        guard status == noErr, let description else { throw DecoderError.formatDescriptionFailed(status) }
        let format = Self.bitstreamFormat(from: description, codec: codec)
        statsLock.lock()
        currentBitstreamFormat = format
        statsLock.unlock()
        // The seat's parameter sets, verbatim, once per format description. Whether the decoder
        // may hold frames for reordering is written in the SPS (`sps_max_num_reorder_pics`, and
        // the VUI's bitstream restriction), and that decides how long a decoded frame waits inside
        // VideoToolbox before this app sees it.
        let hex = sets.ordered.map { data in data.map { String(format: "%02x", $0) }.joined() }.joined(separator: " ")
        onDecoderLog?("NVST parameter sets \(format.summary): \(hex)")
        return description
    }

    func makeSampleBuffer(sample: Data,
                                  formatDescription: CMVideoFormatDescription,
                                  presentationTime: CMTime) throws -> CMSampleBuffer {
        var blockBuffer: CMBlockBuffer?
        // The sample is already a contiguous `Data`; copying it into an `[UInt8]` first was a whole
        // extra pass over a 5K access unit for nothing. `CMBlockBufferReplaceDataBytes` copies from
        // whatever pointer it is given.
        let sampleCount = sample.count
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: sampleCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: sampleCount,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr, let blockBuffer else { throw DecoderError.blockBufferFailed(status) }
        status = sample.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return kCMBlockBufferBadPointerParameterErr }
            return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: sampleCount)
        }
        guard status == noErr else { throw DecoderError.blockBufferFailed(status) }

        var sampleBuffer: CMSampleBuffer?
        var sampleSize = sampleCount
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else { throw DecoderError.sampleBufferFailed(status) }
        return sampleBuffer
    }

    static func tearDown(_ session: VTDecompressionSession?) {
        guard let session else { return }
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        VTDecompressionSessionInvalidate(session)
    }

    static func milliseconds(from start: UInt64, to end: UInt64) -> Double {
        end > start ? Double(end - start) / 1_000_000 : 0
    }

    struct Av1BitReader {
        let bytes: [UInt8]
        var bitOffset: Int = 0

        init(_ data: Data) {
            self.bytes = [UInt8](data)
        }

        mutating func readBits(_ count: Int) -> UInt32? {
            guard count >= 0, count <= 32 else { return nil }
            var result: UInt32 = 0
            for _ in 0..<count {
                let byteIndex = bitOffset / 8
                let bitIndex = 7 - (bitOffset % 8)
                guard byteIndex < bytes.count else { return nil }
                let bit = (UInt32(bytes[byteIndex]) >> bitIndex) & 1
                result = (result << 1) | bit
                bitOffset += 1
            }
            return result
        }

        mutating func readUvlc() -> UInt32? {
            var leadingZeros = 0
            while let bit = readBits(1), bit == 0 {
                leadingZeros += 1
                if leadingZeros > 32 { return nil }
            }
            if leadingZeros == 0 { return 0 }
            guard let value = readBits(leadingZeros) else { return nil }
            return (1 << leadingZeros) - 1 + value
        }
    }

    struct Av1SequenceHeaderInfo {
        var seqProfile: UInt32 = 0
        var seqLevelIdx: UInt32 = 0
        var seqTier: UInt32 = 0
        var highBitdepth: Bool = false
        var twelveBit: Bool = false
        var monochrome: Bool = false
        var subsamplingX: Bool = true
        var subsamplingY: Bool = true
        var chromaSamplePosition: UInt32 = 0
        var width: Int = 1920
        var height: Int = 1080
    }

    static func parseAV1SequenceHeader(_ data: Data) -> Av1SequenceHeaderInfo? {
        guard !data.isEmpty else { return nil }
        let header = data[data.startIndex]
        guard (header & 0x80) == 0 else { return nil }
        let hasExtension = (header & 0x04) != 0
        let hasSize = (header & 0x02) != 0
        var offset = 1
        if hasExtension { offset += 1 }
        if hasSize {
            while offset < data.count {
                let byte = data[data.startIndex + offset]
                offset += 1
                if (byte & 0x80) == 0 { break }
            }
        }
        guard offset < data.count else { return nil }
        let payload = data.dropFirst(offset)
        var bitReader = Av1BitReader(payload)
        guard let seqProfile = bitReader.readBits(3),
              let _ = bitReader.readBits(1),
              let reducedStillPicture = bitReader.readBits(1) else { return nil }
        var info = Av1SequenceHeaderInfo()
        info.seqProfile = seqProfile
        if reducedStillPicture == 1 {
            guard let level = bitReader.readBits(5),
                  let widthBits = bitReader.readBits(4),
                  let heightBits = bitReader.readBits(4),
                  let maxW = bitReader.readBits(Int(widthBits + 1)),
                  let maxH = bitReader.readBits(Int(heightBits + 1)) else { return nil }
            info.seqLevelIdx = level
            info.width = Int(maxW + 1)
            info.height = Int(maxH + 1)
        } else {
            guard let timingInfoPresent = bitReader.readBits(1) else { return nil }
            if timingInfoPresent == 1 {
                _ = bitReader.readBits(32)
                _ = bitReader.readBits(32)
                guard let equalPicInterval = bitReader.readBits(1) else { return nil }
                if equalPicInterval == 1 { _ = bitReader.readUvlc() }
            }
            guard let initialDisplayDelayPresent = bitReader.readBits(1),
                  let opCountMinus1 = bitReader.readBits(5) else { return nil }
            for _ in 0...opCountMinus1 {
                _ = bitReader.readBits(12)
                guard let level = bitReader.readBits(5) else { return nil }
                info.seqLevelIdx = level
                if level > 7 {
                    if let tier = bitReader.readBits(1) { info.seqTier = tier }
                }
                if initialDisplayDelayPresent == 1 {
                    if let delayPresent = bitReader.readBits(1), delayPresent == 1 {
                        _ = bitReader.readBits(4)
                    }
                }
            }
            guard let widthBits = bitReader.readBits(4),
                  let heightBits = bitReader.readBits(4),
                  let maxW = bitReader.readBits(Int(widthBits + 1)),
                  let maxH = bitReader.readBits(Int(heightBits + 1)) else { return nil }
            info.width = Int(maxW + 1)
            info.height = Int(maxH + 1)
            if let frameIdNumbersPresent = bitReader.readBits(1), frameIdNumbersPresent == 1 {
                _ = bitReader.readBits(7)
            }
            _ = bitReader.readBits(3)
            _ = bitReader.readBits(5)
            if let orderHint = bitReader.readBits(1), orderHint == 1 {
                _ = bitReader.readBits(2)
            }
            if let chooseScreenTools = bitReader.readBits(1) {
                var forceScreen = 2
                if chooseScreenTools == 0 {
                    if let f = bitReader.readBits(1) { forceScreen = Int(f) }
                }
                if forceScreen > 0 {
                    if let chooseIntMv = bitReader.readBits(1), chooseIntMv == 0 {
                        _ = bitReader.readBits(1)
                    }
                }
            }
            _ = bitReader.readBits(3)
            if let highBitdepth = bitReader.readBits(1) {
                info.highBitdepth = highBitdepth == 1
                if seqProfile == 2 && highBitdepth == 1 {
                    if let twelve = bitReader.readBits(1) { info.twelveBit = twelve == 1 }
                }
                if seqProfile != 1 {
                    if let mono = bitReader.readBits(1) { info.monochrome = mono == 1 }
                }
                if !info.monochrome {
                    if seqProfile == 0 {
                        info.subsamplingX = true
                        info.subsamplingY = true
                    } else if seqProfile == 1 {
                        info.subsamplingX = false
                        info.subsamplingY = false
                    }
                }
            }
        }
        return info
    }

    func makeAV1FormatDescription(sequenceHeaderOBU: Data) throws -> CMVideoFormatDescription {
        let info = Self.parseAV1SequenceHeader(sequenceHeaderOBU) ?? Av1SequenceHeaderInfo()
        var av1c = Data([
            0x81,
            UInt8(((info.seqProfile & 0x07) << 5) | (info.seqLevelIdx & 0x1f)),
            UInt8(((info.seqTier & 0x01) << 7)
                | ((info.highBitdepth ? 1 : 0) << 6)
                | ((info.twelveBit ? 1 : 0) << 5)
                | ((info.monochrome ? 1 : 0) << 4)
                | ((info.subsamplingX ? 1 : 0) << 3)
                | ((info.subsamplingY ? 1 : 0) << 2)
                | (info.chromaSamplePosition & 0x03)),
            0x00
        ])
        av1c.append(sequenceHeaderOBU)

        let atoms: [String: Any] = ["av1C": av1c]
        let bitDepth = info.highBitdepth ? (info.twelveBit ? 12 : 10) : 8
        let extensions: [CFString: Any] = [
            kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: atoms,
            "BitsPerComponent" as CFString: bitDepth,
        ]

        var description: CMFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCMVideoCodecType_AV1,
            width: Int32(info.width),
            height: Int32(info.height),
            extensions: extensions as CFDictionary,
            formatDescriptionOut: &description
        )
        guard status == noErr, let description else { throw DecoderError.formatDescriptionFailed(status) }
        let format = Self.bitstreamFormat(from: description, codec: .av1)
        statsLock.lock()
        currentBitstreamFormat = format
        statsLock.unlock()
        let hex = sequenceHeaderOBU.map { String(format: "%02x", $0) }.joined()
        onDecoderLog?("NVST AV1 sequence header \(format.summary): \(hex)")
        return description
    }
}
