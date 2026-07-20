import Foundation
import Testing
@testable import RaceStudioCore

/// Behaviour for the session library browser (issue 8.14): it lists indexed
/// sessions date-descending, imports add to the index (dedup by content id), the
/// left filtering column narrows the list, a selected session previews its laps +
/// map without full analysis, and a missing/corrupt library degrades gracefully.
@MainActor @Suite struct LibraryBrowserModelTests {

    private func url(_ name: String) -> URL { URL(fileURLWithPath: "/tmp/\(name).xrk") }

    // MARK: - Listing

    @Test func test_lists_added_sessions_date_descending() {
        let model = LibraryBrowserModel()
        model.add(SessionFixture.make(track: "Older", datetimeUtc: 1_000), sourceURL: url("a"))
        model.add(SessionFixture.make(track: "Newer", datetimeUtc: 2_000), sourceURL: url("b"))

        #expect(model.sessions.map(\.venue) == ["Newer", "Older"])
    }

    @Test func test_starts_empty() {
        #expect(LibraryBrowserModel().sessions.isEmpty)
    }

    // MARK: - Import / dedup

    @Test func test_import_adds_the_session_to_the_index() {
        let model = LibraryBrowserModel()

        let summary = model.add(SessionFixture.make(), sourceURL: url("a"))

        #expect(model.sessions.map(\.id) == [summary.id])
    }

    @Test func test_reimporting_the_same_content_dedups() {
        let model = LibraryBrowserModel()
        let session = SessionFixture.make()

        model.add(session, sourceURL: url("first"))
        model.add(session, sourceURL: url("second"))

        #expect(model.sessions.count == 1)
        // The latest import wins the source URL (SessionIndex semantics).
        #expect(model.sessions[0].sourceURL == url("second"))
    }

    // MARK: - Filtering column

    @Test func test_vehicle_filter_narrows_the_list() {
        let model = LibraryBrowserModel()
        model.add(SessionFixture.make(vehicle: "SFJ", track: "T1"), sourceURL: url("a"))
        model.add(SessionFixture.make(vehicle: "GT3", track: "T2"), sourceURL: url("b"))

        model.setVehicleFilter("GT3")

        #expect(model.sessions.map(\.vehicle) == ["GT3"])
    }

    @Test func test_clearing_the_vehicle_filter_restores_the_list() {
        let model = LibraryBrowserModel()
        model.add(SessionFixture.make(vehicle: "SFJ", track: "T1"), sourceURL: url("a"))
        model.add(SessionFixture.make(vehicle: "GT3", track: "T2"), sourceURL: url("b"))
        model.setVehicleFilter("GT3")

        model.setVehicleFilter(nil)

        #expect(model.sessions.count == 2)
    }

    @Test func test_search_narrows_by_text() {
        let model = LibraryBrowserModel()
        model.add(SessionFixture.make(track: "Monza"), sourceURL: url("a"))
        model.add(SessionFixture.make(track: "Fuji GP Sh"), sourceURL: url("b"))

        model.search("mon")

        #expect(model.sessions.map(\.venue) == ["Monza"])
    }

    @Test func test_vehicles_facet_lists_distinct_vehicles_sorted() {
        let model = LibraryBrowserModel()
        model.add(SessionFixture.make(vehicle: "SFJ", track: "T1"), sourceURL: url("a"))
        model.add(SessionFixture.make(vehicle: "GT3", track: "T2"), sourceURL: url("b"))
        model.add(SessionFixture.make(vehicle: "SFJ", track: "T3"), sourceURL: url("c"))

        #expect(model.vehicles == ["GT3", "SFJ"])
    }

    // MARK: - Selection + preview

    @Test func test_selecting_and_loading_builds_a_preview() async {
        let session = SessionFixture.make(lapDurations: [120, 100])
        let gps = [
            GPSTrackPoint(coordinate: GPSCoord(latitude: 45, longitude: 10), distance: 0, time: 0),
            GPSTrackPoint(coordinate: GPSCoord(latitude: 45.1, longitude: 10.1), distance: 5, time: 1)
        ]
        let loaded = LoadedSession(session: session, dataSource: FakeSessionDataSource(banks: [], gps: gps))
        let model = LibraryBrowserModel(loader: StubLoader(loaded: loaded))
        let summary = model.add(session, sourceURL: url("a"))

        model.select(summary.id)
        await model.loadPreview()

        #expect(model.preview?.summary.laps.count == 2)
        #expect(model.preview?.map.isEmpty == false)
        #expect(model.previewFailed == false)
    }

    @Test func test_preview_is_empty_map_when_session_has_no_gps() async {
        let session = SessionFixture.make()
        let loaded = LoadedSession(session: session, dataSource: FakeSessionDataSource(banks: [], gps: []))
        let model = LibraryBrowserModel(loader: StubLoader(loaded: loaded))
        let summary = model.add(session, sourceURL: url("a"))

        model.select(summary.id)
        await model.loadPreview()

        #expect(model.preview?.map.isEmpty == true)
    }

    @Test func test_preview_load_failure_degrades_gracefully() async {
        let session = SessionFixture.make()
        let model = LibraryBrowserModel(loader: StubLoader(fails: true))
        let summary = model.add(session, sourceURL: url("a"))

        model.select(summary.id)
        await model.loadPreview()

        #expect(model.preview == nil)
        #expect(model.previewFailed)
    }

    @Test func test_selecting_clears_the_previous_preview() async {
        let session = SessionFixture.make()
        let loaded = LoadedSession(session: session, dataSource: FakeSessionDataSource(banks: [], gps: []))
        let model = LibraryBrowserModel(loader: StubLoader(loaded: loaded))
        let summary = model.add(session, sourceURL: url("a"))
        model.select(summary.id)
        await model.loadPreview()
        #expect(model.preview != nil)

        model.select(nil)

        #expect(model.preview == nil)
        #expect(model.selectedID == nil)
    }

    @Test func test_selected_summary_resolves_from_the_id() {
        let model = LibraryBrowserModel()
        let summary = model.add(SessionFixture.make(), sourceURL: url("a"))

        model.select(summary.id)

        #expect(model.selectedSummary?.id == summary.id)
    }

    // MARK: - Graceful degradation (5.3 semantics)

    @Test func test_loads_from_a_missing_library_as_empty() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("no-such-library-8-14.json")
        try? FileManager.default.removeItem(at: missing)

        let model = LibraryBrowserModel(loadingFrom: missing)

        #expect(model.sessions.isEmpty)
    }

    @Test func test_saved_library_lists_again_when_reopened() throws {
        let libURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("roundtrip-library-8-14.json")
        try? FileManager.default.removeItem(at: libURL)
        defer { try? FileManager.default.removeItem(at: libURL) }
        let model = LibraryBrowserModel()
        model.add(SessionFixture.make(track: "Fuji"), sourceURL: url("a"))

        try model.save(to: libURL)
        let reopened = LibraryBrowserModel(loadingFrom: libURL)

        #expect(reopened.sessions.map(\.venue) == ["Fuji"])
    }

    @Test func test_loads_from_a_corrupt_library_as_empty() throws {
        let corrupt = FileManager.default.temporaryDirectory
            .appendingPathComponent("corrupt-library-8-14.json")
        try Data("this is not json".utf8).write(to: corrupt)
        defer { try? FileManager.default.removeItem(at: corrupt) }

        let model = LibraryBrowserModel(loadingFrom: corrupt)

        #expect(model.sessions.isEmpty)
    }
}

/// A scripted ``SessionLoading`` for the browser tests: it returns a canned
/// ``LoadedSession`` (ignoring the URL) or throws, so the preview path is covered
/// without the xcframework.
private struct StubLoader: SessionLoading, @unchecked Sendable {
    var loaded: LoadedSession?
    var fails = false

    struct Boom: Error {}

    func load(
        _ url: URL, onProgress: @escaping @MainActor (DecodeProgress) -> Void
    ) async throws -> LoadedSession {
        if fails { throw Boom() }
        return loaded ?? LoadedSession(session: SessionFixture.make())
    }
}
