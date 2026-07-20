import Testing
import Foundation
@testable import RaceStudioCore

/// Tests for `SessionIndex` (issue 5.3) — deriving a `SessionSummary` from a
/// decoded/imported `Session`, and the case-insensitive search + structured
/// filter over the indexed summaries.
///
/// The index's clock is injected (`now:`) so `importedAt` is deterministic; the
/// realistic 13-lap case reuses the committed `fuji_0033` decode golden.
@Suite struct SessionIndexTests {

    /// A fixed clock so `importedAt` is deterministic across runs.
    private static let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeIndex() -> SessionIndex {
        SessionIndex(now: { Self.fixedNow })
    }

    private func url(_ name: String) -> URL {
        URL(fileURLWithPath: "/imports/\(name)")
    }

    // MARK: - add / summarize

    @Test func test_add_derives_summary_with_best_lap() throws {
        // Realistic oracle: the 13-lap fuji session (metadata + laps from the decode golden).
        let fuji = try GoldenSession.load("fuji_0033")
        let index = makeIndex()

        let summary = index.add(fuji, sourceURL: url("fuji_0033.xrk"))

        #expect(summary.venue == "Fuji GP Sh")
        #expect(summary.vehicle == "SFJ")
        #expect(summary.driver == "CMD")
        #expect(summary.lapCount == 13)
        #expect(summary.sourceURL == url("fuji_0033.xrk"))
        #expect(summary.importedAt == Self.fixedNow)

        // Best lap == the fastest lap, matching the golden's best_lap_index (12).
        let fastest = try #require(fuji.laps.min { $0.durationS < $1.durationS })
        #expect(fastest.index == 12)
        #expect(summary.bestLap == .seconds(fastest.durationS))
        #expect(index.summaries.count == 1)
    }

    @Test func test_add_with_no_laps_has_nil_best_lap() {
        let index = makeIndex()

        let summary = index.add(SessionFixture.make(lapDurations: []), sourceURL: url("empty.xrk"))

        #expect(summary.bestLap == nil)
        #expect(summary.lapCount == 0)
    }

    @Test func test_re_adding_same_file_updates_not_duplicates() {
        let index = makeIndex()
        let session = SessionFixture.make()
        _ = index.add(session, sourceURL: url("a.xrk"))

        // Re-add the identical content from a moved location.
        let updated = index.add(session, sourceURL: url("moved/a.xrk"))

        #expect(index.summaries.count == 1)                          // no duplicate
        #expect(index.summaries.first?.sourceURL == url("moved/a.xrk"))  // updated in place
        #expect(updated.id == SessionIndex.contentID(for: session))  // stable content id
    }

    @Test func test_remove_by_id_drops_summary() {
        let index = makeIndex()
        let summary = index.add(SessionFixture.make(), sourceURL: url("a.xrk"))

        index.remove(id: summary.id)

        #expect(index.summaries.isEmpty)
    }

    // MARK: - search

    @Test func test_search_matches_venue_vehicle_driver_case_insensitive() {
        let index = makeIndex()
        _ = index.add(SessionFixture.make(vehicle: "SFJ", track: "Fuji GP Sh", driver: "CMD",
                                          datetimeUtc: 300), sourceURL: url("fuji.xrk"))
        _ = index.add(SessionFixture.make(vehicle: "GT3", track: "Suzuka", driver: "AB",
                                          datetimeUtc: 200), sourceURL: url("suzuka.xrk"))
        _ = index.add(SessionFixture.make(vehicle: "SFJ", track: "Mugen", driver: "Fuji-San",
                                          datetimeUtc: 100), sourceURL: url("mugen.xrk"))

        // "fuji" matches venue ("Fuji GP Sh") and driver ("Fuji-San"); results are date-descending.
        #expect(index.search("fuji").map(\.venue) == ["Fuji GP Sh", "Mugen"])
        // Vehicle match, case-insensitive.
        #expect(index.search("gt3").map(\.venue) == ["Suzuka"])
        // No match is empty, not an error.
        #expect(index.search("zzz").isEmpty)
    }

    @Test func test_search_orders_by_date_descending() {
        let index = makeIndex()
        _ = index.add(SessionFixture.make(track: "Old", datetimeUtc: 100), sourceURL: url("old.xrk"))
        _ = index.add(SessionFixture.make(track: "New", datetimeUtc: 300), sourceURL: url("new.xrk"))
        _ = index.add(SessionFixture.make(track: "Mid", datetimeUtc: 200), sourceURL: url("mid.xrk"))

        #expect(index.search("").map(\.venue) == ["New", "Mid", "Old"])
    }

    // MARK: - filter

    @Test func test_filter_by_vehicle_and_min_laps() {
        let index = makeIndex()
        _ = index.add(SessionFixture.make(vehicle: "SFJ", track: "A", datetimeUtc: 300,
                                          lapDurations: Array(repeating: 90, count: 6)), sourceURL: url("a.xrk"))
        _ = index.add(SessionFixture.make(vehicle: "SFJ", track: "B", datetimeUtc: 200,
                                          lapDurations: Array(repeating: 90, count: 3)), sourceURL: url("b.xrk"))
        _ = index.add(SessionFixture.make(vehicle: "GT3", track: "C", datetimeUtc: 100,
                                          lapDurations: Array(repeating: 90, count: 8)), sourceURL: url("c.xrk"))

        // vehicle == SFJ AND lapCount >= 5 -> only "a" (SFJ, 6 laps).
        let hits = index.filter(FilterSpec(vehicle: "SFJ", minLaps: 5))
        #expect(hits.map(\.sourceURL) == [url("a.xrk")])

        // An empty spec returns everything.
        #expect(index.filter(FilterSpec()).count == 3)
    }

    @Test func test_filter_by_date_range() {
        let index = makeIndex()
        _ = index.add(SessionFixture.make(track: "In", datetimeUtc: 3000), sourceURL: url("in.xrk"))
        _ = index.add(SessionFixture.make(track: "Out", datetimeUtc: 9000), sourceURL: url("out.xrk"))

        let range = Date(timeIntervalSince1970: 0)...Date(timeIntervalSince1970: 5000)
        #expect(index.filter(FilterSpec(dateRange: range)).map(\.venue) == ["In"])
    }

    // MARK: - contentID

    @Test func test_content_id_is_stable_and_distinguishes_sessions() {
        // Two *independently built* sessions with identical content (as two
        // decodes of the same file would produce) must hash identically.
        let a1 = SessionFixture.make(track: "Fuji")
        let a2 = SessionFixture.make(track: "Fuji")
        let b = SessionFixture.make(track: "Suzuka")

        #expect(SessionIndex.contentID(for: a1) == SessionIndex.contentID(for: a2))  // stable
        #expect(SessionIndex.contentID(for: a1) != SessionIndex.contentID(for: b))   // distinguishing
    }

    @Test func test_content_id_is_injective_across_field_boundaries() {
        // A separator character inside a value must not forge a different
        // session's field boundaries (delimiter-injection collision).
        let a = SessionFixture.make(vehicle: "A|B", track: "C")
        let b = SessionFixture.make(vehicle: "A", track: "B|C")

        #expect(SessionIndex.contentID(for: a) != SessionIndex.contentID(for: b))
    }

    // MARK: - facet-backing summary fields (issue 8.15)

    @Test func test_add_populates_championship_from_series() {
        let index = makeIndex()

        let summary = index.add(SessionFixture.make(series: "GT Cup"), sourceURL: url("a.xrk"))

        #expect(summary.championship == "GT Cup")
        // comment/logger are not surfaced by the decoder yet -> empty.
        #expect(summary.comment.isEmpty)
        #expect(summary.logger.isEmpty)
    }

    @Test func test_facet_values_are_distinct_and_sorted() {
        let index = makeIndex()
        _ = index.add(SessionFixture.make(vehicle: "SFJ", track: "A", series: "GT Cup", datetimeUtc: 300),
                      sourceURL: url("a.xrk"))
        _ = index.add(SessionFixture.make(vehicle: "GT3", track: "B", series: "Trophy", datetimeUtc: 200),
                      sourceURL: url("b.xrk"))
        _ = index.add(SessionFixture.make(vehicle: "SFJ", track: "C", series: "GT Cup", datetimeUtc: 100),
                      sourceURL: url("c.xrk"))

        #expect(index.facetValues(.vehicle) == ["GT3", "SFJ"])
        #expect(index.facetValues(.championship) == ["GT Cup", "Trophy"])
    }

    @Test func test_facet_values_omit_empty_values() {
        let index = makeIndex()
        _ = index.add(SessionFixture.make(vehicle: "SFJ"), sourceURL: url("a.xrk"))

        // comment/logger have no decoder source yet -> empty -> excluded from the facet list.
        #expect(index.facetValues(.comment).isEmpty)
        #expect(index.facetValues(.logger).isEmpty)
    }

    @Test func test_facet_values_break_case_insensitive_ties_deterministically() {
        let index = makeIndex()
        _ = index.add(SessionFixture.make(vehicle: "bmw", track: "A", datetimeUtc: 300), sourceURL: url("a.xrk"))
        _ = index.add(SessionFixture.make(vehicle: "BMW", track: "B", datetimeUtc: 200), sourceURL: url("b.xrk"))

        // Case-variant duplicates tie under localized comparison; the raw-value
        // secondary key keeps the order stable across runs ("BMW" < "bmw" by scalar).
        #expect(index.facetValues(.vehicle) == ["BMW", "bmw"])
    }

    // MARK: - recent (issue 8.15)

    @Test func test_recent_ranks_by_import_time_not_session_date() {
        var tick = 1_000
        let advancingClock: () -> Date = {
            tick += 1
            return Date(timeIntervalSince1970: TimeInterval(tick))
        }
        let index = SessionIndex(now: advancingClock)
        // Session dates are deliberately NON-monotonic so the result proves that
        // "recent" ranks by *import* time, not by session date.
        _ = index.add(SessionFixture.make(track: "First", datetimeUtc: 9_000), sourceURL: url("first.xrk"))
        _ = index.add(SessionFixture.make(track: "Second", datetimeUtc: 1_000), sourceURL: url("second.xrk"))
        _ = index.add(SessionFixture.make(track: "Third", datetimeUtc: 5_000), sourceURL: url("third.xrk"))

        #expect(index.recent(limit: 2).map(\.venue) == ["Third", "Second"])
    }

    @Test func test_recent_limit_is_clamped() {
        let index = makeIndex()
        _ = index.add(SessionFixture.make(track: "A", datetimeUtc: 100), sourceURL: url("a.xrk"))
        _ = index.add(SessionFixture.make(track: "B", datetimeUtc: 200), sourceURL: url("b.xrk"))

        #expect(index.recent(limit: 0).isEmpty)      // non-positive -> empty
        #expect(index.recent(limit: 10).count == 2)  // beyond count -> all
    }

    // MARK: - collections (issue 8.15)

    @Test func test_upsert_and_fetch_a_collection() {
        let index = makeIndex()
        let smart = SessionCollection.smart(id: "c1", name: "Fast SFJ", rule: FilterSpec(vehicle: "SFJ"))

        index.upsertCollection(smart)

        #expect(index.collection(id: "c1") == smart)
        #expect(index.collections == [smart])
    }

    @Test func test_upsert_replaces_a_collection_by_id() {
        let index = makeIndex()
        index.upsertCollection(.manual(id: "c", name: "Old", members: ["a"]))

        index.upsertCollection(.manual(id: "c", name: "New", members: ["a", "b"]))

        #expect(index.collections.count == 1)
        #expect(index.collection(id: "c")?.name == "New")
        #expect(index.collection(id: "c")?.memberIDs == ["a", "b"])
    }

    @Test func test_remove_collection() {
        let index = makeIndex()
        index.upsertCollection(.manual(id: "c", name: "X"))

        index.removeCollection(id: "c")

        #expect(index.collections.isEmpty)
        #expect(index.collection(id: "c") == nil)
    }

    @Test func test_collections_are_sorted_by_name_case_insensitively() {
        let index = makeIndex()
        index.upsertCollection(.manual(id: "b", name: "Zeta"))
        index.upsertCollection(.manual(id: "a", name: "alpha"))
        index.upsertCollection(.manual(id: "c", name: "Mid"))

        #expect(index.collections.map(\.name) == ["alpha", "Mid", "Zeta"])
    }

    @Test func test_smart_collection_resolves_via_its_rule() {
        let index = makeIndex()
        _ = index.add(SessionFixture.make(vehicle: "SFJ", track: "A", datetimeUtc: 300), sourceURL: url("a.xrk"))
        _ = index.add(SessionFixture.make(vehicle: "GT3", track: "B", datetimeUtc: 200), sourceURL: url("b.xrk"))
        let smart = SessionCollection.smart(id: "c", name: "SFJ only", rule: FilterSpec(vehicle: "SFJ"))

        #expect(index.sessions(in: smart).map(\.venue) == ["A"])
    }

    @Test func test_manual_collection_resolves_members_in_curated_order() {
        let index = makeIndex()
        let a = index.add(SessionFixture.make(track: "A", datetimeUtc: 100), sourceURL: url("a.xrk"))
        let b = index.add(SessionFixture.make(track: "B", datetimeUtc: 300), sourceURL: url("b.xrk"))
        // Curated order (b, then a) is preserved — NOT re-sorted by date.
        let manual = SessionCollection.manual(id: "c", name: "Curated", members: [b.id, a.id])

        #expect(index.sessions(in: manual).map(\.venue) == ["B", "A"])
    }

    @Test func test_manual_collection_skips_missing_members() {
        let index = makeIndex()
        let a = index.add(SessionFixture.make(track: "A"), sourceURL: url("a.xrk"))
        let manual = SessionCollection.manual(id: "c", name: "Curated", members: ["gone", a.id])

        #expect(index.sessions(in: manual).map(\.venue) == ["A"])  // dangling member dropped
    }
}
