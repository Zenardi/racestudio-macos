import Testing
import Foundation

@testable import RaceStudioCore

/// Tests for the video overlay persisted with the workspace (issue 9.10): the
/// ``ProjectDocument/overlay`` layout is saved in the `.rsproj` (schema **v7**)
/// and reopens exactly, while a project saved before it existed (v6, v5) opens
/// with **no** overlay — the HUD is off until the operator picks one.
///
/// Every fixture here is synthetic; the "bookmark" is the bytes of a made-up path.
@Suite struct ProjectDocumentOverlayMigrationTests {

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rsoverlay-v7-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func store() -> ProjectStore { ProjectStore(validator: FakeExpressionValidator()) }

    private let bookmark = Data("/tmp/onboard/session-lap.mp4".utf8)

    /// A project as an older build wrote it, at `version`, with a 9.7 video.
    private func project(version: Int, extra: String = "") -> String {
        let video = version >= 6
            ? #"{"bookmark": "\#(bookmark.base64EncodedString())", "displayName": "lap.mp4", "offset": 2.5, "#
                + #""rate": 1.0001, "status": {"kind": "estimated"}}"#
            : #"{"bookmark": "\#(bookmark.base64EncodedString())", "displayName": "lap.mp4", "offset": 2.5}"#
        return """
        {
          "schemaVersion": \(version),
          "sessionRefs": [{"id": "s1", "displayName": "Interlagos"}],
          "layout": {"panes": [{"channelNames": ["GPS Speed"]}], "xAxisMode": "time"},
          "selectedLaps": [{"sessionID": "s1", "lapIndices": [3]}],
          "mathChannels": [],
          "activeLayout": "videoReview",
          "logSheet": {
            "weather": {"conditions": "Dry"},
            "engine": {"make": "", "notes": ""},
            "dimensions": {},
            "weights": {},
            "fuel": {"type": ""},
            "gearing": {"finalDrive": "", "primaryDrive": "", "ratios": []},
            "notes": ""
          },
          "video": \(video)\(extra)
        }
        """
    }

    private func load(_ json: String) throws -> ProjectDocument {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("project.rsproj")
        try Data(json.utf8).write(to: url)
        return try store().load(from: url)
    }

    private func roundTrip(_ document: ProjectDocument) throws -> ProjectDocument {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("v7.rsproj")
        try store().save(document, to: url)
        return try store().load(from: url)
    }

    /// The Kart coaching preset, edited: imperial, the map rotated and nudged.
    private var editedOverlay: OverlayLayout {
        var layout = OverlayPreset.kartCoaching.layout(locale: Locale(identifier: "en"))
        layout.units = .imperial
        layout.widgets[6].options.trackMapRotation = 90
        layout.widgets[6].frame.y = 0.6
        return layout
    }

    // MARK: - Older projects open with the overlay off

    /// A v6 project opens with no overlay, its video and the rest unchanged.
    @Test func test_v6_project_opens_with_no_overlay() throws {
        let loaded = try load(project(version: 6))

        #expect(loaded.overlay == nil)
        #expect(loaded.schemaVersion == ProjectDocument.currentSchemaVersion)
        #expect(loaded.video == VideoAttachment(bookmark: bookmark, displayName: "lap.mp4", offset: 2.5,
                                                rate: 1.0001, status: .estimated))
        #expect(loaded.activeLayout == .videoReview)
        #expect(loaded.selectedLaps == [LapSelection(sessionID: "s1", lapIndices: [3])])
    }

    /// A v5 project — two schemas back — opens with no overlay too.
    @Test func test_v5_project_opens_with_no_overlay() throws {
        let loaded = try load(project(version: 5))

        #expect(loaded.overlay == nil)
        #expect(loaded.video?.offset == 2.5)
    }

    /// A v6 file carries no overlay even if one is written into it: the key
    /// means nothing at that version.
    @Test func test_an_overlay_key_in_a_v6_file_is_ignored() throws {
        let loaded = try load(project(version: 6, extra: #", "overlay": {"name": "Sneaky"}"#))

        #expect(loaded.overlay == nil)
    }

    // MARK: - v7

    /// Save → reopen restores the edited overlay exactly.
    @Test func test_v7_round_trip_with_an_overlay_is_value_equal() throws {
        let document = ProjectDocument(layout: AnalysisLayout(panes: [], xAxisMode: .time), overlay: editedOverlay)

        let loaded = try roundTrip(document)

        #expect(loaded.overlay == editedOverlay)
        #expect(loaded == document)
    }

    /// A v7 project with no overlay stays without one.
    @Test func test_v7_without_an_overlay_round_trips_without_one() throws {
        let document = ProjectDocument(layout: AnalysisLayout(panes: [], xAxisMode: .time))

        #expect(try roundTrip(document).overlay == nil)
    }

    /// A hand-edited overlay is read leniently and validated: the widget this
    /// build can't read is skipped, the stray rect pulled inside the frame.
    @Test func test_a_hand_edited_v7_overlay_opens_validated() throws {
        let overlay = #", "overlay": {"name": "Mine", "widgets": ["#
            + #"{"id": "s", "kind": {"type": "speed"}, "frame": {"x": 2, "y": 0.8, "width": 0.14, "height": 0.15}},"#
            + #"{"id": "x", "kind": {"type": "laser"}, "frame": {"x": 0, "y": 0, "width": 0.1, "height": 0.1}}]}"#
        let v7 = project(version: 7, extra: overlay)

        let loaded = try #require(try load(v7).overlay)

        #expect(loaded.widgets.map(\.id) == ["s"])
        #expect(loaded.widgets[0].frame.isContained(in: .safeArea(margin: OverlayLayout.safeMargin)))
    }

    /// The schema was bumped for the overlay: a save is stamped v7 on disk.
    @Test func test_saved_projects_are_stamped_v7() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("stamp.rsproj")
        try store().save(ProjectDocument(layout: AnalysisLayout(panes: [], xAxisMode: .time)), to: url)

        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]

        #expect(json?["schemaVersion"] as? Int == 7)
    }

    // MARK: - The workspace save path

    /// Saving the window carries the overlay it was given, so a reopened
    /// workspace never drops one.
    @MainActor
    @Test func test_the_workspace_document_carries_the_overlay() {
        let session = Session(
            metadata: SessionMetadata(vehicle: "", track: "Interlagos", driver: "", session: "", series: "",
                                      logDate: "", logTime: "", datetimeUtc: 0),
            channels: [Channel(name: "GPS Speed", unit: "km/h", sampleRateHz: 20, decimals: 1, sampleCount: 10)],
            laps: [Lap(index: 0, startTimeS: 0, durationS: 60, endTimeS: 60)])
        let model = AnalysisWindowModel(session: session, analysis: nil)

        #expect(model.projectDocument(overlay: editedOverlay).overlay == editedOverlay)
        #expect(model.projectDocument().overlay == nil)
    }
}
