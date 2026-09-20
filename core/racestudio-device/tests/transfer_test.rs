//! Executable acceptance tests for issue 6.5 — chunked session download.
//!
//! # What is verified vs hypothesized
//!
//! Issue #133 replaced the synthetic multi-chunk stream with a **real,
//! session-present capture**, so the stream protocol is now observed rather than
//! assumed:
//!
//! - **Verified wire anchor:** `fixtures/device/transfer/chunk.bin` is a *real*,
//!   checksum-observed device download chunk. `test_recorded_device_chunk_frames_and_verifies`
//!   drives it through the same framing the reassembler uses and asserts its
//!   declared offset (65472) and observed checksum (57932).
//! - **Verified multi-chunk stream:** `transfer/session_stream.bin` is a whole
//!   captured session download — three full 65472-byte chunks plus a short final
//!   chunk. It reassembles to the device-stored `.xrz`, which **zlib-inflates**
//!   to the `.xrk` golden and decodes via `racestudio-decode`. The device's
//!   identity word was scrubbed from the session before re-framing (see the
//!   manifest), so the payload bytes are de-identified; every *protocol* field
//!   (framing, stride, offsets, short-final end-of-stream) is verbatim.
//! - **Verified request/response fields:** the open request, its two responses,
//!   and the ACK are committed frames; the declared total length and the 65472
//!   stride are read out of the captured transfer header.
//! - **Still hypothesized:** the **retry / re-request** handshake. The captured
//!   transfer was error-free (no chunk ever failed its checksum), so recovery
//!   behaviour could not be observed and remains exercised against synthetic
//!   streams built in-test — as do out-of-order and duplicate delivery, which the
//!   device never exhibited. Clean-room, interoperability-only
//!   (DMCA §1201(f); EU 2009/24/EC Art. 6).

use std::collections::VecDeque;
use std::path::PathBuf;

use racestudio_device::transfer::{
    download_session, inflate_session, DownloadPlan, ProgressSink, Transport, MAX_CHUNK_RETRIES,
};
use racestudio_device::{parse_frame, stcp_checksum, DeviceError};

// ---- fixture access --------------------------------------------------------

fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..")
}

fn device_fixture(rel: &str) -> PathBuf {
    repo_root().join("fixtures/device").join(rel)
}

// ---- frame + transport helpers ---------------------------------------------

/// Frame one download chunk exactly as the device does (`docs/device/PROTOCOL.md`
/// §3 + §6): payload = `offset(u32 LE) || data`, wrapped in an STCP frame with a
/// valid trailer checksum.
fn chunk_frame(offset: u32, data: &[u8]) -> Vec<u8> {
    let mut payload = Vec::with_capacity(4 + data.len());
    payload.extend_from_slice(&offset.to_le_bytes());
    payload.extend_from_slice(data);

    let mut buf = Vec::new();
    buf.extend_from_slice(b"<hSTCP");
    buf.extend_from_slice(&(payload.len() as u32).to_le_bytes());
    buf.push(0); // flag
    buf.push(b'>');
    buf.extend_from_slice(&payload);
    buf.extend_from_slice(b"<STCP");
    buf.extend_from_slice(&stcp_checksum(&payload).to_le_bytes());
    buf.push(b'>');
    buf
}

/// Split `bytes` into consecutive framed chunks of at most `chunk_len` data bytes.
fn split_into_frames(bytes: &[u8], chunk_len: usize) -> Vec<Vec<u8>> {
    bytes
        .chunks(chunk_len)
        .enumerate()
        .map(|(i, data)| chunk_frame((i * chunk_len) as u32, data))
        .collect()
}

/// Corrupt a framed chunk's trailer checksum so it fails verification.
fn corrupt_checksum(frame: &[u8]) -> Vec<u8> {
    let mut bad = frame.to_vec();
    let n = bad.len();
    bad[n - 2] ^= 0xFF; // flip the low checksum byte
    bad
}

/// A `Transport` test double: replays a queue of pre-framed chunk results,
/// then signals end-of-stream with `Ok(None)`.
struct RecordedTransport {
    queue: VecDeque<Vec<u8>>,
}

impl RecordedTransport {
    fn new(frames: Vec<Vec<u8>>) -> Self {
        Self {
            queue: frames.into(),
        }
    }
}

impl Transport for RecordedTransport {
    fn next_chunk(&mut self) -> Result<Option<Vec<u8>>, DeviceError> {
        Ok(self.queue.pop_front())
    }
}

/// A `ProgressSink` that records every `(bytes_done, total)` it is handed.
#[derive(Default)]
struct CollectingProgress {
    events: Vec<(u64, u64)>,
}

impl ProgressSink for CollectingProgress {
    fn on_progress(&mut self, bytes_done: u64, total: u64) {
        self.events.push((bytes_done, total));
    }
}

fn plan_for(bytes: &[u8], session_id: u32) -> DownloadPlan {
    DownloadPlan {
        session_id,
        total_len: bytes.len() as u64,
        whole_file_checksum: stcp_checksum(bytes),
    }
}

// ---- the real captured session download (issue #133) -----------------------

/// The device's chunk-data stride, observed in every full chunk of the capture.
const CHUNK_STRIDE: usize = 65_472;

/// The total length the captured transfer header declares for the session file,
/// and which the reassembled `.xrz` must cover exactly.
const DECLARED_LEN: u64 = 210_158;

/// The STCP checksum over the whole reassembled `.xrz`. The protocol does **not**
/// carry this on the wire (see `docs/device/PROTOCOL.md` §6), so it is pinned here
/// as an observed property of the fixture rather than read from a device field.
const XRZ_CHECKSUM: u16 = 29_097;

/// The on-device path the capture requested, carried verbatim in the open request.
const SESSION_PATH: &[u8] = b"1:/mem/a_0053.xrz";

fn transfer_fixture(rel: &str) -> Vec<u8> {
    std::fs::read(device_fixture(rel)).unwrap_or_else(|e| panic!("fixture {rel} must exist: {e}"))
}

/// Replays a recorded stream of concatenated STCP frames one frame at a time —
/// exactly the byte sequence the device wrote during the capture.
struct CapturedStream {
    bytes: Vec<u8>,
    pos: usize,
}

impl CapturedStream {
    fn new(bytes: Vec<u8>) -> Self {
        Self { bytes, pos: 0 }
    }
}

impl Transport for CapturedStream {
    fn next_chunk(&mut self) -> Result<Option<Vec<u8>>, DeviceError> {
        if self.pos >= self.bytes.len() {
            return Ok(None);
        }
        let (_, consumed) =
            parse_frame(&self.bytes[self.pos..]).ok_or(DeviceError::TruncatedList)?;
        let frame = self.bytes[self.pos..self.pos + consumed].to_vec();
        self.pos += consumed;
        Ok(Some(frame))
    }
}

/// The plan a caller builds from the captured transfer header: the declared total
/// length comes off the wire; the whole-file checksum does not (§6) and is supplied
/// by the caller.
fn captured_plan() -> DownloadPlan {
    DownloadPlan {
        session_id: 53,
        total_len: DECLARED_LEN,
        whole_file_checksum: XRZ_CHECKSUM,
    }
}

/// Replaying the real captured stream reassembles the session byte-for-byte into
/// the `.xrz` the device holds — the multi-chunk protocol, no longer hypothesized.
#[test]
fn test_real_capture_reassembles_byte_exact() {
    let mut transport = CapturedStream::new(transfer_fixture("transfer/session_stream.bin"));
    let mut progress = CollectingProgress::default();

    let out = download_session(&captured_plan(), &mut transport, &mut progress)
        .expect("the captured stream reassembles");

    assert_eq!(out.len() as u64, DECLARED_LEN, "covers the declared length");
    assert_eq!(stcp_checksum(&out), XRZ_CHECKSUM, "whole-file checksum");
    assert!(
        out.starts_with(&[0x78, 0x01]),
        "the device stores sessions zlib-compressed"
    );
    assert_eq!(
        progress.events.last().copied(),
        Some((DECLARED_LEN, DECLARED_LEN)),
        "progress reaches 100%"
    );
}

/// The reassembled `.xrz` inflates to the committed `.xrk` golden and decodes —
/// the end-to-end proof that a real device download yields a usable session.
#[test]
fn test_real_capture_inflates_and_decodes_to_golden() {
    let mut transport = CapturedStream::new(transfer_fixture("transfer/session_stream.bin"));
    let mut progress = CollectingProgress::default();
    let compressed = download_session(&captured_plan(), &mut transport, &mut progress)
        .expect("the captured stream reassembles");

    let inflated = inflate_session(&compressed).expect("the session inflates");

    let golden = transfer_fixture("golden/transfer_reassembled.xrk");
    assert_eq!(
        inflated, golden,
        "inflates to the committed golden byte-for-byte"
    );

    // Decode the inflated bytes (via a temp file, since decode_session reads a
    // path) — proof the download is a valid session, not just byte-equal.
    let tmp = std::env::temp_dir().join(format!(
        "rs_device_transfer_{}_capture.xrk",
        std::process::id()
    ));
    std::fs::write(&tmp, &inflated).expect("write temp");
    let session = racestudio_decode::decode_session(&tmp).expect("the download decodes");
    let _ = std::fs::remove_file(&tmp);

    let meta = session.metadata();
    assert_eq!(meta.track, "S.Marino AR", "golden: track");
    assert_eq!(meta.datetime_utc, 1_751_802_697, "golden: datetime");
    assert_eq!(session.channels().len(), 26, "golden: channel count");
}

/// The captured transfer header is where a caller learns the file's size and the
/// chunk stride — the on-wire source of `DownloadPlan::total_len`.
#[test]
fn test_observed_transfer_header_declares_total_len_and_stride() {
    let bytes = transfer_fixture("transfer/length_response.bin");
    let (frame, consumed) = parse_frame(&bytes).expect("frame parses");
    assert_eq!(consumed, bytes.len(), "the fixture is exactly one frame");
    assert!(frame.checksum_valid());

    let p = frame.payload;
    assert_eq!(
        &p[8..12],
        &[0x02, 0x00, 0x04, 0x00],
        "read-file opcode 0x0402"
    );
    assert_eq!(
        u32::from_le_bytes(p[16..20].try_into().unwrap()) as u64,
        DECLARED_LEN,
        "payload[16..20] declares the file's total length"
    );
    assert_eq!(
        u32::from_le_bytes(p[20..24].try_into().unwrap()) as usize,
        CHUNK_STRIDE,
        "payload[20..24] declares the 0xFFC0 chunk stride"
    );
    assert_eq!(
        u32::from_le_bytes(p[24..28].try_into().unwrap()),
        0x0a11,
        "tag 0x0a11 marks the transfer header (0x0a09 is the open ack)"
    );
    assert!(
        p[32..].starts_with(SESSION_PATH),
        "the header echoes the requested path"
    );
}

/// The open request names the file to download; its ack echoes it with no length.
#[test]
fn test_observed_open_request_names_the_session_file() {
    let req = transfer_fixture("transfer/open_request.bin");
    let (frame, _) = parse_frame(&req).expect("frame parses");
    assert!(frame.checksum_valid());
    assert_eq!(&frame.payload[8..12], &[0x02, 0x00, 0x04, 0x00]);
    assert!(frame.payload[32..].starts_with(SESSION_PATH));

    let ack = transfer_fixture("transfer/open_ack.bin");
    let (frame, _) = parse_frame(&ack).expect("frame parses");
    assert!(frame.checksum_valid());
    assert_eq!(
        u32::from_le_bytes(frame.payload[24..28].try_into().unwrap()),
        0x0a09,
        "the open ack is tagged 0x0a09"
    );
    assert_eq!(
        u32::from_le_bytes(frame.payload[16..20].try_into().unwrap()),
        0,
        "the open ack declares no length — the header that follows does"
    );
}

/// Flow control: the client ACKs each chunk with the **next** offset it wants.
#[test]
fn test_observed_ack_carries_the_next_chunk_offset() {
    let bytes = transfer_fixture("transfer/ack.bin");
    let (frame, consumed) = parse_frame(&bytes).expect("frame parses");
    assert_eq!(consumed, bytes.len());
    assert!(frame.checksum_valid());
    assert_eq!(frame.payload.len(), 4, "an ACK is a bare u32 LE offset");
    assert_eq!(
        u32::from_le_bytes(frame.payload.try_into().unwrap()) as usize,
        CHUNK_STRIDE,
        "the observed ACK requests the second chunk"
    );
}

/// End-of-stream is signalled by a **short** final chunk, not a terminator frame:
/// full chunks run at the stride until one arrives with fewer data bytes.
#[test]
fn test_short_final_chunk_signals_end_of_stream() {
    let stream = transfer_fixture("transfer/session_stream.bin");
    let mut pos = 0;
    let mut lens = Vec::new();
    let mut offsets = Vec::new();
    while pos < stream.len() {
        let (frame, consumed) = parse_frame(&stream[pos..]).expect("frame parses");
        assert!(frame.checksum_valid(), "every captured chunk verifies");
        let offset = racestudio_device::transfer_chunk_offset(frame.payload).expect("offset");
        let data = racestudio_device::transfer_chunk_data(frame.payload).expect("data");
        offsets.push(offset as usize);
        lens.push(data.len());
        pos += consumed;
    }

    assert_eq!(lens, vec![CHUNK_STRIDE, CHUNK_STRIDE, CHUNK_STRIDE, 13_742]);
    assert_eq!(
        offsets,
        vec![0, CHUNK_STRIDE, 2 * CHUNK_STRIDE, 3 * CHUNK_STRIDE]
    );
    assert!(
        lens.last().is_some_and(|&n| n < CHUNK_STRIDE),
        "the final chunk is short — that is the end-of-stream signal"
    );
    assert_eq!(
        lens.iter().sum::<usize>() as u64,
        DECLARED_LEN,
        "the chunks cover exactly the declared length"
    );
}

// ---- the session container (zlib) ------------------------------------------

/// A session served by the device is zlib-compressed; inflating it yields the
/// `.xrk` container `racestudio-decode` reads.
#[test]
fn test_inflate_session_unwraps_a_compressed_session() {
    let compressed = {
        let mut t = CapturedStream::new(transfer_fixture("transfer/session_stream.bin"));
        let mut p = CollectingProgress::default();
        download_session(&captured_plan(), &mut t, &mut p).expect("reassembles")
    };
    let out = inflate_session(&compressed).expect("inflates");
    assert!(out.starts_with(b"<hCNF"), "an .xrk container header");
    assert!(out.len() > compressed.len(), "inflating grows the payload");
}

/// Not every file the device serves is compressed — the track/config files are
/// stored plain, so an already-uncompressed payload passes through untouched.
#[test]
fn test_inflate_session_passes_through_uncompressed_payloads() {
    // The observed `0:/tkk/al.ria` track file begins with this plain ASCII header.
    let plain = b"106 ACW\x00\x00\x00\x00 track data".to_vec();
    assert_eq!(
        inflate_session(&plain).expect("plain payload passes through"),
        plain
    );
    // An empty payload is not a compressed stream either, and must not error.
    assert_eq!(
        inflate_session(&[]).expect("empty passes through"),
        Vec::<u8>::new()
    );
}

/// A payload that claims to be compressed but is corrupt is a typed error, never
/// a partial or silently-empty session.
#[test]
fn test_inflate_session_rejects_a_corrupt_archive() {
    let mut corrupt = transfer_fixture("transfer/session_stream.bin")[12..2048].to_vec();
    corrupt[0] = 0x78; // a zlib header...
    corrupt[1] = 0x01; // ...over bytes that are not a valid deflate stream
    assert_eq!(
        inflate_session(&corrupt),
        Err(DeviceError::CorruptArchive),
        "a corrupt archive is typed, not silently truncated"
    );
}

/// A crafted archive that would inflate orders of magnitude past its compressed
/// size is refused before it can exhaust memory.
#[test]
fn test_inflate_session_refuses_a_decompression_bomb() {
    use std::io::Write;
    // ~2 MiB of zeros compresses to a couple of KiB — a ratio far past the guard,
    // while staying small enough to build and reject in milliseconds.
    let mut enc = flate2::write::ZlibEncoder::new(Vec::new(), flate2::Compression::best());
    enc.write_all(&vec![0u8; 2 * 1024 * 1024]).expect("encode");
    let bomb = enc.finish().expect("finish");
    assert!(
        bomb.len() * 128 < 2 * 1024 * 1024,
        "the fixture really does exceed the allowance"
    );

    assert_eq!(
        inflate_session(&bomb),
        Err(DeviceError::CorruptArchive),
        "an implausible inflation ratio is refused"
    );
}

// ---- synthetic streams: delivery faults the capture never exhibited ---------

#[test]
fn test_out_of_order_chunks_reassemble() {
    let payload: Vec<u8> = (0..300u32).map(|i| (i % 251) as u8).collect();
    let mut frames = split_into_frames(&payload, 100); // 3 chunks
    frames.swap(0, 2); // deliver chunk 2 first, then 1, then 0
    let mut transport = RecordedTransport::new(frames);
    let mut progress = CollectingProgress::default();

    let out = download_session(&plan_for(&payload, 1), &mut transport, &mut progress)
        .expect("out-of-order chunks still reassemble");

    assert_eq!(
        out, payload,
        "placement is by declared offset, not arrival order"
    );
}

#[test]
fn test_chunk_checksum_failure_triggers_retry() {
    let payload: Vec<u8> = (0..64u8).collect();
    let good = chunk_frame(0, &payload);
    // The device re-sends the chunk after a corrupt delivery; the download retries.
    let frames = vec![corrupt_checksum(&good), good.clone()];
    let mut transport = RecordedTransport::new(frames);
    let mut progress = CollectingProgress::default();

    let out = download_session(&plan_for(&payload, 7), &mut transport, &mut progress)
        .expect("a re-requested good chunk recovers the download");

    assert_eq!(out, payload);
}

#[test]
fn test_unrecoverable_mismatch_returns_error() {
    let payload: Vec<u8> = (0..64u8).collect();
    let good = chunk_frame(0, &payload);
    // Every delivery is corrupt, past the retry budget → unrecoverable.
    let frames = (0..=MAX_CHUNK_RETRIES)
        .map(|_| corrupt_checksum(&good))
        .collect();
    let mut transport = RecordedTransport::new(frames);
    let mut progress = CollectingProgress::default();

    let err = download_session(&plan_for(&payload, 7), &mut transport, &mut progress)
        .expect_err("a persistent bad checksum is unrecoverable");

    assert_eq!(err, DeviceError::ChecksumMismatch);
}

#[test]
fn test_progress_callback_reports_monotonic_bytes() {
    let payload: Vec<u8> = (0..500u32).map(|i| i as u8).collect();
    let frames = split_into_frames(&payload, 100); // 5 chunks
    let mut transport = RecordedTransport::new(frames);
    let mut progress = CollectingProgress::default();

    download_session(&plan_for(&payload, 1), &mut transport, &mut progress).expect("download");

    assert!(!progress.events.is_empty(), "progress is reported");
    let total = payload.len() as u64;
    let mut last = 0u64;
    for (done, reported_total) in &progress.events {
        assert_eq!(*reported_total, total, "total is stable");
        assert!(*done >= last, "bytes done never decreases");
        assert!(*done <= total, "bytes done never exceeds total");
        last = *done;
    }
    assert_eq!(last, total, "final progress reaches 100%");
}

#[test]
fn test_missing_final_chunk_is_error() {
    let payload: Vec<u8> = (0..300u32).map(|i| i as u8).collect();
    let mut frames = split_into_frames(&payload, 100); // 3 chunks
    frames.pop(); // drop the final chunk → a gap at the end
    let mut transport = RecordedTransport::new(frames);
    let mut progress = CollectingProgress::default();

    let err = download_session(&plan_for(&payload, 1), &mut transport, &mut progress)
        .expect_err("a missing chunk is an error, not a truncated success");

    assert_eq!(err, DeviceError::MissingChunk);
}

// ---- verified real-chunk anchor + edge cases -------------------------------

#[test]
fn test_recorded_device_chunk_frames_and_verifies() {
    // The one real captured chunk must be a valid STCP frame whose payload begins
    // with the documented u32 LE offset (65472) and whose trailer checksum (57932)
    // verifies — the wire format the reassembler is built on.
    let bytes = std::fs::read(device_fixture("transfer/chunk.bin")).expect("read chunk");
    let frame = racestudio_device::verified_frame(&bytes).expect("real chunk verifies");
    assert_eq!(frame.checksum, Some(57932), "observed checksum");
    let offset = u32::from_le_bytes(frame.payload[0..4].try_into().expect("4-byte offset"));
    assert_eq!(offset, 65472, "documented chunk offset field");
    assert_eq!(
        frame.payload.len() - 4,
        65472,
        "documented chunk data length"
    );
}

#[test]
fn test_duplicate_chunks_are_idempotent() {
    let payload: Vec<u8> = (0..200u32).map(|i| i as u8).collect();
    let mut frames = split_into_frames(&payload, 100); // 2 chunks
    frames.insert(1, frames[0].clone()); // deliver chunk 0 twice
    let mut transport = RecordedTransport::new(frames);
    let mut progress = CollectingProgress::default();

    let out = download_session(&plan_for(&payload, 1), &mut transport, &mut progress)
        .expect("a duplicate chunk is absorbed, not corrupting the output");

    assert_eq!(out, payload);
}

#[test]
fn test_whole_file_checksum_mismatch_is_error() {
    let payload: Vec<u8> = (0..200u32).map(|i| i as u8).collect();
    let frames = split_into_frames(&payload, 100);
    let mut transport = RecordedTransport::new(frames);
    let mut progress = CollectingProgress::default();

    // Plan declares a whole-file checksum that will not match the reassembled bytes.
    let plan = DownloadPlan {
        session_id: 1,
        total_len: payload.len() as u64,
        whole_file_checksum: stcp_checksum(&payload).wrapping_add(1),
    };
    let err = download_session(&plan, &mut transport, &mut progress)
        .expect_err("a whole-file checksum mismatch fails the download");

    assert_eq!(err, DeviceError::ChecksumMismatch);
}

#[test]
fn test_chunk_overrunning_total_len_is_malformed() {
    let payload: Vec<u8> = (0..100u8).collect();
    // A chunk whose declared offset+len exceeds the planned total is malformed.
    let frames = vec![chunk_frame(0, &payload)];
    let mut transport = RecordedTransport::new(frames);
    let mut progress = CollectingProgress::default();

    let plan = DownloadPlan {
        session_id: 1,
        total_len: 50, // shorter than the chunk claims to fill
        whole_file_checksum: 0,
    };
    let err = download_session(&plan, &mut transport, &mut progress)
        .expect_err("a chunk that overruns the declared size is rejected");

    assert_eq!(err, DeviceError::MalformedRecord);
}

#[test]
fn test_oversize_total_len_is_rejected() {
    let mut transport = RecordedTransport::new(vec![]);
    let mut progress = CollectingProgress::default();
    let plan = DownloadPlan {
        session_id: 1,
        total_len: u64::MAX, // hostile catalog size must not drive a huge allocation
        whole_file_checksum: 0,
    };
    let err = download_session(&plan, &mut transport, &mut progress)
        .expect_err("an implausible total length is rejected before allocating");

    assert_eq!(err, DeviceError::MalformedRecord);
}

#[test]
fn test_empty_session_downloads_to_empty() {
    let mut transport = RecordedTransport::new(vec![]);
    let mut progress = CollectingProgress::default();
    let plan = DownloadPlan {
        session_id: 1,
        total_len: 0,
        whole_file_checksum: 0,
    };
    let out = download_session(&plan, &mut transport, &mut progress).expect("empty is ok");
    assert!(out.is_empty());
}

#[test]
fn test_untrailered_chunk_frame_is_error() {
    // A frame carrying no trailer checksum cannot be verified, so the download
    // aborts with the framing error rather than trusting unverified bytes.
    let mut framed = Vec::new();
    framed.extend_from_slice(b"<hSTCP");
    framed.extend_from_slice(&8u32.to_le_bytes()); // payload length
    framed.push(0); // flag
    framed.push(b'>');
    framed.extend_from_slice(&[0u8; 8]); // offset(4) + data(4), but NO trailer

    let mut transport = RecordedTransport::new(vec![framed]);
    let mut progress = CollectingProgress::default();
    let plan = DownloadPlan {
        session_id: 1,
        total_len: 4,
        whole_file_checksum: 0,
    };
    let err = download_session(&plan, &mut transport, &mut progress)
        .expect_err("an unverifiable frame aborts the download");

    assert_eq!(err, DeviceError::TruncatedList);
}

#[test]
fn test_retry_budget_boundary_recovers() {
    // Exactly MAX_CHUNK_RETRIES corrupt deliveries, then a good one → success.
    // Pins the `>` boundary so a regression to `>=` (one fewer tolerated retry)
    // is caught.
    let payload: Vec<u8> = (0..64u8).collect();
    let good = chunk_frame(0, &payload);
    let mut frames: Vec<Vec<u8>> = (0..MAX_CHUNK_RETRIES)
        .map(|_| corrupt_checksum(&good))
        .collect();
    frames.push(good.clone());
    let mut transport = RecordedTransport::new(frames);
    let mut progress = CollectingProgress::default();

    let out = download_session(&plan_for(&payload, 7), &mut transport, &mut progress)
        .expect("recovers at the exact retry-budget boundary");

    assert_eq!(out, payload);
}

#[test]
fn test_non_progressing_stream_is_bounded_not_infinite() {
    // A device that endlessly re-sends the same already-covered chunk (never the
    // missing bytes) must terminate deterministically, not spin the reassembly
    // loop forever. The transport is effectively infinite but self-caps so a
    // regression fails loudly instead of hanging CI.
    struct EndlessDuplicate {
        frame: Vec<u8>,
        calls: usize,
    }
    impl Transport for EndlessDuplicate {
        fn next_chunk(&mut self) -> Result<Option<Vec<u8>>, DeviceError> {
            self.calls += 1;
            assert!(
                self.calls < 1000,
                "download_session failed to bound a non-progressing stream"
            );
            Ok(Some(self.frame.clone()))
        }
    }

    let payload: Vec<u8> = (0..200u32).map(|i| i as u8).collect();
    let mut transport = EndlessDuplicate {
        frame: chunk_frame(0, &payload[0..100]), // only ever covers the first half
        calls: 0,
    };
    let mut progress = CollectingProgress::default();

    let err = download_session(&plan_for(&payload, 1), &mut transport, &mut progress)
        .expect_err("a non-progressing device terminates with an error");

    assert_eq!(err, DeviceError::MissingChunk);
}

#[test]
fn test_new_error_variants_display() {
    assert_eq!(
        DeviceError::ChecksumMismatch.to_string(),
        "download failed whole-file or unrecoverable chunk checksum verification"
    );
    assert_eq!(
        DeviceError::MissingChunk.to_string(),
        "the session download is missing one or more chunks"
    );
    assert_eq!(
        DeviceError::CorruptArchive.to_string(),
        "the downloaded session is not a readable compressed container"
    );
}
