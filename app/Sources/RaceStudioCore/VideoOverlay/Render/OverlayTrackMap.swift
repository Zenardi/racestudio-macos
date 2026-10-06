import CoreGraphics
import Foundation

/// What the mini track map draws besides the kart (issue 9.11): the racing
/// line and the sector boundaries on it, in the unit map frame the
/// ``TrackPosition`` projects into (north up, `y` growing southwards).
public struct OverlayTrackMap: Equatable, Sendable {
    /// The line the map strokes — the best lap, in the unit frame.
    public let racingLine: [CGPoint]
    /// Where each sector after the first begins, in the unit frame.
    public let sectorTicks: [CGPoint]

    /// No track: the map draws the kart against the unit frame alone.
    public static let empty = OverlayTrackMap(racingLine: [], sectorTicks: [])

    /// A point that is not a number (on either axis) has no place on the map
    /// and is left out.
    public init(racingLine: [CGPoint], sectorTicks: [CGPoint] = []) {
        self.racingLine = racingLine.filter(Self.isFinite)
        self.sectorTicks = sectorTicks.filter(Self.isFinite)
    }

    private static func isFinite(_ point: CGPoint) -> Bool {
        point.x.isFinite && point.y.isFinite
    }

    /// The map of `timeline`'s session: its racing line (the best lap, as the
    /// ``TrackPosition`` frames it), ticked where each of that lap's sectors in
    /// `sectors` after the first begins — none without a best lap, sectors or a
    /// GPS fix there.
    public init(timeline: TelemetryTimeline, sectors: LapSectorTimeline) {
        let best = timeline.clock.best.flatMap { sectors.lapSpan($0.lap) }
        let ticks = best?.sectors.dropFirst().compactMap { timeline.position.reading(at: $0.span.start)?.point }
        self.init(racingLine: timeline.position.racingLine, sectorTicks: ticks ?? [])
    }
}
