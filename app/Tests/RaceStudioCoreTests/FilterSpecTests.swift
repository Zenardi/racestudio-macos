import Testing
import Foundation
@testable import RaceStudioCore

/// Tests for `FilterSpec` (issue 8.15) — the structured filter that backs both a
/// smart collection's rule and the browser's faceted search. It grows from the
/// 5.3 vehicle/date/laps predicates to the six RS3 facets (racer, vehicle, track,
/// championship, comment, logger), each an exact case-insensitive match, and
/// becomes `Codable` so a smart-collection rule persists in the library JSON.
///
/// Facet matching is exercised against hand-built `SessionSummary` values so the
/// facets that the decoder does not yet surface (comment, logger) are still
/// covered — the filter machinery is complete the moment those fields are
/// populated.
@Suite struct FilterSpecTests {

    /// A summary with every facet-relevant field set, for predicate tests.
    private func summary(
        id: String = "id", venue: String = "Fuji", vehicle: String = "SFJ",
        driver: String = "CMD", championship: String = "GT Cup",
        comment: String = "Wet run", logger: String = "MyChron5",
        date: Date = Date(timeIntervalSince1970: 1_000), lapCount: Int = 5
    ) -> SessionSummary {
        SessionSummary(
            id: id, venue: venue, date: date, vehicle: vehicle, driver: driver,
            lapCount: lapCount, bestLap: nil, sourceURL: URL(fileURLWithPath: "/x/\(id).xrk"),
            importedAt: date, isAvailable: true,
            championship: championship, comment: comment, logger: logger)
    }

    // MARK: - facet predicates (exact, case-insensitive)

    @Test func test_empty_spec_matches_any_summary() {
        #expect(FilterSpec().matches(summary()))
    }

    @Test func test_each_facet_matches_case_insensitively() {
        let s = summary()
        #expect(FilterSpec(vehicle: "sfj").matches(s))
        #expect(FilterSpec(racer: "cmd").matches(s))
        #expect(FilterSpec(track: "fuji").matches(s))
        #expect(FilterSpec(championship: "gt cup").matches(s))
        #expect(FilterSpec(comment: "wet run").matches(s))
        #expect(FilterSpec(logger: "mychron5").matches(s))
    }

    @Test func test_facet_is_exact_not_substring() {
        // A facet is a chosen value, not free text: "Fuj" must not match "Fuji".
        #expect(!FilterSpec(track: "Fuj").matches(summary(venue: "Fuji")))
        #expect(FilterSpec(track: "Fuji").matches(summary(venue: "Fuji")))
    }

    @Test func test_each_facet_rejects_a_mismatch() {
        let s = summary()
        #expect(!FilterSpec(vehicle: "GT3").matches(s))
        #expect(!FilterSpec(racer: "AB").matches(s))
        #expect(!FilterSpec(track: "Suzuka").matches(s))
        #expect(!FilterSpec(championship: "Trophy").matches(s))
        #expect(!FilterSpec(comment: "Dry").matches(s))
        #expect(!FilterSpec(logger: "Solo2").matches(s))
    }

    @Test func test_predicates_combine_as_and() {
        let s = summary(vehicle: "SFJ", championship: "GT Cup")
        // Both set and both match.
        #expect(FilterSpec(vehicle: "SFJ", championship: "GT Cup").matches(s))
        // One mismatches -> whole spec fails.
        #expect(!FilterSpec(vehicle: "SFJ", championship: "Other").matches(s))
    }

    @Test func test_date_range_and_min_laps_still_apply() {
        let s = summary(date: Date(timeIntervalSince1970: 2_000), lapCount: 4)
        let inRange = Date(timeIntervalSince1970: 0)...Date(timeIntervalSince1970: 3_000)
        let outRange = Date(timeIntervalSince1970: 5_000)...Date(timeIntervalSince1970: 9_000)
        #expect(FilterSpec(dateRange: inRange).matches(s))
        #expect(!FilterSpec(dateRange: outRange).matches(s))
        #expect(FilterSpec(minLaps: 4).matches(s))
        #expect(!FilterSpec(minLaps: 5).matches(s))
    }

    // MARK: - isEmpty

    @Test func test_is_empty_only_when_no_predicate_is_set() {
        #expect(FilterSpec().isEmpty)
        #expect(!FilterSpec(vehicle: "SFJ").isEmpty)
        #expect(!FilterSpec(comment: "x").isEmpty)
        #expect(!FilterSpec(minLaps: 1).isEmpty)
        #expect(!FilterSpec(dateRange: Date(timeIntervalSince1970: 0)...Date(timeIntervalSince1970: 1)).isEmpty)
    }

    // MARK: - Codable (a smart-collection rule persists in the library JSON)

    @Test func test_codable_roundtrip_preserves_all_predicates() throws {
        let spec = FilterSpec(
            vehicle: "SFJ", racer: "CMD", track: "Fuji", championship: "GT Cup",
            comment: "Wet", logger: "MyChron5",
            dateRange: Date(timeIntervalSince1970: 100)...Date(timeIntervalSince1970: 900),
            minLaps: 3)

        let data = try JSONEncoder().encode(spec)
        let decoded = try JSONDecoder().decode(FilterSpec.self, from: data)

        #expect(decoded == spec)
    }

    @Test func test_codable_roundtrip_of_empty_spec() throws {
        let data = try JSONEncoder().encode(FilterSpec())
        #expect(try JSONDecoder().decode(FilterSpec.self, from: data) == FilterSpec())
    }
}
