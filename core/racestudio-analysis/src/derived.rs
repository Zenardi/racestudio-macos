//! Derived channels (issue 3.6): GPS heading, longitudinal/lateral acceleration,
//! and a gear estimate — quantities computed from logged channels rather than
//! recorded directly.
//!
//! The GPS derivations match **XRKConverter / libxrk** exactly (the golden
//! oracle, `aim_xrk.pyx` / `gps.py`), so overlays agree with the reference tool:
//!
//! - [`heading`] — bearing from the ECEF velocity via the ENU (East-North-Up)
//!   transform, `atan2(V_east, V_north)·180/π` (0° = North, increasing
//!   clockwise/East).
//! - [`yaw_rate`] — `d(heading)/dt` with ±180° wrap-around correction.
//! - [`longitudinal_accel_g`] — `d(speed)/dt / 9.81` (g).
//! - [`lateral_accel_g`] — `speed · yaw_rate · π/180 / 9.81` (g).
//!
//! [`gear_estimate`] derives a gear from the rpm/speed ratio by nearest-centroid
//! classification, returning `0` (neutral) when stopped.
//!
//! Every function is total and panic-free: a non-positive `dt` is guarded (the
//! derivative becomes `0` rather than `±∞`/`NaN`, per libxrk), fewer than two
//! samples yields the zero-initialised or empty result, and mismatched input
//! lengths are truncated to the shortest.

use std::f64::consts::PI;

/// Standard gravity (m/s²) used to express acceleration in g, matching libxrk.
const GRAVITY_MS2: f64 = 9.81;

/// GPS heading in degrees (0° = North, increasing clockwise toward East) for each
/// fix, from its geodetic position (`lat`/`lon`, degrees) and ECEF velocity
/// (`vel_ecef` = `(vx, vy, vz)`; any consistent unit — heading is scale-free).
///
/// This reproduces XRKConverter / libxrk's computed bearing exactly
/// (`gps.ecef_velocity_to_enu` + `atan2(V_east, V_north)·180/π` in
/// `aim_xrk.pyx`), so headings and the channels derived from them agree with the
/// reference tool. The output length is the shortest of the three inputs.
#[must_use]
pub fn heading(lat: &[f64], lon: &[f64], vel_ecef: &[(f64, f64, f64)]) -> Vec<f64> {
    let n = lat.len().min(lon.len()).min(vel_ecef.len());
    (0..n)
        .map(|i| {
            let (vx, vy, vz) = vel_ecef[i];
            enu_heading_deg(vx, vy, vz, lat[i], lon[i])
        })
        .collect()
}

/// Yaw rate (deg/s) as `d(heading)/dt` with ±180° wrap-around correction: a step
/// above +180° folds by −360°, below −180° by +360°, so crossing the ±180° seam
/// is a small turn rather than a ~360° spike. The first sample is `0` (no
/// predecessor); the output length is the shorter of `heading` and `t`.
///
/// `t` is in milliseconds. A non-positive `dt` is guarded to `+∞`, so the rate
/// there is `0` — matching libxrk's `np.where(dt > 0, dt, inf)` policy.
#[must_use]
pub fn yaw_rate(heading: &[f64], t: &[f64]) -> Vec<f64> {
    let n = heading.len().min(t.len());
    let mut out = vec![0.0; n];
    for i in 1..n {
        out[i] = wrap_180(heading[i] - heading[i - 1]) / guarded_dt(t[i - 1], t[i]);
    }
    out
}

/// Longitudinal (inline) acceleration in g: `d(speed)/dt / 9.81`. `speed` is in
/// m/s and `t` in milliseconds. The first sample is `0`; a non-positive `dt` is
/// guarded (yielding `0`). Output length is the shorter of `speed` and `t`.
#[must_use]
pub fn longitudinal_accel_g(speed: &[f64], t: &[f64]) -> Vec<f64> {
    let n = speed.len().min(t.len());
    let mut out = vec![0.0; n];
    for i in 1..n {
        out[i] = (speed[i] - speed[i - 1]) / guarded_dt(t[i - 1], t[i]) / GRAVITY_MS2;
    }
    out
}

/// Lateral acceleration in g: `speed · yaw_rate · π/180 / 9.81`, where the yaw
/// rate is computed from `heading` and `t` (see [`yaw_rate`]). `speed` is in m/s
/// and `t` in milliseconds. Output length is the shortest of the inputs.
#[must_use]
pub fn lateral_accel_g(speed: &[f64], heading: &[f64], t: &[f64]) -> Vec<f64> {
    let yaw = yaw_rate(heading, t);
    let n = speed.len().min(yaw.len());
    (0..n)
        .map(|i| speed[i] * yaw[i] * (PI / 180.0) / GRAVITY_MS2)
        .collect()
}

/// Per-gear rpm/speed centroid ratios for [`gear_estimate`].
///
/// A gear is the ratio `rpm / speed` (roughly constant within a gear). Ratios are
/// given highest-first is not required — gear `g` (1-based) is `ratios[g-1]`.
/// Below `min_speed` (m/s) the vehicle is treated as stopped (neutral, `0`).
#[derive(Debug, Clone)]
pub struct GearRatios {
    ratios: Vec<f64>,
    min_speed: f64,
}

impl GearRatios {
    /// Build gear ratios (gear `g` is `ratios[g-1]`) with the default stopped
    /// threshold of `0.5` m/s.
    #[must_use]
    pub fn new(ratios: impl Into<Vec<f64>>) -> Self {
        Self {
            ratios: ratios.into(),
            min_speed: 0.5,
        }
    }

    /// Set the speed (m/s) below which the vehicle counts as stopped (neutral).
    #[must_use]
    pub fn with_min_speed(mut self, min_speed: f64) -> Self {
        self.min_speed = min_speed;
        self
    }

    /// The gear (1-based) whose centroid is nearest `rpm / speed`, or `0`
    /// (neutral) when stopped or when no ratios are configured.
    fn classify(&self, rpm: f64, speed: f64) -> u8 {
        if speed <= self.min_speed || self.ratios.is_empty() {
            return 0;
        }
        let ratio = rpm / speed;
        let mut best = 0usize;
        let mut best_distance = f64::INFINITY;
        for (index, &centroid) in self.ratios.iter().enumerate() {
            let distance = (ratio - centroid).abs();
            if distance < best_distance {
                best_distance = distance;
                best = index;
            }
        }
        u8::try_from(best + 1).unwrap_or(u8::MAX)
    }
}

/// Estimated gear per sample from the rpm/speed ratio (nearest [`GearRatios`]
/// centroid), `0` (neutral) when stopped. Output length is the shorter of `rpm`
/// and `speed`. Nearest-centroid classification is inherently stable under noise.
#[must_use]
pub fn gear_estimate(rpm: &[f64], speed: &[f64], ratios: &GearRatios) -> Vec<u8> {
    let n = rpm.len().min(speed.len());
    (0..n).map(|i| ratios.classify(rpm[i], speed[i])).collect()
}

// --------------------------------------------------------------------------- //
// Internals
// --------------------------------------------------------------------------- //

/// Heading (degrees, clockwise from North) from an ECEF velocity via the ENU
/// transform at the given latitude/longitude (degrees) — libxrk's
/// `ecef_velocity_to_enu` followed by `atan2(V_east, V_north)`.
fn enu_heading_deg(vx: f64, vy: f64, vz: f64, lat_deg: f64, lon_deg: f64) -> f64 {
    let (lat, lon) = (lat_deg * PI / 180.0, lon_deg * PI / 180.0);
    let (sin_lat, cos_lat) = (lat.sin(), lat.cos());
    let (sin_lon, cos_lon) = (lon.sin(), lon.cos());
    let v_east = -sin_lon * vx + cos_lon * vy;
    let v_north = -sin_lat * cos_lon * vx - sin_lat * sin_lon * vy + cos_lat * vz;
    v_east.atan2(v_north) * (180.0 / PI)
}

/// Fold a heading difference into `[−180, 180]` so a ±180° seam crossing is a
/// small turn, not a ~360° spike (matching libxrk: `> 180 → −360`,
/// `< −180 → +360`; the endpoints are left unchanged).
fn wrap_180(mut delta: f64) -> f64 {
    if delta > 180.0 {
        delta -= 360.0;
    } else if delta < -180.0 {
        delta += 360.0;
    }
    delta
}

/// Time step in seconds from consecutive millisecond timecodes, guarded to `+∞`
/// when non-positive so the derivative that divides by it becomes `0` (libxrk's
/// `np.where(dt > 0, dt, inf)` policy) rather than `±∞`/`NaN`.
fn guarded_dt(t_prev: f64, t: f64) -> f64 {
    let dt = (t - t_prev) / 1000.0;
    if dt > 0.0 {
        dt
    } else {
        f64::INFINITY
    }
}
