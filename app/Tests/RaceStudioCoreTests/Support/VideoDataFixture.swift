import Foundation
@testable import RaceStudioCore

/// The Video + Data suites' session (issue 9.12): ``TelemetryFixture``'s
/// synthetic 62 s kart session — laps `[0, 21)`, `[21, 40)`, `[40, 60.5)`, each
/// cut into two sectors — with footage of `videoDuration` seconds aligned by
/// `offset` (so session time `t` is playhead `t × rate + offset`).
enum VideoDataFixture {

    /// The loaded pieces: the model under test, the timeline it samples, and the
    /// raw fixture.
    @MainActor
    struct Loaded {
        let model: VideoDataViewModel
        let telemetry: TelemetryTimeline
        let built: TelemetryFixture.Built
    }

    @MainActor
    static func loaded(videoDuration: Double = 120, offset: Double = 5, rate: Double = 1,
                       built: TelemetryFixture.Built = TelemetryFixture.make()) async throws -> Loaded {
        let telemetry = try await TelemetryTimeline.load(session: built.session, source: built.source,
                                                         sectors: built.sectors)
        let review = VideoReviewModel(timeline: built.sectors,
                                      sync: VideoSyncModel(videoDuration: videoDuration, offset: offset, rate: rate))
        let model = VideoDataViewModel(review: review)
        model.setTelemetry(telemetry)
        return Loaded(model: model, telemetry: telemetry, built: built)
    }

    /// The fixture's GPS fixes.
    static func track(_ built: TelemetryFixture.Built) -> [GPSTrackPoint] {
        built.source.gpsTrack(start: 0, count: .max)
    }
}
