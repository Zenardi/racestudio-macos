import Foundation
@testable import RaceStudioCore

/// A synthetic MyChron-like session for the telemetry-timeline tests (issue
/// 9.9), served through ``FakeSessionDataSource`` — no `.xrk`, no FFI.
///
/// Every channel is a simple function of time, so a test can state the value a
/// frame must carry exactly:
///
/// - `GPS Speed` (m/s) = 10 + 0.1·t, `RPM` = 8000 + 10·t, `GPS_LateralAcc` (g) =
///   0.01·t − 0.5, `GPS_InlineAcc` (g) = 0.3, `Water Temp` (°C) = 60 + 0.01·t,
///   all at 20 Hz; `Gear` steps 1→4 every 5 s (step-held); `Best Run Diff` (ms)
///   is logged at 1 Hz as 100·(lap number);
/// - the GPS track runs round a circle at 20 Hz with the odometer at 10·t metres;
/// - an out-lap `[0, 21)`, the best lap `[21, 40)` and a 20.5 s lap `[40, 60.5)`
///   — the in-lap of the default 62 s recording; a longer recording keeps
///   lapping every 20 s until 1.5 s before its end.
enum TelemetryFixture {

    /// The sample rate of every continuous channel and the GPS.
    static let rate = 20.0

    static func speedMS(_ t: Double) -> Double { 10 + 0.1 * t }
    static func rpm(_ t: Double) -> Double { 8000 + 10 * t }
    static func lateral(_ t: Double) -> Double { 0.01 * t - 0.5 }
    static func water(_ t: Double) -> Double { 60 + 0.01 * t }
    static func gear(_ t: Double) -> Double { Double(Int(t / 5) % 4 + 1) }

    /// The laps of a recording `duration` seconds long.
    static func laps(duration: Double) -> [Lap] {
        var laps = [Lap(index: 0, startTimeS: 0, durationS: 21, endTimeS: 21),
                    Lap(index: 1, startTimeS: 21, durationS: 19, endTimeS: 40),
                    Lap(index: 2, startTimeS: 40, durationS: 20.5, endTimeS: 60.5)]
        while let last = laps.last, last.endTimeS + 20 <= duration - 1.5 {
            laps.append(Lap(index: last.index + 1, startTimeS: last.endTimeS, durationS: 20,
                            endTimeS: last.endTimeS + 20))
        }
        return laps
    }

    /// The delta-t series the fake core returns for lap `comparison` against lap
    /// 1, on the reference lap's 190 m grid: the out-lap loses a second, every
    /// later lap gains half a second.
    static func deltaSeries(comparison: Int) -> [DeltaSample] {
        let final = comparison == 0 ? 1.0 : -0.5
        return [DeltaSample(distance: 0, dt: 0), DeltaSample(distance: 190, dt: final)]
    }

    /// The built session, its data source and its split timeline.
    struct Built {
        let session: Session
        let source: FakeSessionDataSource
        let sectors: LapSectorTimeline
    }

    /// - Parameters:
    ///   - duration: the recording's length (seconds).
    ///   - gpsOnly: list only the GPS stream's channels (no RPM, gear, …).
    ///   - rpmGap: a window in which the RPM channel logged nothing.
    static func make(duration: Double = 62, gpsOnly: Bool = false,
                     rpmGap: Range<Double>? = nil) -> Built {
        let laps = laps(duration: duration)
        let times = (0..<Int(duration * rate)).map { Double($0) / rate }
        var channels: [(Channel, [DataSample])] = [
            (channel("GPS Speed", "m/s", times.count), times.map { DataSample(time: $0, value: speedMS($0)) }),
            (channel("GPS_InlineAcc", "g", times.count), times.map { DataSample(time: $0, value: 0.3) }),
            (channel("GPS_LateralAcc", "g", times.count), times.map { DataSample(time: $0, value: lateral($0)) })
        ]
        if !gpsOnly {
            let rpmTimes = times.filter { !(rpmGap?.contains($0) ?? false) }
            let diffTimes = stride(from: 0.0, to: duration, by: 1).map { $0 }
            channels += [
                (channel("RPM", "rpm", rpmTimes.count), rpmTimes.map { DataSample(time: $0, value: rpm($0)) }),
                (channel("Gear", "", times.count), times.map { DataSample(time: $0, value: gear($0)) }),
                (channel("Water Temp", "C", times.count), times.map { DataSample(time: $0, value: water($0)) }),
                (channel("Best Run Diff", "ms", diffTimes.count, rate: 1),
                 diffTimes.map { DataSample(time: $0, value: 100 * Double(lapNumber(at: $0, in: laps))) })
            ]
        }
        var deltas: [FakeSessionDataSource.DeltaKey: [DeltaSample]] = [:]
        for lap in laps where lap.index != 1 {
            deltas[FakeSessionDataSource.DeltaKey(reference: 1, comparison: lap.index)]
                = deltaSeries(comparison: Int(lap.index))
        }
        let source = FakeSessionDataSource(banks: channels.map(\.1), gps: track(times), deltas: deltas)
        let session = Session(metadata: SessionFixture.make().metadata, channels: channels.map(\.0), laps: laps)
        let halves = laps.map {
            LapSegments(lap: LapID(Int($0.index)), baseTimes: [$0.durationS / 2, $0.durationS / 2])
        }
        let sectors = LapSectorTimeline.make(laps: laps, segments: halves, layout: SplitLayout.even(base: 2, count: 2))
        return Built(session: session, source: source, sectors: sectors)
    }

    /// A 12-minute, 20 Hz session — the size the memory and speed budgets are
    /// stated for.
    static func twelveMinutes() -> Built {
        make(duration: 720)
    }

    // MARK: - Internals

    private static func channel(_ name: String, _ unit: String, _ count: Int, rate: Double = rate) -> Channel {
        Channel(name: name, unit: unit, sampleRateHz: rate, decimals: 2, sampleCount: UInt32(count))
    }

    /// The 1-based number of the lap holding `t` (the last lap's after the end).
    private static func lapNumber(at t: Double, in laps: [Lap]) -> Int {
        (laps.firstIndex { t >= $0.startTimeS && t < $0.endTimeS } ?? laps.count - 1) + 1
    }

    /// One fix per sample, round a ~220 m circle every 20 s, odometer 10·t m.
    private static func track(_ times: [Double]) -> [GPSTrackPoint] {
        times.map { t in
            let theta = 2 * Double.pi * t / 20
            return GPSTrackPoint(coordinate: GPSCoord(latitude: 45 + 0.001 * cos(theta),
                                                      longitude: 12 + 0.0014 * sin(theta)),
                                 distance: 10 * t, time: t)
        }
    }
}
