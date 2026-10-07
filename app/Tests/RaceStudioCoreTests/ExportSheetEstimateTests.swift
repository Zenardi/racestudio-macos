import Combine
import Foundation
import Testing
@testable import RaceStudioCore

/// The export sheet's live estimate, sync warning, file name and overlay
/// (issue 9.14), on ``ExportSheetFixture``'s session and footage.
@MainActor
@Suite struct ExportSheetEstimateTests {

    private let english = Locale(identifier: "en")

    // MARK: - The live estimate

    /// The sheet opens with an estimate of the default export.
    @Test func test_the_estimate_is_ready_when_the_sheet_opens() throws {
        let model = ExportSheetFixture.model()

        let estimate = try #require(model.estimate)

        #expect(estimate.duration == 19)
        #expect(estimate.width == 1_920 && estimate.height == 1_080)
        #expect(estimate.bytes == (try model.makePlan().get()).estimatedBytes)
        #expect(estimate.text(locale: english) == "0:19 · about 30 MB · 1920 × 1080")
    }

    /// A change re-estimates once the clock has run the debounce delay — not
    /// before.
    @Test func test_the_estimate_follows_a_change_after_the_delay() {
        let clock = ManualScheduler()
        let model = ExportSheetFixture.model(scheduler: clock)
        let before = model.estimate

        model.settings.resolution = .p720
        #expect(model.estimate == before, "debounced")
        clock.advance()

        #expect(model.estimate?.height == 720)
        #expect(clock.delays == [ExportSheetModel.estimateDelay])
    }

    /// Every setting that changes the file re-estimates it: codec, sound,
    /// range and the laps picked.
    @Test func test_every_setting_change_updates_the_estimate() throws {
        let clock = ManualScheduler()
        let model = ExportSheetFixture.model(scheduler: clock)
        var sizes = [try #require(model.estimate?.bytes)]
        var durations = [try #require(model.estimate?.duration)]

        for change in [{ model.settings.codec = .hevc }, { model.settings.audio = .drop },
                       { model.range = .selectedLaps }, { model.togglePick(LapID(0)) }] {
            change()
            clock.advance()
            sizes.append(try #require(model.estimate?.bytes))
            durations.append(try #require(model.estimate?.duration))
        }

        #expect(sizes[1] < sizes[0], "HEVC is smaller")
        #expect(sizes[2] < sizes[1], "no sound is smaller")
        #expect(durations == [19, 19, 19, 19, 40])
    }

    /// Changes in quick succession publish one estimate: the last one's.
    @Test func test_quick_changes_publish_one_estimate() throws {
        let clock = ManualScheduler()
        let model = ExportSheetFixture.model(scheduler: clock)
        var published: [ExportEstimate?] = []
        let watch = model.$estimate.dropFirst().sink { published.append($0) }
        defer { watch.cancel() }

        model.settings.resolution = .p720
        model.settings.resolution = .source
        model.settings.codec = .hevc
        clock.advance()

        #expect(published.count == 1)
        #expect(published.first??.height == 1_080)
        #expect(model.estimate == ExportEstimate(plan: try model.makePlan().get()))
    }

    /// An export that can't run has no estimate.
    @Test func test_an_invalid_export_has_no_estimate() {
        let clock = ManualScheduler()
        let model = ExportSheetFixture.model(scheduler: clock)

        model.range = .selectedLaps
        model.togglePick(LapID(1))
        clock.advance()

        #expect(model.estimate == nil)
        #expect(model.estimateText(locale: english) == "—")
    }

    // MARK: - Menus

    /// The resolution menu names the footage's own size for *Source*.
    @Test func test_resolution_titles_name_the_source_size() {
        let model = ExportSheetFixture.model()

        #expect(ExportResolution.allCases.map { model.resolutionTitle($0, locale: english) }
                == ["Source (1920 × 1080)", "4K (2160p)", "1080p", "720p"])
        #expect(model.resolutionTitle(.source, locale: Locale(identifier: "pt-BR")) == "Original (1920 × 1080)")
    }

    /// The codec menu says what each codec is for.
    @Test func test_codec_titles_say_what_each_is_for() {
        #expect(ExportCodec.allCases.map { $0.title(locale: english) }
                == ["H.264 — plays everywhere", "HEVC — smaller files"])
        #expect(ExportCodec.hevc.title(locale: Locale(identifier: "pt-BR")) == "HEVC — arquivos menores")
    }

    // MARK: - Sync

    /// A video that was never synced, or only from its file date, is warned
    /// about; a confirmed sync is not.
    @Test func test_an_unsynced_video_is_warned_about() {
        #expect(ExportSheetFixture.model(status: .notSynced).syncWarning(locale: english)
                == "This video hasn’t been synced — the overlay may not match the footage.")
        #expect(ExportSheetFixture.model(status: .estimated).syncWarning(locale: english)
                == "This video is synced only from its file date — the overlay may not match the footage.")
        #expect(ExportSheetFixture.model(status: .anchored(lap: LapID(1))).syncWarning(locale: english) == nil)
        #expect(ExportSheetFixture.model(status: .autoAudio(confidence: 0.8)).syncWarning(locale: english) == nil)
    }

    // MARK: - The file and the overlay

    /// The name suggested for the best lap: track, date, lap and lap time.
    @Test func test_the_suggested_name_follows_the_range() {
        let model = ExportSheetFixture.model(locale: english)

        #expect(model.suggestedFileName == "Adria Kart – 2016-01-23 – Lap 2 (0'19.000).mp4")
        model.range = .session
        #expect(model.suggestedFileName == "Adria Kart – 2016-01-23 – Session.mp4")
        model.range = .wholeFootage
        #expect(model.suggestedFileName == "Adria Kart – 2016-01-23 – Full video.mp4")
        model.range = .selectedLaps
        model.togglePick(LapID(0))
        #expect(model.suggestedFileName == "Adria Kart – 2016-01-23 – Laps 1–2.mp4")
    }

    /// One picked lap, or a section under review, is named like a lap or a
    /// selection.
    @Test func test_the_suggested_name_of_one_lap_and_of_a_selection() {
        let model = ExportSheetFixture.model(selection: SessionTimeSpan(start: 25, end: 30), locale: english)

        model.range = .selectedLaps
        #expect(model.suggestedFileName == "Adria Kart – 2016-01-23 – Lap 2 (0'19.000).mp4")
        model.range = .selection
        #expect(model.suggestedFileName == "Adria Kart – 2016-01-23 – Selection.mp4")
    }

    /// The overlay drawn: the workspace's, or a preset — always shown, even
    /// when the HUD is hidden in Video + Data.
    @Test func test_the_overlay_layout_is_always_shown() {
        let model = ExportSheetFixture.model()
        var hidden = OverlayPreset.minimal.layout(locale: english)
        hidden.isEnabled = false

        let workspace = model.layout(workspace: hidden, locale: english)
        model.overlay = .preset(.fullTelemetry)
        let preset = model.layout(workspace: hidden, locale: english)

        #expect(workspace.widgets == hidden.widgets)
        #expect(workspace.isEnabled)
        #expect(preset == OverlayPreset.fullTelemetry.layout(locale: english))
    }

    /// The workspace choice without a workspace overlay draws Kart coaching.
    @Test func test_a_missing_workspace_overlay_draws_kart_coaching() {
        let model = ExportSheetFixture.model()

        #expect(model.layout(workspace: nil, locale: english) == OverlayPreset.kartCoaching.layout(locale: english))
    }

    /// What is remembered for next time: the choices on screen.
    @Test func test_the_preferences_follow_the_choices() {
        let model = ExportSheetFixture.model()

        model.range = .session
        model.overlay = .preset(.minimal)
        model.settings.audio = .drop

        #expect(model.preferences == ExportPreferences(range: .session, overlay: .preset(.minimal),
                                                       settings: ExportSettings(audio: .drop)))
    }
}
