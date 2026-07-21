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

pub mod checksum;
pub mod discovery;
pub mod error;
pub mod framing;
pub mod session;
pub mod transfer;

pub use checksum::stcp_checksum;
pub use discovery::{ap_mode_fallback, discover, parse_discovery, Device, DeviceBrowser};
pub use error::DeviceError;
pub use framing::{parse_frame, verified_frame, Frame, HEADER_MAGIC, TRAILER_MAGIC};
pub use session::{build_session_list_request, parse_session_list, SessionDate, SessionInfo};
pub use transfer::{download_session, DownloadPlan, ProgressSink, Transport, MAX_CHUNK_RETRIES};

/// UDP port used for device discovery (multicast probe/response).
pub const DISCOVERY_PORT: u16 = 36002;
/// TCP port carrying the control + transfer (STCP) frames.
pub const CONTROL_PORT: u16 = 2000;
/// The ASCII discovery probe the client multicasts on [`DISCOVERY_PORT`].
pub const DISCOVERY_PROBE: &[u8] = b"aim-ka";

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
