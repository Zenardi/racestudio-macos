//! Typed errors for device discovery (issue 6.3).

use std::fmt;

/// A failure while discovering a MyChron device, parsing its announcement, or
/// enumerating its on-device sessions (issue 6.4).
///
/// The parsers never panic on malformed input: a bad record surfaces as
/// [`DeviceError::MalformedRecord`], the absence of a responder as
/// [`DeviceError::NoService`] (which the caller turns into the AP-mode fallback),
/// a frame whose trailer checksum does not verify as [`DeviceError::BadChecksum`],
/// and a session list that cannot be fully read as [`DeviceError::TruncatedList`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DeviceError {
    /// A discovery record was malformed or truncated: too short to hold the
    /// documented header, a declared length that overruns the buffer, or a type
    /// tag that is not an AiM discovery response.
    MalformedRecord,
    /// No discovery responder was found on the network — the caller falls back
    /// to AP mode (the device's own access-point gateway).
    NoService,
    /// A response frame's trailer checksum did not match the documented STCP
    /// checksum over its payload — the frame is rejected before parsing and no
    /// partial result is surfaced (issue 6.4).
    BadChecksum,
    /// A session-list response could not be fully read: the frame is incomplete,
    /// carries no trailer, or declares more session records than its payload
    /// holds (issue 6.4).
    TruncatedList,
    /// A session download failed integrity verification: a chunk's checksum kept
    /// failing past the retry budget, or the reassembled whole file did not match
    /// its expected checksum. No partial file is ever surfaced as success (6.5).
    ChecksumMismatch,
    /// A session download ended with a gap: the transport signalled end-of-stream
    /// before every byte of the declared size was covered (issue 6.5).
    MissingChunk,
}

impl fmt::Display for DeviceError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            DeviceError::MalformedRecord => write!(f, "malformed discovery record"),
            DeviceError::NoService => write!(f, "no discovery responder found"),
            DeviceError::BadChecksum => write!(f, "response frame failed checksum verification"),
            DeviceError::TruncatedList => write!(f, "truncated or incomplete session list"),
            DeviceError::ChecksumMismatch => write!(
                f,
                "download failed whole-file or unrecoverable chunk checksum verification"
            ),
            DeviceError::MissingChunk => {
                write!(f, "the session download is missing one or more chunks")
            }
        }
    }
}

impl std::error::Error for DeviceError {}
