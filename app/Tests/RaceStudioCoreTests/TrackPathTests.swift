import Testing
import Foundation
import CoreGraphics
@testable import RaceStudioCore

/// Tests for `TrackPath` (issue 4.3) — racing-line polyline construction and
/// cursor lookup.
@Suite struct TrackPathTests {

    @Test func test_track_path_loop_closes() {
        // A lap loop: the last point coincides with the first within tolerance.
        let loop = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 1, y: 0),
            CGPoint(x: 1, y: 1),
            CGPoint(x: 0.0001, y: 0.0001)
        ]
        let path = TrackPath.build(from: loop)
        #expect(path.count == 4)
        #expect(TrackPath.isClosed(path, tolerance: 1e-3))

        // An open path is not a closed loop.
        let open = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1)]
        #expect(!TrackPath.isClosed(TrackPath.build(from: open), tolerance: 1e-3))
        // A single point cannot form a loop.
        #expect(!TrackPath.isClosed([CGPoint(x: 0, y: 0)], tolerance: 1e-3))
    }

    @Test func test_track_path_drops_nonfinite_points() {
        // GPS dropouts arrive as NaN/inf and must not enter the polyline.
        let points = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: CGFloat.nan, y: 1),
            CGPoint(x: 2, y: CGFloat.infinity),
            CGPoint(x: 3, y: 3)
        ]
        #expect(TrackPath.build(from: points) == [CGPoint(x: 0, y: 0), CGPoint(x: 3, y: 3)])
    }

    @Test func test_point_on_track_nil_when_out_of_range() {
        let path = TrackPath.build(from: [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1)])
        #expect(TrackPath.point(on: path, at: 0) == CGPoint(x: 0, y: 0))
        #expect(TrackPath.point(on: path, at: 1) == CGPoint(x: 1, y: 1))
        #expect(TrackPath.point(on: path, at: 2) == nil)
        #expect(TrackPath.point(on: path, at: -1) == nil)
        #expect(TrackPath.point(on: [], at: 0) == nil)
    }

    @Test func test_nearest_index_to_point() {
        let path = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 20, y: 0)]
        #expect(TrackPath.nearestIndex(to: CGPoint(x: 9, y: 1), in: path) == 1)
        #expect(TrackPath.nearestIndex(to: CGPoint(x: -5, y: 0), in: path) == 0)
        #expect(TrackPath.nearestIndex(to: CGPoint(x: 100, y: 0), in: path) == 2)
        #expect(TrackPath.nearestIndex(to: CGPoint(x: 0, y: 0), in: []) == nil)
    }
}
