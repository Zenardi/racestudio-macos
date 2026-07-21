//! On-device session enumeration (issue 6.4): build the catalog/session-list
//! request the MyChron answers, and parse its response into typed [`SessionInfo`].
//!
//! # What is verified vs hypothesized
//!
//! - [`build_session_list_request`] reproduces the **captured** catalog request
//!   (`fixtures/device/control/command_info.bin`) byte-for-byte, and its payload
//!   checksum matches the observed trailer (94). This is verified.
//! - [`parse_session_list`] verifies the response frame's checksum, then reads the
//!   leading `u32` session **count**. In the one available capture that count is
//!   `0` — the device held no on-board sessions — so this returns an empty list,
//!   which is the verified behaviour against `sessions/list_response.bin`.
//! - The per-record layout below (id/date/laps/size/name) is **hypothesized**: no
//!   capture with sessions present exists yet, so it is a documented placeholder
//!   to be confirmed against a real session-present capture (issue #130). It is
//!   exercised only against a synthetic frame in `tests/session_test.rs`; we make
//!   no claim it matches AiM's wire format. Clean-room, interoperability-only
//!   (DMCA §1201(f); EU 2009/24/EC Art. 6).

use crate::error::DeviceError;
use crate::framing::{encode_frame, verified_frame};

/// The catalog/get-list command code, at `payload[8..12]` of the request
/// (`docs/device/PROTOCOL.md` §5, `command_info.bin`; command `0x0110`).
const CATALOG_COMMAND_CODE: [u8; 4] = [0x10, 0x00, 0x01, 0x00];
/// Observed catalog-command parameter at `payload[16..20]` (semantics uncertain;
/// reproduced verbatim from the captured request so the bytes match exactly).
const CATALOG_PARAM_LEN: [u8; 4] = [0x40, 0x00, 0x00, 0x00];
/// Observed catalog-command parameter at `payload[24..28]` (semantics uncertain).
const CATALOG_PARAM_A: [u8; 4] = [0x01, 0x0a, 0x00, 0x00];
/// Observed catalog-command parameter at `payload[32..36]` (semantics uncertain).
const CATALOG_PARAM_B: [u8; 4] = [0x02, 0x00, 0x00, 0x00];
/// The captured request's payload is 64 bytes (`command_info.bin`).
const REQUEST_PAYLOAD_LEN: usize = 64;

/// The leading `u32` LE session count at the head of the response payload.
const COUNT_PREFIX_LEN: usize = 4;
/// A hypothesized session record's fixed size in bytes (see the module docs).
const SESSION_RECORD_LEN: usize = 56;
/// The magic opening a hypothesized session record.
const SESSION_MAGIC: &[u8] = b"ses";
/// The fixed-width, NUL-padded name field within a session record.
const NAME_OFFSET: usize = 24;
const NAME_LEN: usize = 32;

/// A device-local timestamp, decoded field-by-field from a session record — a
/// **typed** date (not a raw string). Mirrors the observed device-time encoding
/// (`docs/device/PROTOCOL.md` §4: consecutive time fields).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SessionDate {
    /// Four-digit year (e.g. 2026).
    pub year: u16,
    /// Month, 1–12.
    pub month: u8,
    /// Day of month, 1–31.
    pub day: u8,
    /// Hour, 0–23.
    pub hour: u8,
    /// Minute, 0–59.
    pub minute: u8,
    /// Second, 0–59.
    pub second: u8,
}

/// One enumerated on-device session.
///
/// `date` is a typed [`SessionDate`], not a raw string. Two entries comparing
/// `Eq` are the same session.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SessionInfo {
    /// The device-local session id / index.
    pub id: u32,
    /// The session's display name (NUL padding trimmed).
    pub name: String,
    /// The session start timestamp (device-local).
    pub date: SessionDate,
    /// Number of recorded laps.
    pub lap_count: u16,
    /// On-device size of the session's data, in bytes.
    pub size_bytes: u32,
}

/// Build the catalog/session-list request the MyChron answers with its session
/// catalog — the exact bytes observed on the wire (`command_info.bin`, command
/// `0x0110`), wrapped in a checksum-valid STCP frame.
///
/// A byte-for-byte match with the captured request is asserted by
/// `test_request_bytes_match_captured_fixture`.
#[must_use]
pub fn build_session_list_request() -> Vec<u8> {
    let mut payload = [0u8; REQUEST_PAYLOAD_LEN];
    payload[8..12].copy_from_slice(&CATALOG_COMMAND_CODE);
    payload[16..20].copy_from_slice(&CATALOG_PARAM_LEN);
    payload[24..28].copy_from_slice(&CATALOG_PARAM_A);
    payload[32..36].copy_from_slice(&CATALOG_PARAM_B);
    encode_frame(&payload)
}

/// Parse a catalog/session-list response into typed [`SessionInfo`]s.
///
/// The response frame's checksum is **verified before parsing** (a bad checksum
/// is [`DeviceError::BadChecksum`] with no partial list surfaced). The payload's
/// leading `u32` LE is the session count; each of the `count` fixed-size records
/// that follow is decoded. An empty list (count 0) is `Ok(vec![])`, never an
/// error — as with the recorded fixture, whose store was empty.
///
/// # Errors
/// - [`DeviceError::BadChecksum`] if the frame's trailer checksum does not verify.
/// - [`DeviceError::TruncatedList`] if the frame is incomplete/untrailered or the
///   declared count overruns the payload's records.
/// - [`DeviceError::MalformedRecord`] if a record lacks the session magic.
///
/// Never panics on malformed input.
pub fn parse_session_list(bytes: &[u8]) -> Result<Vec<SessionInfo>, DeviceError> {
    let frame = verified_frame(bytes)?;
    let payload = frame.payload;

    let count_bytes = payload
        .get(0..COUNT_PREFIX_LEN)
        .and_then(|b| <[u8; 4]>::try_from(b).ok())
        .ok_or(DeviceError::TruncatedList)?;
    let count = u32::from_le_bytes(count_bytes) as usize;

    // Reject a count that cannot fit in the remaining bytes up front, so a hostile
    // count never drives a large allocation or a long doomed loop.
    let available = payload.len().saturating_sub(COUNT_PREFIX_LEN) / SESSION_RECORD_LEN;
    if count > available {
        return Err(DeviceError::TruncatedList);
    }

    let mut sessions = Vec::with_capacity(count);
    let mut offset = COUNT_PREFIX_LEN;
    for _ in 0..count {
        let end = offset + SESSION_RECORD_LEN;
        let record = payload.get(offset..end).ok_or(DeviceError::TruncatedList)?;
        sessions.push(parse_record(record)?);
        offset = end;
    }
    Ok(sessions)
}

/// Decode one fixed-size session record.
///
/// Layout: `[0..3]` magic `b"ses"`, `[3]` a reserved version byte (currently
/// ignored — validated only once a real session-present capture pins it down,
/// issue #130), then `id`/`date`/`lap_count`/`size_bytes`/`name` as documented on
/// the module.
fn parse_record(record: &[u8]) -> Result<SessionInfo, DeviceError> {
    if record.get(0..SESSION_MAGIC.len()) != Some(SESSION_MAGIC) {
        return Err(DeviceError::MalformedRecord);
    }
    let id = read_u32(record, 4)?;
    let date = SessionDate {
        year: read_u16(record, 8)?,
        month: read_u8(record, 10)?,
        day: read_u8(record, 11)?,
        hour: read_u8(record, 12)?,
        minute: read_u8(record, 13)?,
        second: read_u8(record, 14)?,
    };
    let lap_count = read_u16(record, 16)?;
    let size_bytes = read_u32(record, 18)?;
    let name = decode_name(
        record
            .get(NAME_OFFSET..NAME_OFFSET + NAME_LEN)
            .ok_or(DeviceError::MalformedRecord)?,
    );
    Ok(SessionInfo {
        id,
        name,
        date,
        lap_count,
        size_bytes,
    })
}

/// A NUL-padded ASCII field decoded to a `String` with the padding trimmed.
fn decode_name(bytes: &[u8]) -> String {
    let end = bytes.iter().position(|&b| b == 0).unwrap_or(bytes.len());
    String::from_utf8_lossy(&bytes[..end]).into_owned()
}

/// Read a little-endian `u16` at `at`, or [`DeviceError::MalformedRecord`].
fn read_u16(b: &[u8], at: usize) -> Result<u16, DeviceError> {
    let raw = b
        .get(at..at + 2)
        .and_then(|s| <[u8; 2]>::try_from(s).ok())
        .ok_or(DeviceError::MalformedRecord)?;
    Ok(u16::from_le_bytes(raw))
}

/// Read a little-endian `u32` at `at`, or [`DeviceError::MalformedRecord`].
fn read_u32(b: &[u8], at: usize) -> Result<u32, DeviceError> {
    let raw = b
        .get(at..at + 4)
        .and_then(|s| <[u8; 4]>::try_from(s).ok())
        .ok_or(DeviceError::MalformedRecord)?;
    Ok(u32::from_le_bytes(raw))
}

/// Read a single byte at `at`, or [`DeviceError::MalformedRecord`].
fn read_u8(b: &[u8], at: usize) -> Result<u8, DeviceError> {
    b.get(at).copied().ok_or(DeviceError::MalformedRecord)
}
