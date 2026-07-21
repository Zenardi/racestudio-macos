//! Clean-room observation of the MyChron5/6 WiFi download protocol (issue 6.2).
//!
//! This crate is the *executable form* of the protocol notes: the structures and
//! the checksum below were derived **only** from observing on-the-wire bytes of an
//! AiM iOS-app ↔ MyChron6 exchange (clean-room, interoperability-only RE — DMCA
//! §1201(f), EU Software Directive Art. 6; see [ADR 0006] and [`PROTOCOL.md`]).
//! No AiM firmware, DLL, or app binary was read. **No networking client lands
//! here** — discovery/enumeration/download/delete are issues 6.3–6.6; this crate
//! only decodes the observed framing so the notes are testable against the
//! committed fixtures in `fixtures/device/`.
//!
//! The device speaks a length-prefixed, checksummed frame protocol ("STCP") over
//! TCP port [`CONTROL_PORT`]; it is discovered by a UDP broadcast on
//! [`DISCOVERY_PORT`].
//!
//! ```
//! // The documented checksum is a 16-bit little-endian additive sum of the payload.
//! assert_eq!(racestudio_device::stcp_checksum(&[0x06, 0x08]), 0x0e);
//! ```
//!
//! [ADR 0006]: https://github.com/Zenardi/racestudio-macos/blob/main/docs/adr/0006-device-wifi-reverse-engineering.md
//! [`PROTOCOL.md`]: https://github.com/Zenardi/racestudio-macos/blob/main/docs/device/PROTOCOL.md

// This crate only parses untrusted device bytes; like the decoder it must never
// panic on malformed input. Test code (integration tests) may use expect/unwrap.
#![cfg_attr(
    not(test),
    deny(clippy::unwrap_used, clippy::expect_used, clippy::panic)
)]

pub mod discovery;
pub mod error;

pub use discovery::{ap_mode_fallback, discover, parse_discovery, Device, DeviceBrowser};
pub use error::DeviceError;

/// UDP port used for device discovery (multicast probe/response).
pub const DISCOVERY_PORT: u16 = 36002;
/// TCP port carrying the control + transfer (STCP) frames.
pub const CONTROL_PORT: u16 = 2000;
/// The ASCII discovery probe the client multicasts on [`DISCOVERY_PORT`].
pub const DISCOVERY_PROBE: &[u8] = b"aim-ka";
/// Magic opening a framed STCP message header.
pub const HEADER_MAGIC: &[u8] = b"<hSTCP";
/// Magic opening the trailing checksum marker of an STCP frame.
pub const TRAILER_MAGIC: &[u8] = b"<STCP";

/// The documented checksum: a 16-bit little-endian additive sum of the frame
/// payload bytes, taken mod 65536. Reproduces every observed trailer value.
#[must_use]
pub fn stcp_checksum(payload: &[u8]) -> u16 {
    payload
        .iter()
        .fold(0u16, |acc, &b| acc.wrapping_add(u16::from(b)))
}

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

/// The device's discovery response (observed 236-byte struct): a length + type
/// header followed by the device's own IPv4 address.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DiscoveryResponse {
    /// Total response length (from its own `length` header field).
    pub length: u32,
    /// Response type/version tag (observed value: 2).
    pub kind: u32,
    /// The device's IPv4 address, as advertised in the response body.
    pub device_ip: [u8; 4],
}

/// Parse a device discovery response. Returns `None` if the buffer is too short
/// to contain the documented `length + type + ipv4` prefix.
#[must_use]
pub fn parse_discovery_response(data: &[u8]) -> Option<DiscoveryResponse> {
    let length = u32::from_le_bytes(data.get(0..4)?.try_into().ok()?);
    let kind = u32::from_le_bytes(data.get(4..8)?.try_into().ok()?);
    let device_ip: [u8; 4] = data.get(8..12)?.try_into().ok()?;
    Some(DiscoveryResponse {
        length,
        kind,
        device_ip,
    })
}

/// A transfer-chunk payload starts with a 4-byte little-endian byte offset into
/// the session file; this returns that offset.
#[must_use]
pub fn transfer_chunk_offset(payload: &[u8]) -> Option<u32> {
    Some(u32::from_le_bytes(payload.get(0..4)?.try_into().ok()?))
}

/// The chunk data following the 4-byte offset header of a transfer chunk payload.
#[must_use]
pub fn transfer_chunk_data(payload: &[u8]) -> Option<&[u8]> {
    payload.get(4..)
}
