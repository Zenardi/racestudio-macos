//! Executable acceptance tests for issue 6.4 — on-device session enumeration.
//!
//! The *verified* behaviour is asserted against the committed, de-identified 6.2
//! fixtures: `build_session_list_request()` reproduces the captured catalog
//! request byte-for-byte, and `parse_session_list()` over the recorded
//! `sessions/list_response.bin` yields an **empty** list — because the MyChron6
//! held 0 on-board sessions at capture time, so its catalog response enumerates
//! device identity/config records, not dated sessions (see `docs/device/PROTOCOL.md`
//! §5 and `manifest.json`).
//!
//! The per-session field decoding (id/date/laps/size/name) is exercised against a
//! **synthetic, hypothesized** session frame built in-test (`synthetic_frame`):
//! no session-present capture exists yet, so the record *layout* below is a
//! documented placeholder to be confirmed against a real capture (issue #130).
//! Clean-room, interoperability-only (DMCA §1201(f); EU 2009/24/EC Art. 6): we
//! never fabricate a claim that this layout matches AiM's wire format.

use std::path::PathBuf;

use serde::Deserialize;

use racestudio_device as dev;
use racestudio_device::DeviceError;

// ---- fixture access --------------------------------------------------------

fn fixtures_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../fixtures/device")
}

fn read(rel: &str) -> Vec<u8> {
    std::fs::read(fixtures_dir().join(rel))
        .unwrap_or_else(|e| panic!("fixture {rel} must exist: {e}"))
}

#[derive(Deserialize)]
struct SessionGolden {
    session_count: usize,
    sessions: Vec<GoldenSession>,
}

#[derive(Deserialize)]
#[allow(dead_code)]
struct GoldenSession {
    id: u32,
    name: String,
    lap_count: u16,
    size_bytes: u32,
}

fn golden() -> SessionGolden {
    serde_json::from_slice(&read("golden/sessions.json")).expect("sessions golden parses")
}

// ---- synthetic session frame (hypothesized layout — see module docs) -------
//
// Session-list payload layout, mirrored by `session.rs`:
//   [0..4]   u32 LE   session_count N
//   then N × 56-byte session records:
//     [0..3]   b"ses"        record magic
//     [3]      0x01          version
//     [4..8]   u32 LE        id
//     [8..10]  u16 LE        year        \
//     [10]     u8   month     |
//     [11]     u8   day       | reuses the observed device-time encoding
//     [12]     u8   hour      | (PROTOCOL.md §4: consecutive time fields)
//     [13]     u8   minute    |
//     [14]     u8   second   /
//     [15]     u8   (pad)
//     [16..18] u16 LE        lap_count
//     [18..22] u32 LE        size_bytes
//     [22..24] (pad)
//     [24..56] 32 bytes      name, NUL-padded ASCII

#[allow(clippy::too_many_arguments)]
fn synthetic_record(
    id: u32,
    year: u16,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,
    lap_count: u16,
    size_bytes: u32,
    name: &str,
) -> [u8; 56] {
    let mut r = [0u8; 56];
    r[0..3].copy_from_slice(b"ses");
    r[3] = 0x01;
    r[4..8].copy_from_slice(&id.to_le_bytes());
    r[8..10].copy_from_slice(&year.to_le_bytes());
    r[10] = month;
    r[11] = day;
    r[12] = hour;
    r[13] = minute;
    r[14] = second;
    r[16..18].copy_from_slice(&lap_count.to_le_bytes());
    r[18..22].copy_from_slice(&size_bytes.to_le_bytes());
    let name = name.as_bytes();
    let n = name.len().min(32);
    r[24..24 + n].copy_from_slice(&name[..n]);
    r
}

/// Wrap a session-list payload (`count` + records) in a valid STCP frame with a
/// correct trailer checksum, exactly as the device would frame its response.
fn synthetic_frame(records: &[[u8; 56]]) -> Vec<u8> {
    let mut payload = Vec::new();
    payload.extend_from_slice(&(records.len() as u32).to_le_bytes());
    for r in records {
        payload.extend_from_slice(r);
    }
    frame_payload(&payload)
}

/// Assemble `<hSTCP len flag '>'` + payload + `<STCP checksum '>'`.
fn frame_payload(payload: &[u8]) -> Vec<u8> {
    let mut buf = Vec::new();
    buf.extend_from_slice(dev::HEADER_MAGIC);
    buf.extend_from_slice(&(payload.len() as u32).to_le_bytes());
    buf.push(0); // flag
    buf.push(b'>');
    buf.extend_from_slice(payload);
    buf.extend_from_slice(dev::TRAILER_MAGIC);
    buf.extend_from_slice(&dev::stcp_checksum(payload).to_le_bytes());
    buf.push(b'>');
    buf
}

// ---- the named behaviours --------------------------------------------------

/// Given the recorded session-list fixture, When parsed, Then it matches the
/// golden oracle — which is empty, because the device held 0 sessions at capture.
#[test]
fn test_session_list_matches_golden() {
    let g = golden();
    let sessions = dev::parse_session_list(&read("sessions/list_response.bin"))
        .expect("recorded catalog response parses");

    assert_eq!(
        sessions.len(),
        g.session_count,
        "session count matches the golden"
    );
    assert_eq!(g.session_count, 0, "the recorded store was empty");
    assert!(g.sessions.is_empty());
    assert!(
        sessions.is_empty(),
        "an empty on-device store yields an empty list, not identity/config records"
    );
}

/// `build_session_list_request()` reproduces the captured catalog request
/// (`control/command_info.bin`) byte-for-byte.
#[test]
fn test_request_bytes_match_captured_fixture() {
    let request = dev::build_session_list_request();
    assert_eq!(
        request,
        read("control/command_info.bin"),
        "the built request must equal the captured request byte-for-byte"
    );
    // It is a well-formed, checksum-valid STCP frame (documented checksum 94).
    let (frame, consumed) = dev::parse_frame(&request).expect("request is a valid frame");
    assert_eq!(consumed, request.len());
    assert!(frame.checksum_valid());
    assert_eq!(frame.checksum, Some(94));
}

/// A session frame with dated entries decodes into typed `SessionInfo`, with the
/// date as a typed timestamp (not a raw string) and the lap counts/sizes intact.
#[test]
fn test_dates_and_lapcounts_parse() {
    let frame = synthetic_frame(&[
        synthetic_record(7, 2026, 7, 21, 14, 30, 5, 12, 4_200_000, "Kart AM"),
        synthetic_record(8, 2025, 12, 1, 9, 5, 59, 3, 512_000, "Shakedown"),
    ]);

    let sessions = dev::parse_session_list(&frame).expect("synthetic frame parses");

    assert_eq!(sessions.len(), 2);

    let s0 = &sessions[0];
    assert_eq!(s0.id, 7);
    assert_eq!(s0.name, "Kart AM");
    assert_eq!(s0.lap_count, 12);
    assert_eq!(s0.size_bytes, 4_200_000);
    // The date is a typed timestamp, addressed field-by-field — not a string.
    assert_eq!(s0.date.year, 2026);
    assert_eq!(s0.date.month, 7);
    assert_eq!(s0.date.day, 21);
    assert_eq!(s0.date.hour, 14);
    assert_eq!(s0.date.minute, 30);
    assert_eq!(s0.date.second, 5);

    let s1 = &sessions[1];
    assert_eq!(s1.id, 8);
    assert_eq!(s1.name, "Shakedown");
    assert_eq!(s1.lap_count, 3);
    assert_eq!(s1.size_bytes, 512_000);
    assert_eq!(s1.date.year, 2025);
    assert_eq!(s1.date.month, 12);
    assert_eq!(s1.date.day, 1);
}

/// Given an empty session list, When parsed, Then it yields an empty Vec — an
/// empty store is a success, never an error.
#[test]
fn test_empty_list_is_ok() {
    let frame = synthetic_frame(&[]);
    let sessions = dev::parse_session_list(&frame).expect("empty list parses");
    assert!(sessions.is_empty());
}

/// A truncated/corrupt list returns a typed DeviceError, never a panic and never
/// a partial list.
#[test]
fn test_truncated_list_returns_error() {
    let full = synthetic_frame(&[synthetic_record(1, 2026, 1, 1, 0, 0, 0, 1, 100, "x")]);

    // Cut the frame mid-payload: it can no longer be framed at all.
    let cut = &full[..full.len() / 2];
    assert_eq!(
        dev::parse_session_list(cut),
        Err(DeviceError::TruncatedList),
        "a frame that cannot be assembled is a TruncatedList"
    );

    // Empty input is likewise a TruncatedList, not a panic.
    assert_eq!(
        dev::parse_session_list(&[]),
        Err(DeviceError::TruncatedList)
    );

    // A declared count that overruns the available records is a TruncatedList.
    let mut payload = Vec::new();
    payload.extend_from_slice(&3u32.to_le_bytes()); // claims 3 records...
    payload.extend_from_slice(&synthetic_record(1, 2026, 1, 1, 0, 0, 0, 1, 1, "a")); // ...only 1
    let overrun = frame_payload(&payload);
    assert_eq!(
        dev::parse_session_list(&overrun),
        Err(DeviceError::TruncatedList),
        "a count that overruns the records is a TruncatedList"
    );
}

/// The response frame's checksum is verified before parsing; a bad checksum
/// returns DeviceError::BadChecksum and no partial list is surfaced.
#[test]
fn test_bad_checksum_rejected() {
    let mut frame = synthetic_frame(&[synthetic_record(9, 2026, 6, 6, 6, 6, 6, 6, 6, "corrupt")]);

    // Flip a payload byte so the recorded trailer checksum no longer matches.
    let payload_start = dev::HEADER_MAGIC.len() + 6;
    frame[payload_start + 4] ^= 0xFF;

    let result = dev::parse_session_list(&frame);
    assert_eq!(
        result,
        Err(DeviceError::BadChecksum),
        "a mismatched checksum is rejected before parsing"
    );
    // And nothing partial leaks out — it is an Err, not an Ok with entries.
    assert!(result.is_err());
}

// ---- edge / coverage cases -------------------------------------------------

/// A response frame that carries no trailer at all is a TruncatedList (the
/// checksum could not even be read to verify it).
#[test]
fn test_missing_trailer_is_truncated() {
    // A valid header+payload but no `<STCP ...>` trailer.
    let mut buf = Vec::new();
    buf.extend_from_slice(dev::HEADER_MAGIC);
    buf.extend_from_slice(&4u32.to_le_bytes());
    buf.push(0);
    buf.push(b'>');
    buf.extend_from_slice(&0u32.to_le_bytes()); // count = 0
    assert_eq!(
        dev::parse_session_list(&buf),
        Err(DeviceError::TruncatedList)
    );
}

/// The device store being empty (count 0) is reported as an empty list even when
/// the payload carries trailing catalog/config bytes (as the real capture does).
#[test]
fn test_zero_count_ignores_trailing_catalog_bytes() {
    let mut payload = Vec::new();
    payload.extend_from_slice(&0u32.to_le_bytes()); // count = 0
    payload.extend_from_slice(b"<hiMST....idn....trailing device catalog records");
    let frame = frame_payload(&payload);
    assert!(dev::parse_session_list(&frame)
        .expect("count-0 parses")
        .is_empty());
}

/// A session name shorter than its 32-byte field is decoded without the trailing
/// NUL padding.
#[test]
fn test_name_trims_nul_padding() {
    let frame = synthetic_frame(&[synthetic_record(1, 2026, 1, 1, 0, 0, 0, 1, 1, "AM")]);
    let sessions = dev::parse_session_list(&frame).expect("parses");
    assert_eq!(sessions[0].name, "AM");
    assert!(!sessions[0].name.contains('\0'));
}

/// The two new DeviceError variants render distinct, non-empty messages.
#[test]
fn test_new_error_variants_display() {
    let bad = DeviceError::BadChecksum.to_string();
    let trunc = DeviceError::TruncatedList.to_string();
    assert!(!bad.is_empty());
    assert!(!trunc.is_empty());
    assert_ne!(bad, trunc);
    // and remain distinct from the 6.3 variants
    assert_ne!(bad, DeviceError::MalformedRecord.to_string());
}

/// The built request is a checksum-valid catalog command frame with the
/// documented command code at payload[8..12].
#[test]
fn test_built_request_is_a_valid_catalog_frame() {
    let request = dev::build_session_list_request();
    let (frame, _) = dev::parse_frame(&request).expect("frame parses");
    assert_eq!(frame.length, 64, "catalog command payload is 64 bytes");
    // command code lives at payload[8..12] (PROTOCOL.md §5)
    assert_eq!(&frame.payload[8..12], &[0x10, 0x00, 0x01, 0x00]);
    assert!(frame.checksum_valid());
}

/// A record that declares the session count but lacks the session magic is a
/// MalformedRecord (not silently skipped), never a panic.
#[test]
fn test_record_without_session_magic_is_malformed() {
    let mut record = [0u8; 56];
    record[0..3].copy_from_slice(b"idn"); // an identity record, not a session
    let mut payload = Vec::new();
    payload.extend_from_slice(&1u32.to_le_bytes()); // count claims one session...
    payload.extend_from_slice(&record); // ...but it is not a `ses` record
    let frame = frame_payload(&payload);
    assert_eq!(
        dev::parse_session_list(&frame),
        Err(DeviceError::MalformedRecord)
    );
}
