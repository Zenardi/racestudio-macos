//! Synthesized `GPS Heading` (issue 5.1).
//!
//! The `.xrk` carries no GPS heading channel, but RaceChrono needs one to
//! resolve acceleration direction. This computes the great-circle bearing
//! between consecutive fixes, holding the last valid heading across
//! near-stationary segments — a direct port of `xrk2csv.compute_heading`.
//!
//! This deliberately differs from `racestudio_analysis::derived::heading`, which
//! derives a bearing from per-fix ECEF velocity (unavailable at export time). The
//! export must reproduce `xrk2csv`'s lat/long bearing with its stationary-mask +
//! forward/back-fill contract, so the two are not interchangeable.

/// Earth radius (metres) used for the equirectangular stationary-mask distance.
const EARTH_RADIUS_M: f64 = 6_371_000.0;

/// Segments shorter than this (metres) are treated as stationary — their bearing
/// is undefined and held at the last valid heading.
const STATIONARY_M: f64 = 0.05;

/// Great-circle bearing (degrees, `0..360`) from each fix to the next, aligned
/// to `lat`/`lon` (which must be equal-length and index-aligned).
///
/// Near-stationary segments (displacement below ~5 cm) have an undefined bearing
/// and are held at the last valid heading (forward-fill, then back-fill any
/// leading gap); the result is never `NaN` (holes collapse to `0`). Fewer than
/// two fixes yields all-zero.
#[must_use]
pub fn compute_heading(lat: &[f64], lon: &[f64]) -> Vec<f64> {
    let n = lat.len().min(lon.len());
    let mut heading = vec![0.0_f64; n];
    if n < 2 {
        return heading;
    }
    let mean_lat = nanmean(&lat[..n]).to_radians();

    // Bearing for each segment `i → i+1`, masked to NaN when near-stationary.
    for i in 0..n - 1 {
        let lat1 = lat[i].to_radians();
        let lat2 = lat[i + 1].to_radians();
        let dlon = (lon[i + 1] - lon[i]).to_radians();
        let y = dlon.sin() * lat2.cos();
        let x = lat1.cos() * lat2.sin() - lat1.sin() * lat2.cos() * dlon.cos();
        let bearing = (y.atan2(x).to_degrees() + 360.0) % 360.0;

        // Local displacement via equirectangular deltas.
        let dx = (lon[i + 1] - lon[i]).to_radians() * mean_lat.cos() * EARTH_RADIUS_M;
        let dy = (lat[i + 1] - lat[i]).to_radians() * EARTH_RADIUS_M;
        heading[i] = if dx.hypot(dy) < STATIONARY_M {
            f64::NAN
        } else {
            bearing
        };
    }
    // The final fix has no "next"; hold it at the previous segment's bearing.
    heading[n - 1] = heading[n - 2];

    forward_fill(&mut heading);
    for h in &mut heading {
        if h.is_nan() {
            *h = 0.0; // any remaining hole (all-stationary track) collapses to 0
        }
    }
    heading
}

/// Mean of the finite values, ignoring `NaN` (0 when none are finite).
fn nanmean(values: &[f64]) -> f64 {
    let mut sum = 0.0;
    let mut count = 0usize;
    for &v in values {
        if v.is_finite() {
            sum += v;
            count += 1;
        }
    }
    if count == 0 {
        0.0
    } else {
        sum / count as f64
    }
}

/// In-place forward-fill of `NaN`s (carry the last valid value forward), then
/// back-fill any leading `NaN`s from the first valid value.
fn forward_fill(a: &mut [f64]) {
    let mut last = f64::NAN;
    for x in a.iter_mut() {
        if x.is_nan() {
            *x = last;
        } else {
            last = *x;
        }
    }
    let mut first = f64::NAN;
    for x in a.iter_mut().rev() {
        if x.is_nan() {
            *x = first;
        } else {
            first = *x;
        }
    }
}
