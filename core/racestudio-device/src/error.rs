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
    /// A guarded delete's confirmation did not match its target session (wrong id,
    /// wrong name, or no confirmation at all), so nothing was sent (issue 6.6).
    ConfirmationMismatch,
    /// A guarded delete was attempted without the required "armed" flag; it is
    /// refused and no bytes are transmitted (default-safe, issue 6.6).
    NotArmed,
    /// The device answered a delete request with a non-ack/error response; it is a
    /// typed failure and is never blindly retried (no double-delete) (issue 6.6).
    DeleteRejected,
    /// A downloaded session claimed to be a compressed (`.xrz`) container but its
    /// deflate stream could not be inflated, or it inflated implausibly far past
    /// its compressed size. No partial session is ever surfaced (issue #133).
    CorruptArchive,
    /// The device answered with a frame the live client did not expect at that
    /// point of the exchange — a wrong command echo, tag, or hello — so the
    /// conversation is out of step and is abandoned (issue #179).
    UnexpectedResponse,
    /// A requested on-device file name is not one the client will send: empty,
    /// too long for the command's path field, or not a `[A-Za-z0-9_-]` stem with
    /// an `.xrz`/`.xrk` extension (issue #179).
    InvalidPath,
    /// The device did not answer within the read timeout (issue #179).
    Timeout,
    /// The connection to the device could not be opened (issue #179).
    ConnectionFailed,
    /// The system reported no route to the device ("No route to host"). On
    /// macOS this is how Local Network privacy refuses an app the user has not
    /// allowed — or the Mac is not on the device's network.
    HostUnreachable,
    /// The device closed or reset the connection mid-exchange (issue #179).
    ConnectionClosed,
    /// The caller cancelled the exchange; nothing partial is surfaced (#179).
    Cancelled,
}

impl fmt::Display for DeviceError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            DeviceError::MalformedRecord => write!(f, "malformed discovery record"),
            DeviceError::NoService => write!(f, "no discovery responder found"),
            DeviceError::BadChecksum => write!(f, "response frame failed checksum verification"),
            DeviceError::TruncatedList => {
                write!(f, "truncated or incomplete response frame")
            }
            DeviceError::ChecksumMismatch => write!(
                f,
                "download failed whole-file or unrecoverable chunk checksum verification"
            ),
            DeviceError::MissingChunk => {
                write!(f, "the session download is missing one or more chunks")
            }
            DeviceError::ConfirmationMismatch => {
                write!(
                    f,
                    "the delete confirmation does not match the target session"
                )
            }
            DeviceError::NotArmed => write!(f, "the delete was not armed; nothing was sent"),
            DeviceError::DeleteRejected => write!(f, "the device rejected the delete request"),
            DeviceError::CorruptArchive => {
                write!(
                    f,
                    "the downloaded session is not a readable compressed container"
                )
            }
            DeviceError::UnexpectedResponse => {
                write!(f, "the device sent an unexpected response")
            }
            DeviceError::InvalidPath => write!(f, "the on-device file name is not valid"),
            DeviceError::Timeout => write!(f, "the device did not respond in time"),
            DeviceError::ConnectionFailed => write!(f, "could not connect to the device"),
            DeviceError::HostUnreachable => write!(f, "no route to the device"),
            DeviceError::ConnectionClosed => write!(f, "the device closed the connection"),
            DeviceError::Cancelled => write!(f, "the transfer was cancelled"),
        }
    }
}

impl std::error::Error for DeviceError {}

impl From<std::io::Error> for DeviceError {
    /// Classify a socket failure: a read that timed out, a connection the device
    /// dropped, or one that never opened (issue #179).
    fn from(err: std::io::Error) -> Self {
        use std::io::ErrorKind;
        if err.raw_os_error().is_some_and(is_no_route) {
            return DeviceError::HostUnreachable;
        }
        match err.kind() {
            ErrorKind::TimedOut | ErrorKind::WouldBlock => DeviceError::Timeout,
            ErrorKind::UnexpectedEof
            | ErrorKind::ConnectionReset
            | ErrorKind::ConnectionAborted
            | ErrorKind::BrokenPipe
            | ErrorKind::NotConnected => DeviceError::ConnectionClosed,
            _ => DeviceError::ConnectionFailed,
        }
    }
}

/// `EHOSTUNREACH` / `ENETUNREACH` ("No route to host"). Matched by number
/// because `ErrorKind::HostUnreachable` is newer than the crate's MSRV.
fn is_no_route(errno: i32) -> bool {
    #[cfg(target_os = "linux")]
    const NO_ROUTE: [i32; 2] = [113, 101];
    #[cfg(not(target_os = "linux"))]
    const NO_ROUTE: [i32; 2] = [65, 51];
    NO_ROUTE.contains(&errno)
}
