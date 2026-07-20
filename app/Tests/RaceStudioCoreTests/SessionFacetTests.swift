import Testing
import Foundation
@testable import RaceStudioCore

/// Tests for `SessionFacet` (issue 8.15) — the enumeration of the six RS3 search
/// facets. It centralises, in one place both the browser model and the filter
/// agree on, how each facet reads a `SessionSummary` and how it is applied to a
/// `FilterSpec`.
@Suite struct SessionFacetTests {

    private func summary() -> SessionSummary {
        SessionSummary(
            id: "id", venue: "Fuji", date: Date(timeIntervalSince1970: 0), vehicle: "SFJ",
            driver: "CMD", lapCount: 3, bestLap: nil,
            sourceURL: URL(fileURLWithPath: "/x.xrk"), importedAt: Date(timeIntervalSince1970: 0),
            isAvailable: true, championship: "GT Cup", comment: "Wet", logger: "MyChron5")
    }

    @Test func test_all_six_facets_exist() {
        #expect(Set(SessionFacet.allCases) == [.racer, .vehicle, .track, .championship, .comment, .logger])
    }

    @Test func test_id_is_the_raw_value() {
        #expect(SessionFacet.racer.id == SessionFacet.racer.rawValue)
    }

    @Test func test_each_facet_has_a_human_title() {
        #expect(SessionFacet.racer.title == "Racer")
        #expect(SessionFacet.vehicle.title == "Vehicle")
        #expect(SessionFacet.track.title == "Track")
        #expect(SessionFacet.championship.title == "Championship")
        #expect(SessionFacet.comment.title == "Comment")
        #expect(SessionFacet.logger.title == "Logger")
    }

    @Test func test_value_in_summary_reads_the_right_field() {
        let s = summary()
        #expect(SessionFacet.racer.value(in: s) == "CMD")
        #expect(SessionFacet.vehicle.value(in: s) == "SFJ")
        #expect(SessionFacet.track.value(in: s) == "Fuji")
        #expect(SessionFacet.championship.value(in: s) == "GT Cup")
        #expect(SessionFacet.comment.value(in: s) == "Wet")
        #expect(SessionFacet.logger.value(in: s) == "MyChron5")
    }

    @Test func test_apply_sets_and_clears_the_spec_field() {
        for facet in SessionFacet.allCases {
            var spec = FilterSpec()
            facet.apply("value", to: &spec)
            #expect(facet.value(in: spec) == "value", "\(facet) should round-trip through the spec")

            facet.apply(nil, to: &spec)
            #expect(facet.value(in: spec) == nil, "\(facet) should clear")
            #expect(spec.isEmpty, "clearing the only facet leaves an empty spec")
        }
    }

    @Test func test_apply_targets_only_its_own_field() {
        var spec = FilterSpec()
        SessionFacet.championship.apply("GT Cup", to: &spec)

        #expect(spec.championship == "GT Cup")
        #expect(spec.vehicle == nil)
        #expect(spec.racer == nil)
    }
}
