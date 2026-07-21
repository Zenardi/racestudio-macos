#if canImport(RaceStudioFFIBindings)
import Testing
import Foundation
import Network
@testable import RaceStudioCore
import RaceStudioFFIBindings

/// Discovery tests for issue 6.3. These run **end-to-end across the FFI
/// boundary**: recorded discovery bytes are parsed by the real Rust core
/// (`parseDeviceDiscovery`) and surface as Swift ``Device`` values, and the
/// `NWBrowser`→``Device`` mapping is exercised against constructed endpoints —
/// all with no live device attached. Compiled only when the xcframework is built.
@Suite struct BonjourBrowserTests {

    /// Repo-root-relative path (up from app/Tests/RaceStudioCoreTests/).
    private static func repoFixture(_ relative: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // RaceStudioCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // app
            .deletingLastPathComponent() // repo root
            .appendingPathComponent(relative)
    }

    /// The recorded, de-identified discovery response fixture (issue 6.2/6.3).
    private static func recordedResponse() throws -> Data {
        try Data(contentsOf: repoFixture("fixtures/device/discovery/response.bin"))
    }

    /// A browser that replays recorded discovery bytes through the Rust parser —
    /// the injected fixture stand-in for a live mDNS/AP responder.
    private struct ReplayBrowser: DeviceBrowsing {
        let bytes: Data
        func browse() async throws -> [Device] { try parseDiscovery(bytes) }
    }

    /// A browser that finds nothing — exercises the AP-mode fallback.
    private struct EmptyBrowser: DeviceBrowsing {
        func browse() async throws -> [Device] { [] }
    }

    // MARK: - end-to-end across the FFI boundary

    @Test func test_browser_trait_replays_recorded_fixtures() async throws {
        // Given the recorded response replayed through the injected browser, When
        // discovery runs, Then the Rust core yields the typed device (no fallback).
        let browser = ReplayBrowser(bytes: try Self.recordedResponse())

        let devices = try await discoverDevices(using: browser)

        #expect(devices.count == 1)
        let device = try #require(devices.first)
        #expect(device.address == "10.0.0.1")
        #expect(device.port == 2000)
        #expect(device.model == "MyChron")
        #expect(!device.name.isEmpty)
    }

    @Test func test_ap_mode_fallback_when_no_responder() async throws {
        // With no announcements, discovery yields the well-known AP gateway device.
        let devices = try await discoverDevices(using: EmptyBrowser())

        #expect(devices == [apModeFallback()])
        let gateway = try #require(devices.first)
        #expect(gateway.address == "10.0.0.1")
        #expect(gateway.port == 2000)
    }

    @Test func test_malformed_bytes_throw_discovery_error() throws {
        // A truncated buffer is a thrown DiscoveryError over the boundary — no trap.
        #expect(throws: (any Error).self) {
            try parseDiscovery(Data([0x01, 0x02, 0x03]))
        }
    }

    @Test func test_duplicate_announcements_deduplicated_over_ffi() throws {
        // Two identical announcements collapse to one device (Rust-side dedup).
        var doubled = try Self.recordedResponse()
        doubled.append(try Self.recordedResponse())
        let devices = try parseDiscovery(doubled)
        #expect(devices.count == 1)
    }

    // MARK: - pure NWBrowser → Device mapping (no live device)

    @Test func test_model_parsed_from_service_name() {
        #expect(BonjourBrowser.model(from: "AiM-MYC6-002652") == "MYC6")
        #expect(BonjourBrowser.model(from: "AiM-MYC5-000123") == "MYC5")
        // An unrecognised single-token name falls back to the family label.
        #expect(BonjourBrowser.model(from: "MyChron") == "MyChron")
    }

    @Test func test_service_name_extracted_only_from_service_endpoints() {
        let service = NWEndpoint.service(
            name: "AiM-MYC6-002652",
            type: BonjourBrowser.serviceType,
            domain: "local.",
            interface: nil
        )
        #expect(BonjourBrowser.serviceName(of: service) == "AiM-MYC6-002652")

        let hostPort = NWEndpoint.hostPort(host: "10.0.0.1", port: 2000)
        #expect(BonjourBrowser.serviceName(of: hostPort) == nil)
    }

    @Test func test_device_mapped_from_service_fields() {
        let device = BonjourBrowser.device(
            serviceName: "AiM-MYC6-002652",
            address: "10.0.0.1",
            port: 2000
        )
        #expect(device == Device(
            name: "AiM-MYC6-002652",
            address: "10.0.0.1",
            port: 2000,
            model: "MYC6"
        ))
    }

    @Test func test_endpoints_map_and_deduplicate() {
        let gateway = apModeFallback()
        let service = NWEndpoint.service(
            name: "AiM-MYC6-002652",
            type: BonjourBrowser.serviceType,
            domain: "local.",
            interface: nil
        )
        let hostPort = NWEndpoint.hostPort(host: "10.0.0.1", port: 2000) // ignored

        let devices = BonjourBrowser.devices(
            for: [service, service, hostPort],
            gateway: gateway
        )

        #expect(devices.count == 1, "identical services de-duplicate; non-service ignored")
        #expect(devices.first?.model == "MYC6")
        #expect(devices.first?.address == gateway.address)
    }

    @Test func test_browse_maps_injected_endpoints_and_deduplicates() async throws {
        // Inject an endpoint source (no live NWBrowser): browse() maps + dedups.
        let service = NWEndpoint.service(
            name: "AiM-MYC6-002652",
            type: BonjourBrowser.serviceType,
            domain: "local.",
            interface: nil
        )
        let browser = BonjourBrowser(endpointSource: { _ in [service, service] })

        let devices = try await browser.browse()

        #expect(devices.count == 1)
        #expect(devices.first?.model == "MYC6")
    }

    @Test func test_browse_with_no_endpoints_yields_empty_then_coordinator_falls_back() async throws {
        // browse() alone returns [] when nothing is advertised; the coordinator is
        // what turns that into the AP-mode fallback.
        let browser = BonjourBrowser(endpointSource: { _ in [] })

        #expect(try await browser.browse().isEmpty)
        #expect(try await discoverDevices(using: browser) == [apModeFallback()])
    }

    @Test func test_endpoint_collector_snapshots_last_batch() {
        let collector = EndpointCollector()
        #expect(collector.snapshot().isEmpty)

        let service = NWEndpoint.service(
            name: "AiM-MYC6-1", type: BonjourBrowser.serviceType, domain: "local.", interface: nil
        )
        collector.update([service])
        #expect(collector.snapshot().count == 1)
    }
}
#endif
