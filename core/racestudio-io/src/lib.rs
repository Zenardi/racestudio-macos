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
//! [`write_aim_csv`] is the export entry point; [`read_csv`] is its inverse (5.2)
//! — it parses a generic or AiM RS2Analysis CSV back into a
//! [`Session`](racestudio_decode::Session), reconstructing channels, metadata,
//! and laps (from `Beacon Markers`) and normalizing km/h speed back to m/s. The
//! [`compute_heading`], [`quote_all`], [`fmt_seg_time`], [`uniform_grid_ms`],
//! [`normalize_unit`], and [`laps_from_beacons`] building blocks are public so
//! they can be tested and reused directly. The library index (5.3), project
//! files (5.4), and any SwiftUI dialog are out of scope here.
//!
//! Every entry point returns [`Result`] — [`IoError`] for export, [`ImportError`]
//! for import — and never panics on caller input.

// The writer is a pure, panic-free library (mirrors the decode/analysis crates):
// forbid unwrap/expect/panic on shipped code; test code is exempt.
#![cfg_attr(
    not(test),
    deny(clippy::unwrap_used, clippy::expect_used, clippy::panic)
)]

pub mod csv_export;
pub mod csv_import;
pub mod error;
pub mod grid;
pub mod heading;
pub mod laps_from_beacons;
pub mod quoting;
pub mod units;

pub use csv_export::{write_aim_csv, ExportOptions, ExportReport};
pub use csv_import::read_csv;
pub use error::{ImportError, IoError};
pub use grid::uniform_grid_ms;
pub use heading::compute_heading;
pub use laps_from_beacons::laps_from_beacons;
pub use quoting::{fmt_seg_time, quote_all};
pub use units::{normalize_unit, normalized_unit};
