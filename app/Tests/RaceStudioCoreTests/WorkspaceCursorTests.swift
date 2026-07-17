import Testing
import Foundation
@testable import RaceStudioCore

/// Tests for `WorkspaceCursor` (issue 4.7) — the shared cursor and its
/// time↔distance conversion via the 3.8 mapping.
@Suite struct WorkspaceCursorTests {

    /// A linear 3.8-style mapping: time 0…10 s ↔ distance 0…1000 m, with a
    /// non-uniform middle knot so interpolation is actually exercised.
    private func cursor(time: Double = 0) -> WorkspaceCursor {
        WorkspaceCursor(times: [0, 5, 10], distances: [0, 400, 1000], time: time)
    }

    @Test func test_cursor_time_maps_to_distance_via_3_8() {
        let cursor = cursor()
        cursor.set(time: 5)
        #expect(cursor.distancePosition == 400, "at a knot")
        cursor.set(time: 2.5)
        #expect(cursor.distancePosition == 200, "halfway on the first segment")
    }

    @Test func test_cursor_distance_maps_to_time() {
        let cursor = cursor()
        cursor.set(distance: 400)
        #expect(cursor.timePosition == 5)
        cursor.set(distance: 700) // halfway on the 400…1000 segment → time 7.5
        #expect(cursor.timePosition == 7.5)
    }

    @Test func test_cursor_clamped_to_session_bounds() {
        let cursor = cursor()
        cursor.set(time: 999)
        cursor.clampToBounds()
        #expect(cursor.timePosition == 10, "clamped to the last time")
        cursor.set(time: -5)
        cursor.clampToBounds()
        #expect(cursor.timePosition == 0, "clamped to the first time")
    }

    @Test func test_time_and_distance_agree_on_the_same_point() {
        // Setting via distance and reading distancePosition round-trips exactly.
        let cursor = cursor()
        cursor.set(distance: 250)
        #expect(abs(cursor.distancePosition - 250) < 1e-9)
        #expect(cursor.timePosition == 3.125) // 250/400 · 5
    }

    @Test func test_nonfinite_input_is_ignored() {
        let cursor = cursor(time: 3)
        cursor.set(time: .nan)
        #expect(cursor.timePosition == 3, "a non-finite time is ignored")
        cursor.set(distance: .infinity)
        #expect(cursor.timePosition == 3, "a non-finite distance is ignored")
    }

    @Test func test_empty_mapping_falls_back_to_identity() {
        let cursor = WorkspaceCursor(times: [], distances: [], time: 4)
        #expect(cursor.distancePosition == 4, "reading distance with no mapping → identity")
        cursor.set(distance: 42)
        #expect(cursor.timePosition == 42, "setting distance with no mapping → identity")
        cursor.clampToBounds() // no bounds → no-op
        #expect(cursor.timePosition == 42)
    }
}
