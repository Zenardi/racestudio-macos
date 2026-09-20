import Testing
import Foundation

@testable import RaceStudioCore

/// Tests for how the issue 9.6 video review is **navigated and aligned**: walking
/// the lap × sector grid (including holding one section across a lap change — the
/// core lap-by-lap comparison), anchoring the footage to the track data, and
/// keeping the review valid when the split layout is re-cut.
///
/// Selection, seeking, coverage and playback control live in
/// `VideoReviewModelTests`; both suites read one shared fixture
/// (``VideoReviewFixture``) so they cannot drift apart.
@MainActor
@Suite struct VideoReviewNavigationTests {

    private func timeline() -> LapSectorTimeline { VideoReviewFixture.timeline() }
    private func model() -> VideoReviewModel { VideoReviewFixture.model() }
    private func splitID(_ index: Int) -> Int { VideoReviewFixture.splitID(index) }

    // MARK: - Navigation

    /// Stepping forward walks the sectors of a lap in track order, then rolls into
    /// the next lap.
    @Test func test_next_sector_walks_the_lap_then_rolls_over() {
        let review = model()
        review.select(lap: LapID(0), splitID: splitID(0))

        review.nextSector()
        #expect(review.selectedLabel == "Lap 1 · S2")

        review.nextSector()
        #expect(review.selectedLabel == "Lap 2 · S1", "past the last sector opens the next lap")
    }

    /// Stepping back mirrors it, rolling into the previous lap's final sector.
    @Test func test_previous_sector_rolls_back_into_the_previous_lap() {
        let review = model()
        review.select(lap: LapID(1), splitID: splitID(0))

        review.previousSector()
        #expect(review.selectedLabel == "Lap 1 · S2", "before the first sector is the previous lap's last")
    }

    /// The ends of the session hold: stepping past them changes nothing.
    @Test func test_navigation_stops_at_the_ends() {
        let review = model()

        review.select(lap: LapID(0), splitID: splitID(0))
        review.previousSector()
        #expect(review.selectedLabel == "Lap 1 · S1", "already at the first sector")

        review.select(lap: LapID(1), splitID: splitID(1))
        review.nextSector()
        #expect(review.selectedLabel == "Lap 2 · S2", "already at the last sector")
    }

    /// With nothing selected, stepping forward starts at the first sector so the
    /// control is never dead.
    @Test func test_stepping_from_nothing_starts_at_the_first_sector() {
        let review = model()
        review.nextSector()

        #expect(review.selectedLabel == "Lap 1 · S1")
    }

    /// Stepping by lap while reviewing a sector holds that sector — the core
    /// lap-by-lap comparison: watch the same corner on lap after lap.
    @Test func test_next_lap_holds_the_sector_under_review() {
        let review = model()
        review.select(lap: LapID(0), splitID: splitID(1)) // Lap 1 · S2

        review.nextLap()

        #expect(review.selectedLabel == "Lap 2 · S2", "same section, next lap")
        #expect(review.selectedSpan == SessionTimeSpan(start: 20, end: 24))
    }

    /// Stepping by sector from a whole-lap review enters that lap's own sectors,
    /// not the session's first — the lap under review is respected.
    @Test func test_stepping_from_a_lap_enters_that_laps_sectors() {
        let review = model()
        review.select(lap: LapID(1))

        review.nextSector()
        #expect(review.selectedLabel == "Lap 2 · S1", "forward enters the lap's first sector")

        review.select(lap: LapID(1))
        review.previousSector()
        #expect(review.selectedLabel == "Lap 2 · S2", "back enters the lap's last sector")
    }

    /// Stepping back from nothing starts at the session's final sector.
    @Test func test_stepping_back_from_nothing_starts_at_the_last_sector() {
        let review = model()
        review.previousSector()

        #expect(review.selectedLabel == "Lap 2 · S2")
    }

    /// Stepping by lap from nothing selected starts at an end lap.
    @Test func test_stepping_lap_from_nothing_starts_at_an_end_lap() {
        let forward = model()
        forward.nextLap()
        #expect(forward.selectedLabel == "Lap 1")

        let back = model()
        back.previousLap()
        #expect(back.selectedLabel == "Lap 2")
    }

    /// Lap stepping holds at the ends of the session.
    @Test func test_lap_stepping_stops_at_the_ends() {
        let review = model()

        review.select(lap: LapID(0))
        review.previousLap()
        #expect(review.selectedLabel == "Lap 1", "already at the first lap")

        review.select(lap: LapID(1))
        review.nextLap()
        #expect(review.selectedLabel == "Lap 2", "already at the last lap")
    }

    /// Navigating an empty timeline is inert rather than trapping.
    @Test func test_navigating_an_empty_timeline_does_nothing() {
        let review = VideoReviewModel()

        review.nextSector()
        review.nextLap()

        #expect(review.selectedLap == nil)
        #expect(review.selectedLabel == nil)
    }

    /// A lap change onto a lap the core gave no grid for falls back to whole-lap
    /// review rather than holding a split that does not exist there.
    @Test func test_lap_change_onto_a_gridless_lap_falls_back_to_the_lap() {
        let mixed = LapSectorTimeline.make(
            laps: [Lap(index: 0, startTimeS: 10, durationS: 8, endTimeS: 18),
                   Lap(index: 1, startTimeS: 18, durationS: 6, endTimeS: 24)],
            segments: [LapSegments(lap: LapID(0), baseTimes: [1, 2, 2, 3])],
            layout: SplitLayout.even(base: 4, count: 2))
        let review = VideoReviewModel(timeline: mixed, sync: VideoSyncModel(videoDuration: 120))
        review.select(lap: LapID(0), splitID: mixed.laps[0].sectors[0].splitID)

        review.nextLap()

        #expect(review.selectedLabel == "Lap 2")
        #expect(review.scope == .lap)
    }

    /// Stepping by lap in whole-lap scope simply moves to the next lap.
    @Test func test_next_lap_in_lap_scope_moves_a_lap() {
        let review = model()
        review.select(lap: LapID(0))

        review.nextLap()
        #expect(review.selectedLabel == "Lap 2")

        review.previousLap()
        #expect(review.selectedLabel == "Lap 1")
    }

    // MARK: - Playback control

    /// While the playhead is inside the reviewed window the player is left alone.
    @Test func test_inside_the_window_playback_is_untouched() {
        let review = model()
        review.select(lap: LapID(0), splitID: splitID(0)) // video 10…13

        #expect(review.playbackAction(atPlayhead: 11) == .none)
    }

    /// Reaching the end of a reviewed section stops playback — the operator sees
    /// exactly that section and no more.
    @Test func test_reaching_the_end_of_a_section_stops() {
        let review = model()
        review.select(lap: LapID(0), splitID: splitID(0)) // video 10…13

        #expect(review.playbackAction(atPlayhead: 13) == .stop)
        #expect(review.playbackAction(atPlayhead: 20) == .stop, "past the end also stops")
    }

    /// With looping on, the section repeats instead: the player is sent back to
    /// the window's start.
    @Test func test_looping_replays_the_section() {
        let review = model()
        review.loops = true
        review.select(lap: LapID(0), splitID: splitID(1)) // video 13…18

        #expect(review.playbackAction(atPlayhead: 18) == .seek(13))
    }

    // MARK: - Cursor readout

    /// As the footage plays, the panel names the section the cursor is passing
    /// through.
    @Test func test_readout_names_the_section_under_the_cursor() {
        let review = model()

        #expect(review.label(atSessionTime: 11) == "Lap 1 · S1")
        #expect(review.label(atSessionTime: 21) == "Lap 2 · S2")
        #expect(review.label(atSessionTime: 5) == nil, "outside every lap there is nothing to name")
    }

    /// A lap the core gave no base grid for still reads out at lap granularity.
    @Test func test_readout_falls_back_to_the_lap_without_a_grid() {
        let sparse = LapSectorTimeline.make(
            laps: [Lap(index: 0, startTimeS: 0, durationS: 10, endTimeS: 10)],
            segments: [], layout: SplitLayout.even(base: 4, count: 2))
        let review = VideoReviewModel(timeline: sparse, sync: VideoSyncModel(videoDuration: 60))

        #expect(review.label(atSessionTime: 5) == "Lap 1")
    }

    // MARK: - Alignment

    /// Anchoring the reviewed section to the frame on screen is the track-aware
    /// sync: scrub to where the lap actually begins, anchor, done.
    @Test func test_anchoring_aligns_the_section_start_to_the_frame_on_screen() {
        let review = model()
        review.select(lap: LapID(1)) // session 18…24

        #expect(review.anchorSelection(toPlayhead: 100))
        #expect(review.sync.offset == 82, "offset = playhead − section start")
        #expect(review.seekTarget == 100, "the anchored section now starts on that frame")
    }

    /// Anchoring without a selection is a no-op rather than a silent mis-sync.
    @Test func test_anchoring_without_a_selection_does_nothing() {
        let review = model()

        #expect(!review.anchorSelection(toPlayhead: 100))
        #expect(review.sync.offset == 0)
    }

    /// The wall-clock guess is applied when both clocks are known, and refused
    /// when either is missing.
    @Test func test_auto_offset_is_applied_only_when_both_clocks_are_known() {
        let review = model()

        #expect(review.applyAutoOffset(sessionStartEpoch: 1_000_090, videoStartEpoch: 1_000_000))
        #expect(review.sync.offset == 90)

        #expect(!review.applyAutoOffset(sessionStartEpoch: 0, videoStartEpoch: 1_000_000))
        #expect(review.sync.offset == 90, "a refused guess leaves the alignment alone")
    }

    /// Loading the asset seeds the footage length without disturbing the offset
    /// the operator already set.
    @Test func test_setting_the_duration_keeps_the_offset() {
        let review = VideoReviewModel(timeline: timeline(), sync: VideoSyncModel(videoDuration: 0))
        review.setOffset(42)
        review.setVideoDuration(300)

        #expect(review.sync.videoDuration == 300)
        #expect(review.sync.offset == 42)
        #expect(review.hasVideo)
    }

    /// The fine-trim slider brackets whatever coarse anchor is in force.
    @Test func test_trim_range_follows_the_current_offset() {
        let review = model()
        review.setOffset(-200)

        #expect(review.trimRange == -260 ... -140)
    }

    // MARK: - Timeline changes

    /// Re-splitting the lap (the 8.11 split-count control) rebuilds the timeline;
    /// a selection that no longer exists falls back to the lap rather than
    /// pointing at a deleted column.
    @Test func test_restitching_the_timeline_drops_a_stale_sector() {
        let review = model()
        review.select(lap: LapID(0), splitID: splitID(1))

        review.update(timeline: LapSectorTimeline.make(
            laps: [Lap(index: 0, startTimeS: 10, durationS: 8, endTimeS: 18)],
            segments: [LapSegments(lap: LapID(0), baseTimes: [1, 2, 2, 3])],
            layout: SplitLayout.even(base: 4, count: 1)))

        #expect(review.selectedLap == LapID(0), "the lap survives")
        #expect(review.scope == .lap, "the vanished split falls back to whole-lap review")
    }

    /// A selection whose lap is gone entirely is cleared.
    @Test func test_restitching_clears_a_vanished_lap() {
        let review = model()
        review.select(lap: LapID(1))

        review.update(timeline: .empty)

        #expect(review.selectedLap == nil)
        #expect(review.selectedSpan == nil)
    }
}
