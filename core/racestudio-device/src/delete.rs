//! Guarded session delete (issue 6.6): a **destructive WRITE** behind an explicit
//! typed confirmation and layered safety guards, so nothing is ever deleted
//! unintentionally.
//!
//! [`delete_session`] refuses — transmitting **zero bytes** — unless *both* an
//! "armed" flag is set *and* a [`DeleteConfirmation`] matches the target session's
//! id **and** display name. Only then is exactly one delete frame built and sent;
//! a non-ack response is a typed error that is **never** blindly retried (a retry
//! risks an accidental double-delete). The transport is injected as
//! [`DeleteTransport`] so CI replays recorded/synthetic fixtures with no live
//! device.
//!
//! # What is verified vs hypothesized
//!
//! The STCP request framing (§3) and the guard logic are verified. The delete
//! **opcode** (`payload[8..12]`) and the ack/reject **response shape** are
//! **hypothesized**: the MyChron6 held 0 on-board sessions at 6.2 capture time, so
//! no delete traffic was observed (`docs/device/PROTOCOL.md` §7,
//! `fixtures/device/manifest.json` → `pending`). The `delete/*.bin` fixtures are
//! synthetic, frozen so `build_delete_request` is pinned byte-for-byte and a real
//! capture (issue #130) can be diffed against them. Clean-room,
//! interoperability-only (DMCA §1201(f); EU 2009/24/EC Art. 6).

use crate::error::DeviceError;
use crate::framing::{encode_frame, verified_frame};
use crate::session::SessionInfo;

/// A client command carries a 64-byte payload (`docs/device/PROTOCOL.md` §5).
const DELETE_REQUEST_PAYLOAD_LEN: usize = 64;
/// The command code sits at `payload[8..12]` (§5).
const COMMAND_CODE_OFFSET: usize = 8;
/// The target session id (u32 LE) is written immediately after the command code.
const ID_OFFSET: usize = 12;
/// The **hypothesized** delete command code (§7 — not yet captured; see issue
/// #130). Chosen not to collide with any observed command code; the guard logic
/// and framing around it are what 6.6 verifies, and a real capture will replace
/// this constant.
const DELETE_COMMAND_CODE: [u8; 4] = [0x04, 0x00, 0x02, 0x00];
/// The response payload's leading `u16` LE status word.
const STATUS_LEN: usize = 2;
/// The status value that means "the session was deleted" (any other value, or a
/// too-short payload, is a rejection).
const DELETE_STATUS_OK: u16 = 0;

/// An explicit, typed confirmation that a specific session is the one to delete.
///
/// Both fields must match the target [`SessionInfo`] exactly. The `expected_name`
/// is a **client-side** guard (the name the user saw/typed); it is compared
/// locally and is **never** transmitted — only the id is sent on the wire.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DeleteConfirmation {
    /// The device-local id the caller intends to delete.
    pub session_id: u32,
    /// The display name the caller expects that id to have.
    pub expected_name: String,
}

/// A request/response channel to the device for a delete exchange.
///
/// [`delete_session`] calls [`Self::send`] with the framed delete request exactly
/// once, then [`Self::recv`] once to read the ack/reject. The live TCP transport
/// (6.7's `NWConnection` adapter, not covered here) implements this; tests use a
/// spy that records every byte sent so a refusal can assert **zero** bytes.
pub trait DeleteTransport {
    /// Transmit one framed request to the device.
    ///
    /// # Errors
    /// Any transport-level failure surfaces as a [`DeviceError`]; the delete is
    /// abandoned (nothing is resent).
    fn send(&mut self, frame: &[u8]) -> Result<(), DeviceError>;

    /// Receive the device's response frame.
    ///
    /// # Errors
    /// Any transport-level failure surfaces as a [`DeviceError`].
    fn recv(&mut self) -> Result<Vec<u8>, DeviceError>;
}

/// Build the delete request frame for `session_id` — a 64-byte command payload
/// (delete opcode at `payload[8..12]`, the id at `payload[12..16]`, u32 LE)
/// wrapped in a checksum-valid STCP frame (`docs/device/PROTOCOL.md` §3 + §7).
///
/// The exact bytes are pinned by `test_request_bytes_match_captured_fixture`
/// against the frozen synthetic `fixtures/device/delete/request.bin` (issue #130
/// replaces it with a real capture).
#[must_use]
pub fn build_delete_request(session_id: u32) -> Vec<u8> {
    let mut payload = [0u8; DELETE_REQUEST_PAYLOAD_LEN];
    payload[COMMAND_CODE_OFFSET..COMMAND_CODE_OFFSET + DELETE_COMMAND_CODE.len()]
        .copy_from_slice(&DELETE_COMMAND_CODE);
    payload[ID_OFFSET..ID_OFFSET + 4].copy_from_slice(&session_id.to_le_bytes());
    encode_frame(&payload)
}

/// Delete `target` from the device — but only behind every safety guard.
///
/// The guards run **before any frame is built or byte is sent**, in order:
/// 1. `armed` must be `true` (the belt-and-suspenders arm), else
///    [`DeviceError::NotArmed`].
/// 2. `confirm` must be present and its `session_id` **and** `expected_name` must
///    match `target` exactly, else [`DeviceError::ConfirmationMismatch`].
///
/// Only once both pass is exactly one delete frame sent. The device's response is
/// interpreted as an ack (`Ok(())`) or a rejection; a non-ack is a typed error
/// and is **never** retried, so a failed delete can never become a double-delete.
///
/// # Errors
/// - [`DeviceError::NotArmed`] — not armed; nothing was sent.
/// - [`DeviceError::ConfirmationMismatch`] — missing or mismatched confirmation;
///   nothing was sent.
/// - [`DeviceError::DeleteRejected`] — the device answered with a non-ack status.
/// - [`DeviceError::BadChecksum`] / [`DeviceError::TruncatedList`] — the response
///   frame did not verify (propagated from [`verified_frame`]).
/// - Any [`DeviceError`] surfaced by the [`DeleteTransport`] (`send`/`recv`).
///
/// Never panics.
pub fn delete_session(
    target: &SessionInfo,
    confirm: Option<&DeleteConfirmation>,
    armed: bool,
    transport: &mut dyn DeleteTransport,
) -> Result<(), DeviceError> {
    // Guard 1 (outermost, cheapest): the belt-and-suspenders arm must be set.
    if !armed {
        return Err(DeviceError::NotArmed);
    }
    // Guard 2: an explicit confirmation must be present AND match the target
    // exactly — both the id (what is sent) and the name (what the user confirmed).
    let confirm = confirm.ok_or(DeviceError::ConfirmationMismatch)?;
    if confirm.session_id != target.id || confirm.expected_name != target.name {
        return Err(DeviceError::ConfirmationMismatch);
    }

    // Every guard passed: build and send exactly one delete frame for the id.
    let request = build_delete_request(target.id);
    transport.send(&request)?;

    // Interpret the response. A non-ack is a typed error and is NEVER retried.
    interpret_delete_response(&transport.recv()?, target.id)
}

/// Interpret a delete response: `Ok(())` only on a checksum-verified ack **that
/// names the target session**.
///
/// The response frame's trailer checksum is verified first (a mismatch is
/// [`DeviceError::BadChecksum`], an unframed/untrailered response
/// [`DeviceError::TruncatedList`]). Success requires *both* the leading `u16` LE
/// status to be [`DELETE_STATUS_OK`] *and* the echoed `u32` LE session id to equal
/// `expected_id` — so a stale or cross-talk ack for a *different* session (or a
/// payload too short to carry either field) is [`DeviceError::DeleteRejected`],
/// never a silent success. A delete is destructive: an ack must name OUR session.
fn interpret_delete_response(bytes: &[u8], expected_id: u32) -> Result<(), DeviceError> {
    let frame = verified_frame(bytes)?;
    let status = frame
        .payload
        .get(0..STATUS_LEN)
        .and_then(|b| <[u8; 2]>::try_from(b).ok())
        .map(u16::from_le_bytes);
    let echoed_id = frame
        .payload
        .get(STATUS_LEN..STATUS_LEN + 4)
        .and_then(|b| <[u8; 4]>::try_from(b).ok())
        .map(u32::from_le_bytes);
    match (status, echoed_id) {
        (Some(DELETE_STATUS_OK), Some(id)) if id == expected_id => Ok(()),
        _ => Err(DeviceError::DeleteRejected),
    }
}
