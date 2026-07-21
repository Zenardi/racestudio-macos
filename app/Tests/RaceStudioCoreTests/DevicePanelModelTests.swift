#if canImport(RaceStudioFFIBindings)
import Testing
import Foundation
import Combine
@testable import RaceStudioCore
import RaceStudioFFIBindings

/// State-machine tests for issue 6.7 — the ``DevicePanelModel`` that backs the
/// device panel UI. The model is driven through an injected ``DeviceService``
/// fake fed by the committed golden fixtures (device from `discovery.json`, the
/// empty session list from `sessions.json`) plus clearly-synthetic session rows,
/// so every behaviour is deterministic and device-free — no live MyChron, no
/// networking. The thin SwiftUI shell (`DevicePanelView`) is excluded from the
/// coverage metric; all tested logic lives here in `RaceStudioCore`.
///
/// Compiled only when the xcframework is built (the model names the FFI record
/// types `Device` / `SessionInfo` / `DeleteConfirmation`).
@MainActor
@Suite struct DevicePanelModelTests {

    // MARK: - fixtures

    /// The golden device parsed from the recorded 6.3 discovery response
    /// (`fixtures/device/golden/discovery.json`).
    private static func goldenDevice() throws -> Device {
        struct GoldenDiscovery: Decodable { let devices: [Row] }
        struct Row: Decodable {
            let name: String
            let address: String
            let port: UInt16
            let model: String
        }
        let url = FixtureLoader.fixturesDir()
            .appendingPathComponent("device/golden/discovery.json")
        let golden = try JSONDecoder().decode(GoldenDiscovery.self, from: Data(contentsOf: url))
        let row = try #require(golden.devices.first)
        return Device(name: row.name, address: row.address, port: row.port, model: row.model)
    }

    /// The recorded on-device session list — genuinely **empty**: the MyChron6
    /// held 0 on-board sessions at 6.2 capture time (`sessions.json`, #130). Used
    /// to drive the empty-state path with the honest recorded reality.
    private static func goldenSessions() throws -> [SessionInfo] {
        struct GoldenSessions: Decodable { let sessionCount: Int; let sessions: [Row] }
        struct Row: Decodable {}
        let url = FixtureLoader.fixturesDir()
            .appendingPathComponent("device/golden/sessions.json")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let golden = try decoder.decode(GoldenSessions.self, from: Data(contentsOf: url))
        // The fixture must stay empty until a session-present re-capture (#130).
        #expect(golden.sessionCount == 0)
        return []
    }

    /// Clearly-synthetic session rows for exercising a non-empty table — the
    /// recorded capture had 0 sessions (#130), so the per-session decode path is
    /// driven with labelled synthetic rows (the same approach `session_test.rs`
    /// uses on the Rust side).
    private static func syntheticSessions() -> [SessionInfo] {
        [
            SessionInfo(
                id: 7, name: "SYNTHETIC_A",
                date: SessionDate(year: 2026, month: 7, day: 21, hour: 10, minute: 30, second: 0),
                lapCount: 12, sizeBytes: 4096
            ),
            SessionInfo(
                id: 8, name: "SYNTHETIC_B",
                date: SessionDate(year: 2026, month: 7, day: 21, hour: 11, minute: 0, second: 0),
                lapCount: 8, sizeBytes: 2048
            )
        ]
    }

    /// Advance a fresh model to `.sessions(device, sessions)` for the tests that
    /// start from a populated session table.
    private static func modelAtSessions(
        _ sessions: [SessionInfo],
        service: FakeDeviceService? = nil
    ) async throws -> (DevicePanelModel, FakeDeviceService) {
        let device = try goldenDevice()
        let svc = service ?? FakeDeviceService(devices: .success([device]), sessions: .success(sessions))
        let model = DevicePanelModel(service: svc)
        await model.loadDevices()
        await model.select(device)
        guard case .sessions = model.state else {
            Issue.record("expected model to reach .sessions, got \(model.state)")
            throw CancellationError()
        }
        return (model, svc)
    }

    // MARK: - discovery + enumeration (Goal: list devices → session table)

    @Test func test_devices_listed_on_load() async throws {
        // Given a service that discovers the golden device, When the panel loads,
        // Then it lists that device.
        let device = try Self.goldenDevice()
        let model = DevicePanelModel(service: FakeDeviceService(devices: .success([device])))

        await model.loadDevices()

        #expect(model.state == .devices([device]))
    }

    @Test func test_selecting_device_enumerates_sessions() async throws {
        // Selecting a device enumerates and renders its session table.
        let device = try Self.goldenDevice()
        let sessions = Self.syntheticSessions()
        let model = DevicePanelModel(service: FakeDeviceService(
            devices: .success([device]), sessions: .success(sessions)))

        await model.loadDevices()
        await model.select(device)

        #expect(model.state == .sessions(device, sessions))
    }

    @Test func test_empty_session_list_renders_empty_state() async throws {
        // The recorded device has 0 sessions → a deterministic empty session table.
        let device = try Self.goldenDevice()
        let model = DevicePanelModel(service: FakeDeviceService(
            devices: .success([device]), sessions: .success(try Self.goldenSessions())))

        await model.loadDevices()
        await model.select(device)

        guard case let .sessions(_, list) = model.state else {
            Issue.record("expected .sessions, got \(model.state)")
            return
        }
        #expect(list.isEmpty)
    }

    @Test func test_discovery_failure_sets_error_state() async throws {
        // A discovery failure surfaces as a typed error state, never a trap.
        let model = DevicePanelModel(service: FakeDeviceService(
            devices: .failure(DiscoveryError.NoService(message: "no responder"))))

        await model.loadDevices()

        guard case let .failed(message) = model.state else {
            Issue.record("expected .failed, got \(model.state)")
            return
        }
        // The carried message is surfaced (not a String(reflecting:) debug dump).
        #expect(message == "no responder")
    }

    @Test func test_enumeration_failure_sets_error_state() async throws {
        // An enumeration failure surfaces as a typed error state.
        let device = try Self.goldenDevice()
        let model = DevicePanelModel(service: FakeDeviceService(
            devices: .success([device]),
            sessions: .failure(DiscoveryError.BadChecksum(message: "bad frame"))))

        await model.loadDevices()
        await model.select(device)

        guard case .failed = model.state else {
            Issue.record("expected .failed, got \(model.state)")
            return
        }
    }

    @Test func test_non_discovery_error_maps_to_failed_state() async throws {
        // A non-DiscoveryError still maps cleanly to `.failed` (localizedDescription
        // fallback), never trapping.
        struct GenericError: Error {}
        let model = DevicePanelModel(service: FakeDeviceService(devices: .failure(GenericError())))

        await model.loadDevices()

        guard case .failed = model.state else {
            Issue.record("expected .failed, got \(model.state)")
            return
        }
    }

    // MARK: - download (Goal: progress 0→100% → done / typed error)

    @Test func test_download_advances_progress_to_complete() async throws {
        let device = try Self.goldenDevice()
        let payload = Data((0..<128).map { UInt8($0 % 256) })
        let (model, _) = try await Self.modelAtSessions(
            Self.syntheticSessions(),
            service: FakeDeviceService(
                devices: .success([device]),
                sessions: .success(Self.syntheticSessions()),
                download: .success(payload),
                progress: [0.25, 0.5, 1.0]))
        let session = Self.syntheticSessions()[0]

        // Record every state the model passes through so we can assert progress
        // advanced monotonically to 100% before completion.
        var recorded: [DevicePanelState] = []
        let cancellable = model.$state.sink { recorded.append($0) }
        await model.download(session)
        cancellable.cancel()

        #expect(model.state == .downloaded(device, session, data: payload))
        let progresses = recorded.compactMap { state -> Double? in
            if case let .downloading(_, _, fraction) = state { return fraction }
            return nil
        }
        #expect(progresses.first == 0)                 // starts at 0%
        #expect(progresses.last == 1.0)                // reaches 100%
        #expect(progresses == progresses.sorted())     // monotonic, never regresses
    }

    @Test func test_download_failure_sets_error_state() async throws {
        let (model, _) = try await Self.modelAtSessions(
            Self.syntheticSessions(),
            service: FakeDeviceService(
                devices: .success([try Self.goldenDevice()]),
                sessions: .success(Self.syntheticSessions()),
                download: .failure(DiscoveryError.ChecksumMismatch(message: "corrupt")),
                progress: []))

        await model.download(Self.syntheticSessions()[0])

        guard case .failed = model.state else {
            Issue.record("expected .failed, got \(model.state)")
            return
        }
    }

    // MARK: - guarded delete (Goal: name confirmation gates the 6.6 API)

    @Test func test_delete_requires_name_confirmation() async throws {
        let device = try Self.goldenDevice()
        let sessions = Self.syntheticSessions()
        let target = sessions[0]
        let (model, spy) = try await Self.modelAtSessions(sessions)

        // Tapping Delete arms the confirmation dialog (nothing sent yet).
        model.requestDeletion(of: target)
        #expect(model.pendingDeletion == target)

        // A WRONG name never calls the guarded API — zero delete calls.
        await model.confirmDeletion(typedName: "not the name")
        #expect(spy.deleteCalls.isEmpty, "a mismatched name must send nothing")
        #expect(model.pendingDeletion == target, "the dialog stays open on mismatch")

        // The MATCHING name calls the guarded 6.6 API exactly once, armed, with a
        // confirmation that matches the target (so the core guard also passes) and
        // routed to the device the dialog was armed against, then removes the
        // session and clears the pending dialog.
        await model.confirmDeletion(typedName: target.name)
        #expect(spy.deleteCalls.count == 1)
        let call = try #require(spy.deleteCalls.first)
        #expect(call.confirmation == DeleteConfirmation(sessionId: target.id, expectedName: target.name))
        #expect(call.armed == true)
        #expect(call.target == target)
        #expect(call.device == device, "the delete is routed to the armed device")
        #expect(model.pendingDeletion == nil)
        #expect(model.state == .sessions(device, [sessions[1]]))
    }

    @Test func test_cancel_delete_sends_nothing() async throws {
        let device = try Self.goldenDevice()
        let sessions = Self.syntheticSessions()
        let (model, spy) = try await Self.modelAtSessions(sessions)

        model.requestDeletion(of: sessions[0])
        model.cancelDeletion()

        #expect(spy.deleteCalls.isEmpty, "Cancel must send nothing")
        #expect(model.pendingDeletion == nil)
        #expect(model.state == .sessions(device, sessions), "Cancel returns to the intact table")
    }

    @Test func test_delete_failure_sets_error_state() async throws {
        let sessions = Self.syntheticSessions()
        let target = sessions[0]
        let spy = FakeDeviceService(
            devices: .success([try Self.goldenDevice()]),
            sessions: .success(sessions),
            delete: .failure(DiscoveryError.DeleteRejected(message: "device refused")))
        let (model, _) = try await Self.modelAtSessions(sessions, service: spy)

        model.requestDeletion(of: target)
        await model.confirmDeletion(typedName: target.name)

        #expect(spy.deleteCalls.count == 1, "one attempt, no blind retry")
        guard case .failed = model.state else {
            Issue.record("expected .failed, got \(model.state)")
            return
        }
    }

    // MARK: - state-machine safety (illegal transitions are unrepresentable)

    @Test func test_illegal_state_transitions_rejected() async throws {
        // From the initial idle state, none of the mid-flow actions may fire — no
        // service traffic, no state corruption.
        let device = try Self.goldenDevice()
        let spy = FakeDeviceService(
            devices: .success([device]), sessions: .success(Self.syntheticSessions()))
        let model = DevicePanelModel(service: spy)

        await model.select(device)                           // no device list yet
        await model.download(Self.syntheticSessions()[0])    // no session table yet
        model.requestDeletion(of: Self.syntheticSessions()[0])
        await model.confirmDeletion(typedName: "SYNTHETIC_A") // no pending deletion
        model.cancelDeletion()                                // nothing to cancel

        #expect(model.state == .idle, "illegal transitions leave the state untouched")
        #expect(model.pendingDeletion == nil)
        #expect(spy.downloadCalls.isEmpty)
        #expect(spy.deleteCalls.isEmpty)
    }

    @Test func test_navigation_ignored_while_confirming() async throws {
        // A destructive-write safety regression: while a delete confirmation is
        // armed, navigation (loadDevices) and reset are ignored, so the armed
        // confirmation can never be silently dropped or re-bound to another device.
        let device = try Self.goldenDevice()
        let sessions = Self.syntheticSessions()
        let (model, spy) = try await Self.modelAtSessions(sessions)
        model.requestDeletion(of: sessions[0])

        await model.loadDevices()
        model.reset()

        guard case let .confirmingDeletion(confirmDevice, _, target) = model.state else {
            Issue.record("expected the armed confirmation to survive, got \(model.state)")
            return
        }
        #expect(confirmDevice == device)
        #expect(target == sessions[0])
        #expect(spy.deleteCalls.isEmpty)
    }

    @Test func test_reset_returns_to_idle() async throws {
        let (model, _) = try await Self.modelAtSessions(Self.syntheticSessions())

        model.reset()

        #expect(model.state == .idle)
        #expect(model.pendingDeletion == nil)
    }
}
#endif
