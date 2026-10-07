import Combine
import Foundation
import Testing
@testable import RaceStudioCore

/// The export sheet (issue 9.14): what to export — the whole video, the
/// session, the best lap, picked laps or the section under review — with which
/// overlay and output settings, a live estimate of the duration and size, and
/// whether *Export…* can be pressed.
///
/// The fixture's session has three laps — `[0, 21)`, the best `[21, 40)` and
/// `[40, 60.5)` — and 50 s of 1080p30 footage synced 5 s ahead, so the video
/// covers session time −5…45 s: laps 1 and 2 in full, lap 3 only in part.
@MainActor
@Suite struct ExportSheetModelTests {

    private let english = Locale(identifier: "en")

    // MARK: - Defaults

    /// With nothing remembered: the best lap (the footage covers it), the
    /// workspace's own overlay, 1080p H.264 with the sound kept.
    @Test func test_the_defaults_are_the_best_lap_and_the_workspace_overlay() {
        let model = ExportSheetFixture.model()

        #expect(model.range == .bestLap)
        #expect(model.overlay == .workspace)
        #expect(model.settings == ExportSettings(resolution: .p1080, codec: .h264, audio: .keep))
        #expect(model.bestLap == LapID(1))
    }

    /// A best lap the footage doesn't cover: the session instead.
    @Test func test_an_uncovered_best_lap_defaults_to_the_session() {
        let model = ExportSheetFixture.model(offset: 30)

        #expect(model.range == .session)
    }

    /// A workspace without an overlay of its own: Kart coaching.
    @Test func test_without_a_workspace_overlay_kart_coaching_is_the_default() {
        let model = ExportSheetFixture.model(hasWorkspaceOverlay: false)

        #expect(model.overlay == .preset(.kartCoaching))
        #expect(model.overlayOptions == [.preset(.minimal), .preset(.kartCoaching), .preset(.fullTelemetry)])
    }

    /// The workspace's overlay is offered first, then the built-in presets.
    @Test func test_the_overlay_options_start_with_the_workspace() {
        let model = ExportSheetFixture.model()

        #expect(model.overlayOptions == [.workspace, .preset(.minimal), .preset(.kartCoaching),
                                         .preset(.fullTelemetry)])
        #expect(model.overlayOptions.map { $0.title(locale: english) }
                == ["Current overlay", "Minimal", "Kart coaching", "Full telemetry"])
    }

    /// The last-used choices are restored.
    @Test func test_the_last_used_settings_are_restored() {
        let remembered = ExportPreferences(range: .wholeFootage, overlay: .preset(.minimal),
                                           settings: ExportSettings(resolution: .p720, codec: .hevc, audio: .drop,
                                                                    outsideSession: .noData))

        let model = ExportSheetFixture.model(preferences: remembered)

        #expect(model.range == .wholeFootage)
        #expect(model.overlay == .preset(.minimal))
        #expect(model.settings == remembered.settings)
        #expect(model.preferences == remembered)
    }

    /// A remembered choice that doesn't apply here falls back to the default:
    /// a best lap the footage misses, no section under review, no workspace
    /// overlay.
    @Test func test_a_remembered_choice_that_does_not_apply_falls_back() {
        let uncovered = ExportSheetFixture.model(offset: 30, preferences: ExportPreferences(range: .bestLap))
        let noSelection = ExportSheetFixture.model(preferences: ExportPreferences(range: .selection))
        let noOverlay = ExportSheetFixture.model(hasWorkspaceOverlay: false,
                                                 preferences: ExportPreferences(overlay: .workspace))

        #expect(uncovered.range == .session)
        #expect(noSelection.range == .bestLap)
        #expect(noOverlay.overlay == .preset(.kartCoaching))
    }

    // MARK: - What can be picked

    /// Every lap is listed with its time; a lap the footage doesn't hold in
    /// full is disabled, saying why.
    @Test func test_uncovered_laps_are_disabled_with_a_reason() {
        let model = ExportSheetFixture.model()

        #expect(model.lapItems.map(\.lap) == [LapID(0), LapID(1), LapID(2)])
        #expect(model.lapItems.map(\.isCovered) == [true, true, false])
        #expect(model.lapItems.map { $0.reason(locale: english) } == [nil, nil, "Only partly in the video"])
        #expect(model.lapItems.map { $0.title(locale: english) }
                == ["Lap 1 · 0:21.000", "Lap 2 · 0:19.000", "Lap 3 · 0:20.500"])
        #expect(model.lapItems.map(\.isBest) == [false, true, false])
        #expect(model.lapItems.map(\.id) == [0, 1, 2], "rows are identified by lap")
        #expect(model.rangeOptions.map(\.id) == ExportRangeChoice.allCases, "options are identified by choice")
    }

    /// A session without a valid lap offers the session, never a best lap or
    /// laps to pick — and a best-lap choice names the file after the session.
    @Test func test_without_a_valid_lap_there_is_no_best_lap() {
        let model = ExportSheetFixture.modelWithoutValidLaps()

        #expect(model.bestLap == nil)
        #expect(model.range == .session)
        #expect(model.rangeOptions.map { $0.reason(locale: english) }
                == [nil, nil, "The session has no complete lap", "No lap is wholly in the video",
                    "Select a lap or sector in Video + Data first"])
        #expect(model.rangeOptions[2].title(locale: english) == "Best lap")
        model.range = .bestLap
        #expect(!model.canExport)
        #expect(model.suggestedFileName == "Adria Kart – 2016-01-23 – Session.mp4")
    }

    /// A lap the footage misses entirely says so.
    @Test func test_a_lap_outside_the_video_says_so() {
        let model = ExportSheetFixture.model(offset: 30)

        #expect(model.lapItems.map { $0.reason(locale: english) }
                == ["Only partly in the video", "Not in the video", "Not in the video"])
    }

    /// An uncovered lap — or one the session doesn't have — can't be picked:
    /// the picks stay the best lap they started with.
    @Test func test_an_uncovered_lap_cannot_be_picked() {
        let model = ExportSheetFixture.model()

        model.togglePick(LapID(2))
        model.togglePick(LapID(7))

        #expect(model.pickedLaps == [LapID(1)])
    }

    /// The laps picked start from the window's lap selection, the uncovered
    /// ones left out — or from the best lap without one.
    @Test func test_the_picked_laps_start_from_the_window_selection() {
        let selected = ExportSheetFixture.model(selectedLaps: [LapID(0), LapID(2)])
        let none = ExportSheetFixture.model()

        #expect(selected.pickedLaps == [LapID(0)])
        #expect(none.pickedLaps == [LapID(1)])
    }

    /// Picking toggles.
    @Test func test_picking_a_lap_toggles_it() {
        let model = ExportSheetFixture.model()

        model.togglePick(LapID(0))
        model.togglePick(LapID(1))

        #expect(model.pickedLaps == [LapID(0)])
    }

    /// The range menu offers every choice, disabling — with the reason — what
    /// doesn't apply.
    @Test func test_range_options_say_why_they_are_unavailable() {
        let model = ExportSheetFixture.model(offset: 30)

        let options = model.rangeOptions

        #expect(options.map(\.choice) == [.wholeFootage, .session, .bestLap, .selectedLaps, .selection])
        #expect(options.map(\.isAvailable) == [true, true, false, false, false])
        #expect(options.map { $0.reason(locale: english) }
                == [nil, nil, "Not in the video", "No lap is wholly in the video",
                    "Select a lap or sector in Video + Data first"])
        #expect(options[2].title(locale: english) == "Best lap — lap 2 (0:19.000)")
    }

    /// The section under review can be exported once there is one.
    @Test func test_the_section_under_review_is_offered() {
        let model = ExportSheetFixture.model(selection: SessionTimeSpan(start: 25, end: 30))

        model.range = .selection

        #expect(model.rangeOptions.last?.isAvailable == true)
        #expect(model.canExport)
        #expect(model.request?.range == .span(SessionTimeSpan(start: 25, end: 30)))
    }

    /// A session the footage doesn't reach at all can't be exported.
    @Test func test_a_session_outside_the_video_is_unavailable() {
        let model = ExportSheetFixture.model(offset: 500)

        #expect(model.range == .session)
        #expect(!model.canExport)
        #expect(model.validationMessage(locale: english) == "The video doesn’t cover the session — check the sync")
    }

    // MARK: - Validation

    /// The default export is ready to go.
    @Test func test_the_default_export_can_run() {
        let model = ExportSheetFixture.model()

        #expect(model.canExport)
        #expect(model.validationMessage(locale: english) == nil)
        #expect(model.request?.range == .laps([LapID(1)]))
    }

    /// *Selected laps* with none picked can't be exported, and says why.
    @Test func test_an_empty_lap_pick_disables_export() {
        let model = ExportSheetFixture.model()
        model.range = .selectedLaps

        model.togglePick(LapID(1))

        #expect(!model.canExport)
        #expect(model.request == nil)
        #expect(model.validationMessage(locale: english) == "Pick at least one lap the video covers.")
    }

    /// Picked laps export as one span; the sheet says so when there are
    /// several.
    @Test func test_several_picked_laps_export_as_one_clip() {
        let model = ExportSheetFixture.model()
        model.range = .selectedLaps

        model.togglePick(LapID(0))

        #expect(model.request?.range == .laps([LapID(0), LapID(1)]))
        #expect(model.lapsHint(locale: english) == "Laps 1–2 are exported as one clip, with anything between them.")
    }

    /// One picked lap needs no hint.
    @Test func test_one_picked_lap_has_no_hint() {
        let model = ExportSheetFixture.model()
        model.range = .selectedLaps

        #expect(model.lapsHint(locale: english) == nil)
    }

    /// An output this Mac can't encode can't be exported; the plan's reason is
    /// shown.
    @Test func test_an_unavailable_codec_disables_export() {
        let model = ExportSheetFixture.model(encoders: EncoderAvailability(supportsHEVC: false))

        model.settings.codec = .hevc

        #expect(!model.canExport)
        #expect(model.validationMessage(locale: english) == "This Mac can’t encode HEVC")
    }

    /// The plan is the one the estimate shows: the best lap's frames.
    @Test func test_the_plan_covers_the_chosen_range() throws {
        let model = ExportSheetFixture.model()

        let plan = try model.makePlan().get()

        #expect(plan.firstFrame == 780)
        #expect(plan.frameCount == 570)
        #expect(plan.outputSize == CGSize(width: 1_920, height: 1_080))
    }

    /// No range, no plan.
    @Test func test_an_empty_range_has_no_plan() {
        let model = ExportSheetFixture.model()
        model.range = .selectedLaps
        model.togglePick(LapID(1))

        #expect(model.makePlan() == .failure(.rangeOutsideFootage))
    }
}
