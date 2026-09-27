import Foundation
import Testing
@testable import RaceStudioCore

/// Behaviour for what happens once an import finishes.
///
/// Importing leaves the user in the library with no signal that anything is ready
/// to look at, so a completed import offers to open the session for analysis. The
/// offer is suppressible in both directions — "always" opens straight away,
/// "never" stays put — and the standing answer persists across launches.
@Suite struct ImportFollowUpTests {

    private func summary(_ track: String = "San Marino") -> SessionSummary {
        SessionIndex().add(SessionFixture.make(track: track),
                           sourceURL: URL(fileURLWithPath: "/tmp/\(track).xrk"))
    }

    private func policy(_ store: KeyValueStoring = InMemoryKeyValueStore()) -> ImportFollowUpPolicy {
        ImportFollowUpPolicy(store: store)
    }

    // MARK: - Default: ask

    @Test func test_a_fresh_install_asks_before_opening() {
        let imported = summary()

        #expect(policy().followUp(for: [imported]) == .ask(imported))
    }

    @Test func test_the_default_preference_is_to_ask() {
        #expect(policy().preference == .ask)
    }

    // MARK: - Standing answers

    @Test func test_choosing_always_opens_without_asking() {
        let subject = policy()
        let imported = summary()

        subject.preference = .always

        #expect(subject.followUp(for: [imported]) == .open(imported))
    }

    @Test func test_choosing_never_stays_in_the_library() {
        let subject = policy()

        subject.preference = .never

        #expect(subject.followUp(for: [summary()]) == .stay)
    }

    @Test func test_a_standing_answer_persists_across_launches() {
        let store = InMemoryKeyValueStore()
        let first = policy(store)

        first.preference = .always

        #expect(policy(store).preference == .always, "a relaunched policy reads the saved answer")
    }

    /// A defaults value written by a future version (or corrupted) must not crash
    /// or silently lock the user into a behaviour they cannot see.
    @Test func test_an_unreadable_saved_answer_falls_back_to_asking() {
        let store = InMemoryKeyValueStore(seed: ["import.followUp": Data("nonsense".utf8)])

        #expect(policy(store).preference == .ask)
    }

    // MARK: - Nothing to offer

    @Test func test_an_import_that_produced_nothing_stays_put() {
        #expect(policy().followUp(for: []) == .stay)
    }

    /// A batch import is a "fill my library" action, not a "show me this one"
    /// action, so it never hijacks the window — whatever the standing answer.
    @Test func test_a_batch_import_never_opens_or_asks() {
        let subject = policy()
        let batch = [summary("Adria"), summary("Mugello")]

        #expect(subject.followUp(for: batch) == .stay)
        subject.preference = .always
        #expect(subject.followUp(for: batch) == .stay)
    }
}
