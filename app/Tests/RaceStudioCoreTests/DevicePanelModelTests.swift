#if canImport(RaceStudioFFIBindings)
import Testing
import Foundation
@testable import RaceStudioCore
import RaceStudioFFIBindings

/// State-machine tests for the device panel (issues 6.7, #179). The model is
/// driven through an injected ``DeviceService`` fake fed by the committed
/// goldens — the device from `discovery.json`, the sessions from the
/// de-identified catalog `catalog.json` — and a spy importer, so every
/// behaviour is deterministic and device-free.
@MainActor
@Suite struct DevicePanelModelTests {

    // MARK: - discovery and catalog

    @Test func test_initial_state_is_idle() {
        let model = DevicePanelModel(service: FakeDeviceService(), importer: FakeSessionImporter())

        #expect(model.state == .idle)
    }

    @Test func test_search_lists_discovered_devices() async throws {
        let device = try DevicePanelFixtures.goldenDevice()
        let model = DevicePanelModel(
            service: FakeDeviceService(devices: .success([device])), importer: FakeSessionImporter())

        await model.loadDevices()

        #expect(model.state == .devices([device]))
    }

    @Test func test_search_closes_any_open_connection_first() async {
        let service = FakeDeviceService()
        let model = DevicePanelModel(service: service, importer: FakeSessionImporter())

        await model.loadDevices()

        #expect(service.disconnectCount == 1)
    }

    @Test func test_search_records_when_the_mac_is_off_the_device_network() async {
        let model = DevicePanelModel(
            service: FakeDeviceService(), importer: FakeSessionImporter(), isOnDeviceNetwork: { false })

        await model.loadDevices()

        #expect(model.onDeviceNetwork == false)
    }

    @Test func test_failed_search_shows_its_message() async {
        let model = DevicePanelModel(
            service: FakeDeviceService(devices: .failure(DiscoveryError.NoService(message: "no responder"))),
            importer: FakeSessionImporter())

        await model.loadDevices()

        #expect(model.state == .failed("no responder"))
    }

    @Test func test_selecting_a_device_shows_its_stored_sessions() async throws {
        let harness = try await DevicePanelFixtures.atSessions()

        #expect(harness.model.state == .sessions(harness.device, harness.sessions))
    }

    @Test func test_golden_catalog_lists_six_sessions_newest_first() async throws {
        let sessions = try DevicePanelFixtures.goldenSessions()

        #expect(sessions.map(\.fileName) == [
            "a_0062.xrz", "a_0061.xrz", "a_0060.xrz", "a_0059.xrz", "a_0058.xrz", "a_0057.xrz"
        ])
    }

    @Test func test_device_with_no_sessions_shows_an_empty_table() async throws {
        let device = try DevicePanelFixtures.goldenDevice()
        let model = DevicePanelModel(
            service: FakeDeviceService(devices: .success([device])), importer: FakeSessionImporter())
        await model.loadDevices()

        await model.select(device)

        #expect(model.state == .sessions(device, []))
    }

    @Test func test_select_is_ignored_unless_devices_are_listed() async throws {
        let model = DevicePanelModel(service: FakeDeviceService(), importer: FakeSessionImporter())

        await model.select(try DevicePanelFixtures.goldenDevice())

        #expect(model.state == .idle)
    }

    @Test func test_connection_failure_off_network_says_how_to_join() async throws {
        let device = try DevicePanelFixtures.goldenDevice()
        let model = DevicePanelModel(
            service: FakeDeviceService(
                devices: .success([device]),
                catalog: .failure(DiscoveryError.ConnectionFailed(message: "refused"))),
            importer: FakeSessionImporter(), isOnDeviceNetwork: { false })
        await model.loadDevices()

        await model.select(device)

        #expect(model.state == .failed(
            "Couldn’t connect to the MyChron. \(DevicePanelModel.joinNetworkHint)"))
    }

    @Test func test_connection_failure_on_network_has_no_join_hint() async throws {
        let device = try DevicePanelFixtures.goldenDevice()
        let model = DevicePanelModel(
            service: FakeDeviceService(
                devices: .success([device]), catalog: .failure(DiscoveryError.Timeout(message: "t"))),
            importer: FakeSessionImporter())
        await model.loadDevices()

        await model.select(device)

        #expect(model.state == .failed("The MyChron stopped responding."))
    }

    @Test func test_no_route_on_the_device_network_points_to_local_network_privacy() async throws {
        let device = try DevicePanelFixtures.goldenDevice()
        let model = DevicePanelModel(
            service: FakeDeviceService(
                devices: .success([device]),
                catalog: .failure(DiscoveryError.HostUnreachable(message: "no route"))),
            importer: FakeSessionImporter())
        await model.loadDevices()

        await model.select(device)

        #expect(model.state == .failed(DevicePanelModel.localNetworkHint))
    }

    @Test func test_no_route_off_the_device_network_says_how_to_join() async throws {
        let device = try DevicePanelFixtures.goldenDevice()
        let model = DevicePanelModel(
            service: FakeDeviceService(
                devices: .success([device]),
                catalog: .failure(DiscoveryError.HostUnreachable(message: "no route"))),
            importer: FakeSessionImporter(), isOnDeviceNetwork: { false })
        await model.loadDevices()

        await model.select(device)

        #expect(model.state == .failed(
            "Couldn’t reach the MyChron. \(DevicePanelModel.joinNetworkHint)"))
    }

    @Test func test_network_is_checked_again_when_an_error_happens() async throws {
        let device = try DevicePanelFixtures.goldenDevice()
        var joined = true
        let model = DevicePanelModel(
            service: FakeDeviceService(
                devices: .success([device]),
                catalog: .failure(DiscoveryError.Timeout(message: "t"))),
            importer: FakeSessionImporter(), isOnDeviceNetwork: { joined })
        await model.loadDevices()
        joined = false

        await model.select(device)

        #expect(model.state == .failed("The MyChron stopped responding. \(DevicePanelModel.joinNetworkHint)"))
    }

    @Test func test_closed_connection_is_explained() async throws {
        let device = try DevicePanelFixtures.goldenDevice()
        let model = DevicePanelModel(
            service: FakeDeviceService(
                devices: .success([device]),
                catalog: .failure(DiscoveryError.ConnectionClosed(message: "c"))),
            importer: FakeSessionImporter())
        await model.loadDevices()

        await model.select(device)

        #expect(model.state == .failed("The MyChron closed the connection."))
    }

    @Test func test_refresh_reads_the_catalog_again() async throws {
        let harness = try await DevicePanelFixtures.atSessions()

        await harness.model.refresh()

        #expect(harness.model.state == .sessions(harness.device, harness.sessions))
    }

    @Test func test_refresh_is_ignored_without_a_table() async {
        let model = DevicePanelModel(service: FakeDeviceService(), importer: FakeSessionImporter())

        await model.refresh()

        #expect(model.state == .idle)
    }

    // MARK: - closing and resetting

    @Test func test_close_disconnects() async throws {
        let harness = try await DevicePanelFixtures.atSessions()

        await harness.model.close()

        #expect(harness.service.disconnectCount == 2)
    }

    @Test func test_close_cancels_a_running_queue() async throws {
        let harness = try await DevicePanelFixtures.atSessions(holdsDownloads: true)
        let queue = Task { await harness.model.download([harness.sessions[0]]) }
        await DevicePanelFixtures.untilDownloading(harness)

        await harness.model.close()
        await queue.value

        #expect(harness.service.cancelCount == 1)
    }

    @Test func test_reset_returns_to_idle_from_a_failure() async {
        let model = DevicePanelModel(
            service: FakeDeviceService(devices: .failure(DiscoveryError.NoService(message: "none"))),
            importer: FakeSessionImporter())
        await model.loadDevices()

        model.reset()

        #expect(model.state == .idle)
    }

    @Test func test_non_device_error_uses_its_description() async throws {
        struct Unreadable: Error, LocalizedError { var errorDescription: String? { "unreadable" } }
        let model = DevicePanelModel(
            service: FakeDeviceService(devices: .failure(Unreadable())), importer: FakeSessionImporter())

        await model.loadDevices()

        #expect(model.state == .failed("unreadable"))
    }
}
#endif
