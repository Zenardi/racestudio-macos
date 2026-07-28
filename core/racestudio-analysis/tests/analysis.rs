//! Analysis-crate integration tests, compiled as a single binary.
//!
//! Lap segmentation & alignment (3.1), delta-t (3.2), resampling (3.3), channel
//! statistics (3.4), the math-channel expression engine (3.5), derived channels
//! (3.6), and the windowed FFT (3.7) live in one test binary on purpose: each
//! links the whole `racestudio-analysis` library, so keeping them as separate
//! binaries would emit uncovered dead copies of the modules a given binary
//! doesn't exercise (e.g. `laps` in the resample tests), which the coverage tool
//! counts against the crate. One binary keeps every module exercised where it is
//! compiled.

#[path = "analysis/support/mod.rs"]
mod support;

#[path = "analysis/decimate.rs"]
mod decimate;
#[path = "analysis/delta.rs"]
mod delta;
#[path = "analysis/derived.rs"]
mod derived;
#[path = "analysis/distance.rs"]
mod distance;
#[path = "analysis/expr.rs"]
mod expr;
#[path = "analysis/fft.rs"]
mod fft;
#[path = "analysis/laps.rs"]
mod laps;
#[path = "analysis/resample.rs"]
mod resample;
#[path = "analysis/stats.rs"]
mod stats;
#[path = "analysis/track.rs"]
mod track;
