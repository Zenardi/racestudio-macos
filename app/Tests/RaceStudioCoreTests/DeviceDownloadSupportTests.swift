#if canImport(RaceStudioFFIBindings)
import Testing
import Foundation
@testable import RaceStudioCore
import RaceStudioFFIBindings

/// A stored session with every optional field set, for the display tests.
private func session(
    fileName: String = "a_0061.xrz", track: String = "Kartodromo",
    bestLapNumber: UInt16? = 2, bestLapMs: UInt32? = 53_951,
    durationMs: UInt32? = 1_294_498, sizeBytes: UInt32 = 3_866_208
) -> DeviceSession {
    DeviceSession(
        fileName: fileName, sizeBytes: sizeBytes,
        date: RaceStudioFFIBindings.SessionDate(year: 2025, month: 7, day: 11, hour: 17, minute: 45, second: 28),
        lapCount: 23, bestLapNumber: bestLapNumber, bestLapMs: bestLapMs,
        driver: "", trackName: track, vehicle: "", championship: "",
        durationMs: durationMs, trackLatitude: nil, trackLongitude: nil)
}

/// Issue #179 — how a stored session is shown, and named once downloaded.
@Suite struct DeviceSessionTextTests {

    @Test func test_session_is_identified_by_its_file_name() {
        #expect(session().id == "a_0061.xrz")
    }

    @Test func test_date_is_the_logger_local_time() {
        #expect(DeviceSessionText.date(session()) == "2025-07-11 17:45:28")
    }

    @Test func test_track_name_is_shown() {
        #expect(DeviceSessionText.track(session()) == "Kartodromo")
    }

    @Test func test_missing_track_shows_the_placeholder() {
        #expect(DeviceSessionText.track(session(track: "")) == DeviceSessionText.placeholder)
    }

    @Test func test_best_lap_shows_time_and_lap_number() {
        #expect(DeviceSessionText.bestLap(session()) == "0:53.951 (lap 2)")
    }

    @Test func test_best_lap_without_a_lap_number_shows_the_time() {
        #expect(DeviceSessionText.bestLap(session(bestLapNumber: nil)) == "0:53.951")
    }

    @Test func test_untimed_session_shows_the_placeholder_best_lap() {
        #expect(DeviceSessionText.bestLap(session(bestLapMs: nil)) == DeviceSessionText.placeholder)
    }

    @Test func test_duration_under_an_hour_is_minutes_and_seconds() {
        #expect(DeviceSessionText.duration(session()) == "21:34")
    }

    @Test func test_duration_over_an_hour_includes_hours() {
        #expect(DeviceSessionText.duration(session(durationMs: 3_723_000)) == "1:02:03")
    }

    @Test func test_missing_duration_shows_the_placeholder() {
        #expect(DeviceSessionText.duration(session(durationMs: nil)) == DeviceSessionText.placeholder)
    }

    @Test(arguments: [
        (UInt32(3_866_208), "3.9 MB"),
        (UInt32(62_329), "62 KB"),
        (UInt32(512), "512 B")
    ])
    func test_size_uses_decimal_units(bytes: UInt32, expected: String) {
        #expect(DeviceSessionText.size(session(sizeBytes: bytes)) == expected)
    }

    @Test func test_library_name_is_date_and_track() {
        #expect(DeviceSessionText.libraryFileName(session()) == "2025-07-11 17-45-28 Kartodromo.xrk")
    }

    @Test func test_library_name_replaces_path_characters() {
        #expect(DeviceSessionText.libraryFileName(session(track: "A/B:C"))
            == "2025-07-11 17-45-28 A-B-C.xrk")
    }

    @Test func test_library_name_replaces_control_characters() {
        #expect(DeviceSessionText.libraryFileName(session(track: "A\u{0}B\nC"))
            == "2025-07-11 17-45-28 A-B-C.xrk")
    }

    @Test func test_library_name_caps_a_long_track() {
        let name = DeviceSessionText.libraryFileName(session(track: String(repeating: "x", count: 300)))

        #expect(name == "2025-07-11 17-45-28 \(String(repeating: "x", count: 100)).xrk")
    }

    @Test func test_library_name_without_a_track_uses_the_device_name() {
        #expect(DeviceSessionText.libraryFileName(session(track: ""))
            == "2025-07-11 17-45-28 a_0061.xrk")
    }

    @Test func test_clock_carries_local_time_and_utc() throws {
        let instant = Date(timeIntervalSince1970: 1_784_643_360) // 2026-07-21 14:16:00 UTC
        let saoPaulo = try #require(TimeZone(identifier: "America/Sao_Paulo"))

        let clock = DeviceClock(date: instant, timeZone: saoPaulo)

        #expect(clock.local == RaceStudioFFIBindings.SessionDate(
            year: 2026, month: 7, day: 21, hour: 11, minute: 16, second: 0))
        #expect(clock.utc == RaceStudioFFIBindings.SessionDate(
            year: 2026, month: 7, day: 21, hour: 14, minute: 16, second: 0))
    }
}

/// Issue #179 — telling whether the Mac is on a MyChron's own Wi-Fi.
@Suite struct DeviceNetworkTests {

    @Test func test_access_point_address_means_joined() {
        #expect(DeviceNetwork.isJoined(addresses: ["127.0.0.1", "10.0.0.2"]))
    }

    @Test func test_other_networks_mean_not_joined() {
        #expect(!DeviceNetwork.isJoined(addresses: ["127.0.0.1", "192.168.1.20", "10.0.1.2"]))
    }

    @Test func test_interface_addresses_include_loopback() {
        #expect(DeviceNetwork.currentIPv4Addresses().contains("127.0.0.1"))
    }

    @Test func test_live_check_answers_without_failing() {
        let joined = DeviceNetwork.isJoined()

        #expect(joined == DeviceNetwork.isJoined(addresses: DeviceNetwork.currentIPv4Addresses()))
    }
}

/// A loader that returns a canned session, or fails as an unreadable file does.
private struct CannedLoader: SessionLoading, @unchecked Sendable {
    struct Unreadable: Error {}
    var fails = false

    func load(
        _ url: URL, onProgress: @escaping @MainActor (DecodeProgress) -> Void
    ) async throws -> LoadedSession {
        if fails { throw Unreadable() }
        return LoadedSession(session: SessionFixture.make())
    }
}

/// Issue #179 — a downloaded session lands in the library, all or nothing.
@MainActor
@Suite struct DownloadedSessionImporterTests {
    private let root: URL
    private let library = LibraryBrowserModel()

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("importer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private var managed: URL { root.appendingPathComponent("Sessions", isDirectory: true) }
    private var scratch: URL { root.appendingPathComponent("Scratch", isDirectory: true) }
    private var libraryURL: URL { root.appendingPathComponent("library.json") }

    private func importer(failing: Bool = false) -> DownloadedSessionImporter {
        DownloadedSessionImporter(
            files: ManagedFileStore(directory: managed), loader: CannedLoader(fails: failing),
            library: library, libraryURL: libraryURL, scratchDirectory: scratch)
    }

    private func contents(_ url: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
    }

    @Test func test_imported_session_is_listed_in_the_library() async throws {
        try await importer().importDownloaded(Data("xrk".utf8), for: session())

        #expect(library.allSessions.count == 1)
    }

    @Test func test_imported_session_is_kept_as_a_managed_copy() async throws {
        try await importer().importDownloaded(Data("xrk".utf8), for: session())

        let copies = contents(managed)
        #expect(copies.count == 1)
        #expect(copies.first?.hasPrefix("2025-07-11 17-45-28 Kartodromo") == true)
    }

    @Test func test_library_index_is_saved() async throws {
        try await importer().importDownloaded(Data("xrk".utf8), for: session())

        #expect(FileManager.default.fileExists(atPath: libraryURL.path))
    }

    @Test func test_staging_is_removed_after_import() async throws {
        try await importer().importDownloaded(Data("xrk".utf8), for: session())

        #expect(contents(scratch).isEmpty)
    }

    @Test func test_undecodable_download_leaves_nothing_behind() async {
        await #expect(throws: CannedLoader.Unreadable.self) {
            try await importer(failing: true).importDownloaded(Data("junk".utf8), for: session())
        }

        #expect(library.allSessions.isEmpty)
        #expect(contents(managed).isEmpty)
        #expect(contents(scratch).isEmpty)
    }
}
#endif
