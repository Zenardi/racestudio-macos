import Testing
import Foundation
@testable import RaceStudioCore

/// Tests for `SessionCollection` (issue 8.15) — a named RS3 collection that is
/// either **smart** (rule-based, backed by a `FilterSpec`) or **manual** (a
/// curated, ordered set of session content ids built by drag-and-drop). It is
/// `Codable` so both flavours persist in the library JSON.
@Suite struct SessionCollectionTests {

    // MARK: - construction / accessors

    @Test func test_smart_collection_carries_its_rule() {
        let rule = FilterSpec(vehicle: "SFJ", minLaps: 5)
        let collection = SessionCollection.smart(id: "c1", name: "Fast SFJ", rule: rule)

        #expect(collection.id == "c1")
        #expect(collection.name == "Fast SFJ")
        #expect(collection.isSmart)
        #expect(collection.rule == rule)
        #expect(collection.memberIDs.isEmpty)
    }

    @Test func test_manual_collection_carries_ordered_members() {
        let collection = SessionCollection.manual(id: "c2", name: "Favourites", members: ["a", "b"])

        #expect(collection.isSmart == false)
        #expect(collection.memberIDs == ["a", "b"])
        #expect(collection.rule == nil)
    }

    @Test func test_manual_collection_defaults_to_empty_members() {
        #expect(SessionCollection.manual(id: "c", name: "Empty").memberIDs.isEmpty)
    }

    // MARK: - curating a manual collection (drag-and-drop persistence)

    @Test func test_adding_a_member_appends_in_order() {
        let collection = SessionCollection.manual(id: "c", name: "Curated", members: ["a"])

        let updated = collection.adding("b")

        #expect(updated.memberIDs == ["a", "b"])
    }

    @Test func test_adding_an_existing_member_is_idempotent() {
        let collection = SessionCollection.manual(id: "c", name: "Curated", members: ["a", "b"])

        #expect(collection.adding("a").memberIDs == ["a", "b"])  // no duplicate, order kept
    }

    @Test func test_removing_a_member_drops_it() {
        let collection = SessionCollection.manual(id: "c", name: "Curated", members: ["a", "b", "c"])

        #expect(collection.removing("b").memberIDs == ["a", "c"])
    }

    @Test func test_removing_an_absent_member_is_a_no_op() {
        let collection = SessionCollection.manual(id: "c", name: "Curated", members: ["a"])

        #expect(collection.removing("z").memberIDs == ["a"])
    }

    @Test func test_curating_a_smart_collection_is_a_no_op() {
        // A smart collection is rule-driven; you cannot hand-add members to it.
        let smart = SessionCollection.smart(id: "c", name: "Rule", rule: FilterSpec(vehicle: "SFJ"))

        #expect(smart.adding("a") == smart)
        #expect(smart.removing("a") == smart)
    }

    // MARK: - Codable (persists in the library JSON)

    @Test func test_smart_collection_codable_roundtrip() throws {
        let collection = SessionCollection.smart(
            id: "c1", name: "Wet GT Cup",
            rule: FilterSpec(championship: "GT Cup", comment: "Wet"))

        let data = try JSONEncoder().encode(collection)
        let decoded = try JSONDecoder().decode(SessionCollection.self, from: data)

        #expect(decoded == collection)
    }

    @Test func test_manual_collection_codable_roundtrip_preserves_order() throws {
        let collection = SessionCollection.manual(id: "c2", name: "Shortlist", members: ["z", "a", "m"])

        let data = try JSONEncoder().encode(collection)
        let decoded = try JSONDecoder().decode(SessionCollection.self, from: data)

        #expect(decoded == collection)
        #expect(decoded.memberIDs == ["z", "a", "m"])
    }
}
