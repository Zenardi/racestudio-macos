import Testing
import Foundation
@testable import RaceStudioCore

/// Tests for `LinkedCursor` (issue 8.3) — the window-level shared cursor that
/// promotes the 4.7 `WorkspaceCursor` + `LinkedViewRegistry`: it publishes its
/// time position for SwiftUI panels and fans a move out to imperative linked
/// views, skipping the originator so a move never echoes back.
@MainActor
@Suite struct LinkedCursorTests {

    /// A linked view that records the broadcasts it receives.
    private final class SpyView: CursorLinked {
        private(set) var notifications = 0
        private(set) var lastTime: Double?
        func cursorDidMove(to cursor: WorkspaceCursor) {
            notifications += 1
            lastTime = cursor.timePosition
        }
    }

    /// A linear 3.8-style mapping: time 0…10 s ↔ distance 0…1000 m, with a
    /// non-uniform middle knot so the conversion is actually exercised.
    private func linked(time: Double = 0) -> LinkedCursor {
        LinkedCursor(times: [0, 5, 10], distances: [0, 400, 1000], time: time)
    }

    // MARK: - Publishing the position

    @Test func test_move_time_publishes_the_new_position() {
        let cursor = linked()
        cursor.moveTime(5)
        #expect(cursor.timePosition == 5)
        #expect(cursor.distancePosition == 400, "distance stays consistent via the 3.8 mapping")
    }

    @Test func test_initial_position_seeds_the_published_value() {
        #expect(linked(time: 5).timePosition == 5)
    }

    @Test func test_move_time_clamps_into_bounds() {
        let cursor = linked()
        cursor.moveTime(999)
        #expect(cursor.timePosition == 10)
        cursor.moveTime(-3)
        #expect(cursor.timePosition == 0)
    }

    @Test func test_move_distance_converts_to_time() {
        let cursor = linked()
        cursor.moveDistance(700) // halfway on the 400…1000 segment → time 7.5
        #expect(cursor.timePosition == 7.5)
    }

    // MARK: - Fan-out to imperative linked views

    @Test func test_move_from_origin_notifies_others_but_not_the_originator() {
        let cursor = linked()
        let a = SpyView(), b = SpyView()
        cursor.register(a); cursor.register(b)

        cursor.moveTime(5, from: a)

        #expect(a.notifications == 0, "the originating view is not re-notified (no feedback loop)")
        #expect(b.notifications == 1)
        #expect(b.lastTime == 5, "the moved cursor is delivered")
    }

    @Test func test_move_with_no_origin_notifies_every_registered_view() {
        let cursor = linked()
        let a = SpyView(), b = SpyView()
        cursor.register(a); cursor.register(b)

        // A move with no originator models a non-registered input (a SwiftUI
        // scrubber) — every registered view must hear it.
        cursor.moveTime(5)

        #expect(a.notifications == 1)
        #expect(b.notifications == 1)
    }

    @Test func test_unregister_stops_delivery() {
        let cursor = linked()
        let a = SpyView(), b = SpyView()
        cursor.register(a); cursor.register(b)
        cursor.unregister(b)

        cursor.moveTime(5, from: a)

        #expect(b.notifications == 0)
    }

    // MARK: - Bounds exposure (drives the view's scrub mapping)

    @Test func test_time_bounds_reflect_the_basis() {
        #expect(linked().timeBounds == 0...10)
    }

    @Test func test_time_bounds_are_nil_without_a_basis() {
        #expect(LinkedCursor(times: [], distances: []).timeBounds == nil)
    }
}
