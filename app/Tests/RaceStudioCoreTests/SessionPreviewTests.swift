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
}
