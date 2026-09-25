import CoreMedia
import Foundation
@preconcurrency import WebRTC

public protocol RemoteCoOpHostVideoSink: AnyObject, Sendable {
    var participantID: UUID { get }
    func renderVideoFrame(_ frame: RTCVideoFrame)
}

public final class RemoteCoOpHostVideoRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var sinks: [UUID: any RemoteCoOpHostVideoSink] = [:]

    public init() {}

    public func upsert(_ sink: any RemoteCoOpHostVideoSink) {
        lock.withLock { sinks[sink.participantID] = sink }
    }

    public func remove(participantID: UUID) {
        lock.withLock { sinks[participantID] = nil }
    }

    public func removeAll() {
        lock.withLock { sinks.removeAll() }
    }

    public func activeSinkCount() -> Int {
        lock.withLock { sinks.count }
    }

    public func renderVideoFrame(_ frame: RTCVideoFrame) {
        let currentSinks = lock.withLock { Array(sinks.values) }
        for sink in currentSinks { sink.renderVideoFrame(frame) }
    }

    public func renderPixelBuffer(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        let currentSinks = lock.withLock { Array(sinks.values) }
        guard !currentSinks.isEmpty else { return }
        let buffer = RTCCVPixelBuffer(pixelBuffer: pixelBuffer)
        let timestampNs = presentationTime.isValid ? Int64(CMTimeGetSeconds(presentationTime) * 1_000_000_000) : 0
        let frame = RTCVideoFrame(buffer: buffer, rotation: ._0, timeStampNs: timestampNs)
        for sink in currentSinks { sink.renderVideoFrame(frame) }
    }
}
