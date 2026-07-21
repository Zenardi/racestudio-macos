//! Executable acceptance tests for issue 6.5 — chunked session download.
//!
//! # What is verified vs hypothesized
//!
//! - **Verified wire anchor:** `fixtures/device/transfer/chunk.bin` is a *real*,
//!   checksum-observed device download chunk. `test_recorded_device_chunk_frames_and_verifies`
//!   drives it through the same framing the reassembler uses and asserts its
//!   declared offset (65472) and observed checksum (57932) — proving the chunk
//!   wire format this module builds on matches a genuine capture.
//! - **Verified decode pipeline:** the single captured chunk is one opaque
//!   mid-stream chunk (offset 65472), not a whole decodable `.xrk`, and no
//!   whole-file transfer was captured. So the reassemble→decode chain is proven
//!   against a *real* M1 fixture (`fuji_0033.xrk`) streamed as chunks: the
//!   reassembled bytes must equal the file byte-for-byte, and the result must
//!   decode via `racestudio-decode` to the M1 golden. The `.xrk` and its golden
//!   are real; only the *chunking of that file into a transfer stream* is
//!   synthetic (documented), because the device's real multi-chunk stream is not
//!   yet captured (tracked in issue #133).
//! - **Hypothesized protocol:** out-of-order / duplicate / missing-chunk /
//!   retry / whole-file-checksum behaviour is exercised against synthetic
//!   multi-chunk streams built in-test. Clean-room, interoperability-only
//!   (DMCA §1201(f); EU 2009/24/EC Art. 6).

use std::collections::VecDeque;
use std::path::PathBuf;

use racestudio_device::stcp_checksum;
use racestudio_device::transfer::{
    download_session, DownloadPlan, ProgressSink, Transport, MAX_CHUNK_RETRIES,
};
use racestudio_device::DeviceError;

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

// ---- the seven named acceptance behaviours ---------------------------------

#[test]
fn test_reassembled_bytes_match_expected_xrk() {
    let file = std::fs::read(repo_root().join("fixtures/fuji_0033.xrk")).expect("read fixture");
    let frames = split_into_frames(&file, 65472);
    let mut transport = RecordedTransport::new(frames);
    let mut progress = CollectingProgress::default();

    let out = download_session(&plan_for(&file, 33), &mut transport, &mut progress)
        .expect("download reassembles");

    assert_eq!(
        out, file,
        "reassembled bytes equal the source .xrk byte-for-byte"
    );
}

#[test]
fn test_reassembled_file_decodes_via_m1_golden() {
    let file = std::fs::read(repo_root().join("fixtures/fuji_0033.xrk")).expect("read fixture");
    let frames = split_into_frames(&file, 65472);
    let mut transport = RecordedTransport::new(frames);
    let mut progress = CollectingProgress::default();

    let out = download_session(&plan_for(&file, 33), &mut transport, &mut progress)
        .expect("download reassembles");

    // Decode the *reassembled* bytes (via a temp file, since decode_session reads
    // a path) and assert the M1 golden for fuji_0033 — proving the download is a
    // valid, decodable file, not just byte-equal.
    let tmp = std::env::temp_dir().join(format!(
        "rs_device_transfer_{}_decode.xrk",
        std::process::id()
    ));
    std::fs::write(&tmp, &out).expect("write temp");
    let session = racestudio_decode::decode_session(&tmp).expect("reassembled file decodes");
    let _ = std::fs::remove_file(&tmp);

    // Golden metadata fields from fixtures/golden/fuji_0033.metadata.json — proof
    // the reassembled download decodes to the known M1 result, not just any file.
    let meta = session.metadata();
    assert_eq!(meta.track, "Fuji GP Sh", "M1 golden: track");
    assert_eq!(meta.driver, "CMD", "M1 golden: driver");
    assert_eq!(meta.vehicle, "SFJ", "M1 golden: vehicle");
    assert_eq!(meta.series, "Fuji Practice", "M1 golden: series");
    assert_eq!(meta.session, "Generic testing", "M1 golden: session name");
    assert_eq!(meta.datetime_utc, 1_762_271_407, "M1 golden: datetime");

    // The reassembled file decodes identically to the original fixture (channels
    // and full metadata), independent of the container-vs-decoded count nuance.
    let original = racestudio_decode::decode_session(repo_root().join("fixtures/fuji_0033.xrk"))
        .expect("original fixture decodes");
    assert_eq!(
        session.channels().len(),
        original.channels().len(),
        "reassembled channels match the original decode"
    );
    assert_eq!(
        meta,
        original.metadata(),
        "reassembled metadata matches the original decode"
    );
    assert!(
        !session.channels().is_empty(),
        "the decoded download has channels"
    );
}

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
}
