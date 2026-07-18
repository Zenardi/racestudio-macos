//! Unit normalization for CSV import (issue 5.2) — the strict inverse of the
//! 5.1 writer's forward scaling.
//!
//! The AiM CSV writer stores a couple of channels in km/h (scaled ×3.6 from the
//! decoded m/s). Import undoes that so downstream analysis matches decoded
//! `.xrk`: a `km/h` value on a speed-like channel is divided by 3.6 and its unit
//! relabelled `m/s`; every other channel passes through unchanged.

// The scale factor and the km/h column set are owned by the writer (5.1), so the
// two paths cannot drift; a consistency test pins the set to `GPS_COLUMN_MAP`.
use crate::csv_export::{KMH_OUTPUT_CHANNELS, MS_TO_KMH};

/// Whether `(name, unit)` is a km/h speed-like channel that import rescales.
fn is_scaled_speed(name: &str, unit: &str) -> bool {
    KMH_OUTPUT_CHANNELS.contains(&name) && unit.eq_ignore_ascii_case("km/h")
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
