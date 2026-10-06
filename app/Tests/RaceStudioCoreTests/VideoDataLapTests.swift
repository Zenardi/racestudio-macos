import Combine
import Testing
import Foundation

@testable import RaceStudioCore

/// Tests for `VideoDataViewModel`'s laps and panes (issue 9.12): picking a lap
/// sets the strip plot, the seek target and the play window; *Play lap* plays
/// exactly one whole lap; the plot and the track map follow the cursor's lap;
/// and the HUD renderer and the telemetry are built for the session.
@MainActor
@Suite struct VideoDataLapTests {

    private func sector(lap: Int, index: Int, in loaded: VideoDataFixture.Loaded) throws -> SectorSpan {
        try #require(loaded.model.review.timeline.lapSpan(LapID(lap))?.sectors[index])
    }

    // MARK: - Picking a lap

    /// A lap picked in the lap list is what the plot shows, where the footage
    /// seeks to and the window it plays.
    @Test func test_selecting_a_lap_sets_the_plot_seek_target_and_play_window() async throws {
        let loaded = try await VideoDataFixture.loaded(offset: 5)

        loaded.model.selectLap(LapID(1))

        #expect(loaded.model.plotLap == LapID(1))
        #expect(loaded.model.plotRange == SessionTimeSpan(start: 21, end: 40))
        #expect(loaded.model.stripPlot?.span == SessionTimeSpan(start: 21, end: 40))
        #expect(loaded.model.review.seekTarget == 26)
        #expect(loaded.model.review.videoWindow == 26...45)
        #expect(loaded.model.review.cursorTarget == 21)
    }

    /// A lap the session doesn't have changes nothing.
    @Test func test_selecting_an_unknown_lap_changes_nothing() async throws {
        let loaded = try await VideoDataFixture.loaded()
        loaded.model.selectLap(LapID(1))

        loaded.model.selectLap(LapID(9))

        #expect(loaded.model.plotLap == LapID(1))
        #expect(loaded.model.review.selectedLap == LapID(1))
    }

    /// A sector picked in the grid puts its lap on the plot.
    @Test func test_selecting_a_sector_plots_its_lap() async throws {
        let loaded = try await VideoDataFixture.loaded()

        loaded.model.selectSector(try sector(lap: 2, index: 1, in: loaded))

        #expect(loaded.model.plotLap == LapID(2))
        #expect(loaded.model.review.scope == .sector)
    }

    // MARK: - Play lap

    /// *Play lap* plays the whole lap — a sector under review widens to its lap.
    @Test func test_play_lap_widens_a_sector_to_its_whole_lap() async throws {
        let loaded = try await VideoDataFixture.loaded()
        loaded.model.selectSector(try sector(lap: 2, index: 1, in: loaded))

        #expect(loaded.model.prepareLapPlayback())

        #expect(loaded.model.review.scope == .lap)
        #expect(loaded.model.review.selectedSpan == SessionTimeSpan(start: 40, end: 60.5))
    }

    /// With nothing picked, *Play lap* plays the lap the cursor is in.
    @Test func test_play_lap_without_a_pick_plays_the_cursor_lap() async throws {
        let loaded = try await VideoDataFixture.loaded()
        loaded.model.follow(cursorTime: 25, isPlaying: false)
        loaded.model.review.clearSelection()

        #expect(loaded.model.prepareLapPlayback())

        #expect(loaded.model.review.selectedLap == LapID(1))
    }

    /// A lap the footage never filmed can't be played.
    @Test func test_play_lap_refuses_a_lap_outside_the_footage() async throws {
        let loaded = try await VideoDataFixture.loaded(offset: -100)
        loaded.model.selectLap(LapID(1))

        #expect(!loaded.model.prepareLapPlayback())
    }

    /// With no lap at all there is nothing to play.
    @Test func test_play_lap_without_laps_does_nothing() {
        let model = VideoDataViewModel(review: VideoReviewModel())

        #expect(!model.prepareLapPlayback())
        #expect(model.plotLap == nil)
        #expect(model.plotRange == nil)
    }

    // MARK: - The plot follows the cursor's lap

    /// The plot shows the lap the cursor is in, keeping the last one between
    /// laps; it is rebuilt only when that lap changes.
    @Test func test_the_plot_follows_the_cursor_lap() async throws {
        let loaded = try await VideoDataFixture.loaded()
        var rebuilt = 0
        let watch = loaded.model.$stripPlot.dropFirst().sink { _ in rebuilt += 1 }

        loaded.model.follow(cursorTime: 10, isPlaying: false)
        loaded.model.follow(cursorTime: 12, isPlaying: false)
        #expect(loaded.model.plotLap == LapID(0))
        loaded.model.follow(cursorTime: 50, isPlaying: false)
        #expect(loaded.model.plotLap == LapID(2))
        loaded.model.follow(cursorTime: 61.5, isPlaying: false)
        #expect(loaded.model.plotLap == LapID(2), "after the last lap the plot keeps it")

        #expect(rebuilt == 1, "lap 0 was already on show; only the move to lap 2 rebuilds")
        watch.cancel()
    }

    /// Once the telemetry is in, the plot starts on the first lap.
    @Test func test_the_plot_starts_on_the_first_lap() async throws {
        let loaded = try await VideoDataFixture.loaded()

        #expect(loaded.model.plotLap == LapID(0))
        #expect(loaded.model.stripPlot?.traces.map(\.role) == [.speed, .rpm])
    }

    // MARK: - Track map

    /// The map shows the plotted lap's line, with the kart's dot at the cursor,
    /// a mark where each later sector begins, and a click there meaning that
    /// fix's session time.
    @Test func test_the_map_shows_the_plotted_lap() async throws {
        let loaded = try await VideoDataFixture.loaded()
        loaded.model.setTrack(VideoDataFixture.track(loaded.built))

        loaded.model.selectLap(LapID(1))

        let map = try #require(loaded.model.lapMap)
        #expect(map.times.allSatisfy { (21...40).contains($0) })
        #expect(loaded.model.trackMarkers(atTime: 30).map(\.isCursorLap) == [true])
        let marks = loaded.model.sectorMarks
        #expect(marks.count == 1)
        let mark = try #require(marks.first)
        #expect(abs(try #require(loaded.model.sessionTime(atFix: mark)) - 30.5) < 0.05)
        #expect(loaded.model.sessionTime(atFix: -1) == nil)
    }

    /// Without a GPS track there is no map.
    @Test func test_without_a_track_there_is_no_map() async throws {
        let loaded = try await VideoDataFixture.loaded()

        #expect(loaded.model.lapMap == nil)
        #expect(loaded.model.trackMarkers(atTime: 30).isEmpty)
        #expect(loaded.model.sectorMarks.isEmpty)
    }

    /// A session with no lap has nothing to plot or map, track or not.
    @Test func test_without_a_lap_there_is_nothing_to_plot_or_map() {
        let model = VideoDataViewModel(review: VideoReviewModel())

        model.setTrack(VideoDataFixture.track(TelemetryFixture.make()))

        #expect(model.stripPlot == nil)
        #expect(model.lapMap == nil)
        #expect(model.sessionTime(atFix: 0) == nil)
    }

    /// The window shares its GPS track, so the map needs no second read.
    @Test func test_the_window_shares_its_gps_track() {
        let built = TelemetryFixture.make()
        let analysis = AnalysisSession(session: built.session, dataSource: built.source)

        let window = AnalysisWindowModel(session: built.session, analysis: analysis)

        #expect(window.gpsTrack == VideoDataFixture.track(built))
    }

    // MARK: - The HUD renderer

    /// The HUD is drawn by the shared renderer, told what this session can feed.
    @Test func test_the_renderer_knows_what_the_session_feeds() async throws {
        let loaded = try await VideoDataFixture.loaded()
        let layout = OverlayPreset.kartCoaching.layout()

        let renderer = try #require(loaded.model.makeRenderer(layout: layout, kart: nil, metadata: nil,
                                                                locale: Locale(identifier: "pt_BR")))

        #expect(renderer.layout == layout)
        #expect(renderer.session.channelMap == loaded.telemetry.channelMap)
        #expect(renderer.session.hasLaps && renderer.session.hasSectors && renderer.session.hasTrackPosition)
        #expect(renderer.formatter.decimalSeparator == ",")
        #expect(renderer.sectors == loaded.built.sectors)
        #expect(!renderer.track.racingLine.isEmpty)
    }

    /// Each telemetry handed in is a new revision, so the HUD knows to rebuild
    /// its renderer.
    @Test func test_each_new_telemetry_is_a_new_revision() async throws {
        let loaded = try await VideoDataFixture.loaded()
        let first = loaded.model.telemetryRevision

        loaded.model.setTelemetry(loaded.telemetry)

        #expect(loaded.model.telemetryRevision == first + 1)
    }

    /// Before the telemetry is in there is nothing to draw.
    @Test func test_no_renderer_before_the_telemetry() {
        let model = VideoDataViewModel(review: VideoReviewModel())

        #expect(model.makeRenderer(layout: OverlayPreset.minimal.layout(), kart: nil, metadata: nil) == nil)
        #expect(model.overlayContext(kart: nil, metadata: nil) == nil)
    }

    // MARK: - Loading

    /// The telemetry is loaded from the window's analysis session, with the
    /// overlay's named channels, and the frame at the cursor is shown at once.
    @Test func test_loading_the_telemetry_shows_the_cursor_frame() async throws {
        let built = TelemetryFixture.make()
        let analysis = AnalysisSession(session: built.session, dataSource: built.source)
        let model = VideoDataViewModel(review: VideoReviewModel(timeline: built.sectors))
        model.follow(cursorTime: 30, isPlaying: false)

        await model.loadTelemetry(from: analysis, channels: ["Water Temp"])

        let frame = try #require(model.currentFrame)
        #expect(frame.speed != nil)
        #expect(frame.value(ofChannel: "Water Temp") == TelemetryFixture.water(30))
    }

    /// Of two loads in flight, only the one asked for last is kept.
    @Test func test_a_superseded_load_never_writes() async throws {
        let built = TelemetryFixture.make()
        let analysis = AnalysisSession(session: built.session, dataSource: built.source)
        let model = VideoDataViewModel(review: VideoReviewModel(timeline: built.sectors))
        model.follow(cursorTime: 30, isPlaying: false)

        // The task starts only once the direct call below suspends, so it is
        // the later request.
        let later = Task { await model.loadTelemetry(from: analysis, channels: ["Water Temp"]) }
        await model.loadTelemetry(from: analysis, channels: [])
        await later.value

        #expect(model.currentFrame?.value(ofChannel: "Water Temp") != nil)
    }
}
