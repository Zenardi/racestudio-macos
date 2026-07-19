import Testing
@testable import RaceStudioCore

/// Tests for `AnalysisSession.segmentTimes(splits:)` (issue 8.11): the thin read
/// through the ``SessionDataSource`` seam that vends the per-lap split-times base
/// grid — covered here with a ``FakeSessionDataSource`` (no xcframework).
@MainActor
@Suite struct AnalysisSessionSplitsTests {

    private func session() -> Session {
        Session(
            metadata: SessionMetadata(
                vehicle: "", track: "", driver: "", session: "",
                series: "", logDate: "", logTime: "", datetimeUtc: 0),
            channels: [], laps: [])
    }

    @Test func test_segment_times_forwards_the_split_count_and_maps_the_rows() {
        let canned = [
            LapSegments(lap: LapID(0), baseTimes: [1, 2, 3]),
            LapSegments(lap: LapID(1), baseTimes: [3, 2, 1])
        ]
        let source = FakeSessionDataSource(banks: [], segments: canned)
        let sut = AnalysisSession(session: session(), dataSource: source)

        let rows = sut.segmentTimes(splits: 6)

        #expect(rows == canned)
        #expect(source.lastSegmentSplits == 6, "the split count crosses the seam unchanged")
    }

    @Test func test_segment_times_reads_nothing_for_a_nonpositive_count() {
        let source = FakeSessionDataSource(banks: [], segments: [LapSegments(lap: LapID(0), baseTimes: [1])])
        let sut = AnalysisSession(session: session(), dataSource: source)

        #expect(sut.segmentTimes(splits: 0).isEmpty)
        #expect(source.lastSegmentSplits == nil, "a non-positive count never reaches the source")
    }
}
