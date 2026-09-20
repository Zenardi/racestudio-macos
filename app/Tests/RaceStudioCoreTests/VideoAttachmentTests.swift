import Testing
import Foundation

@testable import RaceStudioCore

/// Tests for the persisted video attachment (issue 9.6): the `VideoAttachment`
/// value, the ``VideoAttachmentStore`` that turns a user-picked file into a
/// re-openable bookmark (and back), and the schema-v5 `ProjectDocument.video`
/// field that carries the attached footage and its sync offset across a
/// save/reopen.
///
/// The bookmark seam is faked, so none of this touches real security-scoped
/// bookmarks or the sandbox.
@Suite struct VideoAttachmentTests {

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rsvideo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func store() -> ProjectStore { ProjectStore(validator: FakeExpressionValidator()) }

    private let videoURL = URL(fileURLWithPath: "/tmp/onboard/session-lap.mp4")

    private func attachment(offset: Double = 0) -> VideoAttachment {
        VideoAttachment(bookmark: Data("/tmp/onboard/session-lap.mp4".utf8),
                        displayName: "session-lap.mp4", offset: offset)
    }

    private func document(video: VideoAttachment?) -> ProjectDocument {
        ProjectDocument(
            sessionRefs: [SessionRef(id: "s1", displayName: "Fuji")],
            layout: AnalysisLayout(panes: [Pane(channelNames: ["Speed"])], xAxisMode: .time),
            selectedLaps: [LapSelection(sessionID: "s1", lapIndices: [0])],
            video: video)
    }

    // MARK: - The attachment value

    /// The attachment carries everything needed to bring the footage back: the
    /// bookmark, a name to show, and the alignment the operator settled on.
    @Test func test_attachment_carries_bookmark_name_and_offset() {
        let attached = attachment(offset: -12.5)

        #expect(attached.displayName == "session-lap.mp4")
        #expect(attached.offset == -12.5)
        #expect(!attached.bookmark.isEmpty)
    }

    /// A non-finite offset can never be persisted — it would defeat the clamp in
    /// `VideoSyncModel` on the next load.
    @Test func test_nonfinite_offset_is_sanitized() {
        #expect(VideoAttachment(bookmark: Data(), displayName: "v", offset: .nan).offset == 0)
        #expect(VideoAttachment(bookmark: Data(), displayName: "v", offset: .infinity).offset == 0)
    }

    /// Re-aligning the footage produces a new attachment against the same file.
    @Test func test_reoffsetting_keeps_the_same_file() {
        let moved = attachment(offset: 3).withOffset(-9)

        #expect(moved.offset == -9)
        #expect(moved.bookmark == attachment().bookmark)
        #expect(moved.displayName == "session-lap.mp4")
    }

    /// The value encodes and decodes unchanged — it is persisted inside the
    /// project document.
    @Test func test_attachment_roundtrips_through_codable() throws {
        let original = attachment(offset: 7.25)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(VideoAttachment.self, from: data)

        #expect(decoded == original)
    }

    // MARK: - Attaching and resolving

    /// Attaching a picked file bookmarks it and names it after the file.
    @Test func test_attaching_a_file_bookmarks_and_names_it() throws {
        let attached = try VideoAttachmentStore(bookmarks: FakeBookmarkStore()).attach(videoURL, offset: 4)

        #expect(attached.displayName == "session-lap.mp4")
        #expect(attached.offset == 4)
        #expect(!attached.bookmark.isEmpty)
    }

    /// Resolving an attachment hands back the same file, so a reopened project
    /// plays the footage it was saved with.
    @Test func test_resolving_returns_the_attached_file() throws {
        let videoStore = VideoAttachmentStore(bookmarks: FakeBookmarkStore())
        let attached = try videoStore.attach(videoURL)

        let resolved = try videoStore.resolve(attached)

        #expect(resolved.path == videoURL.resolvingSymlinksInPath().path)
    }

    /// A deleted or unreadable file surfaces as a typed failure, so the panel can
    /// say the video is gone instead of failing the whole project load.
    @Test func test_a_broken_bookmark_reports_unresolvable() throws {
        let bookmarks = FakeBookmarkStore()
        bookmarks.brokenPaths = [videoURL.resolvingSymlinksInPath().path]
        let videoStore = VideoAttachmentStore(bookmarks: bookmarks)
        let attached = try videoStore.attach(videoURL)

        #expect(throws: VideoAttachmentError.unresolvable) { try videoStore.resolve(attached) }
    }

    /// A moved file resolves but is stale — a distinct signal, so the panel can
    /// offer to re-link rather than silently playing a copy.
    @Test func test_a_moved_file_reports_stale() throws {
        let bookmarks = FakeBookmarkStore()
        bookmarks.stalePaths = [videoURL.resolvingSymlinksInPath().path]
        let videoStore = VideoAttachmentStore(bookmarks: bookmarks)
        let attached = try videoStore.attach(videoURL)

        #expect(throws: VideoAttachmentError.stale) { try videoStore.resolve(attached) }
    }

    /// A bookmark that cannot even be created fails at attach time rather than
    /// producing an attachment that can never resolve.
    @Test func test_unbookmarkable_file_fails_to_attach() {
        let bookmarks = FailingBookmarkStore()

        #expect(throws: VideoAttachmentError.unresolvable) {
            try VideoAttachmentStore(bookmarks: bookmarks).attach(videoURL)
        }
    }

    // MARK: - Persistence in the project

    /// The attached video is part of the saved workspace: save, reopen, and the
    /// same footage comes back aligned exactly as it was left.
    @Test func test_video_roundtrips_through_save_load() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("p.rsproj")
        let doc = document(video: attachment(offset: -12.5))

        try store().save(doc, to: url)
        let loaded = try store().load(from: url)

        #expect(loaded.video == attachment(offset: -12.5))
        #expect(loaded.video?.offset == -12.5, "the alignment survives the round trip")
        #expect(loaded == doc)
    }

    /// A workspace with no video saves and loads as one.
    @Test func test_a_project_without_a_video_roundtrips() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("novideo.rsproj")

        try store().save(document(video: nil), to: url)
        let loaded = try store().load(from: url)

        #expect(loaded.video == nil)
    }

    /// The attached video is part of value equality — two workspaces differing
    /// only in their footage are different documents.
    @Test func test_documents_differing_only_in_video_are_not_equal() {
        #expect(document(video: attachment()) != document(video: nil))
        #expect(document(video: attachment(offset: 1)) != document(video: attachment(offset: 2)))
    }

    /// A project saved before 9.6 has no video key; it migrates forward with no
    /// attachment rather than failing to load.
    @Test func test_v4_document_migrates_forward_without_a_video() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("v4.rsproj")
        let v4 = """
        {
          "schemaVersion": 4,
          "sessionRefs": [{"id": "s1", "displayName": "Fuji"}],
          "layout": {"panes": [{"channelNames": ["Speed", "RPM"]}], "xAxisMode": "distance"},
          "selectedLaps": [{"sessionID": "s1", "lapIndices": [3, 4]}],
          "mathChannels": [{"name": "AccelMag", "unit": "g", "expression": "sqrt(Ax*Ax + Ay*Ay)"}],
          "activeLayout": "trackMap",
          "logSheet": {
            "weather": {"conditions": "Dry"},
            "engine": {"make": "", "notes": ""},
            "dimensions": {},
            "weights": {},
            "fuel": {"type": ""},
            "gearing": {"finalDrive": "", "primaryDrive": "", "ratios": []},
            "notes": "bedded pads"
          }
        }
        """
        try Data(v4.utf8).write(to: url)

        let loaded = try store().load(from: url)

        #expect(loaded.schemaVersion == ProjectDocument.currentSchemaVersion)
        #expect(loaded.video == nil, "a pre-9.6 project has no attached footage")
        #expect(loaded.activeLayout == .trackMap, "the rest migrates unchanged")
        #expect(loaded.logSheet.weather.conditions == "Dry", "the v4 log sheet carries over")
        #expect(loaded.logSheet.notes == "bedded pads")
        #expect(loaded.selectedLaps == [LapSelection(sessionID: "s1", lapIndices: [3, 4])])
        #expect(loaded.mathChannels.first?.unit == "g")
    }

    /// The schema version was bumped for this field — a v5 file is this build's
    /// current shape.
    @Test func test_schema_version_is_five() {
        #expect(ProjectDocument.currentSchemaVersion == 5)
    }
}

/// A `BookmarkStoring` whose bookmark creation always fails — the attach-time
/// error path.
private final class FailingBookmarkStore: BookmarkStoring, @unchecked Sendable {
    func data(for url: URL) throws -> Data { throw BookmarkError.unresolvable }
    func url(for data: Data) throws -> (url: URL, isStale: Bool) { throw BookmarkError.unresolvable }
}

/// Tests for carrying the attached video through the window ↔ project mapping
/// (issue 9.6): the window does not own the footage (the video-review player
/// does), so it is passed in when the workspace is captured.
@MainActor
@Suite struct VideoWorkspaceMappingTests {

    private func window() -> AnalysisWindowModel {
        AnalysisWindowModel(session: Session(
            metadata: SessionMetadata(vehicle: "Kart", track: "Fuji", driver: "EZ", session: "S1",
                                      series: "", logDate: "", logTime: "", datetimeUtc: 0),
            channels: [], laps: []), analysis: nil)
    }

    private func attachment() -> VideoAttachment {
        VideoAttachment(bookmark: Data("bm".utf8), displayName: "onboard.mp4", offset: -3.5)
    }

    /// Capturing the workspace carries the attached footage and its alignment.
    @Test func test_captured_workspace_carries_the_attached_video() {
        #expect(window().projectDocument(video: attachment()).video == attachment())
    }

    /// A workspace captured with no video attached persists none.
    @Test func test_captured_workspace_without_a_video_carries_none() {
        #expect(window().projectDocument().video == nil)
    }
}
