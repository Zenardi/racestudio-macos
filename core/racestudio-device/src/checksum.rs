//! The STCP payload checksum (issue 6.2 notes), factored into its own module so
//! the 6.4 session enumeration and 6.5 download share one verified implementation.
//!
//! `docs/device/PROTOCOL.md` §3: the trailer checksum is a 16-bit little-endian
//! additive sum of the frame payload bytes, taken mod 65536. It reproduces every
//! observed trailer value in the capture.

/// The documented checksum: a 16-bit little-endian additive sum of the frame
/// payload bytes, taken mod 65536. Reproduces every observed trailer value.
#[must_use]
pub fn stcp_checksum(payload: &[u8]) -> u16 {
    payload
        .iter()
        .fold(0u16, |acc, &b| acc.wrapping_add(u16::from(b)))
}
