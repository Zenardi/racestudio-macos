//! Delta-t / time variance (issue 3.2).
//!
//! [`delta_t`] is the core two-lap overlay metric: at every point along the
//! track, how much time the comparison lap has gained or lost versus a reference
//! lap. It returns the cumulative time difference as a function of distance,
//! `dt(d) = t_C(d) − t_R(d)` — **positive means the comparison lap is slower**
//! (losing time) at that distance, negative means faster.
//!
//! Each lap's distance axis comes from integrating its GPS speed (3.1); time as a
//! function of distance is then inverted per lap and subtracted on the reference
//! lap's distance grid. The general resampler (3.3) will replace the local
//! interpolation; the predictive/live "gap to reference" and any rendering are
//! out of scope.

use crate::error::AnalysisError;
use crate::laps::{Lap, SPEED_CHANNEL};
use crate::math::{cumulative_trapezoid, interp, is_monotonic};

/// Cumulative time variance of `comparison` versus `reference` as a function of
/// distance: a series of `(distance, dt_seconds)` on the reference lap's distance
/// grid, where `dt = t_comparison(distance) − t_reference(distance)`.
///
/// `dt` at distance `0` is `0` by construction; positive `dt` means the
/// comparison lap is slower at that distance (see the module docs).
///
/// # Errors
/// - [`AnalysisError::EmptyLap`] if either lap has no GPS speed samples to derive
///   a distance axis from.
/// - [`AnalysisError::DistanceNotMonotonic`] if either lap's distance axis moves
///   backward (e.g. a spurious negative speed), so time cannot be inverted.
pub fn delta_t(reference: &Lap, comparison: &Lap) -> Result<Vec<(f64, f64)>, AnalysisError> {
    let grid = validated_distance(reference)?;
    let comparison_distance = validated_distance(comparison)?;

    // The two laps rarely integrate to the exact same total distance, so the
    // comparison is sampled at the *proportional* track position: reference grid
    // distance `d` maps to `d * (D_comparison / D_reference)`. This aligns both
    // the start line (0 → 0) and the finish line (D_ref → D_cmp), so delta-t is
    // 0 at distance 0 and equals the lap-time difference at the end.
    let d_reference = grid.last().copied().unwrap_or(0.0);
    let d_comparison = comparison_distance.last().copied().unwrap_or(0.0);
    let scale = if d_reference > 0.0 {
        d_comparison / d_reference
    } else {
        0.0
    };
    let comparison_grid: Vec<f64> = grid.iter().map(|&d| d * scale).collect();

    let t_reference = time_at_distance(reference, &grid);
    let t_comparison = time_at_distance(comparison, &comparison_grid);

    Ok(grid
        .into_iter()
        .zip(t_reference.into_iter().zip(t_comparison))
        .map(|(distance, (t_ref, t_cmp))| (distance, t_cmp - t_ref))
        .collect())
}

/// The time (seconds from lap start) at which `lap` reaches each distance in
/// `grid`, by inverting its distance→time relation with linear interpolation.
///
/// Returns all-zero times for a lap with no usable distance axis; callers
/// (`delta_t`) validate that up front via [`validated_distance`].
fn time_at_distance(lap: &Lap, grid: &[f64]) -> Vec<f64> {
    let (distance, time) = distance_time(lap);
    grid.iter().map(|&d| interp(&distance, &time, d)).collect()
}

/// A lap's `(distance, time_seconds)` relation along its GPS speed samples:
/// distance is the faithful (unclamped) trapezoidal integral of speed, time is
/// each sample's timecode re-based to the **first sample** (distance `0`).
///
/// Re-basing to the first sample — rather than the beacon lap start, which can
/// precede the first GPS fix by tens of milliseconds — is what makes `delta_t` at
/// distance `0` exactly `0`: both laps' clocks read zero at their start line.
fn distance_time(lap: &Lap) -> (Vec<f64>, Vec<f64>) {
    let Some(speed) = lap.channel(SPEED_CHANNEL) else {
        return (Vec::new(), Vec::new());
    };
    let samples = speed.samples();
    let distance = cumulative_trapezoid(samples, false);
    let origin = samples.first().map_or(0.0, |&(t, _)| t);
    let time = samples
        .iter()
        .map(|&(t, _)| (t - origin) / 1000.0)
        .collect();
    (distance, time)
}

/// A lap's distance axis, validated: non-empty ([`AnalysisError::EmptyLap`]) and
/// monotonically non-decreasing ([`AnalysisError::DistanceNotMonotonic`]).
fn validated_distance(lap: &Lap) -> Result<Vec<f64>, AnalysisError> {
    let (distance, _time) = distance_time(lap);
    if distance.is_empty() {
        return Err(AnalysisError::EmptyLap);
    }
    if !is_monotonic(&distance) {
        return Err(AnalysisError::DistanceNotMonotonic);
    }
    Ok(distance)
}
