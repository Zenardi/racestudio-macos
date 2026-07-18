//! RaceChrono-compatible AiM CSV export for RaceStudio (milestone M5, issue 5.1).
//!
//! This crate reproduces, in pure Rust, the "AiM CSV File" that the sibling
//! XRKConverter `xrk2csv.py` writes and that RaceChrono's AiM RS2Analysis
//! importer consumes. Given a decoded [`Session`](racestudio_decode::Session) it
//! resamples every channel onto a uniform 20 Hz grid, converts GPS speed and
//! velocity-accuracy from m/s to km/h, emits latitude/longitude at 8 decimals,
//! synthesizes a `GPS Heading` column as the great-circle bearing between
//! consecutive fixes, and serializes the header + name/unit + data blocks with
//! AiM's `QUOTE_ALL` quoting and the no-trailing-comma rule RaceChrono requires.
//!
//! [`write_aim_csv`] is the entry point; the [`compute_heading`], [`quote_all`],
//! [`fmt_seg_time`], and [`uniform_grid_ms`] building blocks are public so they
//! can be tested and reused directly. It is the inverse target of 5.2 (CSV
//! import); import, the library index (5.3), and any SwiftUI export dialog are
//! out of scope here.
//!
//! Every entry point returns [`Result`] with the single [`IoError`] enum and
//! never panics on caller input.

// The writer is a pure, panic-free library (mirrors the decode/analysis crates):
// forbid unwrap/expect/panic on shipped code; test code is exempt.
#![cfg_attr(
    not(test),
    deny(clippy::unwrap_used, clippy::expect_used, clippy::panic)
)]

pub mod csv_export;
pub mod error;
pub mod grid;
pub mod heading;
pub mod quoting;

pub use csv_export::{write_aim_csv, ExportOptions, ExportReport};
pub use error::IoError;
pub use grid::uniform_grid_ms;
pub use heading::compute_heading;
pub use quoting::{fmt_seg_time, quote_all};
