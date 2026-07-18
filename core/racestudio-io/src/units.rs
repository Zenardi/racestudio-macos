//! Unit normalization for CSV import (issue 5.2) — the strict inverse of the
//! 5.1 writer's forward scaling.
//!
//! The AiM CSV writer stores a couple of channels in km/h (scaled ×3.6 from the
//! decoded m/s). Import undoes that so downstream analysis matches decoded
//! `.xrk`: a `km/h` value on a speed-like channel is divided by 3.6 and its unit
//! relabelled `m/s`; every other channel passes through unchanged.

/// m/s ↔ km/h — must match `csv_export::MS_TO_KMH`.
const MS_TO_KMH: f64 = 3.6;

/// The output channel names the 5.1 writer stores in km/h (scaled from m/s):
/// `GPS Speed` and `GPS SpdAccuracy`. Import reverses the scale for these.
const KMH_CHANNELS: &[&str] = &["GPS Speed", "GPS SpdAccuracy"];

/// Whether `(name, unit)` is a km/h speed-like channel that import rescales.
fn is_scaled_speed(name: &str, unit: &str) -> bool {
    KMH_CHANNELS.contains(&name) && unit.eq_ignore_ascii_case("km/h")
}

/// Normalize a value for `(name, unit)`: a km/h speed-like channel is converted
/// to m/s (÷3.6); everything else is returned unchanged. `NaN` passes through.
#[must_use]
pub fn normalize_unit(name: &str, unit: &str, value: f64) -> f64 {
    if is_scaled_speed(name, unit) {
        value / MS_TO_KMH
    } else {
        value
    }
}

/// The unit label after normalization: `m/s` for a km/h speed-like channel, else
/// the original unit unchanged.
#[must_use]
pub fn normalized_unit(name: &str, unit: &str) -> String {
    if is_scaled_speed(name, unit) {
        "m/s".to_string()
    } else {
        unit.to_string()
    }
}
