//! The uniform export time grid (issue 5.1).

/// Build the uniform sample grid (integer milliseconds) that the AiM CSV is
/// resampled onto, matching `xrk2csv.py`:
///
/// - `step = 1000 / rate_hz`,
/// - `n = round(duration_ms / step) + 1` samples,
/// - grid time `i` is `round(i · step)` ms (ties to even, like NumPy),
///
/// so the first row is always `0` ms and the grid spans the whole recording.
///
/// A non-positive or non-finite `rate_hz` yields a single `[0]` grid (the
/// caller rejects such a rate up front with [`InvalidRate`](crate::IoError));
/// this stays panic-free regardless.
#[must_use]
pub fn uniform_grid_ms(duration_ms: f64, rate_hz: f64) -> Vec<i64> {
    if !rate_hz.is_finite() || rate_hz <= 0.0 || !duration_ms.is_finite() {
        return vec![0];
    }
    let step = 1000.0 / rate_hz;
    let count = (duration_ms / step).round_ties_even().max(0.0) as i64;
    let n = count + 1;
    (0..n)
        .map(|i| (i as f64 * step).round_ties_even() as i64)
        .collect()
}
