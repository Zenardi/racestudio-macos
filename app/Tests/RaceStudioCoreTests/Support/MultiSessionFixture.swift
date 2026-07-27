import Foundation
@testable import RaceStudioCore

/// Shared fixtures for the multi-session compare tests (parity gap 9.1, issue
/// #138): in-memory `AnalysisSession`s over a `FakeSessionDataSource`, so
/// `MultiSessionModel`'s logic is covered FFI-free. Free functions (prefixed
/// `ms`) so both `MultiSessionModelTests` and `MultiSessionModelEdgeTests` share
/// them without duplication.

/// Two contiguous laps spanning t = 0…10 s (lap 0: 0…5, lap 1: 5…10).
func msTwoLaps() -> [Lap] {
    [Lap(index: 0, startTimeS: 0, durationS: 5, endTimeS: 5),
     Lap(index: 1, startTimeS: 5, durationS: 5, endTimeS: 10)]
}

/// Distance-paired `Speed` samples at t = 0…10: cumulative distance `distScale·t`
/// m, value `valueScale·t`.
func msSpeedBank(distScale: Double = 10, valueScale: Double) -> [DistanceSample] {
    (0...10).map {
        DistanceSample(time: Double($0), distance: Double($0) * distScale, value: Double($0) * valueScale)
    }
}

/// A distance channel whose two laps have different distance-vs-time so a
/// cross-lap delta is non-zero: lap 0 covers 10 m/s, lap 1 covers 20 m/s.
///   lap 0 (t 0…5)  → distances [0,10,20,30,40,50], times [0,1,2,3,4,5]
///   lap 1 (t 5…10) → distances [0,20,40,60,80,100], times [0,1,2,3,4,5]
func msDeltaBank() -> [DistanceSample] {
    (0...10).map { i in
        let t = Double(i)
        let d = t <= 5 ? 10 * t : 50 + 20 * (t - 5)
        return DistanceSample(time: t, distance: d, value: t)
    }
}

/// An `AnalysisSession` over a single `Speed` channel carrying `distance`.
@MainActor
func msSession(distance: [DistanceSample], laps: [Lap], name: String = "") -> AnalysisSession {
    let session = Session(
        metadata: SessionMetadata(vehicle: "", track: "", driver: "", session: name,
                                  series: "", logDate: "", logTime: "", datetimeUtc: 0),
        channels: [Channel(name: "Speed", unit: "km/h", sampleRateHz: 10, decimals: 1,
                           sampleCount: UInt32(distance.count))],
        laps: laps)
    return AnalysisSession(session: session,
                           dataSource: FakeSessionDataSource(banks: [], distanceBanks: [distance]))
}
