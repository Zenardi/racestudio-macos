//! The error types for the CSV export (5.1) and import (5.2) paths.

use std::fmt;

/// A failure while writing an AiM CSV.
///
/// Every fallible path in the writer funnels through this enum; no input ever
/// panics.
#[derive(Debug)]
pub enum IoError {
    /// The session carried no channels at all (nothing to export).
    NoChannels,
    /// The requested sample rate was not a positive, finite number of Hz.
    InvalidRate(f64),
    /// The underlying writer (`std::io::Write`) failed.
    Write(std::io::Error),
}

impl fmt::Display for IoError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            IoError::NoChannels => write!(f, "no channels found in session"),
            IoError::InvalidRate(rate) => {
                write!(
                    f,
                    "sample rate must be a positive, finite value (got {rate})"
                )
            }
            IoError::Write(err) => write!(f, "failed to write CSV: {err}"),
        }
    }
}

impl std::error::Error for IoError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            IoError::Write(err) => Some(err),
            _ => None,
        }
    }
}

impl From<std::io::Error> for IoError {
    fn from(err: std::io::Error) -> Self {
        IoError::Write(err)
    }
}

/// A failure while importing a CSV back into a [`Session`](racestudio_decode::Session)
/// (issue 5.2).
///
/// Every fallible path in [`read_csv`](crate::read_csv) funnels through this
/// enum; no input ever panics.
#[derive(Debug, PartialEq)]
pub enum ImportError {
    /// The input had no rows (or only blank lines).
    Empty,
    /// No usable header (name) row was found.
    NoHeader,
    /// A data row's field count did not match the header's.
    RaggedRow {
        /// 1-based line number of the offending row.
        line: usize,
        /// Number of columns the header declared.
        expected: usize,
        /// Number of fields the row actually had.
        found: usize,
    },
    /// A cell that should have been numeric could not be parsed.
    BadNumber {
        /// 1-based line number of the offending row.
        line: usize,
        /// The text that failed to parse.
        text: String,
    },
    /// The time column was not non-decreasing.
    NonMonotonicTime {
        /// 1-based line number where time went backward.
        line: usize,
    },
    /// The CSV layout matched neither the AiM block nor a generic name/data shape.
    UnknownDialect,
}

impl fmt::Display for ImportError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ImportError::Empty => write!(f, "the CSV input was empty"),
            ImportError::NoHeader => write!(f, "no header (name) row found"),
            ImportError::RaggedRow {
                line,
                expected,
                found,
            } => write!(
                f,
                "ragged row at line {line}: expected {expected} fields, found {found}"
            ),
            ImportError::BadNumber { line, text } => {
                write!(f, "non-numeric value {text:?} at line {line}")
            }
            ImportError::NonMonotonicTime { line } => {
                write!(f, "time column decreased at line {line}")
            }
            ImportError::UnknownDialect => write!(f, "unrecognized CSV layout"),
        }
    }
}

impl std::error::Error for ImportError {}
