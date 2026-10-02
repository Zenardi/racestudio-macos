import Foundation
import Testing
@testable import RaceStudioCore

/// The kart garage: karts are assigned per session, the last kart used at a
/// track pre-fills the next session imported from it, and every edit survives
/// a relaunch.
@Suite struct KartModelTests {

    private let f4 = Kart(id: "k1", name: "Race kart", category: "F4", chassis: "Thunder",
                          engine: "RBC Honda", powerHP: 18)

    @Test func test_specification_lists_every_field() {
        #expect(f4.specification == "F4 · Thunder · RBC Honda · 18 HP")
    }

    @Test func test_specification_skips_blank_fields() {
        let kart = Kart(name: "Spare", chassis: "Thunder")

        #expect(kart.specification == "Thunder")
    }

    @Test func test_fractional_power_keeps_one_decimal() {
        #expect(Kart(name: "x", powerHP: 12.5).powerText == "12.5 HP")
    }

    @Test(arguments: [0.0, -3.0, Double.nan, Double.infinity])
    func test_unusable_power_is_not_shown(power: Double) {
        #expect(Kart(name: "x", powerHP: power).powerText == nil)
    }

    @Test func test_display_name_is_the_name() {
        #expect(f4.displayName == "Race kart")
    }

    @Test func test_unnamed_kart_is_shown_by_its_specification() {
        #expect(Kart(name: "  ", category: "F4").displayName == "F4")
    }

    @Test func test_kart_with_nothing_set_is_never_blank() {
        #expect(Kart(name: "").displayName == "Unnamed kart")
    }

    @Test func test_normalized_trims_text_and_clears_bad_power() {
        let kart = Kart(id: "k", name: " Race ", category: " F4 ", powerHP: -1).normalized

        #expect(kart == Kart(id: "k", name: "Race", category: "F4", powerHP: nil))
    }
}

@Suite struct SessionIndexGarageTests {

    private static let f4 = Kart(id: "f4", name: "F4", category: "F4", chassis: "Thunder",
                                 engine: "RBC Honda", powerHP: 18)
    private static let spare = Kart(id: "spare", name: "Spare")
    private static let url = URL(fileURLWithPath: "/tmp/s.xrk")

    private static func indexWithGarage() -> SessionIndex {
        let index = SessionIndex()
        index.upsertKart(f4)
        index.upsertKart(spare)
        return index
    }

    @Test func test_garage_lists_karts_by_name() {
        let index = Self.indexWithGarage()

        #expect(index.karts.map(\.id) == ["f4", "spare"])
    }

    @Test func test_session_has_no_kart_until_one_is_assigned() {
        let index = Self.indexWithGarage()

        let summary = index.add(SessionFixture.make(), sourceURL: Self.url)

        #expect(summary.kartID == nil)
    }

    @Test func test_assigning_a_kart_records_it_on_the_session() {
        let index = Self.indexWithGarage()
        let summary = index.add(SessionFixture.make(), sourceURL: Self.url)

        index.assignKart("f4", toSession: summary.id)

        #expect(index.summary(id: summary.id)?.kartID == "f4")
    }

    @Test func test_next_session_at_the_same_track_gets_its_kart() {
        let index = Self.indexWithGarage()
        let first = index.add(SessionFixture.make(datetimeUtc: 1), sourceURL: Self.url)
        index.assignKart("f4", toSession: first.id)

        let next = index.add(SessionFixture.make(datetimeUtc: 2), sourceURL: Self.url)

        #expect(next.kartID == "f4")
    }

    @Test func test_session_at_another_track_gets_no_kart() {
        let index = Self.indexWithGarage()
        let first = index.add(SessionFixture.make(track: "Fuji", datetimeUtc: 1), sourceURL: Self.url)
        index.assignKart("f4", toSession: first.id)

        let other = index.add(SessionFixture.make(track: "Suzuka", datetimeUtc: 2), sourceURL: Self.url)

        #expect(other.kartID == nil)
    }

    @Test func test_the_last_assigned_kart_is_the_default() {
        let index = Self.indexWithGarage()
        let first = index.add(SessionFixture.make(datetimeUtc: 1), sourceURL: Self.url)
        index.assignKart("f4", toSession: first.id)
        index.assignKart("spare", toSession: first.id)

        #expect(index.defaultKart(forTrackOf: first) == Self.spare)
    }

    @Test func test_reimport_keeps_the_chosen_kart() {
        let index = Self.indexWithGarage()
        let first = index.add(SessionFixture.make(datetimeUtc: 1), sourceURL: Self.url)
        index.assignKart("spare", toSession: first.id)
        let other = index.add(SessionFixture.make(datetimeUtc: 2), sourceURL: Self.url)
        index.assignKart("f4", toSession: other.id)

        let again = index.add(SessionFixture.make(datetimeUtc: 1), sourceURL: Self.url)

        #expect(again.kartID == "spare")
    }

    @Test func test_clearing_the_kart_unassigns_the_session() {
        let index = Self.indexWithGarage()
        let summary = index.add(SessionFixture.make(), sourceURL: Self.url)
        index.assignKart("f4", toSession: summary.id)

        index.assignKart(nil, toSession: summary.id)

        #expect(index.summary(id: summary.id)?.kartID == nil)
    }

    @Test func test_unknown_kart_is_not_assigned() {
        let index = Self.indexWithGarage()
        let summary = index.add(SessionFixture.make(), sourceURL: Self.url)

        index.assignKart("nope", toSession: summary.id)

        #expect(index.summary(id: summary.id)?.kartID == nil)
    }

    @Test func test_deleting_a_kart_unassigns_its_sessions_and_defaults() {
        let index = Self.indexWithGarage()
        let first = index.add(SessionFixture.make(datetimeUtc: 1), sourceURL: Self.url)
        index.assignKart("f4", toSession: first.id)

        index.removeKart(id: "f4")
        let next = index.add(SessionFixture.make(datetimeUtc: 2), sourceURL: Self.url)

        #expect(index.summary(id: first.id)?.kartID == nil)
        #expect(next.kartID == nil)
        #expect(index.kart(id: "f4") == nil)
    }

    @Test func test_kart_filter_keeps_only_its_sessions() {
        let index = Self.indexWithGarage()
        let onF4 = index.add(SessionFixture.make(datetimeUtc: 1), sourceURL: Self.url)
        index.assignKart("f4", toSession: onF4.id)
        index.add(SessionFixture.make(track: "Elsewhere", datetimeUtc: 2), sourceURL: Self.url)

        let filtered = index.filter(FilterSpec(kartID: "f4"))

        #expect(filtered.map(\.id) == [onF4.id])
    }

    @Test func test_garage_survives_a_save_and_load() throws {
        let index = Self.indexWithGarage()
        let summary = index.add(SessionFixture.make(), sourceURL: Self.url)
        index.assignKart("f4", toSession: summary.id)

        let reloaded = try JSONDecoder().decode(SessionIndex.self, from: JSONEncoder().encode(index))

        #expect(reloaded == index)
        #expect(reloaded.defaultKart(forTrackOf: summary) == Self.f4)
    }

    @Test func test_library_from_before_the_garage_loads_with_none() throws {
        let legacy = Data(#"{"summaries": [], "decoderGeneration": 2}"#.utf8)

        let index = try JSONDecoder().decode(SessionIndex.self, from: legacy)

        #expect(index.karts.isEmpty)
    }

    @Test func test_an_unreadable_kart_is_skipped_not_fatal() throws {
        let json = #"{"summaries": [], "karts": [{"id": "ok", "name": "Good", "category": "", "#
            + #""chassis": "", "engine": ""}, {"broken": true}]}"#

        let index = try JSONDecoder().decode(SessionIndex.self, from: Data(json.utf8))

        #expect(index.karts.map(\.id) == ["ok"])
    }
}

@MainActor
@Suite struct LibraryBrowserGarageTests {

    private static let f4 = Kart(id: "f4", name: "F4", category: "F4", chassis: "Thunder",
                                 engine: "RBC Honda", powerHP: 18)

    private static func tempLibrary() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("garage-\(UUID().uuidString).json")
    }

    @Test func test_saved_kart_joins_the_garage() {
        let model = LibraryBrowserModel()

        model.saveKart(Self.f4)

        #expect(model.karts == [Self.f4])
    }

    @Test func test_assigned_kart_is_found_for_the_session() {
        let model = LibraryBrowserModel()
        model.saveKart(Self.f4)
        let session = SessionFixture.make()
        let summary = model.add(session, sourceURL: URL(fileURLWithPath: "/tmp/s.xrk"))

        model.assignKart("f4", toSession: summary.id)

        #expect(model.kart(for: session) == Self.f4)
        #expect(model.kart(forSession: summary.id) == Self.f4)
    }

    @Test func test_kart_filter_narrows_the_list() {
        let model = LibraryBrowserModel()
        model.saveKart(Self.f4)
        let onF4 = model.add(SessionFixture.make(datetimeUtc: 1), sourceURL: URL(fileURLWithPath: "/tmp/a"))
        model.add(SessionFixture.make(track: "Other", datetimeUtc: 2), sourceURL: URL(fileURLWithPath: "/tmp/b"))
        model.assignKart("f4", toSession: onF4.id)

        model.setKartFilter("f4")

        #expect(model.sessions.map(\.id) == [onF4.id])
        #expect(model.kartFilter == "f4")
    }

    @Test func test_deleting_the_filtered_kart_clears_the_filter() {
        let model = LibraryBrowserModel()
        model.saveKart(Self.f4)
        model.setKartFilter("f4")

        model.deleteKart(id: "f4")

        #expect(model.kartFilter == nil)
        #expect(model.karts.isEmpty)
    }

    @Test func test_garage_edits_are_saved_without_an_import() {
        let url = Self.tempLibrary()
        let model = LibraryBrowserModel(loadingFrom: url)

        model.saveKart(Self.f4)

        #expect(LibraryStore().load(from: url).karts == [Self.f4])
    }

    @Test func test_rename_is_saved_without_an_import() {
        let url = Self.tempLibrary()
        let model = LibraryBrowserModel(loadingFrom: url)
        let summary = model.add(SessionFixture.make(), sourceURL: URL(fileURLWithPath: "/tmp/s.xrk"))

        model.rename(id: summary.id, to: "Morning stint")

        #expect(LibraryStore().load(from: url).summary(id: summary.id)?.customName == "Morning stint")
    }

    @Test func test_in_memory_library_writes_nothing() {
        let model = LibraryBrowserModel()

        model.saveKart(Self.f4)

        #expect(model.karts.count == 1) // no autosave target, no crash
    }
}

/// The analysis summary panel names the session's kart.
@Suite struct SummaryKartTests {

    @Test func test_summary_shows_the_kart_with_its_specification() {
        let kart = Kart(name: "Race kart", category: "F4", chassis: "Thunder", engine: "RBC Honda", powerHP: 18)

        let model = SessionSummaryViewModel(session: SessionFixture.make(), kart: kart)

        #expect(model.metadata.kart == "Race kart — F4 · Thunder · RBC Honda · 18 HP")
    }

    @Test func test_kart_without_specification_shows_its_name() {
        let model = SessionSummaryViewModel(session: SessionFixture.make(), kart: Kart(name: "Spare"))

        #expect(model.metadata.kart == "Spare")
    }

    @Test func test_no_kart_hides_the_row() {
        #expect(SessionSummaryViewModel(session: SessionFixture.make()).metadata.kart == nil)
    }
}
