//! Decode error type for the `.xrk` decoder.
//!
//! The variant set grew across the layered decoders (1.2 container/header, 1.3
//! channels, 1.4 GPS, 1.5 laps) and is now the single, `#[non_exhaustive]`
//! `DecodeError` every entry point returns (1.6) — the one failure surface for
//! [`decode_session`](crate::decode_session) and the individual decoders alike.

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
    /// A channel data message's sample bytes run past the end of the stream.
    TruncatedChannel,
    /// A multi-sample (`(M`) burst declares a sample count that is zero or
    /// whose bytes overrun the message framing.
    BadSampleCount,
    /// A channel definition carries a unit type the decoder does not recognise.
    ///
    /// Reserved for strict unit validation. The default [`decode_channels`] is
    /// tolerant — as libxrk is — and maps an unrecognised unit type to an empty
    /// unit string rather than returning this error.
    ///
    /// [`decode_channels`]: crate::decode_channels
    UnknownUnit,
    /// The GPS message stream is truncated: its bytes are not a whole number of
    /// 56-byte NAV-SOL records.
    TruncatedGps,
    /// A LAP marker message is too short to contain the lap-timing fields.
    TruncatedLaps,
}

impl fmt::Display for DecodeError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            DecodeError::Io(err) => write!(f, "failed to read .xrk file: {err}"),
            DecodeError::BadMagic => {
                write!(f, "not an .xrk file: missing '<h' header magic")
            }
            DecodeError::TruncatedHeader => write!(f, "truncated .xrk header"),
            DecodeError::TruncatedChannel => {
                write!(
                    f,
                    "truncated channel data: sample bytes run past end-of-file"
                )
            }
            DecodeError::BadSampleCount => {
                write!(f, "invalid channel sample count in a multi-sample burst")
            }
            DecodeError::UnknownUnit => write!(f, "unrecognised channel unit type"),
            DecodeError::TruncatedGps => {
                write!(
                    f,
                    "truncated GPS data: not a whole number of 56-byte records"
                )
            }
            DecodeError::TruncatedLaps => {
                write!(
                    f,
                    "truncated lap marker: too short for the lap-timing fields"
                )
            }
        }
    }
}

impl std::error::Error for DecodeError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            DecodeError::Io(err) => Some(err),
            DecodeError::BadMagic
            | DecodeError::TruncatedHeader
            | DecodeError::TruncatedChannel
            | DecodeError::BadSampleCount
            | DecodeError::UnknownUnit
            | DecodeError::TruncatedGps
            | DecodeError::TruncatedLaps => None,
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

        for err in [
            DecodeError::BadMagic,
            DecodeError::TruncatedHeader,
            DecodeError::TruncatedChannel,
            DecodeError::BadSampleCount,
            DecodeError::UnknownUnit,
            DecodeError::TruncatedGps,
            DecodeError::TruncatedLaps,
        ] {
            assert!(!err.to_string().is_empty());
            assert!(err.source().is_none());
        }
        assert!(DecodeError::BadMagic.to_string().contains("magic"));
        assert!(DecodeError::TruncatedChannel
            .to_string()
            .contains("channel"));
        assert!(DecodeError::BadSampleCount.to_string().contains("count"));
        assert!(DecodeError::UnknownUnit.to_string().contains("unit"));
        assert!(DecodeError::TruncatedGps.to_string().contains("GPS"));
        assert!(DecodeError::TruncatedLaps.to_string().contains("lap"));
    }
}
