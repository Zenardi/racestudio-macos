//! Reconstruct laps from `Beacon Markers` (issue 5.2) — the inverse of the 5.1
//! writer, which emits each lap's cumulative end time as a beacon.

use racestudio_decode::Lap;

/// Rebuild laps from beacon end-times (seconds, cumulative from the session
/// start). Lap `i` spans `[beacons[i-1], beacons[i]]` (the first lap starts at
/// 0), mirroring 5.1's writer. Non-finite or out-of-order beacons (a beacon not
/// greater than the previous) are skipped so a malformed row never produces a
/// negative-duration lap.
#[must_use]
pub fn laps_from_beacons(beacons_s: &[f64]) -> Vec<Lap> {
    let mut laps = Vec::new();
    let mut prev = 0.0_f64;
    for &end in beacons_s {
        // Skip non-finite or non-increasing beacons rather than emit a
        // zero/negative-duration lap; `prev` only advances on an accepted beacon.
        if end.is_finite() && end > prev {
            laps.push(Lap::new(laps.len() as u32, prev, end - prev));
            prev = end;
        }
    }
    laps
}
