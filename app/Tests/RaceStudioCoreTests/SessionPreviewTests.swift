import Testing
@testable import RaceStudioCore

/// Behaviour for the library browser's non-destructive preview (issue 8.14): a
/// selected session previews its laps summary and a map thumbnail, derived purely
/// from the decoded ``Session`` (+ its GPS coordinates) — no full analysis.
@Suite struct SessionPreviewTests {

    @Test func test_preview_carries_the_laps_summary() {
        let session = SessionFixture.make(lapDurations: [120, 100, 110])

        let preview = SessionPreview(session: session, coordinates: [])

        #expect(preview.summary.laps.count == 3)
    }

    @Test func test_preview_flags_the_best_lap_in_the_summary() {
        let session = SessionFixture.make(lapDurations: [120, 100, 110])

        let preview = SessionPreview(session: session, coordinates: [])

        // The fastest lap (100 s, index 1) is flagged; the others are not.
        #expect(preview.summary.laps.filter(\.isBest).map(\.number) == [2])
    }

    @Test func test_preview_builds_the_map_from_coordinates() {
        let session = SessionFixture.make()
        let coords = [
            GPSCoord(latitude: 45.0, longitude: 10.0),
            GPSCoord(latitude: 45.1, longitude: 10.1)
        ]

        let preview = SessionPreview(session: session, coordinates: coords)

        #expect(!preview.map.isEmpty)
        #expect(preview.map.points.count == 2)
    }

    @Test func test_preview_without_gps_still_shows_laps() {
        let session = SessionFixture.make(lapDurations: [90, 95])

        let preview = SessionPreview(session: session, coordinates: [])

        #expect(preview.map.isEmpty)
        #expect(preview.summary.laps.count == 2)
    }

    // MARK: - The map is the best lap (not the whole session)

    /// A fix at `time` seconds, a distinct point per time so counts are exact.
    private static func fix(_ time: Double) -> GPSTrackPoint {
        GPSTrackPoint(coordinate: GPSCoord(latitude: 45 + time / 10_000, longitude: 10 + time / 5_000),
                      distance: time, time: time)
    }

    @Test func test_map_draws_only_the_best_laps_fixes() {
        // Laps: 0–120 s, 120–220 s (best, 100 s), 220–330 s.
        let session = SessionFixture.make(lapDurations: [120, 100, 110])
        let track = [10, 130, 150, 200, 250, 300].map(Self.fix)

        let preview = SessionPreview(session: session, track: track)

        #expect(preview.map.points.count == 3) // 130, 150, 200
    }

    @Test func test_map_falls_back_to_the_whole_track_without_laps() {
        let session = SessionFixture.make(lapDurations: [])
        let track = [10, 20, 30].map(Self.fix)

        let preview = SessionPreview(session: session, track: track)

        #expect(preview.map.points.count == 3)
    }

    @Test func test_map_falls_back_when_the_best_lap_has_no_gps() {
        let session = SessionFixture.make(lapDurations: [120, 100, 110])
        let track = [10, 20, 250, 260].map(Self.fix) // nothing inside 120–220 s

        let preview = SessionPreview(session: session, track: track)

        #expect(preview.map.points.count == 4)
    }

    @Test func test_map_is_empty_without_gps() {
        let preview = SessionPreview(session: SessionFixture.make(), track: [])

        #expect(preview.map.isEmpty)
    }
}
