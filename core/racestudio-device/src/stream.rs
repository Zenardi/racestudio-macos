//! Read one STCP frame off a byte stream (issue #179).
//!
//! [`crate::parse_frame`] decodes a frame already in memory; on a live TCP
//! connection the bytes arrive in arbitrary pieces, so this reads exactly one
//! frame — the 12-byte header, the declared payload, then the 8-byte checksum
//! trailer — and hands back its raw bytes for [`crate::verified_frame`].
//!
//! Every frame in the #133 capture (1536 client, 1593 device) carries a trailer,
//! so one is required: a trailerless frame cannot be told apart from the start
//! of the next one without reading ahead, which would block on a device that is
//! waiting for us.

use std::io::Read;

use crate::error::DeviceError;
use crate::framing::{HEADER_MAGIC, TRAILER_MAGIC};

/// The largest payload the client accepts in one frame. A full download chunk
/// is 65476 bytes; anything far beyond that is a corrupt or hostile length that
/// must not drive an allocation.
pub const MAX_FRAME_PAYLOAD: usize = 1024 * 1024;

const HEADER_LEN: usize = 12;
const TRAILER_LEN: usize = 8;

/// Read exactly one frame from `reader` and return its raw bytes (header,
/// payload and trailer).
///
/// # Errors
/// - [`DeviceError::UnexpectedResponse`] when the bytes are not an STCP header
///   or the trailer is missing.
/// - [`DeviceError::MalformedRecord`] when the declared payload length exceeds
///   [`MAX_FRAME_PAYLOAD`].
/// - [`DeviceError::Timeout`] / [`DeviceError::ConnectionClosed`] /
///   [`DeviceError::ConnectionFailed`] for socket failures.
pub fn read_frame(reader: &mut impl Read) -> Result<Vec<u8>, DeviceError> {
    let mut header = [0u8; HEADER_LEN];
    reader.read_exact(&mut header)?;
    if !header.starts_with(HEADER_MAGIC) || header[HEADER_LEN - 1] != b'>' {
        return Err(DeviceError::UnexpectedResponse);
    }
    let mut len_bytes = [0u8; 4];
    len_bytes.copy_from_slice(&header[HEADER_MAGIC.len()..HEADER_MAGIC.len() + 4]);
    let payload_len =
        usize::try_from(u32::from_le_bytes(len_bytes)).map_err(|_| DeviceError::MalformedRecord)?;
    if payload_len > MAX_FRAME_PAYLOAD {
        return Err(DeviceError::MalformedRecord);
    }

    let mut frame = Vec::with_capacity(HEADER_LEN + payload_len + TRAILER_LEN);
    frame.extend_from_slice(&header);
    frame.resize(HEADER_LEN + payload_len + TRAILER_LEN, 0);
    reader.read_exact(&mut frame[HEADER_LEN..])?;

    let trailer = &frame[HEADER_LEN + payload_len..];
    if !trailer.starts_with(TRAILER_MAGIC) || trailer[TRAILER_LEN - 1] != b'>' {
        return Err(DeviceError::UnexpectedResponse);
    }
    Ok(frame)
}
