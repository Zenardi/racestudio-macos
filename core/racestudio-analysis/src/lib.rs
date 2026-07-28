//! Telemetry analysis engine for RaceStudio (channels, math, resampling).
//!
//! Milestone M3 builds the analysis surface on top of the decoded, immutable
//! [`Session`](racestudio_decode::Session) model (1.6). The first layer (issue
//! 3.1) is **lap segmentation & alignment**: [`segment_laps`] splits a session
//! into per-lap [`Lap`] views, [`distance_axis`] integrates a speed channel into
//! a cumulative distance axis, and [`align_by_time`] / [`align_by_distance`] pair
//! two laps' samples on a shared time or distance axis for overlay comparison.
//!
//! The second layer (issue 3.2) is **delta-t** ([`delta_t`]): the cumulative
//! time variance between a reference and a comparison lap as a function of
//! distance — the core two-lap overlay metric.
//!
//! The third layer (issue 3.3) is **resampling** ([`resample_uniform`],
//! [`to_distance_grid`]): placing an irregular series onto a uniform-rate or a
//! supplied distance grid with linear interpolation, so overlay, delta-t, and
//! FFT can share a common axis.
//!
//! The fourth layer (issue 3.4) is **channel statistics** ([`channel_stats`],
//! [`stats_over_range`], [`stats_per_lap`]): Welford-based min / max / mean /
//! std / RMS / range over a whole channel, a `[t0, t1)` window, or each lap.
//!
//! The fifth layer (issue 3.5) is the **math-channel expression engine**
//! ([`mod@expr`]): a small `tokenize` → `parse` → `eval_scalar` / `eval_series`
//! pipeline for user-defined channels, with its own typed [`ExprError`](expr::ExprError).
//!
//! The sixth layer (issue 3.6) is **derived channels** ([`heading`],
//! [`yaw_rate`], [`longitudinal_accel_g`], [`lateral_accel_g`],
//! [`gear_estimate`]): GPS bearing, yaw rate, acceleration in g, and a gear
//! estimate, matching XRKConverter/libxrk's computed channels.
//!
//! The seventh layer (issue 3.7) is the **windowed FFT** ([`spectrum`],
//! [`apply_window`], [`Window`]): a `rustfft`-backed single-sided amplitude
//! [`Spectrum`] with per-window coherent-gain correction and `k·fs/N` scaling.
//!
//! The eighth layer (issue 9.2) is **track detection** ([`match_track`],
//! [`auto_splits`], [`bundled_tracks`]): identifying the circuit from a GPS trace
//! against a bundled, versioned [`TrackDb`] of start/finish + sector [`Gate`]s,
//! then reading the auto start/finish and sector splits off the matched track's
//! geometry instead of from hand-placed beacons.
//!
//! Every fallible entry point returns [`Result`] and never panics on caller
//! input — the [`AnalysisError`] enum for the numeric layers, and the dedicated
//! [`ExprError`](expr::ExprError) for the expression engine.

// Analysis is a pure, panic-free library (mirrors the decode crate, issue 1.6):
// forbid unwrap/expect/panic on shipped code; test code is exempt.
#![cfg_attr(
    not(test),
    deny(clippy::unwrap_used, clippy::expect_used, clippy::panic)
)]

pub mod decimate;
pub mod delta;
pub mod derived;
pub mod error;
pub mod expr;
pub mod fft;
pub mod laps;
mod math;
pub mod resample;
pub mod splits;
pub mod stats;
pub mod track;

pub use decimate::min_max_decimate;
pub use delta::delta_t;
pub use derived::{
    gear_estimate, heading, lateral_accel_g, longitudinal_accel_g, yaw_rate, GearRatios,
};
pub use error::AnalysisError;
pub use fft::{apply_window, spectrum, Spectrum, Window};
pub use laps::{
    align_by_distance, align_by_time, cumulative_distance, distance_axis, segment_laps, Alignment,
    Lap, LapAxis, LapChannel,
};
pub use resample::{resample_uniform, resample_uniform_max_gap, to_distance_grid};
pub use splits::segment_times;
pub use stats::{channel_stats, stats_over_range, stats_per_lap, Stats};
pub use track::{
    auto_splits, auto_splits_within, bundled_tracks, match_track, match_track_within, AutoSplits,
    Gate, LatLon, TrackDb, TrackDef, MATCH_TOLERANCE_M, TRACK_DB_VERSION,
};
