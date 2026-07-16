//! Telemetry analysis engine for RaceStudio (channels, math, resampling).
//!
//! Milestone M3 builds the analysis surface on top of the decoded, immutable
//! [`Session`](racestudio_decode::Session) model (1.6). The first layer (issue
//! 3.1) is **lap segmentation & alignment**: [`segment_laps`] splits a session
//! into per-lap [`Lap`] views, [`distance_axis`] integrates a speed channel into
//! a cumulative distance axis, and [`align_by_time`] / [`align_by_distance`] pair
//! two laps' samples on a shared time or distance axis for overlay comparison.
//!
//! Every fallible entry point returns [`Result`] with the single
//! [`AnalysisError`] enum and never panics on caller input.

// Analysis is a pure, panic-free library (mirrors the decode crate, issue 1.6):
// forbid unwrap/expect/panic on shipped code; test code is exempt.
#![cfg_attr(
    not(test),
    deny(clippy::unwrap_used, clippy::expect_used, clippy::panic)
)]

pub mod error;
pub mod laps;

pub use error::AnalysisError;
pub use laps::{
    align_by_distance, align_by_time, distance_axis, segment_laps, Alignment, Lap, LapAxis,
    LapChannel,
};
