import Foundation
import Testing
@testable import RaceStudioCore

/// Behaviour for the analysis window's bottom scrubber.
///
/// The bar was a bare slider over **absolute session time** with a `t = 123.45 s`
/// readout. With two or more laps selected that gives the user nothing to work
/// with: dragging sweeps the whole recording including laps they did not select,
/// the readout is in session seconds rather than "12.3 s into lap 7", the track
/// shows no lap boundaries, and — the real problem — a single absolute cursor says
/// nothing about *where in each selected lap* it lands, which is the entire point
/// of selecting several.
///
/// `LapScrub` gives the control two modes. **Session** is the old behaviour, now
/// with lap boundaries marked and a lap-aware readout. **Lap** scrubs a position
/// *within* a lap and reports the equivalent point in every selected lap, which is
/// what comparing laps means.
@Suite struct LapScrubTests {

    /// Three laps: 40 s, 38 s, 42 s, laid out contiguously from t = 0.
    private let laps: [Lap] = {
        var out: [Lap] = []
        var start = 0.0
        for (i, duration) in [40.0, 38.0, 42.0].enumerated() {
            out.append(Lap(index: UInt32(i), startTimeS: start,
                           durationS: duration, endTimeS: start + duration))
            start += duration
        }
        return out
    }()

    private func scrub(mode: ScrubMode, time: Double,
                       selected: [Int] = [0, 1], reference: Int? = 0) -> LapScrub {
        LapScrub(laps: laps, selected: selected, reference: reference, mode: mode, time: time)
    }

    // MARK: - Session mode

    @Test func test_session_mode_spans_the_whole_recording() throws {
        let range = try #require(scrub(mode: .session, time: 0).range)

        #expect(range.lowerBound == 0)
        #expect(range.upperBound == 120, "40 + 38 + 42")
    }

    @Test func test_session_mode_values_are_absolute_seconds() {
        let subject = scrub(mode: .session, time: 55)

        #expect(subject.value == 55)
        #expect(subject.time(for: 70) == 70)
    }

    /// Even in session mode the readout must say which lap the cursor is in — the
    /// old bare `t = 55.00 s` left the user to work that out.
    @Test func test_session_mode_readout_names_the_lap_and_the_offset_into_it() {
        let subject = scrub(mode: .session, time: 55)

        #expect(subject.currentLap?.index == 1, "55 s is 15 s into the 38 s second lap")
        #expect(subject.readout == "Lap 2 · 00:15.000 / 00:38.000")
    }

    /// Lap boundaries drawn on the slider track are what make the control legible.
    @Test func test_session_mode_marks_the_lap_boundaries() {
        let ticks = scrub(mode: .session, time: 0).lapTicks

        #expect(ticks.count == 2, "two interior boundaries for three laps")
        #expect(abs(ticks[0] - 40.0 / 120.0) < 1e-9)
        #expect(abs(ticks[1] - 78.0 / 120.0) < 1e-9)
    }

    @Test func test_a_cursor_past_the_last_lap_has_no_current_lap() {
        let subject = scrub(mode: .session, time: 500)

        #expect(subject.currentLap == nil)
        #expect(subject.readout == LapScrub.outsideLapsText)
    }

    // MARK: - Lap mode

    @Test func test_lap_mode_spans_the_reference_laps_duration() throws {
        let range = try #require(scrub(mode: .lap, time: 0, reference: 1).range)

        #expect(range.lowerBound == 0)
        #expect(range.upperBound == 38, "the second lap's duration")
    }

    @Test func test_lap_mode_values_are_offsets_into_the_reference_lap() {
        let subject = scrub(mode: .lap, time: 52, reference: 1)

        #expect(subject.value == 12, "52 s absolute is 12 s into a lap starting at 40")
        #expect(subject.time(for: 20) == 60, "20 s into the lap is 60 s absolute")
    }

    @Test func test_lap_mode_readout_is_relative_to_the_lap() {
        #expect(scrub(mode: .lap, time: 52, reference: 1).readout
                == "Lap 2 · 00:12.000 / 00:38.000")
    }

    /// The point of the mode: the same lap-offset resolved in every selected lap, so
    /// the channel readouts above are comparing like with like.
    @Test func test_lap_mode_reports_the_same_offset_in_every_selected_lap() {
        let aligned = scrub(mode: .lap, time: 10, selected: [0, 1, 2], reference: 0).alignedTimes

        #expect(aligned.map(\.lapNumber) == [1, 2, 3])
        #expect(aligned.map(\.offset) == [10, 10, 10])
        #expect(aligned.map(\.time) == [10, 50, 88], "10 s into laps starting at 0, 40, 78")
        #expect(aligned.allSatisfy { !$0.isBeyondLap })
    }

    /// A lap shorter than the offset has no such point. Reporting it as if it did
    /// would be a silent lie, so it is flagged and clamped to the lap's end.
    @Test func test_an_offset_past_a_shorter_laps_end_is_flagged_and_clamped() {
        let aligned = scrub(mode: .lap, time: 39, selected: [0, 1], reference: 0).alignedTimes

        #expect(aligned[0].isBeyondLap == false)
        #expect(aligned[1].isBeyondLap == true, "39 s exceeds the 38 s second lap")
        #expect(aligned[1].time == 78, "clamped to that lap's end")
    }

    @Test func test_lap_mode_marks_no_interior_boundaries() {
        // Inside a single lap there is no lap boundary to mark.
        #expect(scrub(mode: .lap, time: 0).lapTicks.isEmpty)
    }

    @Test func test_lap_mode_falls_back_to_the_first_selected_lap_without_a_reference() throws {
        let range = try #require(scrub(mode: .lap, time: 0, selected: [2], reference: nil).range)

        #expect(range.upperBound == 42, "the third lap's duration")
    }

    // MARK: - Availability

    /// Asking for lap mode with nothing selected must not leave an inert slider: the
    /// control degrades to scrubbing the session and reports which mode it is really
    /// in, so the UI can show the truth rather than a dead "Lap" toggle.
    @Test func test_lap_mode_without_a_lap_degrades_to_session_mode() throws {
        let subject = LapScrub(laps: laps, selected: [], reference: nil, mode: .lap, time: 0)

        #expect(!subject.canScrubByLap)
        #expect(subject.mode == .session, "downgraded rather than left unusable")
        #expect(try #require(subject.range).upperBound == 120)
        #expect(subject.alignedTimes.isEmpty)
    }

    @Test func test_lap_mode_is_available_once_a_lap_is_selected() {
        #expect(scrub(mode: .lap, time: 0).canScrubByLap)
    }

    @Test func test_a_session_with_no_laps_has_nothing_to_scrub() {
        let empty = LapScrub(laps: [], selected: [], reference: nil, mode: .session, time: 0)

        #expect(empty.range == nil)
        #expect(empty.lapTicks.isEmpty)
        #expect(empty.alignedTimes.isEmpty)
    }

    /// A zero-length or non-finite lap cannot be scrubbed within, matching the
    /// `Lap.isValid` rule the rest of the app uses.
    @Test func test_a_degenerate_lap_cannot_be_scrubbed_within() {
        let broken = [Lap(index: 0, startTimeS: 0, durationS: 0, endTimeS: 0)]
        let subject = LapScrub(laps: broken, selected: [0], reference: 0, mode: .lap, time: 0)

        #expect(!subject.canScrubByLap)
        #expect(subject.range == nil, "a degenerate lap gives the session no width either")
    }

    @Test func test_a_non_finite_lap_is_ignored() {
        let broken = [Lap(index: 0, startTimeS: 0, durationS: .nan, endTimeS: .nan)]
        let subject = LapScrub(laps: broken, selected: [0], reference: 0, mode: .session, time: 0)

        #expect(subject.range == nil)
    }

    /// A selection referring to a lap that is no longer there must not crash or
    /// produce a phantom row.
    @Test func test_a_selection_pointing_at_a_missing_lap_is_skipped() {
        let aligned = scrub(mode: .lap, time: 5, selected: [0, 99], reference: 0).alignedTimes

        #expect(aligned.map(\.lapNumber) == [1])
    }

    // MARK: - Explaining the control

    @Test func test_each_mode_explains_what_dragging_does() {
        #expect(scrub(mode: .session, time: 0).help.contains("whole session"))
        #expect(scrub(mode: .lap, time: 0).help.contains("every selected lap"))
    }

    @Test func test_both_modes_are_offered_with_titles() {
        for mode in ScrubMode.allCases {
            #expect(!mode.title.isEmpty)
        }
    }

    // MARK: - Switching modes keeps the cursor put

    /// Toggling the mode must not move the cursor — the user is changing how they
    /// address time, not where they are looking.
    @Test func test_switching_mode_preserves_the_absolute_cursor_time() {
        let session = scrub(mode: .session, time: 52, reference: 1)
        let lap = scrub(mode: .lap, time: 52, reference: 1)

        #expect(session.time(for: session.value) == 52)
        #expect(lap.time(for: lap.value) == 52)
    }
}

/// The window model's scrubber accessor — the seam the measures bar actually reads,
/// so the selection and cursor it passes through are covered rather than assumed.
@MainActor @Suite struct AnalysisWindowScrubTests {

    private func model() -> AnalysisWindowModel {
        AnalysisWindowModel(viewModel: SessionViewModel(
            session: SessionFixture.make(lapDurations: [40, 38, 42]), analysis: nil))
    }

    @Test func test_the_scrubber_spans_the_session_by_default() throws {
        let subject = model().scrub(mode: .session)

        #expect(try #require(subject.range).upperBound == 120)
        #expect(subject.lapTicks.count == 2)
    }

    /// With laps selected, lap mode becomes available and anchors on the selection.
    @Test func test_selecting_laps_makes_lap_mode_available() throws {
        let subject = model()
        subject.toggleLap(LapID(1))

        let scrub = subject.scrub(mode: .lap)

        #expect(scrub.canScrubByLap)
        #expect(try #require(scrub.range).upperBound == 38, "the second lap's duration")
    }

    /// The payoff for a multi-lap selection: one scrub position, resolved in each lap.
    @Test func test_two_selected_laps_both_resolve_the_cursor() {
        let subject = model()
        subject.toggleLap(LapID(0))
        subject.toggleLap(LapID(2))
        subject.linkedCursor.moveTime(10)

        let aligned = subject.scrub(mode: .lap).alignedTimes

        #expect(aligned.map(\.lapNumber) == [1, 3])
        #expect(aligned.allSatisfy { abs($0.offset - 10) < 1e-9 })
    }

    @Test func test_no_selection_leaves_lap_mode_unavailable() {
        #expect(!model().scrub(mode: .lap).canScrubByLap)
    }
}
