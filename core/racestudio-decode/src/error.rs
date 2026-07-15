//! Decode error types for the `.xrk` decoder.
//!
//! The variant set is intentionally small in 1.2 (container + header). It grows
//! as the channel/GPS/lap decoders land (1.3-1.5) and is unified in 1.6.

use std::fmt;
use std::io;

/// An error decoding an AiM `.xrk` container.
#[derive(Debug)]
#[non_exhaustive]
pub enum DecodeError {
    /// The file could not be read from disk.
    Io(io::Error),
    /// The file does not begin with the `.xrk` header magic (`<h`).
    BadMagic,
    /// The file begins with valid magic but its first header message is cut
    /// short (payload/footer runs past end-of-file).
    TruncatedHeader,
}

impl fmt::Display for DecodeError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            DecodeError::Io(err) => write!(f, "failed to read .xrk file: {err}"),
            DecodeError::BadMagic => {
                write!(f, "not an .xrk file: missing '<h' header magic")
            }
            DecodeError::TruncatedHeader => write!(f, "truncated .xrk header"),
        }
    }
}

impl std::error::Error for DecodeError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            DecodeError::Io(err) => Some(err),
            DecodeError::BadMagic | DecodeError::TruncatedHeader => None,
        }
    }
}

impl From<io::Error> for DecodeError {
    fn from(err: io::Error) -> Self {
        DecodeError::Io(err)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::error::Error;

    #[test]
    fn test_display_and_source() {
        let io = DecodeError::from(io::Error::new(io::ErrorKind::NotFound, "gone"));
        assert!(io.to_string().contains("gone"));
        assert!(io.source().is_some(), "Io wraps a source error");

        for err in [DecodeError::BadMagic, DecodeError::TruncatedHeader] {
            assert!(!err.to_string().is_empty());
            assert!(err.source().is_none());
        }
        assert!(DecodeError::BadMagic.to_string().contains("magic"));
    }
}
