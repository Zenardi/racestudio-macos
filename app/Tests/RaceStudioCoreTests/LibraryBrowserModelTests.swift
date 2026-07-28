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

    /// The Home dashboard reads ``LibraryBrowserModel/allSessions`` — the whole
    /// library — so its stats stay correct even when the browser has an active
    /// filter that narrows the visible ``sessions``.
    @Test func test_all_sessions_is_unfiltered_by_the_active_search() {
        let model = LibraryBrowserModel()
        model.add(SessionFixture.make(track: "Adria"), sourceURL: url("a"))
        model.add(SessionFixture.make(track: "Mugello"), sourceURL: url("b"))

        model.search("Adria")
        #expect(model.sessions.count == 1, "the visible list narrows to the match")
        #expect(model.allSessions.count == 2, "allSessions stays the whole library")
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

    // MARK: - Faceted search (issue 8.15)

    @Test func test_setting_a_facet_narrows_the_list() {
        let model = LibraryBrowserModel()
        model.add(SessionFixture.make(vehicle: "SFJ", track: "A", series: "GT Cup"), sourceURL: url("a"))
        model.add(SessionFixture.make(vehicle: "GT3", track: "B", series: "Trophy"), sourceURL: url("b"))

        model.setFacet(.championship, to: "GT Cup")

        #expect(model.sessions.map(\.vehicle) == ["SFJ"])
    }

    @Test func test_clearing_a_facet_restores_the_list() {
        let model = LibraryBrowserModel()
        model.add(SessionFixture.make(vehicle: "SFJ", series: "GT Cup"), sourceURL: url("a"))
        model.add(SessionFixture.make(vehicle: "GT3", series: "Trophy"), sourceURL: url("b"))
        model.setFacet(.championship, to: "GT Cup")

        model.setFacet(.championship, to: nil)

        #expect(model.sessions.count == 2)
    }

    @Test func test_vehicle_filter_delegates_to_the_vehicle_facet() {
        let model = LibraryBrowserModel()
        model.add(SessionFixture.make(vehicle: "SFJ"), sourceURL: url("a"))
        model.add(SessionFixture.make(vehicle: "GT3"), sourceURL: url("b"))

        model.setVehicleFilter("GT3")

        #expect(model.vehicleFilter == "GT3")
        #expect(model.sessions.map(\.vehicle) == ["GT3"])
    }

    @Test func test_facet_values_lists_choices_for_a_facet() {
        let model = LibraryBrowserModel()
        model.add(SessionFixture.make(series: "GT Cup"), sourceURL: url("a"))
        model.add(SessionFixture.make(series: "Trophy"), sourceURL: url("b"))

        #expect(model.facetValues(.championship) == ["GT Cup", "Trophy"])
    }

    // MARK: - Scope: Recent (issue 8.15)

    @Test func test_show_recent_scopes_to_the_last_imported() {
        var tick = 1_000
        let index = SessionIndex(now: { tick += 1; return Date(timeIntervalSince1970: TimeInterval(tick)) })
        let model = LibraryBrowserModel(index: index)
        model.add(SessionFixture.make(track: "First", datetimeUtc: 9_000), sourceURL: url("first"))
        model.add(SessionFixture.make(track: "Second", datetimeUtc: 1_000), sourceURL: url("second"))
        model.add(SessionFixture.make(track: "Third", datetimeUtc: 5_000), sourceURL: url("third"))

        model.showRecent(limit: 2)

        #expect(model.sessions.map(\.venue) == ["Third", "Second"])
    }

    @Test func test_show_all_restores_the_full_list_after_recent() {
        let model = LibraryBrowserModel()
        model.add(SessionFixture.make(track: "A", datetimeUtc: 100), sourceURL: url("a"))
        model.add(SessionFixture.make(track: "B", datetimeUtc: 200), sourceURL: url("b"))
        model.add(SessionFixture.make(track: "C", datetimeUtc: 300), sourceURL: url("c"))
        model.showRecent(limit: 1)
        #expect(model.sessions.count == 1)

        model.showAll()

        #expect(model.sessions.count == 3)
    }

    // MARK: - Collections (issue 8.15)

    @Test func test_add_and_list_collections() {
        let model = LibraryBrowserModel()

        model.addCollection(.smart(id: "s", name: "Fast SFJ", rule: FilterSpec(vehicle: "SFJ")))

        #expect(model.collections.map(\.name) == ["Fast SFJ"])
    }

    @Test func test_show_collection_scopes_to_its_sessions() {
        let model = LibraryBrowserModel()
        model.add(SessionFixture.make(vehicle: "SFJ", track: "A"), sourceURL: url("a"))
        model.add(SessionFixture.make(vehicle: "GT3", track: "B"), sourceURL: url("b"))
        model.addCollection(.smart(id: "s", name: "SFJ", rule: FilterSpec(vehicle: "SFJ")))

        model.showCollection(id: "s")

        #expect(model.sessions.map(\.venue) == ["A"])
    }

    @Test func test_dragging_a_session_into_a_manual_collection_persists() throws {
        let libURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("manual-collection-8-15.json")
        try? FileManager.default.removeItem(at: libURL)
        defer { try? FileManager.default.removeItem(at: libURL) }
        let model = LibraryBrowserModel()
        let summary = model.add(SessionFixture.make(track: "Fuji"), sourceURL: url("a"))
        model.addCollection(.manual(id: "m", name: "Favourites"))

        model.addSession(summary.id, toCollection: "m")
        try model.save(to: libURL)

        // Reopen: the curated membership survived the round-trip.
        let reopened = LibraryBrowserModel(loadingFrom: libURL)
        reopened.showCollection(id: "m")
        #expect(reopened.sessions.map(\.venue) == ["Fuji"])
    }

    @Test func test_removing_the_active_collection_falls_back_to_all() {
        let model = LibraryBrowserModel()
        model.add(SessionFixture.make(vehicle: "SFJ", track: "A"), sourceURL: url("a"))
        model.add(SessionFixture.make(vehicle: "GT3", track: "B"), sourceURL: url("b"))
        model.addCollection(.smart(id: "s", name: "SFJ", rule: FilterSpec(vehicle: "SFJ")))
        model.showCollection(id: "s")
        #expect(model.sessions.count == 1)  // scoped to the collection

        model.removeCollection(id: "s")

        #expect(model.collections.isEmpty)
        #expect(model.sessions.count == 2)  // scope fell back to All
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
