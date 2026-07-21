//! Executable acceptance tests for issue 6.6 — guarded session delete.
//!
//! Delete is a **destructive WRITE**. Every test drives the guarded API through a
//! spy [`DeleteTransport`] that records every byte "sent", so the refusal paths
//! assert **zero destructive bytes** reach the wire, and the happy path asserts
//! **exactly one** delete frame is sent and never retried.
//!
//! # What is verified vs hypothesized
//!
//! - **Verified:** the guard logic (arming + confirmation match ⇒ zero bytes on any
//!   refusal), the STCP request framing (§3), and that a non-ack response is a
//!   typed error that is never retried (no accidental double-delete).
//! - **Hypothesized:** the delete **opcode** (`payload[8..12]`) and the ack/reject
//!   **response shape** are not in any capture — the MyChron6 held 0 on-board
//!   sessions at 6.2 capture time, so no delete traffic was observed. The
//!   `delete/*.bin` fixtures are **synthetic**, frozen so `build_delete_request`
//!   is pinned byte-for-byte and a future real capture (issue #130) can be diffed
//!   against them. Clean-room, interoperability-only (DMCA §1201(f); EU
//!   2009/24/EC Art. 6).

use std::collections::VecDeque;
use std::path::PathBuf;

use racestudio_device::delete::{
    build_delete_request, delete_session, DeleteConfirmation, DeleteTransport,
};
use racestudio_device::{DeviceError, SessionDate, SessionInfo};

// ---- fixtures + fakes ------------------------------------------------------

fn device_fixture(rel: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../fixtures/device")
        .join(rel)
}

/// The session id/name frozen into the synthetic `delete/*.bin` fixtures.
const FIXTURE_SESSION_ID: u32 = 7;
const FIXTURE_SESSION_NAME: &str = "FIXTURE_SESSION";

/// A target session to delete, matching the fixtures' id (the display name is a
/// client-side guard only and is never sent on the wire).
fn target() -> SessionInfo {
    SessionInfo {
        id: FIXTURE_SESSION_ID,
        name: FIXTURE_SESSION_NAME.to_string(),
        date: SessionDate {
            year: 2026,
            month: 7,
            day: 21,
            hour: 10,
            minute: 30,
            second: 0,
        },
        lap_count: 12,
        size_bytes: 4_096,
    }
}

/// A confirmation that matches [`target`] exactly.
fn matching_confirmation() -> DeleteConfirmation {
    DeleteConfirmation {
        session_id: FIXTURE_SESSION_ID,
        expected_name: FIXTURE_SESSION_NAME.to_string(),
    }
}

/// A `DeleteTransport` spy: records every framed request handed to `send`, and
/// replays a queue of `recv` responses. `send` never fails here, so a refusal
/// that transmits nothing leaves `sent` empty.
#[derive(Default)]
struct SpyTransport {
    sent: Vec<Vec<u8>>,
    responses: VecDeque<Result<Vec<u8>, DeviceError>>,
}

impl SpyTransport {
    /// A spy that will answer the (single) delete request with `response`.
    fn answering(response: Result<Vec<u8>, DeviceError>) -> Self {
        let mut responses = VecDeque::new();
        responses.push_back(response);
        Self {
            sent: Vec::new(),
            responses,
        }
    }

    /// Total bytes handed to `send` — `0` proves nothing destructive was sent.
    fn bytes_sent(&self) -> usize {
        self.sent.iter().map(Vec::len).sum()
    }
}

impl DeleteTransport for SpyTransport {
    fn send(&mut self, frame: &[u8]) -> Result<(), DeviceError> {
        self.sent.push(frame.to_vec());
        Ok(())
    }

    fn recv(&mut self) -> Result<Vec<u8>, DeviceError> {
        self.responses
            .pop_front()
            .unwrap_or(Err(DeviceError::TruncatedList))
    }
}

fn ack_frame() -> Vec<u8> {
    std::fs::read(device_fixture("delete/ack.bin")).expect("read ack fixture")
}

fn reject_frame() -> Vec<u8> {
    std::fs::read(device_fixture("delete/reject.bin")).expect("read reject fixture")
}

/// Frame a delete response: payload = `status(u16 LE) || id(u32 LE)`, wrapped in a
/// checksum-valid STCP frame (the hypothesized 6.6 ack/reject shape).
fn response_frame(status: u16, id: u32) -> Vec<u8> {
    let mut payload = Vec::new();
    payload.extend_from_slice(&status.to_le_bytes());
    payload.extend_from_slice(&id.to_le_bytes());
    let mut frame = Vec::new();
    frame.extend_from_slice(b"<hSTCP");
    frame.extend_from_slice(&(payload.len() as u32).to_le_bytes());
    frame.push(0);
    frame.push(b'>');
    frame.extend_from_slice(&payload);
    frame.extend_from_slice(b"<STCP");
    frame.extend_from_slice(&racestudio_device::stcp_checksum(&payload).to_le_bytes());
    frame.push(b'>');
    frame
}

// ---- the eight named acceptance behaviours ---------------------------------

#[test]
fn test_matching_confirmation_sends_one_delete_frame() {
    let mut transport = SpyTransport::answering(Ok(ack_frame()));

    let result = delete_session(
        &target(),
        Some(&matching_confirmation()),
        true,
        &mut transport,
    );

    assert_eq!(result, Ok(()), "an armed, matching, acked delete succeeds");
    assert_eq!(transport.sent.len(), 1, "exactly one delete frame is sent");
    assert_eq!(
        transport.sent[0],
        build_delete_request(FIXTURE_SESSION_ID),
        "the sent frame is the delete request for the target id"
    );
}

#[test]
fn test_wrong_id_sends_zero_bytes() {
    let confirm = DeleteConfirmation {
        session_id: FIXTURE_SESSION_ID + 1, // wrong id
        expected_name: FIXTURE_SESSION_NAME.to_string(),
    };
    let mut transport = SpyTransport::answering(Ok(ack_frame()));

    let err = delete_session(&target(), Some(&confirm), true, &mut transport)
        .expect_err("a mismatched id must refuse");

    assert_eq!(err, DeviceError::ConfirmationMismatch);
    assert_eq!(transport.bytes_sent(), 0, "NO destructive bytes were sent");
}

#[test]
fn test_wrong_name_sends_zero_bytes() {
    let confirm = DeleteConfirmation {
        session_id: FIXTURE_SESSION_ID,
        expected_name: "NOT_THE_NAME".to_string(), // wrong name
    };
    let mut transport = SpyTransport::answering(Ok(ack_frame()));

    let err = delete_session(&target(), Some(&confirm), true, &mut transport)
        .expect_err("a mismatched name must refuse");

    assert_eq!(err, DeviceError::ConfirmationMismatch);
    assert_eq!(transport.bytes_sent(), 0, "NO destructive bytes were sent");
}

#[test]
fn test_missing_confirmation_refuses() {
    let mut transport = SpyTransport::answering(Ok(ack_frame()));

    // No confirmation at all — the default-safe refusal.
    let err = delete_session(&target(), None, true, &mut transport)
        .expect_err("a missing confirmation must refuse");

    assert_eq!(err, DeviceError::ConfirmationMismatch);
    assert_eq!(transport.bytes_sent(), 0, "NO destructive bytes were sent");
}

#[test]
fn test_not_armed_sends_zero_bytes() {
    let mut transport = SpyTransport::answering(Ok(ack_frame()));

    // A perfectly matching confirmation, but the belt-and-suspenders arm is off.
    let err = delete_session(
        &target(),
        Some(&matching_confirmation()),
        false,
        &mut transport,
    )
    .expect_err("an unarmed delete must refuse");

    assert_eq!(err, DeviceError::NotArmed);
    assert_eq!(transport.bytes_sent(), 0, "NO destructive bytes were sent");
}

#[test]
fn test_delete_reject_response_is_error() {
    let mut transport = SpyTransport::answering(Ok(reject_frame()));

    let err = delete_session(
        &target(),
        Some(&matching_confirmation()),
        true,
        &mut transport,
    )
    .expect_err("a device reject surfaces as a typed error");

    assert_eq!(err, DeviceError::DeleteRejected);
    // The request WAS sent (delete was attempted) but the device refused it.
    assert_eq!(transport.sent.len(), 1, "one attempt, then a typed error");
}

#[test]
fn test_no_blind_retry_on_error() {
    // The device answers the delete with a reject; the client must NOT resend
    // (a blind retry risks an accidental double-delete).
    let mut transport = SpyTransport::answering(Ok(reject_frame()));

    let _ = delete_session(
        &target(),
        Some(&matching_confirmation()),
        true,
        &mut transport,
    );

    assert_eq!(
        transport.sent.len(),
        1,
        "exactly one delete frame is ever sent — no blind retry"
    );
    assert!(
        transport.responses.is_empty(),
        "recv was consulted exactly once"
    );
}

#[test]
fn test_request_bytes_match_captured_fixture() {
    // The synthetic, frozen delete-request golden (issue #130 will replace it with
    // a real capture). Pins `build_delete_request` byte-for-byte.
    let fixture =
        std::fs::read(device_fixture("delete/request.bin")).expect("read request fixture");

    assert_eq!(
        build_delete_request(FIXTURE_SESSION_ID),
        fixture,
        "the built delete request matches the frozen fixture byte-for-byte"
    );
}

// ---- edge / negative cases -------------------------------------------------

#[test]
fn test_ack_for_a_different_session_is_rejected() {
    // A checksum-valid, status-OK ack that echoes a DIFFERENT session id must NOT
    // be treated as success — a stale/cross-talk ack can never confirm OUR delete.
    let wrong_id_ack = response_frame(0, FIXTURE_SESSION_ID + 1);
    let mut transport = SpyTransport::answering(Ok(wrong_id_ack));

    let err = delete_session(
        &target(),
        Some(&matching_confirmation()),
        true,
        &mut transport,
    )
    .expect_err("an ack for another session is not our success");

    assert_eq!(err, DeviceError::DeleteRejected);
    assert_eq!(transport.sent.len(), 1, "one attempt, then a typed error");
}

#[test]
fn test_not_armed_takes_precedence_over_mismatch() {
    // When BOTH guards would fail (not armed AND no confirmation), arming is checked
    // first — the outermost safety gate — so the error is NotArmed. Pins the guard
    // order against a refactor that swaps the two checks.
    let mut transport = SpyTransport::answering(Ok(ack_frame()));

    let err = delete_session(&target(), None, false, &mut transport)
        .expect_err("both guards fail; arming is checked first");

    assert_eq!(err, DeviceError::NotArmed);
    assert_eq!(transport.bytes_sent(), 0, "NO destructive bytes were sent");
}

#[test]
fn test_bad_checksum_response_is_error() {
    // A response whose trailer checksum does not verify is rejected before it is
    // ever trusted as an ack — never silently treated as success.
    let mut corrupt = ack_frame();
    let n = corrupt.len();
    corrupt[n - 2] ^= 0xFF; // flip the low checksum byte
    let mut transport = SpyTransport::answering(Ok(corrupt));

    let err = delete_session(
        &target(),
        Some(&matching_confirmation()),
        true,
        &mut transport,
    )
    .expect_err("an unverifiable response is not an ack");

    assert_eq!(err, DeviceError::BadChecksum);
    assert_eq!(
        transport.sent.len(),
        1,
        "one attempt; no retry on a bad ack"
    );
}

#[test]
fn test_transport_send_error_propagates_without_retry() {
    // If the transport itself fails to send, the error propagates and nothing is
    // resent (recv is never reached).
    struct FailingSend {
        attempts: usize,
    }
    impl DeleteTransport for FailingSend {
        fn send(&mut self, _frame: &[u8]) -> Result<(), DeviceError> {
            self.attempts += 1;
            Err(DeviceError::NoService)
        }
        fn recv(&mut self) -> Result<Vec<u8>, DeviceError> {
            panic!("recv must not be called after a failed send");
        }
    }

    let mut transport = FailingSend { attempts: 0 };
    let err = delete_session(
        &target(),
        Some(&matching_confirmation()),
        true,
        &mut transport,
    )
    .expect_err("a transport send failure propagates");

    assert_eq!(err, DeviceError::NoService);
    assert_eq!(transport.attempts, 1, "the send was attempted exactly once");
}

#[test]
fn test_transport_recv_error_propagates() {
    // A transport-level receive failure surfaces as its typed error, unretried.
    let mut transport = SpyTransport::answering(Err(DeviceError::TruncatedList));

    let err = delete_session(
        &target(),
        Some(&matching_confirmation()),
        true,
        &mut transport,
    )
    .expect_err("a recv failure propagates");

    assert_eq!(err, DeviceError::TruncatedList);
    assert_eq!(transport.sent.len(), 1, "one attempt, no retry");
}

#[test]
fn test_new_error_variants_display() {
    assert_eq!(
        DeviceError::ConfirmationMismatch.to_string(),
        "the delete confirmation does not match the target session"
    );
    assert_eq!(
        DeviceError::NotArmed.to_string(),
        "the delete was not armed; nothing was sent"
    );
    assert_eq!(
        DeviceError::DeleteRejected.to_string(),
        "the device rejected the delete request"
    );
}

#[test]
fn test_delete_golden_documents_the_request() {
    // The descriptive golden pins the request's documented fields; a live check
    // keeps it honest against `build_delete_request`.
    #[derive(serde::Deserialize)]
    struct Golden {
        synthetic: bool,
        session_id: u32,
        request_bytes: usize,
        request_checksum: u16,
    }
    let bytes = std::fs::read(device_fixture("golden/delete.json")).expect("read golden");
    let golden: Golden = serde_json::from_slice(&bytes).expect("golden parses");

    assert!(
        golden.synthetic,
        "the delete golden is honestly flagged synthetic"
    );
    let frame = build_delete_request(golden.session_id);
    assert_eq!(
        frame.len(),
        golden.request_bytes,
        "golden request byte length"
    );
    let verified = racestudio_device::verified_frame(&frame).expect("request verifies");
    assert_eq!(
        verified.checksum,
        Some(golden.request_checksum),
        "golden request checksum"
    );
}

#[test]
fn test_built_request_is_a_checksum_valid_frame_for_the_id() {
    // The built request is a well-formed, checksum-verifiable STCP frame carrying
    // the target id — regardless of the (hypothesized) opcode.
    let id = 42;
    let frame = build_delete_request(id);
    let verified = racestudio_device::verified_frame(&frame).expect("request frame verifies");
    // The target id is encoded little-endian at payload[12..16] (docs §7).
    let encoded = u32::from_le_bytes(verified.payload[12..16].try_into().expect("id field"));
    assert_eq!(encoded, id, "the request encodes the target session id");
}
