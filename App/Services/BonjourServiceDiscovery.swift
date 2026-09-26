import Foundation

private struct BonjourResolvedRecord: Sendable {
    let hostID: String
    let pin: String
    let signalingPort: Int
    let quality: String
    let latency: String
    let hostIP: String
}

private final class BonjourDiscoveryDelegate: NSObject, NetServiceBrowserDelegate, NetServiceDelegate, @unchecked Sendable {
    let onService: @Sendable (BonjourResolvedRecord) -> Void
    let onStop: @Sendable () -> Void

    init(onService: @escaping @Sendable (BonjourResolvedRecord) -> Void, onStop: @escaping @Sendable () -> Void) {
        self.onService = onService
        self.onStop = onStop
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        service.delegate = self
        service.resolve(withTimeout: 3)
    }

    func netServiceBrowserDidStopSearch(_ browser: NetServiceBrowser) {
        onStop()
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        onStop()
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        let values = NetService.dictionary(fromTXTRecord: sender.txtRecordData() ?? Data())
        guard let hostID = text(values["hostID"]),
              let pin = text(values["pin"]),
              let signalingPort = Int(text(values["port"]) ?? "") else { return }
        onService(BonjourResolvedRecord(
            hostID: hostID,
            pin: pin,
            signalingPort: signalingPort,
            quality: text(values["quality"]) ?? "",
            latency: text(values["latency"]) ?? "",
            hostIP: text(values["hostIP"]) ?? sender.hostName ?? ""
        ))
    }

    private func text(_ value: Data?) -> String? {
        guard let value else { return nil }
        return String(data: value, encoding: .utf8)
    }
}

public actor BonjourServiceDiscovery {
    public var onServiceFound: ((BonjourService) -> Void)?
    public var onDiscoveryComplete: (() -> Void)?

    private var services: [BonjourService] = []
    private var browser: NetServiceBrowser?
    private var delegate: BonjourDiscoveryDelegate?
    private var discoveryActive = false

    public init() {}

    public func startDiscovery(timeout: TimeInterval = 5.0) async {
        guard !discoveryActive else { return }
        discoveryActive = true
        services.removeAll()

        let browser = NetServiceBrowser()
        let delegate = BonjourDiscoveryDelegate(
            onService: { [weak self] record in
                Task { await self?.handleResolvedService(record) }
            },
            onStop: { [weak self] in
                Task { await self?.finishDiscovery() }
            }
        )
        self.browser = browser
        self.delegate = delegate
        browser.delegate = delegate
        browser.searchForServices(ofType: "_pixelnow-remote-coop._tcp.", inDomain: "local.")

        do {
            try await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
        } catch {
            finishDiscovery()
            return
        }
        finishDiscovery()
    }

    public func stopDiscovery() {
        finishDiscovery()
    }

    public func getServices() -> [BonjourService] {
        services
    }

    public func addService(_ service: BonjourService) {
        guard !services.contains(where: { $0.id == service.id }) else { return }
        services.append(service)
        onServiceFound?(service)
    }

    public func discoverServices() async -> [BonjourService] {
        await startDiscovery()
        return services
    }

    private func finishDiscovery() {
        guard discoveryActive else { return }
        discoveryActive = false
        browser?.stop()
        browser?.delegate = nil
        browser = nil
        delegate = nil
        onDiscoveryComplete?()
    }

    private func handleResolvedService(_ record: BonjourResolvedRecord) {
        guard let hostID = UUID(uuidString: record.hostID) else { return }
        let discovered = BonjourService(
            hostID: hostID,
            pin: record.pin,
            signalingPort: record.signalingPort,
            quality: record.quality,
            latency: record.latency,
            hostIP: record.hostIP
        )
        addService(discovered)
    }
}
