//! Resampling & linear interpolation (issue 3.3).
//!
//! Channels are logged at heterogeneous, non-uniform rates, yet overlay (3.1),
//! delta-t (3.2), and FFT (3.7) all need a common grid. This module places an
//! irregular `(t, v)` series onto either:
//!
//! - a **uniform-rate** grid ([`resample_uniform`] / [`resample_uniform_max_gap`]),
//!   at `t_start, t_start + 1/hz, …`, linearly interpolated, or
//! - a supplied **distance** grid ([`to_distance_grid`]).
//!
//! `hz` is expressed in samples per unit of the series' own time axis (so a
//! millisecond timebase takes a per-millisecond rate). Large gaps are not
//! interpolated across — points strictly inside a gap wider than `max_gap` are
//! `NaN` holes rather than a fabricated straight line. Nothing panics on caller
//! input.

use crate::error::AnalysisError;
use crate::math::{find_bracket, interp, is_monotonic, lerp};

/// Guards the output-length floor against float error, so an input that is
/// exactly uniform at `hz` resamples to the same count (idempotence).
const LENGTH_EPSILON: f64 = 1e-9;

/// Resample `series` onto a uniform grid at rate `hz`, interpolating across every
/// gap. Equivalent to [`resample_uniform_max_gap`] with an infinite `max_gap`.
///
/// The output has `floor((t_end − t_start) · hz) + 1` samples at
/// `t_start, t_start + 1/hz, …`; the first and last samples equal the input
/// endpoints exactly, and the time axis is strictly increasing. An empty series
/// or a non-finite / non-positive `hz` yields an empty result.
#[must_use]
pub fn resample_uniform(series: &[(f64, f64)], hz: f64) -> Vec<(f64, f64)> {
    resample_uniform_max_gap(series, hz, f64::INFINITY)
}

/// Like [`resample_uniform`], but a grid point that falls strictly inside an
/// input gap wider than `max_gap` (in time) is emitted as a `NaN` hole instead
/// of being interpolated. Grid points that coincide with an input sample are
/// always real values.
#[must_use]
pub fn resample_uniform_max_gap(series: &[(f64, f64)], hz: f64, max_gap: f64) -> Vec<(f64, f64)> {
    if series.is_empty() || !hz.is_finite() || hz <= 0.0 {
        return Vec::new();
    }
    let times: Vec<f64> = series.iter().map(|&(t, _)| t).collect();
    let t_start = times[0];
    let t_end = times[times.len() - 1];
    let span = t_end - t_start;

    let count = (span * hz + LENGTH_EPSILON).floor().max(0.0) as usize;
    let n = count + 1;

    (0..n)
        .map(|i| {
            // Snap the final grid point to the exact endpoint so both endpoints
            // are preserved even when span·hz is not integral.
            let t = if i == n - 1 {
                t_end
            } else {
                t_start + i as f64 / hz
            };
            (t, sample_at(&times, series, t, max_gap))
        })
        .collect()
}

/// Map `series` onto a supplied distance axis: for each distance in `grid`, the
/// channel value linearly interpolated over `dist` (the distance of each series
/// sample). `dist` is truncated to the series length.
///
/// # Errors
/// [`AnalysisError::DistanceNotMonotonic`] if `dist` decreases anywhere (equal
/// consecutive distances are allowed). An empty series maps every grid point to
/// a `NaN` hole.
pub fn to_distance_grid(
    series: &[(f64, f64)],
    dist: &[f64],
    grid: &[f64],
) -> Result<Vec<f64>, AnalysisError> {
    let n = series.len().min(dist.len());
    if n == 0 {
        return Ok(vec![f64::NAN; grid.len()]);
    }
    let distances = &dist[..n];
    if !is_monotonic(distances) {
        return Err(AnalysisError::DistanceNotMonotonic);
    }
    let values: Vec<f64> = series[..n].iter().map(|&(_, v)| v).collect();
    Ok(grid
        .iter()
        .map(|&g| interp(distances, &values, g))
        .collect())
}

/// The value at time `t`: the sample value at a coinciding or clamped endpoint,
/// a `NaN` hole when `t` lies strictly inside a gap wider than `max_gap`, else
/// the linear interpolation of the two bracketing samples.
///
/// When `lo != hi`, [`find_bracket`] guarantees `times[lo] <= t < times[hi]`, so
/// only the lower knot can coincide with `t`.
fn sample_at(times: &[f64], series: &[(f64, f64)], t: f64, max_gap: f64) -> f64 {
    let (lo, hi) = find_bracket(times, t);
    if lo == hi || t == times[lo] {
        return series[lo].1;
    }
    if times[hi] - times[lo] > max_gap {
        return f64::NAN;
    }
    lerp(times[lo], series[lo].1, times[hi], series[hi].1, t)
}
