//! The client's command frames for the live download client (issue #179), and
//! the parse of the device's command echoes.
//!
//! Every exchange the AiM app runs over TCP 2000 is the same transaction
//! (`docs/device/PROTOCOL.md` §5–§6, observed in the #133 capture):
//!
//! ```text
//! client  command (64-byte payload: code, upload length, tag 0x0a01, path)
//! device  echo, tag 0x0a01 "send your upload"     (only when an upload follows)
//! client  upload: offset(u32)=0 + data
//! device  4-byte ack
//! device  echo, tag 0x0a09 "accepted"             (when there is no upload)
//! device  echo, tag 0x0a11: payload[16..20] = response length, [20..24] = stride
//! client  ACK(next offset) / device chunk(offset + data)  … until the length is covered
//! ```
//!
//! Every builder here reproduces a captured frame byte-for-byte; the fixtures in
//! `fixtures/device/client/` pin them. Only **read** commands are built: nothing
//! in this module can modify what the device stores. Clean-room,
//! interoperability-only (DMCA §1201(f); EU 2009/24/EC Art. 6).

use crate::error::DeviceError;
use crate::framing::encode_frame;
use crate::session::SessionDate;

/// A client command (and a device echo) carries a 64-byte payload.
pub const COMMAND_PAYLOAD_LEN: usize = 64;

/// The opcodes the live client sends, as the u32 LE at `payload[8..12]`.
pub mod opcode {
    /// Open the session: the client uploads its clock, the device answers with
    /// its identity and path table (`sessions/list_response.bin`).
    pub const SESSION_OPEN: u32 = 0x0001_0010;
    /// The three info reads the AiM app issues after opening, in order. Their
    /// replies are read and discarded; they are sent so the conversation matches
    /// the observed one.
    pub const INFO: [u32; 3] = [0x0002_0002, 0x0002_0008, 0x0002_0003];
    /// Read the download summary: a CSV with one row per stored session.
    pub const CATALOG: u32 = 0x0002_0024;
    /// Read one file by its on-device path (`1:/mem/a_0053.xrz`).
    pub const READ_FILE: u32 = 0x0004_0002;
    /// End the conversation. The device sends no reply.
    pub const CLOSE: u32 = 0x0000_0001;
}

/// The tags at `payload[24..28]` of a command and of the device's echoes.
pub mod tag {
    /// A client request; also the device's "send your upload" echo.
    pub const REQUEST: u32 = 0x0a01;
    /// The client's close command.
    pub const CLOSE: u32 = 0x0a00;
    /// The device accepted a command that carries no upload.
    pub const ACCEPTED: u32 = 0x0a09;
    /// The device's response header, declaring the response length.
    pub const RESPONSE_HEADER: u32 = 0x0a11;
}

const CODE_OFFSET: usize = 8;
const LENGTH_OFFSET: usize = 16;
const STRIDE_OFFSET: usize = 20;
const TAG_OFFSET: usize = 24;
const PATH_OFFSET: usize = 32;

/// The longest path a command carries: the field runs to the end of the payload
/// and keeps a terminating NUL.
pub const MAX_PATH_LEN: usize = COMMAND_PAYLOAD_LEN - PATH_OFFSET - 1;

/// The 64 bytes the session-open command uploads: the client's clock.
const CLOCK_UPLOAD_LEN: u32 = 64;
/// The session-open parameter at `payload[32..36]` (observed 2, meaning unknown).
const SESSION_OPEN_PARAM: u32 = 2;
/// Where the local and UTC times start inside the clock upload.
const LOCAL_TIME_OFFSET: usize = 8;
const UTC_TIME_OFFSET: usize = 40;

/// The client hello's payload (the device answers `… 06 09 …`).
const HELLO_PAYLOAD: [u8; 8] = [0, 0, 0, 0, 0x06, 0x08, 0, 0];
/// The bytes that identify the device's hello (`control/hello.bin`).
const DEVICE_HELLO_ID: [u8; 2] = [0x06, 0x09];

/// A device echo of a client command (`payload` is 64 bytes).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CommandEcho {
    /// The echoed opcode.
    pub code: u32,
    /// What the echo means: [`tag::REQUEST`], [`tag::ACCEPTED`] or
    /// [`tag::RESPONSE_HEADER`].
    pub tag: u32,
    /// For a response header, the length of the response that follows.
    pub length: u32,
    /// The chunk stride the device will use (observed `0xFFC0`).
    pub stride: u32,
}

/// The client hello that opens every connection (`client/hello_request.bin`).
#[must_use]
pub fn build_hello() -> Vec<u8> {
    encode_frame(&HELLO_PAYLOAD)
}

/// Is `payload` the device's hello (`control/hello.bin`)?
#[must_use]
pub fn is_device_hello(payload: &[u8]) -> bool {
    payload.len() == HELLO_PAYLOAD.len() && payload.get(4..6) == Some(&DEVICE_HELLO_ID[..])
}

/// The session-open command (opcode `0x0110`), announcing the 64-byte clock
/// upload — the same bytes as `control/command_info.bin`.
#[must_use]
pub fn build_session_open() -> Vec<u8> {
    let mut payload = command_payload(opcode::SESSION_OPEN, tag::REQUEST);
    put_u32(&mut payload, LENGTH_OFFSET, CLOCK_UPLOAD_LEN);
    put_u32(&mut payload, PATH_OFFSET, SESSION_OPEN_PARAM);
    encode_frame(&payload)
}

/// The clock upload that follows the session-open echo
/// (`client/clock_upload.bin`): a zero offset, then the local and the UTC time
/// as year, month, day, hour, minute, second (u32 LE each).
#[must_use]
pub fn build_clock_upload(local: &SessionDate, utc: &SessionDate) -> Vec<u8> {
    let mut data = [0u8; CLOCK_UPLOAD_LEN as usize];
    put_time(&mut data, LOCAL_TIME_OFFSET, local);
    put_time(&mut data, UTC_TIME_OFFSET, utc);
    build_upload(&data)
}

/// A command with no upload and no path: the info reads and the catalog read.
#[must_use]
pub fn build_read_request(code: u32) -> Vec<u8> {
    encode_frame(&command_payload(code, tag::REQUEST))
}

/// The catalog read (opcode `0x0224`, `client/catalog_request.bin`).
#[must_use]
pub fn build_catalog_request() -> Vec<u8> {
    build_read_request(opcode::CATALOG)
}

/// Read the file at `path` (opcode `0x0402`, `transfer/open_request.bin`).
///
/// # Errors
/// [`DeviceError::InvalidPath`] when `path` is empty, longer than
/// [`MAX_PATH_LEN`], or holds a NUL or a non-ASCII byte.
pub fn build_read_file(path: &str) -> Result<Vec<u8>, DeviceError> {
    let bytes = path.as_bytes();
    if bytes.is_empty()
        || bytes.len() > MAX_PATH_LEN
        || bytes.iter().any(|&b| b == 0 || !b.is_ascii())
    {
        return Err(DeviceError::InvalidPath);
    }
    let mut payload = command_payload(opcode::READ_FILE, tag::REQUEST);
    payload[PATH_OFFSET..PATH_OFFSET + bytes.len()].copy_from_slice(bytes);
    Ok(encode_frame(&payload))
}

/// The flow-control ACK asking for the chunk at `next_offset`
/// (`transfer/ack.bin`).
#[must_use]
pub fn build_ack(next_offset: u32) -> Vec<u8> {
    encode_frame(&next_offset.to_le_bytes())
}

/// The close command (opcode `0x0001`, `client/close_request.bin`).
#[must_use]
pub fn build_close() -> Vec<u8> {
    encode_frame(&command_payload(opcode::CLOSE, tag::CLOSE))
}

/// Parse a device echo from a verified frame's payload.
///
/// # Errors
/// [`DeviceError::UnexpectedResponse`] when the payload is not a 64-byte echo.
pub fn parse_echo(payload: &[u8]) -> Result<CommandEcho, DeviceError> {
    if payload.len() != COMMAND_PAYLOAD_LEN {
        return Err(DeviceError::UnexpectedResponse);
    }
    Ok(CommandEcho {
        code: get_u32(payload, CODE_OFFSET),
        tag: get_u32(payload, TAG_OFFSET),
        length: get_u32(payload, LENGTH_OFFSET),
        stride: get_u32(payload, STRIDE_OFFSET),
    })
}

/// A client upload frame: a zero offset, then `data`.
fn build_upload(data: &[u8]) -> Vec<u8> {
    let mut payload = Vec::with_capacity(4 + data.len());
    payload.extend_from_slice(&0u32.to_le_bytes());
    payload.extend_from_slice(data);
    encode_frame(&payload)
}

fn command_payload(code: u32, tag: u32) -> [u8; COMMAND_PAYLOAD_LEN] {
    let mut payload = [0u8; COMMAND_PAYLOAD_LEN];
    put_u32(&mut payload, CODE_OFFSET, code);
    put_u32(&mut payload, TAG_OFFSET, tag);
    payload
}

fn put_time(buf: &mut [u8], at: usize, time: &SessionDate) {
    let fields = [
        u32::from(time.year),
        u32::from(time.month),
        u32::from(time.day),
        u32::from(time.hour),
        u32::from(time.minute),
        u32::from(time.second),
    ];
    for (i, value) in fields.into_iter().enumerate() {
        put_u32(buf, at + i * 4, value);
    }
}

/// Write `value` LE at `at`. Every caller passes an offset inside a fixed-size
/// buffer, so the slice is always in bounds.
fn put_u32(buf: &mut [u8], at: usize, value: u32) {
    if let Some(slot) = buf.get_mut(at..at + 4) {
        slot.copy_from_slice(&value.to_le_bytes());
    }
}

/// Read a u32 LE at `at` of a payload already checked to be 64 bytes long.
fn get_u32(buf: &[u8], at: usize) -> u32 {
    buf.get(at..at + 4)
        .and_then(|b| <[u8; 4]>::try_from(b).ok())
        .map_or(0, u32::from_le_bytes)
}
