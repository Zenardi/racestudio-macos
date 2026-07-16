//! Analysis-crate integration tests, compiled as a single binary.
//!
//! Lap segmentation & alignment (3.1), delta-t (3.2), resampling (3.3), channel
//! statistics (3.4), and the math-channel expression engine (3.5) live in one
//! test binary on purpose: each links the whole `racestudio-analysis` library,
//! so keeping them as separate binaries would emit uncovered dead copies of the
//! modules a given binary doesn't exercise (e.g. `laps` in the resample tests),
//! which the coverage tool counts against the crate. One binary keeps every
//! module exercised where it is compiled.

#[path = "analysis/support/mod.rs"]
mod support;

#[path = "analysis/delta.rs"]
mod delta;
#[path = "analysis/expr.rs"]
mod expr;
#[path = "analysis/laps.rs"]
mod laps;
#[path = "analysis/resample.rs"]
mod resample;
#[path = "analysis/stats.rs"]
mod stats;
