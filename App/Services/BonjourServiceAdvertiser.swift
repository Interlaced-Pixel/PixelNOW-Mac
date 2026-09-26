import Foundation

private final class BonjourPublicationDelegate: NSObject, NetServiceDelegate, @unchecked Sendable {
    var onFailure: (@Sendable (Error) -> Void)?

    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        onFailure?(BonjourPublicationError.publishFailed(errorDict))
    }
}

private enum BonjourPublicationError: LocalizedError {
    case publishFailed([String: NSNumber])

    var errorDescription: String? {
        switch self {
        case .publishFailed(let values):
            let details = values.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ", ")
            return "Bonjour publication failed: \(details)"
        }
    }
}

public actor BonjourServiceAdvertiser {
    private var service: NetService?
    private var delegate: BonjourPublicationDelegate?
    private var advertised = false

    public init() {}

    public func advertise(hostID: UUID,
                          pin: String,
                          hostIP: String,
                          signalingPort: Int,
                          quality: String,
                          latency: String) async throws {
        guard signalingPort > 0, signalingPort <= Int(UInt16.max) else { return }
        guard !advertised else { return }

        let name = "PixelNOW-Remote-CoOp-\(hostID.uuidString.prefix(8))"
        let service = NetService(domain: "local.", type: "_pixelnow-remote-coop._tcp.", name: name, port: Int32(signalingPort))
        let record: [String: Data] = [
            "hostID": Data(hostID.uuidString.utf8),
            "pin": Data(pin.utf8),
            "hostIP": Data(hostIP.utf8),
            "port": Data(String(signalingPort).utf8),
            "quality": Data(quality.utf8),
            "latency": Data(latency.utf8)
        ]
        service.setTXTRecord(NetService.data(fromTXTRecord: record))
        let delegate = BonjourPublicationDelegate()
        delegate.onFailure = { error in
            WebRTCMediaTelemetry.capture("remote.coop.bonjour.publish.failed", level: .warning, message: error.localizedDescription)
        }
        service.delegate = delegate
        service.publish(options: [.listenForConnections])
        self.service = service
        self.delegate = delegate
        advertised = true
    }

    public func stop() {
        service?.stop()
        service?.delegate = nil
        service = nil
        delegate = nil
        advertised = false
    }
}

public struct BonjourService: Hashable, Identifiable, Sendable {
    public let id: UUID
    public let hostID: UUID
    public let pin: String
    public let signalingPort: Int
    public let quality: String
    public let latency: String
    public let hostIP: String

    public init(id: UUID = UUID(), hostID: UUID, pin: String, signalingPort: Int, quality: String, latency: String, hostIP: String) {
        self.id = id
        self.hostID = hostID
        self.pin = pin
        self.signalingPort = signalingPort
        self.quality = quality
        self.latency = latency
        self.hostIP = hostIP
    }
}
