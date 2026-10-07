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
    private func editedOverlay() throws -> OverlayLayout {
        var layout = OverlayPreset.kartCoaching.layout(locale: Locale(identifier: "en"))
        let map = try #require(layout.widgets.firstIndex { $0.id == "trackMap" })
        layout.units = .imperial
        layout.widgets[map].options.trackMapRotation = 90
        layout.widgets[map].frame.y = 0.6
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
        let overlay = try editedOverlay()
        let document = ProjectDocument(layout: AnalysisLayout(panes: [], xAxisMode: .time), overlay: overlay)

        let loaded = try roundTrip(document)

        #expect(loaded.overlay == overlay)
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

        let project = try load(v7)
        let loaded = try #require(project.overlay)

        #expect(loaded.widgets.map(\.id) == ["s"])
        #expect(loaded.widgets[0].frame.isContained(in: .safeArea(margin: OverlayLayout.safeMargin)))
        #expect(project.warnings == ["video overlay: 1 unreadable entry skipped"])
    }

    /// An overlay that isn't a layout at all costs only the overlay: the workspace
    /// opens with it off, and the load says so.
    @Test(arguments: ["5", "[]", #""Minimal""#])
    func test_an_unreadable_overlay_opens_the_project_with_it_off(value: String) throws {
        let loaded = try load(project(version: 7, extra: #", "overlay": \#(value)"#))

        #expect(loaded.overlay == nil)
        #expect(loaded.video?.offset == 2.5)
        #expect(loaded.warnings == ["unreadable video overlay; opened with the overlay off"])
    }

    /// Several unreadable overlay entries are counted in one warning.
    @Test func test_skipped_overlay_entries_are_counted_in_one_warning() throws {
        let overlay = #", "overlay": {"theme": "neon", "widgets": [7, "#
            + #"{"id": "s", "kind": {"type": "speed"}, "frame": {"x": 0.1, "y": 0.8, "width": 0.14, "height": 0.15}}]}"#

        let loaded = try load(project(version: 7, extra: overlay))

        #expect(loaded.warnings == ["video overlay: 2 unreadable entries skipped"])
        #expect(loaded.overlay?.widgets.map(\.id) == ["s"])
    }

    /// The schema was bumped for the overlay (v7) and is stamped on disk — now
    /// at the current schema, which issue 9.12 bumped again (see
    /// `ProjectDocumentVideoDataMigrationTests`).
    @Test func test_saved_projects_are_stamped_with_the_current_schema() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("stamp.rsproj")
        try store().save(ProjectDocument(layout: AnalysisLayout(panes: [], xAxisMode: .time)), to: url)

        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]

        #expect(json?["schemaVersion"] as? Int == ProjectDocument.currentSchemaVersion)
        #expect(ProjectDocument.currentSchemaVersion >= 7)
    }

    // MARK: - The workspace save path

    @MainActor
    private func windowModel() -> AnalysisWindowModel {
        let session = Session(
            metadata: SessionMetadata(vehicle: "", track: "Interlagos", driver: "", session: "", series: "",
                                      logDate: "", logTime: "", datetimeUtc: 0),
            channels: [Channel(name: "GPS Speed", unit: "km/h", sampleRateHz: 20, decimals: 1, sampleCount: 10)],
            laps: [Lap(index: 0, startTimeS: 0, durationS: 60, endTimeS: 60)])
        return AnalysisWindowModel(session: session, analysis: nil)
    }

    /// The window owns its workspace's overlay — off until one is chosen — and a
    /// saved document carries it.
    @MainActor
    @Test func test_the_window_owns_the_overlay_it_saves() throws {
        let model = windowModel()
        let overlay = try editedOverlay()
        #expect(model.videoOverlay == nil)
        #expect(model.projectDocument().overlay == nil)

        model.videoOverlay = overlay

        #expect(model.projectDocument().overlay == overlay)
    }

    /// Reopening a workspace restores its overlay into the window — or clears it.
    @MainActor
    @Test func test_restoring_a_workspace_restores_its_overlay() throws {
        let model = windowModel()
        let overlay = try editedOverlay()
        let saved = ProjectDocument(layout: AnalysisLayout(panes: [], xAxisMode: .time), overlay: overlay)

        model.restore(from: saved)
        #expect(model.videoOverlay == overlay)

        model.restore(from: ProjectDocument(layout: AnalysisLayout(panes: [], xAxisMode: .time)))
        #expect(model.videoOverlay == nil)
    }
}
