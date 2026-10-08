import CoreMedia
import Foundation
import Testing
@testable import RaceStudioCore

/// The running lap time burned into an export (issue 9.16): every exported
/// frame shows the time since its own lap's beacon, read at the session time
/// that frame maps to — so the timer resets between the two frames either side
/// of the lap line, and an export that starts mid-lap shows the lap's true
/// time on its first frame.
@Suite struct ExportLapTimerTests {

    /// Two 50 s laps: L0 [0, 50) and L1 [50, 100).
    private static let laps = [Lap(index: 0, startTimeS: 0, durationS: 50, endTimeS: 50),
                               Lap(index: 1, startTimeS: 50, durationS: 50, endTimeS: 100)]

    /// An export of footage synced with no offset whose first frame is footage
    /// time `sourceStart`.
    private func export(from sourceStart: Double) -> OverlayRenderContext {
        let distance = TelemetrySeries(times: [0, 100], values: [0, 1_000], maxGap: .infinity)
        let delta = LiveDelta(reference: nil, laps: Self.laps, distance: distance) { _, _ in [] }
        let telemetry = TelemetryTimeline(channelMap: TelemetryChannelMap.resolve(channels: []), series: [:],
                                          clock: LapClock(laps: Self.laps),
                                          position: TrackPosition(track: [], laps: Self.laps), liveDelta: delta)
        return OverlayRenderContext(overlay: ExportOverlay(drawer: SessionTimeBar(origin: 0), telemetry: telemetry),
                                    sync: VideoSyncModel(videoDuration: 600, offset: 0, rate: 1),
                                    session: SessionTimeSpan(start: 0, end: 100), outsideSession: .hidden,
                                    sourceStart: sourceStart, rotation: .none)
    }

    /// What the lap timer and lap info show on 30 fps frame `index` of `export`.
    private func shown(onFrame index: Int, of export: OverlayRenderContext) throws
        -> (timer: [String], info: [String]) {
        var cursor = SamplingCursor()
        let time = export.sessionTime(at: CMTime(value: CMTimeValue(index), timescale: 30))
        let frame = try #require(export.telemetryFrame(at: time, cursor: &cursor))
        return (LapTimerWidget().readouts(frame, context: OverlayRenderFixture.context(.lapTimer)),
                LapInfoWidget().readouts(frame, context: OverlayRenderFixture.context(.lapInfo)))
    }

    /// The last frame before the line shows the finishing lap's time; the
    /// first frame on it starts the next lap at zero, and lap info's last lap
    /// is the lap just finished.
    @Test func test_the_timer_resets_between_the_frames_either_side_of_the_line() throws {
        let export = export(from: 0)

        let before = try shown(onFrame: 1_499, of: export)
        let after = try shown(onFrame: 1_500, of: export)

        #expect(before.timer == ["0:49.967"])
        #expect(after.timer == ["0:00.000"])
        #expect(after.info == ["2", "0:50.000", "0:50.000"])
    }

    /// An export starting mid-lap — or with lead-in before the line — shows on
    /// its first frame the time of the lap it starts in, not zero.
    @Test(arguments: zip([68.0, 48.0], ["0:18.000", "0:48.000"]))
    func test_an_export_starting_mid_lap_shows_the_laps_true_time(start: Double, timer: String) throws {
        #expect(try shown(onFrame: 0, of: export(from: start)).timer == [timer])
    }
}
