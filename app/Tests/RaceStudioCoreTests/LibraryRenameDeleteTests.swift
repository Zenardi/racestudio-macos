import Foundation
import Testing
@testable import RaceStudioCore

/// Behaviour for naming and removing library sessions.
///
/// A logger stamps the venue from whatever track was last configured on it, so the
/// name is often wrong — one of the user's two stints at the same circuit came
/// through as `Velopark1000`. A session therefore carries an optional user-set
/// name that overrides the decoded venue for display and search, leaving the
/// decoded value intact as the facet/filter key.
///
/// Removing a session always forgets the row; whether RaceStudio's own copy of the
/// file is also trashed is the caller's explicit choice, and a row still pointing
/// at a user-picked file can never have that file deleted.
@MainActor @Suite struct LibraryRenameDeleteTests {

    private func url(_ name: String) -> URL { URL(fileURLWithPath: "/tmp/\(name).xrk") }

    // MARK: - Display title

    @Test func test_a_session_displays_its_decoded_venue_by_default() {
        let model = LibraryBrowserModel()
        let summary = model.add(SessionFixture.make(track: "Velopark1000"), sourceURL: url("a"))

        #expect(summary.displayTitle == "Velopark1000")
    }

    /// A session whose header carried no track name must still render a title
    /// rather than an empty row.
    @Test func test_a_session_with_no_venue_falls_back_to_a_placeholder() {
        let model = LibraryBrowserModel()
        let summary = model.add(SessionFixture.make(track: ""), sourceURL: url("a"))

        #expect(summary.displayTitle == SessionSummary.untitledText)
    }

    // MARK: - Renaming

    @Test func test_renaming_overrides_the_displayed_title() {
        let model = LibraryBrowserModel()
        let summary = model.add(SessionFixture.make(track: "Velopark1000"), sourceURL: url("a"))

        model.rename(id: summary.id, to: "San Marino — Layout 2")

        #expect(model.sessions[0].displayTitle == "San Marino — Layout 2")
    }

    /// The decoded venue is the facet/filter key and stays untouched, so a renamed
    /// session still groups with its circuit.
    @Test func test_renaming_leaves_the_decoded_venue_intact() {
        let model = LibraryBrowserModel()
        let summary = model.add(SessionFixture.make(track: "Velopark1000"), sourceURL: url("a"))

        model.rename(id: summary.id, to: "San Marino")

        #expect(model.sessions[0].venue == "Velopark1000")
    }

    @Test func test_clearing_the_name_restores_the_decoded_venue() {
        let model = LibraryBrowserModel()
        let summary = model.add(SessionFixture.make(track: "Velopark1000"), sourceURL: url("a"))
        model.rename(id: summary.id, to: "San Marino")

        model.rename(id: summary.id, to: "")

        #expect(model.sessions[0].customName == nil)
        #expect(model.sessions[0].displayTitle == "Velopark1000")
    }

    /// A name of pure whitespace is a cleared name, not a blank title.
    @Test func test_a_whitespace_only_name_clears_rather_than_blanks_the_title() {
        let model = LibraryBrowserModel()
        let summary = model.add(SessionFixture.make(track: "Adria"), sourceURL: url("a"))

        model.rename(id: summary.id, to: "   \n ")

        #expect(model.sessions[0].displayTitle == "Adria")
    }

    @Test func test_a_name_is_trimmed_of_surrounding_whitespace() {
        let model = LibraryBrowserModel()
        let summary = model.add(SessionFixture.make(), sourceURL: url("a"))

        model.rename(id: summary.id, to: "  San Marino  ")

        #expect(model.sessions[0].customName == "San Marino")
    }

    @Test func test_renaming_an_unknown_session_changes_nothing() {
        let model = LibraryBrowserModel()
        model.add(SessionFixture.make(track: "Adria"), sourceURL: url("a"))

        model.rename(id: "not-a-session", to: "Nope")

        #expect(model.sessions[0].displayTitle == "Adria")
    }

    /// Free-text search is how the user finds a session they renamed, so the custom
    /// name has to be searchable alongside the decoded fields.
    @Test func test_search_matches_the_custom_name() {
        let model = LibraryBrowserModel()
        let summary = model.add(SessionFixture.make(track: "Velopark1000"), sourceURL: url("a"))
        model.rename(id: summary.id, to: "San Marino")

        model.search("marino")

        #expect(model.sessions.count == 1)
    }

    // MARK: - Renaming survives a save/load round trip

    @Test func test_a_custom_name_persists_through_the_library_index() throws {
        let index = SessionIndex()
        let summary = index.add(SessionFixture.make(track: "Velopark1000"), sourceURL: url("a"))
        index.rename(id: summary.id, to: "San Marino")

        let restored = try JSONDecoder().decode(
            SessionIndex.self, from: try JSONEncoder().encode(index))

        #expect(restored.summaries[0].customName == "San Marino")
    }

    // MARK: - Deleting

    @Test func test_deleting_removes_the_row() throws {
        let model = LibraryBrowserModel()
        let summary = model.add(SessionFixture.make(), sourceURL: url("a"))

        try model.delete(id: summary.id, .removeFromLibrary)

        #expect(model.sessions.isEmpty)
    }

    @Test func test_deleting_clears_a_selection_pointing_at_it() throws {
        let model = LibraryBrowserModel()
        let summary = model.add(SessionFixture.make(), sourceURL: url("a"))
        model.select(summary.id)

        try model.delete(id: summary.id, .removeFromLibrary)

        #expect(model.selectedID == nil)
    }

    @Test func test_deleting_keeps_a_selection_pointing_elsewhere() throws {
        let model = LibraryBrowserModel()
        let keep = model.add(SessionFixture.make(track: "Keep"), sourceURL: url("a"))
        let drop = model.add(SessionFixture.make(track: "Drop"), sourceURL: url("b"))
        model.select(keep.id)

        try model.delete(id: drop.id, .removeFromLibrary)

        #expect(model.selectedID == keep.id)
    }

    @Test func test_deleting_an_unknown_session_changes_nothing() throws {
        let model = LibraryBrowserModel()
        model.add(SessionFixture.make(), sourceURL: url("a"))

        try model.delete(id: "not-a-session", .removeFromLibrary)

        #expect(model.sessions.count == 1)
    }

    /// A deleted session must not linger as a phantom member of a manual collection.
    @Test func test_deleting_prunes_the_session_from_manual_collections() throws {
        let model = LibraryBrowserModel()
        let summary = model.add(SessionFixture.make(), sourceURL: url("a"))
        model.addCollection(.manual(id: "m", name: "Race day"))
        model.addSession(summary.id, toCollection: "m")

        try model.delete(id: summary.id, .removeFromLibrary)

        model.showCollection(id: "m")
        #expect(model.sessions.isEmpty)
        #expect(model.collections[0].memberIDs == [], "the stale member id is pruned")
    }
}

/// Deleting a session that RaceStudio holds its own copy of. The row always goes;
/// the copy goes only when asked, and a file the app does not own is never touched.
@MainActor @Suite struct LibraryDeleteFileTests {

    private func makeStore() throws -> Scratch {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rs-delete-\(UUID().uuidString)", isDirectory: true)
        let scratch = root.appendingPathComponent("Downloads", isDirectory: true)
        let managed = root.appendingPathComponent("Sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        return Scratch(store: ManagedFileStore(directory: managed), managed: managed, scratch: scratch)
    }

    private func adopted(_ files: ManagedFileStore, in scratch: URL, named: String) throws -> URL {
        let original = scratch.appendingPathComponent(named)
        try Data(named.utf8).write(to: original)
        return try files.adopt(original)
    }

    @Test func test_discarding_the_copy_removes_both_the_row_and_the_file() throws {
        let env = try makeStore()
        let model = LibraryBrowserModel(files: env.store)
        let copy = try adopted(env.store, in: env.scratch, named: "stint-1.xrk")
        let summary = model.add(SessionFixture.make(), sourceURL: copy)

        try model.delete(id: summary.id, .discardingCopy)

        #expect(model.sessions.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: copy.path))
    }

    @Test func test_removing_from_the_library_leaves_the_copy_on_disk() throws {
        let env = try makeStore()
        let model = LibraryBrowserModel(files: env.store)
        let copy = try adopted(env.store, in: env.scratch, named: "stint-1.xrk")
        let summary = model.add(SessionFixture.make(), sourceURL: copy)

        try model.delete(id: summary.id, .removeFromLibrary)

        #expect(model.sessions.isEmpty)
        #expect(FileManager.default.fileExists(atPath: copy.path))
    }

    /// A row imported before adoption existed still points at the user's own file.
    /// The row is forgotten, the file is not deleted, and the caller is told.
    @Test func test_discarding_a_legacy_row_forgets_it_without_touching_the_users_file() throws {
        let env = try makeStore()
        let model = LibraryBrowserModel(files: env.store)
        let original = env.scratch.appendingPathComponent("precious.xrk")
        try Data("telemetry".utf8).write(to: original)
        let summary = model.add(SessionFixture.make(), sourceURL: original)

        #expect(throws: ManagedFileStore.StorageError.notManaged) {
            try model.delete(id: summary.id, .discardingCopy)
        }
        #expect(model.sessions.isEmpty, "the row is removed before the file error is raised")
        #expect(FileManager.default.fileExists(atPath: original.path), "the user's file survives")
    }

    /// The confirmation sheet only offers "Move Copy to Trash" for rows the app
    /// actually owns a copy of, so it asks this first.
    @Test func test_only_a_managed_row_reports_a_discardable_copy() throws {
        let env = try makeStore()
        let model = LibraryBrowserModel(files: env.store)
        let managed = model.add(SessionFixture.make(track: "Managed"),
                                sourceURL: try adopted(env.store, in: env.scratch, named: "stint-1.xrk"))
        let legacy = model.add(SessionFixture.make(track: "Legacy"),
                               sourceURL: env.scratch.appendingPathComponent("precious.xrk"))

        #expect(model.canDiscardCopy(id: managed.id))
        #expect(!model.canDiscardCopy(id: legacy.id))
    }

    @Test func test_an_unknown_session_reports_no_discardable_copy() throws {
        let env = try makeStore()

        #expect(!LibraryBrowserModel(files: env.store).canDiscardCopy(id: "absent"))
    }

    /// With no managed store wired (the list-only test configuration) nothing is
    /// discardable, so the sheet degrades to "remove from library" alone.
    @Test func test_without_a_managed_store_nothing_is_discardable() {
        let model = LibraryBrowserModel()
        let summary = model.add(SessionFixture.make(), sourceURL: URL(fileURLWithPath: "/tmp/a.xrk"))

        #expect(!model.canDiscardCopy(id: summary.id))
    }
}

/// Re-importing a file the user has already renamed.
@MainActor @Suite struct LibraryRenameDedupTests {

    /// The summary is re-derived from the decode on every import, and the decode
    /// knows nothing about renames — so the rename has to be carried across
    /// explicitly or a re-import silently reverts the title.
    @Test func test_reimporting_preserves_a_name_the_user_chose() {
        let model = LibraryBrowserModel()
        let session = SessionFixture.make(track: "Velopark1000")
        let summary = model.add(session, sourceURL: URL(fileURLWithPath: "/tmp/a.xrk"))
        model.rename(id: summary.id, to: "San Marino")

        model.add(session, sourceURL: URL(fileURLWithPath: "/tmp/b.xrk"))

        #expect(model.sessions[0].displayTitle == "San Marino")
        #expect(model.sessions[0].sourceURL.lastPathComponent == "b.xrk", "the re-import still wins the URL")
    }
}
