#if canImport(RaceStudioFFIBindings)
import Foundation
import Network
import os
import RaceStudioFFIBindings

/// Live mDNS/Bonjour discovery adapter (issue 6.3): browses for the MyChron's
/// advertised service via `NWBrowser` and maps each result into a ``Device``.
///
/// This is the thin I/O adapter — the discovery *logic* (parsing, selection,
/// AP-mode fallback) lives in `DeviceDiscovery.swift` and the Rust core. The
/// endpoint→``Device`` mapping here is pure and unit-tested against constructed
/// `NWEndpoint`s; only the `NWBrowser` event loop is untested live glue, so no
/// device is required to exercise the mapping.
public struct BonjourBrowser: DeviceBrowsing {

    /// The Bonjour service type to browse for.
    ///
    /// - Important: **Unverified.** The discovery mechanism proven by the 6.2
    ///   capture is the proprietary **UDP 36002 `aim-ka`** exchange
    ///   (`docs/device/PROTOCOL.md` §2) — *not* an mDNS/Bonjour advertisement.
    ///   No capture yet confirms the MyChron advertises any Bonjour service, so
    ///   this type is a placeholder to be confirmed against a live LAN capture
    ///   (see the 6.3 caveat in `PROTOCOL.md`). Until then the live browse below
    ///   surfaces its terminal state via ``logger`` and callers fall back to
    ///   AP mode; the *verified* discovery path is `parseDiscovery` over the
    ///   recorded UDP-36002 response.
    public static let serviceType = "_aim-stcp._tcp"

    /// Diagnostics for the live browser so a failed/denied browse (e.g. the macOS
    /// Local Network permission being refused) is observable rather than silently
    /// indistinguishable from "no devices found".
    private static let logger = Logger(subsystem: "RaceStudioCore", category: "discovery")

    /// How long to browse before returning what was found.
    public let browseWindow: Duration

    /// Source of raw service endpoints. Injectable so the `browse()` orchestration
    /// (mapping + de-duplication) is testable without a live `NWBrowser`; the
    /// default is the live browser.
    private let endpointSource: @Sendable (Duration) async throws -> [NWEndpoint]

    public init(browseWindow: Duration = .seconds(2)) {
        self.browseWindow = browseWindow
        self.endpointSource = BonjourBrowser.liveEndpoints
    }

    /// Test seam: browse a caller-supplied endpoint source instead of `NWBrowser`.
    init(
        browseWindow: Duration = .seconds(2),
        endpointSource: @escaping @Sendable (Duration) async throws -> [NWEndpoint]
    ) {
        self.browseWindow = browseWindow
        self.endpointSource = endpointSource
    }

    // MARK: - Pure mapping (unit-tested; no live device required)

    /// The device family parsed from a Bonjour instance name such as
    /// `AiM-MYC6-002652` → `MYC6`; an unrecognised shape falls back to the family
    /// label `MyChron`.
    static func model(from serviceName: String) -> String {
        let parts = serviceName.split(separator: "-")
        return parts.count >= 2 ? String(parts[1]) : "MyChron"
    }

    /// The Bonjour instance name of a service endpoint, or `nil` for a
    /// non-service (already host/port-resolved) endpoint.
    static func serviceName(of endpoint: NWEndpoint) -> String? {
        if case let .service(name, _, _, _) = endpoint {
            return name
        }
        return nil
    }

    /// Map a discovered service to a ``Device`` at `address`/`port`. In the AiM
    /// AP-mode topology the device is its own gateway, so the gateway address/port
    /// are used; full LAN endpoint resolution is deferred to the 6.5 connect step.
    /// The instance name becomes the display name, and its middle token the model.
    static func device(serviceName: String, address: String, port: UInt16) -> Device {
        Device(
            name: serviceName,
            address: address,
            port: port,
            model: model(from: serviceName)
        )
    }

    /// Map a batch of browse endpoints to de-duplicated devices, using `gateway`
    /// for the address/port. Pure over the endpoints; `NWBrowser` only supplies
    /// them. The result is sorted by name so ordering is stable run-to-run (the
    /// browser delivers an unordered `Set`).
    static func devices(for endpoints: [NWEndpoint], gateway: Device) -> [Device] {
        var mapped: [Device] = []
        for endpoint in endpoints {
            guard let name = serviceName(of: endpoint) else { continue }
            let candidate = device(serviceName: name, address: gateway.address, port: gateway.port)
            if !mapped.contains(candidate) {
                mapped.append(candidate)
            }
        }
        return mapped.sorted { $0.name < $1.name }
    }

    // MARK: - Live NWBrowser adapter (thin I/O glue)

    public func browse() async throws -> [Device] {
        let endpoints = try await endpointSource(browseWindow)
        return BonjourBrowser.devices(for: endpoints, gateway: apModeFallback())
    }

    /// Start an `NWBrowser`, collect the advertised service endpoints over
    /// `window`, then stop. Untested live glue — the mapping/orchestration above
    /// is the covered logic. Honors task cancellation (the sleep propagates
    /// `CancellationError`) and always cancels the browser on the way out.
    private static let liveEndpoints: @Sendable (Duration) async throws -> [NWEndpoint] = { window in
        let browser = NWBrowser(
            for: .bonjour(type: BonjourBrowser.serviceType, domain: nil),
            using: NWParameters()
        )
        let collector = EndpointCollector()
        browser.stateUpdateHandler = { state in
            if case let .failed(error) = state {
                BonjourBrowser.logger.error(
                    "NWBrowser failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        browser.browseResultsChangedHandler = { results, _ in
            collector.update(results.map(\.endpoint))
        }
        browser.start(queue: .global())
        defer { browser.cancel() }
        try await Task.sleep(for: window)
        return collector.snapshot()
    }
}

/// A tiny thread-safe box the `NWBrowser` handler writes discovered endpoints
/// into — paired with ``BonjourBrowser``'s live glue.
final class EndpointCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var endpoints: [NWEndpoint] = []

    /// Replace the collected endpoints with the browser's latest batch.
    func update(_ latest: [NWEndpoint]) {
        lock.lock()
        defer { lock.unlock() }
        endpoints = latest
    }

    /// A snapshot of the currently-collected endpoints.
    func snapshot() -> [NWEndpoint] {
        lock.lock()
        defer { lock.unlock() }
        return endpoints
    }
}
#endif
