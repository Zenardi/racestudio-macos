//! Small numeric helpers shared across the analysis engine: linear
//! interpolation, cumulative trapezoidal integration, and a monotonicity check.
//!
//! These are the local primitives lap segmentation (3.1) and delta-t (3.2) build
//! on until the general resampler (3.3) supersedes them.

/// Linear interpolation of `ys` (paired with ascending `xs`) at `x`, clamped to
/// the endpoints. Empty input yields `0.0`; a single point yields that point.
pub(crate) fn interp(xs: &[f64], ys: &[f64], x: f64) -> f64 {
    match (xs.first(), xs.last()) {
        (None, _) | (_, None) => 0.0,
        (Some(&first), _) if x <= first => ys.first().copied().unwrap_or(0.0),
        (_, Some(&last)) if x >= last => ys.last().copied().unwrap_or(0.0),
        _ => {
            // `first < x < last`, so a bracketing segment `[lo, hi]` exists with
            // `xs[lo] < x <= xs[hi]`; the span is therefore strictly positive.
            let hi = xs.iter().position(|&xi| xi >= x).unwrap_or(xs.len() - 1);
            let lo = hi.saturating_sub(1);
            let (x0, x1) = (xs[lo], xs[hi]);
            let (y0, y1) = (ys[lo], ys[hi]);
            y0 + (y1 - y0) * (x - x0) / (x1 - x0)
        }
    }
}

/// Cumulative trapezoidal integral of a `(timecode_ms, value)` series (time in
/// milliseconds → seconds), one value per sample starting at `0`.
///
/// When `clamp_steps` is set, each step's area is floored at `0` so the result is
/// guaranteed monotonically non-decreasing — used for the lap distance axis (3.1)
/// where speed is non-negative. Left unclamped, the integral is faithful and can
/// decrease, so callers (delta-t, 3.2) can detect a non-monotonic distance.
pub(crate) fn cumulative_trapezoid(samples: &[(f64, f64)], clamp_steps: bool) -> Vec<f64> {
    let mut axis = Vec::with_capacity(samples.len());
    let mut total = 0.0;
    let mut previous: Option<(f64, f64)> = None;
    for &(time_ms, value) in samples {
        if let Some((prev_time, prev_value)) = previous {
            let dt_s = (time_ms - prev_time) / 1000.0;
            let area = 0.5 * (prev_value + value) * dt_s;
            total += if clamp_steps { area.max(0.0) } else { area };
        }
        axis.push(total);
        previous = Some((time_ms, value));
    }
    axis
}

/// Whether `values` never decreases (non-strictly monotonic).
pub(crate) fn is_monotonic(values: &[f64]) -> bool {
    values.windows(2).all(|w| w[1] >= w[0])
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_interp_empty_is_zero() {
        assert_eq!(interp(&[], &[], 5.0), 0.0);
    }

    #[test]
    fn test_interp_single_point() {
        assert_eq!(interp(&[3.0], &[42.0], 0.0), 42.0);
        assert_eq!(interp(&[3.0], &[42.0], 9.0), 42.0);
    }

    #[test]
    fn test_interp_clamps_and_lerps() {
        let xs = [0.0, 10.0, 20.0];
        let ys = [0.0, 100.0, 200.0];
        assert_eq!(interp(&xs, &ys, -5.0), 0.0, "clamped below");
        assert_eq!(interp(&xs, &ys, 25.0), 200.0, "clamped above");
        assert_eq!(interp(&xs, &ys, 5.0), 50.0, "midpoint of first segment");
        assert_eq!(interp(&xs, &ys, 15.0), 150.0, "midpoint of second segment");
    }

    #[test]
    fn test_cumulative_trapezoid_empty_and_single() {
        assert!(cumulative_trapezoid(&[], true).is_empty());
        assert_eq!(cumulative_trapezoid(&[(0.0, 12.0)], false), vec![0.0]);
    }

    #[test]
    fn test_cumulative_trapezoid_constant_rate() {
        // Constant 10 over 1 s → 10; another 1 s → 20 (same clamped or not).
        let samples = [(0.0, 10.0), (1000.0, 10.0), (2000.0, 10.0)];
        assert_eq!(cumulative_trapezoid(&samples, true), vec![0.0, 10.0, 20.0]);
        assert_eq!(cumulative_trapezoid(&samples, false), vec![0.0, 10.0, 20.0]);
    }

    #[test]
    fn test_cumulative_trapezoid_clamp_vs_faithful() {
        // A negative segment: clamped floors the step at 0 (stays flat), the
        // faithful integral moves backward.
        let samples = [(0.0, 0.0), (1000.0, -100.0), (2000.0, 0.0)];
        let clamped = cumulative_trapezoid(&samples, true);
        let faithful = cumulative_trapezoid(&samples, false);
        assert!(is_monotonic(&clamped), "clamped is non-decreasing");
        assert!(!is_monotonic(&faithful), "faithful dips below zero");
    }

    #[test]
    fn test_is_monotonic() {
        assert!(is_monotonic(&[0.0, 1.0, 1.0, 2.0]));
        assert!(is_monotonic(&[]));
        assert!(!is_monotonic(&[0.0, 2.0, 1.0]));
    }
}
