import Testing
import Foundation
@testable import RaceStudioCore

/// Tests for `AnalysisSession.gpsTrack(window:)` (issue 8.6) — the GPS racing-line
/// builder over 8.2's `gps_track` accessor, read through the ``SessionDataSource``
/// seam so it is covered **without the xcframework**.
@Suite struct AnalysisSessionGPSTests {

    // MARK: - Builders (no logic — fixed, index-derived data)

    private func session() -> Session {
        Session(
            metadata: SessionMetadata(
                vehicle: "", track: "", driver: "", session: "",
                series: "", logDate: "", logTime: "", datetimeUtc: 0),
            channels: [], laps: [])
    }

    /// A track of `count` fixes where fix `i` is at `(lat: i, lon: 2·i)`, distance
    /// `10·i` m, time `i` s — so a windowed read's contents are predictable.
    private func track(_ count: Int) -> [GPSTrackPoint] {
        (0..<count).map {
            GPSTrackPoint(coordinate: GPSCoord(latitude: Double($0), longitude: Double($0) * 2),
                          distance: Double($0) * 10, time: Double($0))
        }
    }

    // MARK: - gpsTrack

    @MainActor @Test func test_gps_track_reads_the_whole_track_over_the_all_window() {
        let source = FakeSessionDataSource(banks: [], gps: track(5))
        let sut = AnalysisSession(session: session(), dataSource: source)

        let fixes = sut.gpsTrack(window: .all)

        #expect(fixes.count == 5)
        #expect(fixes.first == GPSTrackPoint(coordinate: GPSCoord(latitude: 0, longitude: 0),
                                             distance: 0, time: 0))
        #expect(fixes.last == GPSTrackPoint(coordinate: GPSCoord(latitude: 4, longitude: 8),
                                            distance: 40, time: 4))
    }

    @MainActor @Test func test_gps_track_forwards_a_bounded_fix_window_across_the_seam() {
        let source = FakeSessionDataSource(banks: [], gps: track(10))
        let sut = AnalysisSession(session: session(), dataSource: source)

        let fixes = sut.gpsTrack(window: SampleWindow(start: 3, count: 4))

        #expect(fixes.map(\.time) == [3, 4, 5, 6])
        #expect(source.lastGPSRequest == FakeSessionDataSource.GPSRequest(start: 3, count: 4))
    }

    @MainActor @Test func test_gps_track_with_a_zero_count_window_issues_no_read() {
        let source = FakeSessionDataSource(banks: [], gps: track(5))
        let sut = AnalysisSession(session: session(), dataSource: source)

        let fixes = sut.gpsTrack(window: SampleWindow(start: 0, count: 0))

        #expect(fixes.isEmpty)
        #expect(source.lastGPSRequest == nil)   // a zero-width window never hits the seam
    }

    @MainActor @Test func test_gps_track_is_empty_for_a_session_without_gps() {
        let source = FakeSessionDataSource(banks: [], gps: [])
        let sut = AnalysisSession(session: session(), dataSource: source)

        #expect(sut.gpsTrack().isEmpty)
    }
}
