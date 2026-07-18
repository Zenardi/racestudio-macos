//! The single error type for the export/import writers (issue 5.1).

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
