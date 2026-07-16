//! Small numeric helpers shared across the analysis engine: linear
//! interpolation (with binary-search bracketing), cumulative trapezoidal
//! integration, and a monotonicity check.
//!
//! These are the local primitives lap segmentation (3.1), delta-t (3.2), and
//! resampling (3.3) build on.

/// Linear interpolation between two points `(x0, y0)`–`(x1, y1)` evaluated at
/// `x`. A zero-width span (`x0 == x1`) returns `y0`.
pub(crate) fn lerp(x0: f64, y0: f64, x1: f64, y1: f64, x: f64) -> f64 {
    let span = x1 - x0;
    if span == 0.0 {
        y0
    } else {
        y0 + (y1 - y0) * (x - x0) / span
    }
}

/// The indices `(lo, hi)` of the samples in ascending `xs` that bracket `x`, by
/// binary search: `xs[lo] <= x <= xs[hi]` with `hi = lo` or `hi = lo + 1`. `x`
/// at or beyond an end clamps to `(0, 0)` / `(last, last)`; empty `xs` yields
/// `(0, 0)` (callers guard emptiness).
pub(crate) fn find_bracket(xs: &[f64], x: f64) -> (usize, usize) {
    let n = xs.len();
    if n == 0 {
        return (0, 0);
    }
    if x <= xs[0] {
        return (0, 0);
    }
    if x >= xs[n - 1] {
        return (n - 1, n - 1);
    }
    // Invariant: xs[lo] <= x < xs[hi]; narrow until the pair is adjacent.
    let (mut lo, mut hi) = (0usize, n - 1);
    while lo + 1 < hi {
        let mid = lo + (hi - lo) / 2;
        if xs[mid] <= x {
            lo = mid;
        } else {
            hi = mid;
        }
    }
    (lo, hi)
}

/// Linear interpolation of `ys` (paired with ascending `xs`) at `x`, clamped to
/// the endpoints. Empty input yields `0.0`; a single point yields that point.
pub(crate) fn interp(xs: &[f64], ys: &[f64], x: f64) -> f64 {
    if xs.is_empty() || ys.is_empty() {
        return 0.0;
    }
    let (lo, hi) = find_bracket(xs, x);
    if lo == hi {
        return ys[lo];
    }
    lerp(xs[lo], ys[lo], xs[hi], ys[hi], x)
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
        assert_eq!(interp(&xs, &ys, 10.0), 100.0, "exact interior knot");
    }

    #[test]
    fn test_lerp_including_zero_span() {
        assert_eq!(lerp(0.0, 0.0, 10.0, 100.0, 2.5), 25.0);
        assert_eq!(lerp(5.0, 42.0, 5.0, 99.0, 5.0), 42.0, "zero span → y0");
    }

    #[test]
    fn test_find_bracket() {
        let xs = [0.0, 10.0, 20.0, 30.0];
        assert_eq!(find_bracket(&xs, -1.0), (0, 0), "clamp below");
        assert_eq!(find_bracket(&xs, 0.0), (0, 0), "at first");
        assert_eq!(find_bracket(&xs, 40.0), (3, 3), "clamp above");
        assert_eq!(find_bracket(&xs, 30.0), (3, 3), "at last");
        assert_eq!(find_bracket(&xs, 5.0), (0, 1));
        assert_eq!(find_bracket(&xs, 25.0), (2, 3));
        assert_eq!(
            find_bracket(&xs, 10.0),
            (1, 2),
            "interior knot brackets [knot, next]"
        );
        assert_eq!(find_bracket(&[], 5.0), (0, 0), "empty");
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
