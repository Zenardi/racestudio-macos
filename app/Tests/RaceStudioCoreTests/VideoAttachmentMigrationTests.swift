import Testing
import Foundation

@testable import RaceStudioCore

/// Tests for the issue 9.7 additions to the persisted video attachment: the clock
/// ``VideoAttachment/rate`` and the ``SyncStatus`` are saved with the workspace
/// (`.rsproj` schema **v6**), and a v5 project — saved before either existed —
/// opens unchanged at `rate = 1`.
///
/// Every fixture here is synthetic: the "bookmark" is the bytes of a made-up
/// path, never real footage.
@Suite struct VideoAttachmentMigrationTests {

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rsvideo-v6-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func store() -> ProjectStore { ProjectStore(validator: FakeExpressionValidator()) }

    private let bookmark = Data("/tmp/onboard/session-lap.mp4".utf8)

    /// A v5 `.rsproj` as 9.6 wrote it, with the given `video` JSON (or none).
    private func v5Project(video: String?) -> String {
        let videoField = video.map { #","video": \#($0)"# } ?? ""
        return """
        {
          "schemaVersion": 5,
          "sessionRefs": [{"id": "s1", "displayName": "Fuji"}],
          "layout": {"panes": [{"channelNames": ["Speed"]}], "xAxisMode": "time"},
          "selectedLaps": [{"sessionID": "s1", "lapIndices": [2]}],
          "mathChannels": [],
          "activeLayout": "videoReview",
          "logSheet": {
            "weather": {"conditions": "Wet"},
            "engine": {"make": "", "notes": ""},
            "dimensions": {},
            "weights": {},
            "fuel": {"type": ""},
            "gearing": {"finalDrive": "", "primaryDrive": "", "ratios": []},
            "notes": ""
          }\(videoField)
        }
        """
    }

    private func v5Video(offset: Double) -> String {
        #"{"bookmark": "\#(bookmark.base64EncodedString())", "displayName": "session-lap.mp4", "offset": \#(offset)}"#
    }

    private func load(_ json: String) throws -> ProjectDocument {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("project.rsproj")
        try Data(json.utf8).write(to: url)
        return try store().load(from: url)
    }

    // MARK: - v5 → v6

    /// A v5 video never aligned (offset 0) migrates at unit rate, not synced.
    @Test func test_v5_unaligned_video_migrates_as_not_synced() throws {
        let loaded = try load(v5Project(video: v5Video(offset: 0)))

        #expect(loaded.schemaVersion == ProjectDocument.currentSchemaVersion)
        #expect(loaded.video?.rate == 1)
        #expect(loaded.video?.status == .notSynced)
        #expect(loaded.video?.bookmark == bookmark)
    }

    /// A v5 video with an offset was aligned by the operator: it migrates as
    /// synced by hand, the offset unchanged and the rate `1`.
    @Test func test_v5_aligned_video_migrates_as_anchored() throws {
        let loaded = try load(v5Project(video: v5Video(offset: -12.5)))

        #expect(loaded.video == VideoAttachment(bookmark: bookmark, displayName: "session-lap.mp4",
                                                offset: -12.5, rate: 1, status: .anchored(lap: nil)))
    }

    /// Everything else in a v5 project carries over unchanged.
    @Test func test_v5_project_migrates_the_rest_unchanged() throws {
        let loaded = try load(v5Project(video: v5Video(offset: 3)))

        #expect(loaded.activeLayout == .videoReview)
        #expect(loaded.logSheet.weather.conditions == "Wet")
        #expect(loaded.selectedLaps == [LapSelection(sessionID: "s1", lapIndices: [2])])
    }

    /// A v5 project with no video stays without one.
    @Test func test_v5_project_without_a_video_migrates_without_one() throws {
        #expect(try load(v5Project(video: nil)).video == nil)
    }

    /// The schema was bumped for these fields: a save is stamped v6 on disk.
    @Test func test_saved_projects_are_stamped_v6() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("stamp.rsproj")
        try store().save(ProjectDocument(layout: AnalysisLayout(panes: [], xAxisMode: .time)), to: url)

        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]

        #expect(json?["schemaVersion"] as? Int == 6)
    }

    /// A corrupt sync status is cosmetic: the project still opens, the footage
    /// simply reads as not synced, and its offset and rate survive.
    @Test func test_a_malformed_status_opens_as_not_synced() throws {
        let video = #"{"bookmark": "\#(bookmark.base64EncodedString())", "displayName": "a.mp4", "offset": 4, "#
            + #""rate": 1.0002, "status": {"kind": "telepathic"}}"#
        let v6 = v5Project(video: video).replacingOccurrences(of: #""schemaVersion": 5"#,
                                                               with: #""schemaVersion": 6"#)

        let loaded = try load(v6)

        #expect(loaded.video?.status == .notSynced)
        #expect(loaded.video?.offset == 4)
        #expect(loaded.video?.rate == 1.0002)
    }

    // MARK: - v6

    /// Save → reopen restores the offset, the rate and the status.
    @Test func test_v6_roundtrip_restores_offset_rate_and_status() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("v6.rsproj")
        let video = VideoAttachment(bookmark: bookmark, displayName: "session-lap.mp4", offset: 81.25,
                                    rate: 1.000_083, status: .twoPoint(lapA: LapID(2), lapB: LapID(13)))
        let document = ProjectDocument(layout: AnalysisLayout(panes: [], xAxisMode: .time), video: video)

        try store().save(document, to: url)
        let loaded = try store().load(from: url)

        #expect(loaded.video == video)
        #expect(loaded == document)
    }

    /// A v6 attachment missing the new keys still loads, with the defaults.
    @Test func test_v6_attachment_without_rate_or_status_decodes_with_defaults() throws {
        let json = #"{"bookmark": "\#(bookmark.base64EncodedString())", "displayName": "a.mp4", "offset": 4}"#

        let decoded = try JSONDecoder().decode(VideoAttachment.self, from: Data(json.utf8))

        #expect(decoded.rate == 1)
        #expect(decoded.status == .notSynced)
        #expect(decoded.offset == 4)
    }

    /// A hand-edited or corrupt rate is sanitized on decode, as on construction.
    @Test func test_decoding_sanitizes_an_unusable_rate() throws {
        let json = #"""
        {"bookmark": "\#(bookmark.base64EncodedString())", "displayName": "a.mp4", "offset": 4,
         "rate": -2, "status": {"kind": "estimated"}}
        """#

        let decoded = try JSONDecoder().decode(VideoAttachment.self, from: Data(json.utf8))

        #expect(decoded.rate == 1)
        #expect(decoded.status == .estimated)
    }

    // MARK: - The attachment value

    /// A new attachment runs at unit rate and is not synced.
    @Test func test_attachment_defaults_to_unit_rate_not_synced() {
        let attached = VideoAttachment(bookmark: bookmark, displayName: "v.mp4")

        #expect(attached.rate == 1)
        #expect(attached.status == .notSynced)
    }

    /// A non-finite, zero or negative rate can never be persisted.
    @Test(arguments: [Double.nan, .infinity, 0, -1])
    func test_unusable_rate_is_sanitized(rate: Double) {
        #expect(VideoAttachment(bookmark: bookmark, displayName: "v.mp4", rate: rate).rate == 1)
    }

    /// Re-offsetting keeps the rate and the status.
    @Test func test_reoffsetting_keeps_rate_and_status() {
        let attached = VideoAttachment(bookmark: bookmark, displayName: "v.mp4", offset: 1,
                                       rate: 1.0002, status: .anchored(lap: LapID(3)))

        let moved = attached.withOffset(9)

        #expect(moved.offset == 9)
        #expect(moved.rate == 1.0002)
        #expect(moved.status == .anchored(lap: LapID(3)))
    }

    /// Re-stamping the sync replaces offset, rate and status together, against
    /// the same file.
    @Test func test_restamping_the_sync_keeps_the_same_file() {
        let attached = VideoAttachment(bookmark: bookmark, displayName: "v.mp4")

        let synced = attached.withSync(offset: -3, rate: 0.9999, status: .estimated)

        #expect(synced == VideoAttachment(bookmark: bookmark, displayName: "v.mp4",
                                          offset: -3, rate: 0.9999, status: .estimated))
    }
}
