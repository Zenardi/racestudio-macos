import Foundation
import Testing
@testable import RaceStudioCore

/// What the Video + Data view hands the export (issue 9.14): the sheet's
/// input read off the review — sync, status, laps, the section under review —
/// and the overlay an export burns in, drawn by the same renderer as the HUD
/// over the session's telemetry, never replacing the HUD's own.
@MainActor
@Suite struct VideoDataExportTests {

    private let footage = FootageInfo(duration: 120, frameRate: FrameGrid(numerator: 30, denominator: 1),
                                      naturalSize: CGSize(width: 1_920, height: 1_080), rotation: .none,
                                      audio: nil, codec: "avc1")
    private let source = URL(fileURLWithPath: "/footage/onboard.mp4")

    // MARK: - The sheet's input

    /// The input carries the review's sync, status, laps and section under
    /// review, the session's span from its telemetry, the workspace's overlay,
    /// and what the session can feed it — the kart included (issue 9.19).
    @Test func test_the_sheet_input_is_read_off_the_review() async throws {
        let loaded = try await VideoDataFixture.loaded(offset: 5)
        loaded.model.review.select(lap: LapID(1))
        loaded.model.review.anchorSelection(toPlayhead: 26)
        let workspace = OverlayPreset.fullTelemetry.layout(locale: Locale(identifier: "en"))

        let input = try #require(loaded.model.exportSheetInput(
            source: source, footage: footage, session: loaded.built.session, selectedLaps: [LapID(2)],
            workspaceOverlay: workspace, kart: OverlayRenderFixture.kart))

        #expect(input.source == source)
        #expect(input.footage == footage)
        #expect(input.sync == loaded.model.review.sync)
        #expect(input.status == .anchored(lap: LapID(1)))
        #expect(input.timeline == loaded.built.sectors)
        #expect(input.laps == loaded.built.session.laps)
        #expect(input.session == SessionTimeSpan(start: try #require(loaded.telemetry.timeRange).lowerBound,
                                                 end: try #require(loaded.telemetry.timeRange).upperBound))
        #expect(input.selection == SessionTimeSpan(start: 21, end: 40))
        #expect(input.selectedLaps == [LapID(2)])
        #expect(input.metadata == loaded.built.session.metadata)
        #expect(input.hasWorkspaceOverlay && input.workspaceOverlay == workspace)
        #expect(input.overlaySession == loaded.model.overlayContext(kart: OverlayRenderFixture.kart,
                                                                    metadata: loaded.built.session.metadata,
                                                                    telemetry: loaded.telemetry))
        #expect(input.overlaySession?.kart == OverlayRenderFixture.kart)
    }

    /// Before the telemetry is in, there is no session span to export against.
    @Test func test_no_sheet_input_before_the_telemetry() {
        let model = VideoDataViewModel(review: VideoReviewModel())

        #expect(model.exportSheetInput(source: source, footage: footage, session: TelemetryFixture.make().session,
                                       selectedLaps: [], workspaceOverlay: nil) == nil)
    }

    // MARK: - The overlay

    /// A layout whose readouts the telemetry on show already samples is drawn
    /// from it — the session is not read again — by the shared renderer, shown
    /// even when the layout had the HUD off.
    @Test func test_the_overlay_reuses_the_telemetry_on_show() async throws {
        let built = TelemetryFixture.make()
        let model = try await loadedModel(built, channels: ["Water Temp"])
        var layout = OverlayPreset.kartCoaching.layout(locale: Locale(identifier: "en"))
        layout.isEnabled = false

        let overlay = try #require(try await model.exportOverlay(layout: layout, kart: nil, metadata: nil,
                                                                  analysis: nil))

        let renderer = try #require(overlay.drawer as? OverlayRenderer)
        #expect(renderer.layout.isEnabled)
        #expect(renderer.layout.widgets == layout.widgets)
        #expect(renderer.sectors == built.sectors)
        #expect(overlay.telemetry.frame(at: 30) == model.telemetry?.frame(at: 30))
    }

    /// A layout naming a channel the HUD's telemetry doesn't sample gets its
    /// own load, and the HUD keeps the telemetry it shows.
    @Test func test_the_overlay_loads_the_channels_it_needs() async throws {
        let built = TelemetryFixture.make()
        let model = try await loadedModel(built, channels: [])
        let revision = model.telemetryRevision
        let layout = OverlayLayout(name: "Temps", widgets: [
            OverlayWidget(kind: .channelValue(.channel("Water Temp")), frame: NormalizedRect(x: 0.1, y: 0.1,
                                                                                               width: 0.2,
                                                                                               height: 0.1))
        ])

        let overlay = try #require(try await model.exportOverlay(
            layout: layout, kart: nil, metadata: nil,
            analysis: AnalysisSession(session: built.session, dataSource: built.source)))

        #expect(overlay.telemetry.frame(at: 30).value(ofChannel: "Water Temp") == TelemetryFixture.water(30))
        #expect(model.telemetry?.frame(at: 30).value(ofChannel: "Water Temp") == nil)
        #expect(model.telemetryRevision == revision)
    }

    /// Laps and sectors re-cut since the telemetry was loaded need a fresh
    /// load too: the overlay's lap clock is cut by them.
    @Test func test_re_cut_sectors_need_a_fresh_load() async throws {
        let built = TelemetryFixture.make()
        let model = try await loadedModel(built, channels: [])
        model.review.update(timeline: VideoReviewFixture.timeline())

        let reused = try await model.exportOverlay(layout: OverlayPreset.minimal.layout(), kart: nil, metadata: nil,
                                                   analysis: nil)

        #expect(reused == nil, "no analysis to reload from")
    }

    /// Telemetry handed in directly — not loaded for any channels — serves a
    /// layout that names none.
    @Test func test_telemetry_set_directly_serves_a_layout_without_named_channels() async throws {
        let loaded = try await VideoDataFixture.loaded()

        let overlay = try await loaded.model.exportOverlay(layout: OverlayPreset.minimal.layout(), kart: nil,
                                                           metadata: nil, analysis: nil)
        let named = try await loaded.model.exportOverlay(
            layout: OverlayLayout(name: "Temps", widgets: [
                OverlayWidget(kind: .channelValue(.channel("Water Temp")),
                              frame: NormalizedRect(x: 0.1, y: 0.1, width: 0.2, height: 0.1))
            ]), kart: nil, metadata: nil, analysis: nil)

        #expect(overlay != nil)
        #expect(named == nil)
    }

    /// Before the telemetry is in there is nothing to draw from.
    @Test func test_no_overlay_before_the_telemetry() async throws {
        let model = VideoDataViewModel(review: VideoReviewModel())

        #expect(try await model.exportOverlay(layout: OverlayPreset.minimal.layout(), kart: nil, metadata: nil,
                                              analysis: nil) == nil)
    }

    // MARK: - Helpers

    private func loadedModel(_ built: TelemetryFixture.Built, channels: [String]) async throws -> VideoDataViewModel {
        let model = VideoDataViewModel(review: VideoReviewModel(timeline: built.sectors,
                                                                sync: VideoSyncModel(videoDuration: 120)))
        await model.loadTelemetry(from: AnalysisSession(session: built.session, dataSource: built.source),
                                  channels: channels)
        _ = try #require(model.telemetry)
        return model
    }
}
