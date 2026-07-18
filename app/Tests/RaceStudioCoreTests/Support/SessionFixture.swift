import Foundation
@testable import RaceStudioCore

/// Builds synthetic `Session` values for the session-library tests (issue 5.3) —
/// a deterministic, dependency-free alternative to decoding a real `.xrk` when a
/// test only needs session metadata and lap timings. The realistic 13-lap case
/// is covered separately by `GoldenSession.load("fuji_0033")`.
enum SessionFixture {

    /// A synthetic session. `lapDurations` are per-lap durations in seconds; laps
    /// are laid out contiguously so `start`/`end` are cumulative.
    static func make(
        vehicle: String = "SFJ",
        track: String = "Fuji GP Sh",
        driver: String = "CMD",
        datetimeUtc: Int64 = 1_762_271_407,
        lapDurations: [Double] = [120, 100, 110]
    ) -> Session {
        var laps: [Lap] = []
        var start = 0.0
        for (offset, duration) in lapDurations.enumerated() {
            laps.append(Lap(index: UInt32(offset), startTimeS: start,
                            durationS: duration, endTimeS: start + duration))
            start += duration
        }
        return Session(
            metadata: SessionMetadata(
                vehicle: vehicle, track: track, driver: driver,
                session: "Generic testing", series: "Practice",
                logDate: "11/04/2025", logTime: "15:50:07", datetimeUtc: datetimeUtc),
            channels: [Channel(name: "RPM", unit: "rpm", sampleRateHz: 100, decimals: 0, sampleCount: 1000)],
            laps: laps)
    }
}
