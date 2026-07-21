//! STCP frame decode + checksum-verified extraction (issue 6.2 notes), factored
//! into its own module so 6.4 session enumeration and 6.5 download share one
//! implementation.
//!
//! Wire layout (`docs/device/PROTOCOL.md` §3): `HEADER_MAGIC + length(u32 LE) +
//! flag(u8) + '>'`, then `length` payload bytes, then (optionally)
//! `TRAILER_MAGIC + checksum(u16 LE) + '>'`.

use crate::checksum::stcp_checksum;
use crate::error::DeviceError;

/// Magic opening a framed STCP message header.
pub const HEADER_MAGIC: &[u8] = b"<hSTCP";
/// Magic opening the trailing checksum marker of an STCP frame.
pub const TRAILER_MAGIC: &[u8] = b"<STCP";

/// One STCP frame, borrowed from a byte buffer.
///
/// Wire layout: `HEADER_MAGIC + length(u32 LE) + flag(u8) + '>'`, then `length`
/// payload bytes, then (optionally) `TRAILER_MAGIC + checksum(u16 LE) + '>'`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Frame<'a> {
    /// Declared payload length (from the header).
    pub length: u32,
    /// Header flag byte (observed to be 0 in every captured frame).
    pub flag: u8,
    /// The payload bytes.
    pub payload: &'a [u8],
    /// The trailer checksum, if a trailer followed the payload.
    pub checksum: Option<u16>,
}

impl Frame<'_> {
    /// True when a trailer checksum is present and the documented algorithm
    /// reproduces it over the payload.
    #[must_use]
    pub fn checksum_valid(&self) -> bool {
        self.checksum == Some(stcp_checksum(self.payload))
    }
}

/// Parse the STCP frame at the start of `data`.
///
/// Returns the borrowed [`Frame`] and the number of bytes it consumed (header +
/// payload + trailer, when a trailer is present), or `None` if `data` does not
/// begin with a complete, valid frame header + payload.
#[must_use]
pub fn parse_frame(data: &[u8]) -> Option<(Frame<'_>, usize)> {
    let rest = data.strip_prefix(HEADER_MAGIC)?;
    let length = u32::from_le_bytes(rest.get(0..4)?.try_into().ok()?);
    let flag = *rest.get(4)?;
    if *rest.get(5)? != b'>' {
        return None;
    }
    let payload_start = HEADER_MAGIC.len() + 6; // 6 magic + 4 len + 1 flag + 1 '>'
    let payload_end = payload_start.checked_add(length as usize)?;
    let payload = data.get(payload_start..payload_end)?;

    let mut checksum = None;
    let mut consumed = payload_end;
    if let Some(trailer) = data
        .get(payload_end..)
        .and_then(|t| t.strip_prefix(TRAILER_MAGIC))
    {
        // A malformed/truncated trailer is treated as "no trailer": the framed
        // payload is still returned rather than the whole parse failing.
        if trailer.get(2) == Some(&b'>') {
            if let Some(cs) = trailer.get(0..2).and_then(|b| <[u8; 2]>::try_from(b).ok()) {
                checksum = Some(u16::from_le_bytes(cs));
                consumed = payload_end + TRAILER_MAGIC.len() + 3; // 5 magic + 2 checksum + 1 '>'
            }
        }
    }
    Some((
        Frame {
            length,
            flag,
            payload,
            checksum,
        },
        consumed,
    ))
}

/// Decode a complete STCP frame at the start of `data` and verify its trailer
/// checksum before returning it — the checksum-first gate a response parser (6.4
/// session list, 6.5 download) runs so no unverified payload is ever parsed.
///
/// # Errors
/// - [`DeviceError::TruncatedList`] when `data` does not form a complete frame,
///   or the frame carries no readable trailer to verify.
/// - [`DeviceError::BadChecksum`] when the trailer is present but the documented
///   checksum does not reproduce it over the payload.
pub fn verified_frame(data: &[u8]) -> Result<Frame<'_>, DeviceError> {
    let (frame, _) = parse_frame(data).ok_or(DeviceError::TruncatedList)?;
    match frame.checksum {
        None => Err(DeviceError::TruncatedList),
        Some(_) if !frame.checksum_valid() => Err(DeviceError::BadChecksum),
        Some(_) => Ok(frame),
    }
}

/// Assemble a complete STCP frame around `payload`: header + payload + checksum
/// trailer (`docs/device/PROTOCOL.md` §3), the inverse of [`parse_frame`]. Shared
/// by every request builder (6.4 session-list, 6.6 delete) so one implementation
/// produces the wire bytes and the same [`stcp_checksum`] trailer everywhere.
#[must_use]
pub(crate) fn encode_frame(payload: &[u8]) -> Vec<u8> {
    let mut buf =
        Vec::with_capacity(HEADER_MAGIC.len() + 6 + payload.len() + TRAILER_MAGIC.len() + 3);
    buf.extend_from_slice(HEADER_MAGIC);
    buf.extend_from_slice(&(payload.len() as u32).to_le_bytes());
    buf.push(0); // flag (observed 0)
    buf.push(b'>');
    buf.extend_from_slice(payload);
    buf.extend_from_slice(TRAILER_MAGIC);
    buf.extend_from_slice(&stcp_checksum(payload).to_le_bytes());
    buf.push(b'>');
    buf
}
