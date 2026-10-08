import CoreGraphics
import Foundation
@testable import RaceStudioCore

/// Synthetic inputs for the overlay renderer tests (issue 9.11) — a made-up
/// kart session with every role, a kart, a venue, an oval track and three
/// sectors; no footage, no session file, no personal data.
enum OverlayRenderFixture {

    // MARK: - Session

    /// Every role's channel, plus an `Oil Temp` no role covers.
    static let channels: [Channel] = [
        channel("GPS Speed", "km/h", 1), channel("RPM", "rpm", 0), channel("Gear", "", 0),
        channel("Throttle", "%", 0), channel("Brake", "bar", 1), channel("GPS_LateralAcc", "g", 2),
        channel("GPS_InlineAcc", "g", 2), channel("Water Temp", "C", 1), channel("Exhaust Temp", "C", 0),
        channel("Oil Temp", "C", 1)
    ]

    static let kart = Kart(id: "synthetic", name: "Test kart", category: "F4", chassis: "Thunder",
                           engine: "RBC Honda", powerHP: 18)

    static let metadata = SessionMetadata(vehicle: "", track: "Synthetic Raceway", driver: "", session: "Practice 2",
                                          series: "", logDate: "10/06/2026", logTime: "14:00:00", datetimeUtc: 0)

    /// A session that feeds every widget.
    static func session(channels: [Channel] = channels, kart: Kart? = kart,
                        metadata: SessionMetadata? = metadata) -> OverlaySessionContext {
        OverlaySessionContext(channelMap: TelemetryChannelMap.resolve(channels: channels), hasLaps: true,
                              hasSectors: true, hasTrackPosition: true, kart: kart, metadata: metadata)
    }

    // MARK: - Track and sectors

    /// An oval with a kink, 120 points round the unit square.
    static let racingLine: [CGPoint] = (0..<120).map { index in
        let theta = Double(index) / 120 * 2 * .pi
        return CGPoint(x: 0.5 + 0.45 * cos(theta), y: 0.5 + 0.3 * sin(theta) + 0.1 * sin(2 * theta))
    }

    static let track = OverlayTrackMap(racingLine: racingLine,
                                       sectorTicks: [racingLine[40], racingLine[80]])

    /// Lap 5 (index 4) in three sectors, after lap 4 (index 3).
    static let lapStart = 106.968
    static let sectors = LapSectorTimeline(laps: [
        lapSpan(3, start: 59.056, splits: [15.8, 16.1, 16.012]),
        lapSpan(4, start: lapStart, splits: [15.532, 16.5, 15.88])
    ])

    // MARK: - Frames

    static let lastLap = LapTiming(lap: LapID(3), number: 4, time: 47.912)
    static let bestLap = LapTiming(lap: LapID(2), number: 3, time: 46.881)

    /// Mid-lap in sector 2: every value present, gaining 0.23 s.
    static let midLap = TelemetryFrame(
        time: lapStart + 18.432,
        values: [.speed: 87.4, .rpm: 12_850, .gear: 3, .throttle: 72, .brake: 0, .latG: 0.62, .lonG: -0.35,
                 .waterTemp: 54.2, .exhaustTemp: 612],
        lap: reading(elapsed: 18.432, sector: 1), delta: -0.23,
        position: TrackPositionReading(point: racingLine[50], heading: 90),
        gTrail: trail(endingAt: lapStart + 18.432), channels: ["Oil Temp": 98.6])

    /// Four tenths into lap 5, the lap-4 time showing as the last lap, losing 0.41 s.
    static let lapStartFrame = TelemetryFrame(
        time: lapStart + 0.4,
        values: [.speed: 102.9, .rpm: 14_210, .gear: 4, .throttle: 100, .brake: 0, .latG: -0.12, .lonG: 0.31,
                 .waterTemp: 54.9, .exhaustTemp: 655],
        lap: reading(elapsed: 0.4, sector: 0), delta: 0.41,
        position: TrackPositionReading(point: racingLine[1], heading: 0),
        gTrail: trail(endingAt: lapStart + 0.4), channels: ["Oil Temp": 99.1])

    /// A channel gap: nothing known at all.
    static let gap = TelemetryFrame(time: 300, values: [:])

    // MARK: - Widget contexts

    /// The context a widget of `kind` draws with, in `rect` (pixels, drawing space).
    static func context(_ kind: OverlayWidgetKind, rect: CGRect = CGRect(x: 0, y: 0, width: 240, height: 140),
                        outputHeight: CGFloat = 1080, plate: OverlayPlateStyle = .translucent,
                        sizeClass: OverlaySizeClass = .medium, units: UnitSystem = .metric,
                        options: OverlayWidgetOptions = OverlayWidgetOptions(),
                        formatter: OverlayFormatter = OverlayFormatter(),
                        session: OverlaySessionContext = session(), track: OverlayTrackMap = track,
                        sectors: LapSectorTimeline = sectors) -> OverlayWidgetContext {
        let widget = OverlayWidget(kind: kind, frame: .unit, plate: plate, sizeClass: sizeClass, options: options)
        return OverlayWidgetContext(widget: widget, rect: rect, outputHeight: outputHeight, theme: .raceStudio,
                                    formatter: formatter, units: units, session: session, track: track,
                                    sectors: sectors)
    }

    /// Which parts of a widget to draw.
    enum Parts {
        case all, staticOnly, dynamicOnly
    }

    /// `drawer` drawn for `frame` with `context` into a transparent bitmap that
    /// just holds the widget's rect.
    static func render<Drawer: OverlayWidgetDrawer>(_ drawer: Drawer, _ frame: TelemetryFrame,
                                                    context: OverlayWidgetContext,
                                                    parts: Parts = .all) -> OverlayBitmap {
        let bitmap = OverlayBitmap(width: Int(context.rect.maxX), height: Int(context.rect.maxY))
        let layout = drawer.layout(in: context)
        if parts != .dynamicOnly { drawer.drawStatic(layout, in: bitmap.context, context: context) }
        if parts != .staticOnly { drawer.drawDynamic(frame, layout, in: bitmap.context, context: context) }
        return bitmap
    }

    // MARK: - Internals

    private static func channel(_ name: String, _ unit: String, _ decimals: UInt8) -> Channel {
        Channel(name: name, unit: unit, sampleRateHz: 20, decimals: decimals, sampleCount: 1_000)
    }

    private static func lapSpan(_ index: Int, start: Double, splits: [Double]) -> LapSpan {
        var sectors: [SectorSpan] = []
        var cursor = start
        for (position, length) in splits.enumerated() {
            sectors.append(SectorSpan(lap: LapID(index), splitID: position, name: "S\(position + 1)", index: position,
                                      span: SessionTimeSpan(start: cursor, end: cursor + length)))
            cursor += length
        }
        return LapSpan(lap: LapID(index), span: SessionTimeSpan(start: start, end: cursor), sectors: sectors)
    }

    /// Lap 5's reading: lap 4's sectors are the bests so far.
    private static func reading(elapsed: Double, sector: Int) -> LapClockReading {
        LapClockReading(lap: LapID(4), number: 5, elapsed: elapsed, last: lastLap, best: bestLap, bestSoFar: bestLap,
                        isOutLap: false, isInLap: false, sector: sectors.laps[1].sectors[sector],
                        sectorBestsSoFar: [0: 15.8, 1: 16.1, 2: 16.012])
    }

    /// One second of G samples at 10 Hz swinging round the ball, oldest first.
    private static func trail(endingAt end: Double) -> [GForcePoint] {
        (0..<10).map { index in
            let phase = Double(index) / 10
            return GForcePoint(time: end - 0.9 + phase, lateral: 0.6 * cos(phase * 3),
                               longitudinal: -0.4 * sin(phase * 3))
        }
    }
}
