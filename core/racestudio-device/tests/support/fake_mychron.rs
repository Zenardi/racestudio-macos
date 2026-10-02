//! An in-process fake MyChron for the live-client tests (issue #179).
//!
//! It listens on a loopback TCP port and answers the conversation the AiM app
//! was observed to hold (`docs/device/PROTOCOL.md` §4–§6): the device hello,
//! the command echoes and response headers, and chunked responses paced by the
//! client's ACKs. The replies come from the committed fixtures — the de-identified
//! catalog CSV and the captured `a_0053.xrz` session stream — so a client that
//! completes a download here has spoken the recorded protocol. Every frame the
//! client sends is recorded, so tests can assert exactly what reached the
//! "device". [`Fault`] injects the failures a real link can produce.
//!
//! Shared by the device crate's tests and the FFI crate's (via `#[path]`).

#![allow(dead_code)]

use std::collections::HashMap;
use std::io::{Read, Write};
use std::net::{SocketAddr, TcpListener, TcpStream};
use std::path::PathBuf;
use std::thread::{self, JoinHandle};
use std::time::Duration;

use racestudio_device::{parse_frame, stcp_checksum};

/// The chunk stride the device uses (`0xFFC0`).
pub const STRIDE: usize = 0xFFC0;

const SESSION_OPEN: u32 = 0x0001_0010;
const INFO: [u32; 3] = [0x0002_0002, 0x0002_0008, 0x0002_0003];
const CATALOG: u32 = 0x0002_0024;
const READ_FILE: u32 = 0x0004_0002;
const CLOSE: u32 = 0x0000_0001;

const TAG_REQUEST: u32 = 0x0a01;
const TAG_ACCEPTED: u32 = 0x0a09;
const TAG_RESPONSE_HEADER: u32 = 0x0a11;

/// A failure the fake injects into the conversation.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Fault {
    /// Behave like the recorded device.
    None,
    /// Corrupt the first chunk of a file read once (its checksum no longer
    /// verifies); the client must ask for the same offset again.
    CorruptFirstChunk,
    /// Close the connection after sending this many file chunks.
    DropAfterChunks(usize),
    /// Before the first file chunk, hold the socket open without answering.
    StallBeforeChunk(Duration),
    /// Answer the client hello with something that is not the device hello.
    WrongHello,
    /// Echo the catalog command with a different opcode.
    WrongEcho,
}

/// A running fake device.
pub struct FakeMyChron {
    /// Where the fake listens.
    pub addr: SocketAddr,
    handle: JoinHandle<Vec<Vec<u8>>>,
}

impl FakeMyChron {
    /// A device holding the fixture catalog and the captured session, served
    /// under its captured name (`a_0053.xrz`) and as the catalog's newest entry
    /// (`a_0062.xrz`).
    pub fn start(fault: Fault) -> Self {
        let mut files = HashMap::new();
        files.insert("1:/mem/a_0053.xrz".to_string(), stored_session());
        files.insert("1:/mem/a_0062.xrz".to_string(), stored_session());
        Self::start_with(catalog_csv(), files, fault)
    }

    /// A device holding `catalog` and `files` (keyed by full on-device path).
    pub fn start_with(catalog: Vec<u8>, files: HashMap<String, Vec<u8>>, fault: Fault) -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind loopback");
        let addr = listener.local_addr().expect("local addr");
        let handle = thread::spawn(move || {
            let (stream, _) = listener.accept().expect("accept");
            stream
                .set_read_timeout(Some(Duration::from_secs(10)))
                .expect("read timeout");
            let mut device = Conversation {
                stream,
                log: Vec::new(),
                fault,
                catalog,
                files,
            };
            device.run();
            device.log
        });
        FakeMyChron { addr, handle }
    }

    /// Wait for the conversation to end; return every payload the client sent.
    pub fn client_payloads(self) -> Vec<Vec<u8>> {
        self.handle.join().expect("fake device thread")
    }
}

/// The opcode of a 64-byte client command payload.
pub fn opcode_of(payload: &[u8]) -> Option<u32> {
    (payload.len() == 64).then(|| u32_at(payload, 8))
}

/// The fixtures directory, valid from any crate under `core/`.
pub fn fixtures_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../fixtures/device")
}

/// Read a fixture file.
pub fn fixture(rel: &str) -> Vec<u8> {
    std::fs::read(fixtures_dir().join(rel)).unwrap_or_else(|e| panic!("fixture {rel}: {e}"))
}

/// The de-identified catalog CSV (the data inside `client/catalog_response.bin`).
pub fn catalog_csv() -> Vec<u8> {
    payload_of(&fixture("client/catalog_response.bin"))[4..].to_vec()
}

/// The captured session as stored on the device (zlib-compressed `.xrz`),
/// reassembled from `transfer/session_stream.bin`.
pub fn stored_session() -> Vec<u8> {
    let stream = fixture("transfer/session_stream.bin");
    let mut rest = &stream[..];
    let mut out = Vec::new();
    while let Some((frame, used)) = parse_frame(rest) {
        out.extend_from_slice(&frame.payload[4..]);
        rest = &rest[used..];
    }
    out
}

/// The `.xrk` the captured session inflates to.
pub fn golden_xrk() -> Vec<u8> {
    fixture("golden/transfer_reassembled.xrk")
}

/// Wrap `payload` in an STCP frame.
pub fn frame(payload: &[u8]) -> Vec<u8> {
    let mut out = b"<hSTCP".to_vec();
    out.extend_from_slice(&(payload.len() as u32).to_le_bytes());
    out.extend_from_slice(&[0, b'>']);
    out.extend_from_slice(payload);
    out.extend_from_slice(b"<STCP");
    out.extend_from_slice(&stcp_checksum(payload).to_le_bytes());
    out.push(b'>');
    out
}

fn payload_of(raw: &[u8]) -> Vec<u8> {
    parse_frame(raw).expect("fixture frame").0.payload.to_vec()
}

fn u32_at(buf: &[u8], at: usize) -> u32 {
    u32::from_le_bytes(buf[at..at + 4].try_into().expect("4 bytes"))
}

fn echo(code: u32, tag: u32, length: u32) -> Vec<u8> {
    let mut payload = [0u8; 64];
    payload[8..12].copy_from_slice(&code.to_le_bytes());
    payload[16..20].copy_from_slice(&length.to_le_bytes());
    payload[20..24].copy_from_slice(&(STRIDE as u32).to_le_bytes());
    payload[24..28].copy_from_slice(&tag.to_le_bytes());
    frame(&payload)
}

struct Conversation {
    stream: TcpStream,
    log: Vec<Vec<u8>>,
    fault: Fault,
    catalog: Vec<u8>,
    files: HashMap<String, Vec<u8>>,
}

impl Conversation {
    fn run(&mut self) {
        let _ = self.converse();
    }

    /// `None` ends the conversation (the client left, or a fault fired).
    fn converse(&mut self) -> Option<()> {
        self.read()?;
        let hello = if self.fault == Fault::WrongHello {
            frame(&[0, 0, 0, 0, 0x06, 0x07, 0, 0])
        } else {
            fixture("control/hello.bin")
        };
        self.send(&hello)?;
        loop {
            let command = self.read()?;
            let code = opcode_of(&command)?;
            match code {
                CLOSE => return Some(()),
                SESSION_OPEN => {
                    self.send(&echo(code, TAG_REQUEST, 0))?;
                    self.read()?; // the clock upload
                    self.send(&frame(&0u32.to_le_bytes()))?;
                    let identity = payload_of(&fixture("sessions/list_response.bin"))[4..].to_vec();
                    self.serve(code, &identity, false)?;
                }
                c if INFO.contains(&c) => {
                    self.send(&echo(code, TAG_ACCEPTED, 0))?;
                    self.serve(code, &[0x5a; 100], false)?;
                }
                CATALOG => {
                    let echoed = if self.fault == Fault::WrongEcho {
                        code + 1
                    } else {
                        code
                    };
                    self.send(&echo(echoed, TAG_ACCEPTED, 0))?;
                    let catalog = self.catalog.clone();
                    self.serve(code, &catalog, false)?;
                }
                READ_FILE => {
                    let path_bytes = &command[32..];
                    let end = path_bytes
                        .iter()
                        .position(|&b| b == 0)
                        .unwrap_or(path_bytes.len());
                    let path = String::from_utf8_lossy(&path_bytes[..end]).into_owned();
                    let data = self.files.get(&path)?.clone();
                    self.send(&echo(code, TAG_ACCEPTED, 0))?;
                    self.serve(code, &data, true)?;
                }
                _ => return None,
            }
        }
    }

    /// Send the response header, then one chunk per client ACK until `data`
    /// is covered.
    fn serve(&mut self, code: u32, data: &[u8], is_file: bool) -> Option<()> {
        self.send(&echo(code, TAG_RESPONSE_HEADER, data.len() as u32))?;
        if data.is_empty() {
            return Some(());
        }
        let mut sent = 0usize;
        let mut corrupted = false;
        loop {
            let ack = self.read()?;
            if ack.len() != 4 {
                return None;
            }
            let offset = u32_at(&ack, 0) as usize;
            if is_file {
                match self.fault {
                    Fault::StallBeforeChunk(pause) if sent == 0 => {
                        thread::sleep(pause);
                        return None;
                    }
                    Fault::DropAfterChunks(n) if sent == n => return None,
                    _ => {}
                }
            }
            let end = (offset + STRIDE).min(data.len());
            let mut payload = (offset as u32).to_le_bytes().to_vec();
            payload.extend_from_slice(data.get(offset..end)?);
            let mut chunk = frame(&payload);
            let corrupt_now = is_file && self.fault == Fault::CorruptFirstChunk && !corrupted;
            if corrupt_now {
                chunk[12 + 4] ^= 0xFF; // first data byte; the trailer no longer matches
                corrupted = true;
            }
            self.send(&chunk)?;
            sent += 1;
            if end == data.len() && !corrupt_now {
                return Some(());
            }
        }
    }

    fn read(&mut self) -> Option<Vec<u8>> {
        let mut header = [0u8; 12];
        self.stream.read_exact(&mut header).ok()?;
        let len = u32_at(&header, 6) as usize;
        let mut rest = vec![0u8; len + 8];
        self.stream.read_exact(&mut rest).ok()?;
        let payload = rest[..len].to_vec();
        self.log.push(payload.clone());
        Some(payload)
    }

    fn send(&mut self, bytes: &[u8]) -> Option<()> {
        self.stream.write_all(bytes).ok()
    }
}
