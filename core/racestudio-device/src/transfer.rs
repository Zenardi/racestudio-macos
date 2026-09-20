//! Chunked session download (issue 6.5): pull a session's bytes from the device
//! as a stream of checksum-verified chunks, reassemble them by offset into the
//! original file, and gate the result on a whole-file checksum before surfacing
//! success — so a corrupt or incomplete transfer never masquerades as a good file.
//!
//! # Transport injection
//!
//! The byte source is abstracted behind [`Transport`] so CI replays recorded
//! fixtures with no live device; the live TCP adapter (`std::net` / `NWConnection`)
//! is the non-coverage implementation of the same trait. Progress is reported via
//! [`ProgressSink`] so the 6.7 device panel can render a progress bar.
//!
//! # What is verified vs hypothesized
//!
//! The STCP framing, the chunk-offset field (`payload[0..4]`, u32 LE), the 65472
//! chunk stride, the short-final-chunk end-of-stream, and the ACK-with-next-offset
//! flow control are all **observed** against a real session-present capture
//! (issue #133, `fixtures/device/transfer/session_stream.bin`). That capture also
//! showed two things the 6.5 notes had wrong:
//!
//! - A session is stored **zlib-compressed** (`.xrz`); the reassembled bytes must
//!   be passed through [`inflate_session`] before they are a readable `.xrk`.
//! - The device sends **no whole-file checksum**. Integrity on the wire is
//!   per-chunk (the STCP trailer) plus the declared total length, so
//!   [`DownloadPlan::whole_file_checksum`] is a caller-supplied expectation, not
//!   a device-reported field.
//!
//! The **retry / re-request** handshake is still hypothesized: the captured
//! transfer was error-free, so recovery behaviour was never exercised on the wire.
//! Clean-room, interoperability-only (DMCA §1201(f); EU 2009/24/EC Art. 6).

use std::io::Read;

use flate2::read::ZlibDecoder;

use crate::checksum::stcp_checksum;
use crate::error::DeviceError;
use crate::framing::verified_frame;

/// The number of consecutive per-chunk checksum-failure retries tolerated before
/// a download is declared unrecoverable ([`DeviceError::ChecksumMismatch`]).
pub const MAX_CHUNK_RETRIES: u32 = 3;

/// Upper bound on a session's declared size (256 MiB). A hostile or corrupt
/// catalog size must never drive an unbounded reassembly-buffer allocation.
const MAX_TOTAL_LEN: u64 = 256 * 1024 * 1024;

/// A chunk frame's payload begins with this many bytes of little-endian offset,
/// followed by the chunk data (`docs/device/PROTOCOL.md` §6).
const CHUNK_OFFSET_LEN: usize = 4;

/// What to download, and how to verify it: the parameters a caller obtains from
/// the 6.4 session catalog (the id and size) plus the whole-file checksum the
/// device reports for integrity.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DownloadPlan {
    /// The device-local id of the session to download (from [`crate::SessionInfo`]).
    pub session_id: u32,
    /// The session's total size in bytes (from the catalog); the reassembled
    /// output must cover exactly this many bytes.
    pub total_len: u64,
    /// The expected whole-file STCP checksum, verified after reassembly.
    ///
    /// **Caller-supplied.** The session-present capture (issue #133) showed the
    /// device reports no whole-file checksum — the transfer header carries only
    /// the total length and the chunk stride — so this is the caller's own
    /// expectation, not a device-reported value.
    pub whole_file_checksum: u16,
}

/// A source of session-download chunk frames.
///
/// [`download_session`] pulls raw STCP chunk frames from this until it signals
/// end-of-stream with `Ok(None)`. The recorded test double replays fixture bytes;
/// the live TCP transport (issue 6.7's adapter, not covered here) sends the read
/// commands and yields the frames the device returns — including a re-delivery
/// after a corrupt chunk, which the downloader retries.
pub trait Transport {
    /// Deliver the next raw STCP chunk frame, or `Ok(None)` at end-of-stream.
    ///
    /// # Errors
    /// Any transport-level failure surfaces as a [`DeviceError`], aborting the
    /// download.
    fn next_chunk(&mut self) -> Result<Option<Vec<u8>>, DeviceError>;
}

/// A sink for download progress, so a UI can render a progress bar.
///
/// [`download_session`] calls this with a leading `(0, total)` sample and then
/// after every chunk that covers new bytes; `bytes_done` is monotonically
/// non-decreasing and reaches `total` exactly once the download completes.
pub trait ProgressSink {
    /// Report that `bytes_done` of `total` bytes have been reassembled.
    fn on_progress(&mut self, bytes_done: u64, total: u64);
}

/// Download a session by reassembling its chunk stream, verifying integrity.
///
/// Each chunk frame's checksum is verified before use; a corrupt chunk is
/// retried (up to [`MAX_CHUNK_RETRIES`]) rather than failing the whole transfer.
/// Chunks are placed by their declared offset, so out-of-order and duplicate
/// deliveries reassemble correctly and idempotently. Once every byte is covered,
/// the reassembled file's whole-file checksum is verified before it is returned.
///
/// # Errors
/// - [`DeviceError::MalformedRecord`] if `total_len` is implausibly large, a
///   chunk is too short to carry its offset field, or a chunk overruns the
///   declared size.
/// - [`DeviceError::TruncatedList`] if a chunk frame is incomplete or carries no
///   readable trailer to verify (propagated from [`verified_frame`], unretried).
/// - [`DeviceError::ChecksumMismatch`] if a chunk stays corrupt past the retry
///   budget, or the reassembled whole file fails its checksum — no partial file
///   is ever returned as success.
/// - [`DeviceError::MissingChunk`] if the stream ends before full coverage, or a
///   device only ever re-sends non-progressing (duplicate/empty) chunks.
/// - Any [`DeviceError`] surfaced by the [`Transport`].
///
/// Never panics on malformed input.
pub fn download_session(
    plan: &DownloadPlan,
    transport: &mut dyn Transport,
    progress: &mut dyn ProgressSink,
) -> Result<Vec<u8>, DeviceError> {
    if plan.total_len > MAX_TOTAL_LEN {
        return Err(DeviceError::MalformedRecord);
    }
    // Bounded by MAX_TOTAL_LEN above, so this conversion cannot fail in practice;
    // the checked form keeps the crate panic-free regardless of target width.
    let total = usize::try_from(plan.total_len).map_err(|_| DeviceError::MalformedRecord)?;

    let mut out = vec![0u8; total];
    let mut covered = vec![false; total];
    let mut covered_bytes: usize = 0;
    // One budget bounds *any* non-progressing chunk: one that keeps failing its
    // checksum, and one that verifies but covers no new bytes (a duplicate or a
    // zero-length chunk). `next_chunk` is untrusted device input, so a device
    // that never advances — even with well-formed frames — must not spin this
    // loop forever.
    let mut stalled: u32 = 0;

    // A leading sample so a sink observes the download even when it is empty.
    progress.on_progress(0, plan.total_len);

    while covered_bytes < total {
        let Some(raw) = transport.next_chunk()? else {
            // The stream ended before every byte was covered.
            return Err(DeviceError::MissingChunk);
        };

        let frame = match verified_frame(&raw) {
            Ok(frame) => frame,
            Err(DeviceError::BadChecksum) => {
                // Retryable: request a re-delivery until the budget is exhausted.
                stalled += 1;
                if stalled > MAX_CHUNK_RETRIES {
                    return Err(DeviceError::ChecksumMismatch);
                }
                continue;
            }
            Err(other) => return Err(other),
        };

        let newly_covered = place_chunk(frame.payload, &mut out, &mut covered)?;
        covered_bytes += newly_covered;

        if newly_covered == 0 {
            // A verified chunk that advanced nothing (a duplicate or zero-length
            // chunk). Tolerate a few, but a device that only ever re-sends these
            // is never going to deliver the bytes still missing.
            stalled += 1;
            if stalled > MAX_CHUNK_RETRIES {
                return Err(DeviceError::MissingChunk);
            }
        } else {
            stalled = 0; // forward progress clears the budget
            progress.on_progress(covered_bytes as u64, plan.total_len);
        }
    }

    // Whole-file integrity gate before any success is surfaced.
    if stcp_checksum(&out) != plan.whole_file_checksum {
        return Err(DeviceError::ChecksumMismatch);
    }
    Ok(out)
}

/// Verify-and-place one chunk into the reassembly buffer, returning the number of
/// **newly** covered bytes (0 for a duplicate or a zero-length chunk).
///
/// The chunk payload is `offset(u32 LE) || data`; the data is written at its
/// declared offset (order-independent) and each byte position is marked covered
/// at most once, so overlapping and duplicate deliveries are idempotent.
///
/// # Errors
/// [`DeviceError::MalformedRecord`] if the chunk is too short to carry its offset
/// field, or its declared `offset + len` overruns the reassembly buffer.
fn place_chunk(payload: &[u8], out: &mut [u8], covered: &mut [bool]) -> Result<usize, DeviceError> {
    let offset = chunk_offset(payload)?;
    let data = payload
        .get(CHUNK_OFFSET_LEN..)
        .ok_or(DeviceError::MalformedRecord)?;
    // Reject a chunk that would overrun the declared size before any slicing.
    let end = offset
        .checked_add(data.len())
        .filter(|&end| end <= out.len())
        .ok_or(DeviceError::MalformedRecord)?;

    // `[offset..end]` is in bounds for both buffers (both sized `total`); write and
    // mark coverage in one pass, counting only positions not already covered.
    let mut newly_covered = 0usize;
    for ((dst, cov), &byte) in out[offset..end]
        .iter_mut()
        .zip(&mut covered[offset..end])
        .zip(data)
    {
        *dst = byte;
        if !*cov {
            *cov = true;
            newly_covered += 1;
        }
    }
    Ok(newly_covered)
}

/// Read a chunk frame's leading u32 LE offset field.
fn chunk_offset(payload: &[u8]) -> Result<usize, DeviceError> {
    let bytes = payload
        .get(0..CHUNK_OFFSET_LEN)
        .and_then(|b| <[u8; 4]>::try_from(b).ok())
        .ok_or(DeviceError::MalformedRecord)?;
    usize::try_from(u32::from_le_bytes(bytes)).map_err(|_| DeviceError::MalformedRecord)
}

/// How far a session may inflate relative to its compressed size before it is
/// rejected as a decompression bomb. Real sessions in the capture inflate ~2.3x;
/// this leaves two orders of magnitude of headroom while still refusing the
/// 1000x-and-up ratios a crafted archive needs to exhaust memory.
const MAX_INFLATION_RATIO: usize = 128;

/// The floor for that bound, so a very small payload is not over-constrained.
const MIN_INFLATION_ALLOWANCE: usize = 1024 * 1024;

/// Unwrap a downloaded session into the `.xrk` container the decoder reads.
///
/// The device stores recorded sessions **zlib-compressed** (`.xrz`), so the bytes
/// [`download_session`] reassembles are not directly decodable — issue #133's
/// capture is what established this. Payloads the device serves uncompressed
/// (the track/config files, e.g. `0:/tkk/al.ria`) are returned unchanged, so this
/// is safe to apply to any downloaded file.
///
/// # Errors
/// [`DeviceError::CorruptArchive`] if the payload carries a zlib header but its
/// deflate stream is unreadable, or it inflates past [`MAX_INFLATION_RATIO`]
/// times its compressed size — no partial session is ever surfaced.
///
/// Never panics.
pub fn inflate_session(bytes: &[u8]) -> Result<Vec<u8>, DeviceError> {
    if !is_zlib_stream(bytes) {
        return Ok(bytes.to_vec());
    }
    let allowance = bytes
        .len()
        .saturating_mul(MAX_INFLATION_RATIO)
        .max(MIN_INFLATION_ALLOWANCE);

    let mut out = Vec::new();
    // `take` bounds the read so a decompression bomb cannot exhaust memory: it
    // stops one byte past the allowance, which the length check below rejects.
    let limit = u64::try_from(allowance)
        .unwrap_or(u64::MAX)
        .saturating_add(1);
    ZlibDecoder::new(bytes)
        .take(limit)
        .read_to_end(&mut out)
        .map_err(|_| DeviceError::CorruptArchive)?;

    if out.len() > allowance {
        return Err(DeviceError::CorruptArchive);
    }
    Ok(out)
}

/// Does this payload begin with a zlib header (RFC 1950)?
///
/// The compression method must be deflate (low nibble 8) and the two header bytes
/// must satisfy the RFC's `(CMF << 8 | FLG) % 31 == 0` check — so an uncompressed
/// payload that happens to start with `0x78` is not mistaken for an archive.
fn is_zlib_stream(bytes: &[u8]) -> bool {
    match bytes {
        [cmf, flg, ..] => cmf & 0x0F == 8 && (u16::from(*cmf) << 8 | u16::from(*flg)) % 31 == 0,
        _ => false,
    }
}
