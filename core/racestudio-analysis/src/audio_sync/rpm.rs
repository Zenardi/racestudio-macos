//! The session side of the match (issue 9.8): the `RPM` channel as `ln rpm` on a
//! uniform time grid, with stalls, glitches and logging gaps masked out.

use crate::resample::resample_uniform_max_gap;

/// Readings below this fraction of the session's top RPM are a stalled engine
/// or a sensor glitch, never a running engine's pitch, so they are masked.
const RPM_FLOOR_FRACTION: f64 = 0.1;

/// Logging gaps wider than this (seconds) are holes, not interpolated across.
const MAX_GAP_S: f64 = 1.0;

/// Below this standard deviation of `ln rpm` (≈ 1 %) the trace is flat — a
/// constant RPM has no shape for the audio to line up with.
const FLAT_LOG_STD: f64 = 0.01;

/// The timing weight of a steady instant (`d ln rpm/dt` in 1/s): small against
/// the 0.3–1 /s of a braking or accelerating kart, so transitions dominate,
/// but non-zero so a steady stretch still counts.
const SLOPE_FLOOR: f64 = 0.05;

/// Half-width (seconds) of the central difference the RPM slope is taken over.
const SLOPE_HALF_WINDOW_S: f64 = 0.25;

/// The usable readings of `rpm`: finite, positive, above the stall floor, and
/// sorted by time.
pub(crate) fn usable(rpm: &[(f64, f64)]) -> Vec<(f64, f64)> {
    let top = rpm
        .iter()
        .filter(|&&(t, v)| t.is_finite() && v.is_finite())
        .map(|&(_, v)| v)
        .fold(0.0_f64, f64::max);
    let floor = top * RPM_FLOOR_FRACTION;
    let mut points: Vec<(f64, f64)> = rpm
        .iter()
        .copied()
        .filter(|&(t, v)| t.is_finite() && v.is_finite() && v > 0.0 && v >= floor)
        .collect();
    points.sort_by(|a, b| a.0.total_cmp(&b.0));
    points
}

/// The time span (seconds) the usable readings cover.
pub(crate) fn span(points: &[(f64, f64)]) -> f64 {
    match (points.first(), points.last()) {
        (Some(first), Some(last)) => last.0 - first.0,
        _ => 0.0,
    }
}

/// Whether the usable readings are flat (`ln rpm` varies by less than ~1 %).
pub(crate) fn is_flat(points: &[(f64, f64)]) -> bool {
    let n = points.len() as f64;
    if n < 2.0 {
        return true;
    }
    let mean = points.iter().map(|&(_, v)| v.ln()).sum::<f64>() / n;
    let var = points
        .iter()
        .map(|&(_, v)| (v.ln() - mean).powi(2))
        .sum::<f64>()
        / n;
    var.sqrt() < FLAT_LOG_STD
}

/// `ln rpm` on a uniform grid: `values[i]` at `t0 + i·step` seconds, `NaN` in a
/// gap.
#[derive(Debug, Clone)]
pub(crate) struct LogRpm {
    pub t0: f64,
    pub step: f64,
    pub values: Vec<f64>,
}

impl LogRpm {
    /// Resample the usable `points` onto a grid every `step` seconds (3.3's
    /// linear interpolation, gaps wider than a second left as holes).
    pub fn new(points: &[(f64, f64)], step: f64) -> Self {
        let grid = resample_uniform_max_gap(points, 1.0 / step, MAX_GAP_S);
        let t0 = grid.first().map_or(0.0, |&(t, _)| t);
        let values = grid.iter().map(|&(_, v)| v.ln()).collect();
        Self { t0, step, values }
    }

    /// How much the instant `t` says about timing: [`SLOPE_FLOOR`] plus the
    /// magnitude of `d ln rpm / dt` (per second, over ±[`SLOPE_HALF_WINDOW_S`]),
    /// or `None` where there is no RPM.
    ///
    /// Braking and accelerating are where the RPM curve — and the engine note —
    /// move, so they pin the offset; a governed top speed or a steady corner
    /// looks the same a lap later and pins nothing. Weighting by slope lets the
    /// transitions decide, which is what separates the true alignment from the
    /// same lap profile one lap off.
    pub fn weight_at(&self, t: f64) -> Option<f64> {
        let here = self.at(t)?;
        let before = self.at(t - SLOPE_HALF_WINDOW_S).unwrap_or(here);
        let after = self.at(t + SLOPE_HALF_WINDOW_S).unwrap_or(here);
        Some(SLOPE_FLOOR + ((after - before) / (2.0 * SLOPE_HALF_WINDOW_S)).abs())
    }

    /// `ln rpm` at time `t` by linear interpolation, or `None` outside the grid
    /// or in a gap.
    pub fn at(&self, t: f64) -> Option<f64> {
        let pos = (t - self.t0) / self.step;
        if pos.is_nan() || pos < 0.0 {
            return None;
        }
        let i = pos.floor() as usize;
        let a = *self.values.get(i)?;
        let w = pos - i as f64;
        let value = if w == 0.0 {
            a
        } else {
            a + (*self.values.get(i + 1)? - a) * w
        };
        value.is_finite().then_some(value)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn usable_drops_glitches_stalls_and_sorts() {
        let raw = [
            (2.0, 5000.0),
            (0.0, 4000.0),
            (1.0, f64::NAN),
            (f64::NAN, 4000.0),
            (3.0, 100.0), // below 10 % of the 5 000 top: a stall reading
            (4.0, -1.0),
        ];
        assert_eq!(usable(&raw), vec![(0.0, 4000.0), (2.0, 5000.0)]);
    }

    #[test]
    fn span_and_flatness() {
        assert_eq!(span(&[]), 0.0);
        assert_eq!(span(&[(1.0, 3000.0), (4.5, 3000.0)]), 3.5);
        assert!(is_flat(&[(0.0, 3000.0)]));
        assert!(is_flat(&[(0.0, 3000.0), (1.0, 3001.0)]));
        assert!(!is_flat(&[(0.0, 3000.0), (1.0, 4000.0)]));
    }

    #[test]
    fn log_rpm_interpolates_and_masks_gaps() {
        let rpm = LogRpm::new(&[(10.0, 1000.0), (10.5, 2000.0), (14.0, 2000.0)], 0.25);
        assert_eq!(rpm.t0, 10.0);
        assert!((rpm.at(10.0).unwrap() - 1000.0_f64.ln()).abs() < 1e-12);
        let mid = rpm.at(10.125).unwrap();
        assert!(mid > 1000.0_f64.ln() && mid < 2000.0_f64.ln());
        assert_eq!(rpm.at(12.0), None, "inside the 3.5 s logging gap");
        assert_eq!(rpm.at(9.0), None, "before the trace");
        assert_eq!(rpm.at(20.0), None, "after the trace");
        assert_eq!(rpm.at(f64::NAN), None);
    }

    #[test]
    fn weight_grows_with_the_rpm_slope() {
        // ln rpm rising at 0.5 /s, then flat.
        let ramp: Vec<(f64, f64)> = (0..=40)
            .map(|i| {
                let t = f64::from(i) * 0.1;
                (t, (2.0 + 0.5 * t.min(2.0)).exp())
            })
            .collect();
        let rpm = LogRpm::new(&ramp, 0.05);
        let rising = rpm.weight_at(1.0).unwrap();
        let steady = rpm.weight_at(3.5).unwrap();
        assert!(
            (rising - (SLOPE_FLOOR + 0.5)).abs() < 1e-3,
            "rising {rising}"
        );
        assert!((steady - SLOPE_FLOOR).abs() < 1e-9, "steady {steady}");
        assert_eq!(rpm.weight_at(10.0), None);
        // At the trace's edge the missing side counts as flat.
        assert!(rpm.weight_at(0.0).unwrap() > SLOPE_FLOOR);
    }
}
