//! Per-segment split times for the Split Times report (issue 8.11).
//!
//! [`segment_times`] cuts a single [`Lap`] into `N` equal-**distance** segments —
//! the same track pieces lap after lap — and reports how long the car spent in
//! each. The lap's distance axis is its `GPS Speed` channel integrated with the
//! trapezoidal rule ([`cumulative_distance`]); the cut times are read back off
//! that axis. The first and last cuts are pinned to the lap's own `[0, duration]`,
//! so the returned times always **sum to the lap duration exactly** — no time is
//! lost or double-counted at a boundary.
//!
//! A lap with no `GPS Speed` channel (or a zero-length distance axis) has no
//! odometer to cut on, so it falls back to `N` equal-*time* segments — still
//! summing to the duration. Nothing panics on caller input.

use crate::laps::{cumulative_distance, Lap, SPEED_CHANNEL};
use crate::math::interp;

/// The time (seconds) spent in each of `splits` equal-distance segments of `lap`,
/// in track order (issue 8.11).
///
/// `splits` is treated as **at least 1** — a `0` request yields the whole lap as a
/// single segment. See the module docs for the distance-cut construction and the
/// GPS-less equal-time fallback; the returned vector always has exactly
/// `splits.max(1)` elements and sums to the lap duration.
#[must_use]
pub fn segment_times(lap: &Lap, splits: usize) -> Vec<f64> {
    let n = splits.max(1);
    let duration_s = lap.duration_ms() / 1000.0;
    let equal_time = || vec![duration_s / n as f64; n];

    // No odometer → fall back to equal-time segments.
    let Some(speed) = lap
        .channel(SPEED_CHANNEL)
        .filter(|c| !c.samples().is_empty())
    else {
        return equal_time();
    };
    let distances = cumulative_distance(speed.samples());
    let total = distances.last().copied().unwrap_or(0.0);
    if total <= 0.0 {
        return equal_time();
    }

    // Time-from-lap-start (seconds) at each speed sample, the axis `interp` reads a
    // boundary's cut time off of (as a function of cumulative distance).
    let times_s: Vec<f64> = speed
        .samples()
        .iter()
        .map(|&(t, _)| (t - lap.start_time_ms()) / 1000.0)
        .collect();

    // The cut time at the `k`-th of `n + 1` equal-distance boundaries. The ends are
    // pinned to the lap's own `[0, duration]` so the segment times telescope to the
    // duration exactly; interior boundaries are interpolated off the distance axis.
    let boundary_time = |k: usize| -> f64 {
        if k == 0 {
            0.0
        } else if k == n {
            duration_s
        } else {
            interp(&distances, &times_s, k as f64 * total / n as f64)
        }
    };
    (0..n)
        .map(|i| (boundary_time(i + 1) - boundary_time(i)).max(0.0))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::laps::LapChannel;

    /// A lap over `[start_ms, end_ms)` carrying a single `GPS Speed` channel.
    fn lap_with_speed(number: u32, start_ms: f64, end_ms: f64, speed: &[(f64, f64)]) -> Lap {
        Lap::new(
            number,
            start_ms,
            end_ms,
            vec![LapChannel::new(SPEED_CHANNEL, speed.to_vec())],
        )
    }

    #[test]
    fn test_constant_speed_splits_partition_the_lap_into_equal_times() {
        // 10 m/s held over a 10 s lap → distance is linear in time, so equal-distance
        // cuts are equal-time cuts: two segments of 5 s each.
        let speed: Vec<(f64, f64)> = (0..=10).map(|i| (i as f64 * 1000.0, 10.0)).collect();
        let lap = lap_with_speed(0, 0.0, 10_000.0, &speed);

        let times = segment_times(&lap, 2);

        assert_eq!(times, vec![5.0, 5.0]);
    }

    #[test]
    fn test_faster_first_half_spends_less_time_in_the_first_segment() {
        // 20 m/s for the first 2 s (→ 40 m), then 10 m/s for the next 6 s (→ 60 m):
        // total 100 m over 8 s. The 50 m mid-cut lands 1 s into the slow section, at
        // t = 3 s, so segment 1 (0–50 m) = 3 s and segment 2 (50–100 m) = 5 s — the
        // faster first stretch covers its distance in less time.
        let speed = [(0.0, 20.0), (2000.0, 20.0), (2000.0, 10.0), (8000.0, 10.0)];
        let lap = lap_with_speed(0, 0.0, 8000.0, &speed);

        let times = segment_times(&lap, 2);

        assert!((times[0] - 3.0).abs() < 1e-9, "first segment {}", times[0]);
        assert!((times[1] - 5.0).abs() < 1e-9, "second segment {}", times[1]);
        assert!((times.iter().sum::<f64>() - 8.0).abs() < 1e-9);
    }

    #[test]
    fn test_segment_times_always_sum_to_the_lap_duration() {
        // A ramped speed (non-linear distance): the exact split times are awkward, but
        // the conservation invariant must hold and no segment may be negative.
        let speed: Vec<(f64, f64)> = (0..=12).map(|i| (i as f64 * 500.0, i as f64)).collect();
        let lap = lap_with_speed(3, 0.0, 6000.0, &speed);

        let times = segment_times(&lap, 5);

        assert_eq!(times.len(), 5);
        assert!(times.iter().all(|&t| t >= 0.0));
        assert!((times.iter().sum::<f64>() - 6.0).abs() < 1e-9);
    }

    #[test]
    fn test_no_speed_channel_falls_back_to_equal_time_segments() {
        // A lap with only a non-speed channel has no odometer → equal-time cuts.
        let lap = Lap::new(
            0,
            0.0,
            8000.0,
            vec![LapChannel::new("AX", vec![(0.0, 1.0), (8000.0, 2.0)])],
        );

        let times = segment_times(&lap, 4);

        assert_eq!(times, vec![2.0, 2.0, 2.0, 2.0]);
    }

    #[test]
    fn test_zero_length_distance_axis_falls_back_to_equal_time() {
        // Speed pinned at 0 → the odometer never advances (total distance 0), so the
        // distance cut is undefined and we fall back to equal-time.
        let speed = [(0.0, 0.0), (3000.0, 0.0), (6000.0, 0.0)];
        let lap = lap_with_speed(0, 0.0, 6000.0, &speed);

        let times = segment_times(&lap, 3);

        assert_eq!(times, vec![2.0, 2.0, 2.0]);
    }

    #[test]
    fn test_zero_splits_yields_a_single_whole_lap_segment() {
        let speed: Vec<(f64, f64)> = (0..=5).map(|i| (i as f64 * 1000.0, 10.0)).collect();
        let lap = lap_with_speed(0, 0.0, 5000.0, &speed);

        let times = segment_times(&lap, 0);

        assert_eq!(times, vec![5.0], "a 0 request is one whole-lap segment");
    }

    #[test]
    fn test_lap_offset_from_session_start_is_rebased() {
        // A lap that starts at t = 100 s: the times are rebased to the lap start, so
        // the segments still sum to the duration, not the absolute end time.
        let speed: Vec<(f64, f64)> = (0..=4)
            .map(|i| (100_000.0 + i as f64 * 1000.0, 10.0))
            .collect();
        let lap = lap_with_speed(7, 100_000.0, 104_000.0, &speed);

        let times = segment_times(&lap, 2);

        assert_eq!(times, vec![2.0, 2.0]);
    }
}
