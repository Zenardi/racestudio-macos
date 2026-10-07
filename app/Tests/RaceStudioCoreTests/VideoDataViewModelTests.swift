import Combine
import Testing
import Foundation

@testable import RaceStudioCore

/// Tests for `VideoDataViewModel`'s clock (issue 9.12): one clock drives the
/// Video + Data view. While the footage plays, each displayed frame maps the
/// playhead through the sync to a session time and its ``TelemetryFrame`` —
/// published only when what the HUD shows changes — and drives the cursor;
/// while paused, the cursor drives the footage. The "No footage here" plate
/// follows whether the footage covers the cursor.
///
/// Lap selection, the strip plot, the map, the renderer and loading are in
/// `VideoDataLapTests`.
@MainActor
@Suite struct VideoDataViewModelTests {

    // MARK: - Playing: the playhead drives

    /// A displayed frame maps the playhead through the sync — offset *and* clock
    /// rate — and publishes exactly the timeline's frame at that session time,
    /// which the cursor is then driven to.
    @Test func test_tick_maps_the_playhead_through_the_sync() async throws {
        let loaded = try await VideoDataFixture.loaded(offset: 5, rate: 1.0001)
        let expected = (30 - 5) / 1.0001

        let tick = loaded.model.tick(playhead: 30, isPlaying: true)

        #expect(tick.cursorTime == expected)
        #expect(loaded.model.displayedTime == expected)
        #expect(loaded.model.currentFrame == loaded.telemetry.frame(at: expected))
        #expect(tick.action == .none)
    }

    /// While paused the playhead drives nothing: the cursor does.
    @Test func test_a_paused_tick_changes_nothing() async throws {
        let loaded = try await VideoDataFixture.loaded()

        let tick = loaded.model.tick(playhead: 30, isPlaying: false)

        #expect(tick == VideoDataTick(cursorTime: nil, action: .none))
        #expect(loaded.model.currentFrame == nil)
    }

    /// The same displayed values are not published twice — a repeated playhead,
    /// or two instants with nothing to show, invalidate nothing.
    @Test func test_unchanged_values_are_not_republished() async throws {
        let loaded = try await VideoDataFixture.loaded(offset: 5)
        loaded.model.tick(playhead: 30, isPlaying: true)
        loaded.model.tick(playhead: 2, isPlaying: true)
        var published = 0
        let watch = loaded.model.objectWillChange.sink { published += 1 }

        loaded.model.tick(playhead: 2, isPlaying: true)
        loaded.model.tick(playhead: 1, isPlaying: true)

        #expect(published == 0, "−3 s and −4 s are both before the session: nothing to show either time")
        watch.cancel()
    }

    /// A playhead whose values differ is published.
    @Test func test_changed_values_are_published() async throws {
        let loaded = try await VideoDataFixture.loaded()
        loaded.model.tick(playhead: 30, isPlaying: true)
        var frames: [TelemetryFrame?] = []
        let watch = loaded.model.$currentFrame.dropFirst().sink { frames.append($0) }

        loaded.model.tick(playhead: 31, isPlaying: true)

        #expect(frames == [loaded.telemetry.frame(at: 26)])
        watch.cancel()
    }

    /// At the end of the lap under review the footage loops back to its start,
    /// or stops — the review's own window rules.
    @Test func test_the_end_of_the_reviewed_lap_loops_or_stops() async throws {
        let loaded = try await VideoDataFixture.loaded(offset: 5)
        loaded.model.selectLap(LapID(1))

        loaded.model.review.loops = true
        #expect(loaded.model.tick(playhead: 45, isPlaying: true).action == .seek(26))

        loaded.model.review.loops = false
        #expect(loaded.model.tick(playhead: 45, isPlaying: true).action == .stop)
        #expect(loaded.model.tick(playhead: 44, isPlaying: true).action == .none)
    }

    // MARK: - Paused: the cursor drives

    /// A cursor move while paused — a scrub of the plot or a click on the map —
    /// seeks the footage to the matching frame and shows the frame there.
    @Test func test_following_the_cursor_while_paused_seeks_and_shows() async throws {
        let loaded = try await VideoDataFixture.loaded(offset: 5, rate: 1.0001)

        let seek = loaded.model.follow(cursorTime: 30, isPlaying: false)

        #expect(seek == 30 * 1.0001 + 5)
        #expect(loaded.model.currentFrame == loaded.telemetry.frame(at: 30))
    }

    /// While playing, the cursor's moves are the playhead's own echo: following
    /// them would fight the footage, so nothing happens.
    @Test func test_following_the_cursor_while_playing_does_nothing() async throws {
        let loaded = try await VideoDataFixture.loaded()

        #expect(loaded.model.follow(cursorTime: 30, isPlaying: true) == nil)
        #expect(loaded.model.currentFrame == nil)
        #expect(loaded.model.follow(cursorTime: .nan, isPlaying: false) == nil)
    }

    /// Without footage the panes still follow the cursor; there is just nothing
    /// to seek.
    @Test func test_without_footage_the_cursor_still_drives_the_panes() async throws {
        let loaded = try await VideoDataFixture.loaded(videoDuration: 0)

        #expect(loaded.model.follow(cursorTime: 30, isPlaying: false) == nil)
        #expect(loaded.model.currentFrame == loaded.telemetry.frame(at: 30))
        #expect(!loaded.model.showsNoFootage, "no footage at all is the attach prompt, not the plate")
    }

    // MARK: - Coverage at the cursor

    /// Where the footage doesn't reach the cursor the player says "No footage
    /// here" — while the HUD keeps showing the telemetry at the cursor.
    @Test func test_an_uncovered_cursor_shows_the_no_footage_plate() async throws {
        let loaded = try await VideoDataFixture.loaded(videoDuration: 120, offset: -30)

        loaded.model.follow(cursorTime: 20, isPlaying: false)
        #expect(loaded.model.coverageAtCursor == .none)
        #expect(loaded.model.showsNoFootage)
        #expect(loaded.model.currentFrame == loaded.telemetry.frame(at: 20), "the panes work on telemetry alone")

        loaded.model.follow(cursorTime: 40, isPlaying: false)
        #expect(loaded.model.coverageAtCursor == .full)
        #expect(!loaded.model.showsNoFootage)
    }

    /// Before the cursor has been shown there is nothing to judge.
    @Test func test_no_plate_before_anything_is_shown() async throws {
        let loaded = try await VideoDataFixture.loaded(videoDuration: 120, offset: -30)

        #expect(loaded.model.coverageAtCursor == .none)
        #expect(!loaded.model.showsNoFootage)
    }

    /// Re-syncing the footage re-judges the cursor at once.
    @Test func test_a_resync_rejudges_the_cursor() async throws {
        let loaded = try await VideoDataFixture.loaded(videoDuration: 120, offset: -30)
        loaded.model.follow(cursorTime: 20, isPlaying: false)

        loaded.model.review.setOffset(0)

        #expect(loaded.model.coverageAtCursor == .full)
        #expect(!loaded.model.showsNoFootage)
    }

    // MARK: - VoiceOver

    /// The HUD's VoiceOver value is the summary of the frame on show, in the
    /// overlay's units.
    @Test func test_the_accessibility_summary_reads_the_frame_on_show() async throws {
        let loaded = try await VideoDataFixture.loaded()
        let en = Locale(identifier: "en_US")
        #expect(loaded.model.accessibilitySummary(units: .metric, locale: en) == "No telemetry here")

        loaded.model.follow(cursorTime: 30, isPlaying: false)

        #expect(loaded.model.accessibilitySummary(units: .imperial, locale: en)
                == OverlayAccessibilitySummary.text(for: loaded.telemetry.frame(at: 30), units: .imperial, locale: en))
    }

    // MARK: - Readings

    /// Two frames read the same when everything they show matches, whatever
    /// instant they were sampled at.
    @Test func test_frames_compare_by_what_they_show() {
        let first = TelemetryFrame(time: 1, values: [.speed: 80], delta: 0.1)
        let later = TelemetryFrame(time: 2, values: [.speed: 80], delta: 0.1)
        let faster = TelemetryFrame(time: 2, values: [.speed: 81], delta: 0.1)

        #expect(first.hasSameReadings(as: later))
        #expect(!first.hasSameReadings(as: faster))
        #expect(!first.hasSameReadings(as: TelemetryFrame(time: 1, values: [.speed: 80], delta: 0.2)))
    }
}
