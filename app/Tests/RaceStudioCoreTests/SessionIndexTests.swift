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
}
