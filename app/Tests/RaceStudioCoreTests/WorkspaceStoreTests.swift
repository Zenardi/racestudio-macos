import Testing
import Foundation
@testable import RaceStudioCore

/// Tests for ``WorkspaceStore`` (issue 9.20): each session's workspace, kept in
/// the app's own folder under the session's content id, so it comes back when
/// the session is opened again — with no Save and no file to pick.
@Suite struct WorkspaceStoreTests {

    // MARK: - Fixture (no logic — fixed data)

    private let session = String(repeating: "ab12", count: 16)

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func store(in dir: URL, write: ((Data, URL) throws -> Void)? = nil) -> WorkspaceStore {
        WorkspaceStore(directory: dir, validator: FakeExpressionValidator(), write: write)
    }

    private var document: ProjectDocument {
        ProjectDocument(sessionRefs: [SessionRef(id: session, displayName: "Practice")],
                        layout: AnalysisLayout(panes: [Pane(channelNames: ["RPM"])], xAxisMode: .time),
                        selectedLaps: [LapSelection(sessionID: session, lapIndices: [1, 2], reference: 2)],
                        activeLayout: .videoReview,
                        overlay: OverlayPreset.minimal.layout(locale: Locale(identifier: "en")))
    }

    private struct DiskFull: Error {}

    // MARK: - Saving and loading

    /// A workspace is written to `<content id>.rsproj` in the store's folder and
    /// read back value-equal.
    @Test func test_a_workspace_is_saved_under_the_sessions_content_id() throws {
        let dir = try makeTempDir()
        let store = store(in: dir)

        try store.save(document, session: session)

        #expect(store.url(forSession: session) == dir.appendingPathComponent("\(session).rsproj"))
        #expect(FileManager.default.fileExists(atPath: store.url(forSession: session).path))
        #expect(store.load(session: session) == .document(document))
    }

    /// A session never saved has no workspace.
    @Test func test_a_session_without_a_saved_workspace_has_none() throws {
        let store = store(in: try makeTempDir())

        #expect(store.load(session: session) == .none)
    }

    /// The folder is created on the first save.
    @Test func test_the_folder_is_created_on_the_first_save() throws {
        let dir = try makeTempDir().appendingPathComponent("Workspaces", isDirectory: true)

        try store(in: dir).save(document, session: session)

        #expect(FileManager.default.fileExists(atPath: dir.path))
    }

    /// A write that fails is reported, and the previous workspace stays.
    @Test func test_a_failed_write_throws_and_keeps_the_previous_workspace() throws {
        let dir = try makeTempDir()
        try store(in: dir).save(document, session: session)
        var changed = document
        changed.activeLayout = .trackMap

        #expect(throws: ProjectError.ioFailure) {
            try store(in: dir, write: { _, _ in throw DiskFull() }).save(changed, session: session)
        }
        #expect(store(in: dir).load(session: session) == .document(document))
    }

    // MARK: - Unreadable workspaces

    /// A corrupt workspace is moved aside, byte for byte, so the next save can
    /// never overwrite it.
    @Test func test_an_unreadable_workspace_is_kept_aside() throws {
        let dir = try makeTempDir()
        let store = store(in: dir)
        let garbage = Data("not a workspace".utf8)
        try garbage.write(to: store.url(forSession: session))

        let loaded = store.load(session: session)

        #expect(loaded == .unreadable(keptAside: true))
        #expect(!FileManager.default.fileExists(atPath: store.url(forSession: session).path))
        #expect(try Data(contentsOf: store.asideURL(forSession: session)) == garbage)
    }

    /// A workspace written by a newer RaceStudio is kept aside too, so going
    /// back to this version never destroys it.
    @Test func test_a_workspace_from_a_newer_version_is_kept_aside() throws {
        let dir = try makeTempDir()
        let store = store(in: dir)
        let newer = Data(#"{"schemaVersion": 999}"#.utf8)
        try newer.write(to: store.url(forSession: session))

        #expect(store.load(session: session) == .unreadable(keptAside: true))
        #expect(try Data(contentsOf: store.asideURL(forSession: session)) == newer)
    }

    /// A workspace that can't be read or moved stays where it is, and the load
    /// says it couldn't be kept aside.
    @Test func test_an_unreadable_workspace_that_cannot_be_moved_stays_in_place() throws {
        let dir = try makeTempDir()
        let store = store(in: dir)
        try Data("not a workspace".utf8).write(to: store.url(forSession: session))
        // A read-only folder: the file reads, but nothing in it can move.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }

        #expect(store.load(session: session) == .unreadable(keptAside: false))
        #expect(FileManager.default.fileExists(atPath: store.url(forSession: session).path))
    }

    /// A second unreadable workspace replaces the first one kept aside.
    @Test func test_keeping_aside_replaces_an_older_aside_file() throws {
        let dir = try makeTempDir()
        let store = store(in: dir)
        try Data("old".utf8).write(to: store.asideURL(forSession: session))
        try Data("new".utf8).write(to: store.url(forSession: session))

        #expect(store.load(session: session) == .unreadable(keptAside: true))
        #expect(try Data(contentsOf: store.asideURL(forSession: session)) == Data("new".utf8))
    }

    // MARK: - Deleting

    /// Deleting a session's workspace removes its file; deleting one that was
    /// never saved is fine.
    @Test func test_deleting_a_workspace_removes_its_file() throws {
        let dir = try makeTempDir()
        let store = store(in: dir)
        try store.save(document, session: session)

        store.delete(session: session)
        store.delete(session: "ffff")

        #expect(store.load(session: session) == .none)
    }

    /// A workspace that can't be deleted stays readable, and nothing throws.
    @Test func test_a_workspace_that_cannot_be_deleted_stays() throws {
        let dir = try makeTempDir()
        let store = store(in: dir)
        try store.save(document, session: session)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }

        store.delete(session: session)

        #expect(store.load(session: session) == .document(document))
    }

    // MARK: - File names

    /// The file is named by the content id only when it is a plain hex id;
    /// anything else is hashed, so a name can never leave the folder.
    @Test(arguments: ["../../escape", "a/b", "", "ID WITH SPACES", String(repeating: "f", count: 200)])
    func test_a_content_id_always_names_a_file_in_the_folder(id: String) throws {
        let dir = try makeTempDir()
        let store = store(in: dir)

        let url = store.url(forSession: id)

        #expect(url.deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL)
        #expect(url.pathExtension == "rsproj")
        #expect(url.lastPathComponent.count <= 80)
        #expect(store.asideURL(forSession: id).deletingLastPathComponent().standardizedFileURL
                    == dir.standardizedFileURL)
    }

    /// Two different ids never share a file.
    @Test func test_different_ids_name_different_files() throws {
        let store = store(in: try makeTempDir())

        #expect(store.url(forSession: "a/b") != store.url(forSession: "a_b"))
        #expect(store.url(forSession: session) != store.url(forSession: session.uppercased()))
    }

    /// The default folder sits beside the library in Application Support.
    @Test func test_the_default_folder_is_beside_the_library() {
        #expect(WorkspaceStore.defaultDirectory()
                    == LibraryStore.defaultURL().deletingLastPathComponent()
                        .appendingPathComponent("Workspaces", isDirectory: true))
    }
}
