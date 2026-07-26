//! Lazy channel-loading tests (issue 7.2).
//!
//! Opening a session should read metadata + the channel index **without**
//! materializing any sample vector; a channel's samples are decoded only on the
//! first [`Channel::samples`] access and then cached (decoded exactly once).
//! [`Container::channel_index`] is the lazy entry point; [`decode_channels`] stays
//! the eager one, and the two must agree on the channel set, order, metadata, and
//! decoded samples — the only difference is *when* samples are decoded.
//!
//! The fixtures here are tiny synthetic `.xrk` containers built in-memory (so the
//! tests run everywhere, fixture-free); the large real `synthetic_5m.xrk` +
//! decimation golden are exercised by the analysis crate's `decimate` tests.

use std::path::{Path, PathBuf};

use racestudio_decode::{decode_channels, open_container};

// --------------------------------------------------------------------------- //
// Minimal `.xrk` framing (mirrors the in-crate decoder unit-test helpers).
// --------------------------------------------------------------------------- //

const MAGIC: [u8; 2] = [0x3C, 0x68];

fn token_to_u32(token: &str) -> u32 {
    let mut bytes = token.as_bytes().to_vec();
    while bytes.len() < 4 {
        bytes.push(b' '); // pad 3-char tokens with a trailing space
    }
    u32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]])
}

/// Build a framed header message (`<h … >`) with a correct checksum.
fn frame(token: &str, payload: &[u8]) -> Vec<u8> {
    let tok = token_to_u32(token);
    let mut out = Vec::new();
    out.extend_from_slice(&MAGIC);
    out.extend_from_slice(&tok.to_le_bytes());
    out.extend_from_slice(&(payload.len() as i32).to_le_bytes());
    out.push(0); // version
    out.push(b'>');
    out.extend_from_slice(payload);
    out.push(b'<');
    out.extend_from_slice(&tok.to_le_bytes());
    let checksum = (payload.iter().map(|&b| u32::from(b)).sum::<u32>() & 0xFFFF) as u16;
    out.extend_from_slice(&checksum.to_le_bytes());
    out.push(b'>');
    out
}

/// A 112-byte CHS payload: index, unit type, decoder type, name, period, size.
fn chs(
    index: u16,
    name: &str,
    unit_type: u8,
    decoder: u8,
    data_size: u8,
    period_us: u32,
) -> Vec<u8> {
    let mut p = vec![0u8; 112];
    p[0..2].copy_from_slice(&index.to_le_bytes());
    p[12] = unit_type;
    p[20] = decoder;
    let nb = name.as_bytes();
    p[32..32 + nb.len()].copy_from_slice(nb);
    p[64..68].copy_from_slice(&period_us.to_le_bytes());
    p[72] = data_size;
    p
}

/// A `(S` message: timecode + channel + `data`.
fn data_s(channel: u16, tc: i32, data: &[u8]) -> Vec<u8> {
    let mut m = vec![b'(', b'S'];
    m.extend_from_slice(&tc.to_le_bytes());
    m.extend_from_slice(&channel.to_le_bytes());
    m.extend_from_slice(data);
    m.push(b')');
    m
}

/// Two non-empty i32/f32 channels ("RPM" 100 Hz, "Speed" 100 Hz), five samples
/// each, at strictly increasing timecodes.
fn two_channel_xrk() -> Vec<u8> {
    let mut cnf = frame("CHS", &chs(0, "RPM", 15, 0, 4, 10_000));
    cnf.extend(frame("CHS", &chs(1, "Speed", 16, 6, 4, 10_000)));
    let mut file = frame("CNF", &cnf);
    for i in 0..5i32 {
        let tc = 100 + i * 100;
        file.extend(data_s(0, tc, &(1000 + i * 250).to_le_bytes()));
        file.extend(data_s(1, tc, &(30.0f32 + i as f32 * 2.5).to_le_bytes()));
    }
    file
}

/// Two defined channels but samples only for channel 0 — channel 1 is a defined
/// yet empty channel that both decodes must drop.
fn defined_but_empty_xrk() -> Vec<u8> {
    let mut cnf = frame("CHS", &chs(0, "RPM", 15, 0, 4, 10_000));
    cnf.extend(frame("CHS", &chs(1, "Speed", 16, 6, 4, 10_000)));
    let mut file = frame("CNF", &cnf);
    for i in 0..3i32 {
        file.extend(data_s(0, 100 + i * 100, &(2000 + i * 100).to_le_bytes()));
    }
    file
}

/// Write synthetic `.xrk` bytes to the integration-test temp dir and return the
/// path (`decode`/`open_container` take a path).
fn write_xrk(name: &str, bytes: &[u8]) -> PathBuf {
    let path = Path::new(env!("CARGO_TARGET_TMPDIR")).join(name);
    std::fs::write(&path, bytes).expect("write synthetic .xrk");
    path
}

// --------------------------------------------------------------------------- //
// Tests
// --------------------------------------------------------------------------- //

#[test]
fn test_channel_samples_decoded_lazily_once() {
    // Given a freshly opened channel index, samples are not materialized; the
    // first access decodes and caches them, and every later access returns that
    // same cached allocation (decoded exactly once).
    let path = write_xrk("lazy_once.xrk", &two_channel_xrk());
    let container = open_container(&path).expect("open container");
    let index = container.channel_index().expect("channel index");
    assert!(!index.is_empty(), "channel index should list the channels");

    let channel = &index[0];
    assert!(
        !channel.is_materialized(),
        "opening the index must not decode samples"
    );

    let first = channel.samples();
    assert!(!first.is_empty(), "first access decodes the samples");
    assert!(
        channel.is_materialized(),
        "samples are cached after the first access"
    );
    let first_ptr = first.as_ptr();

    let second = channel.samples();
    assert_eq!(
        second.as_ptr(),
        first_ptr,
        "the second access must reuse the cache, not decode again"
    );
}

#[test]
fn test_channel_index_matches_eager_decode() {
    // Given the same container, the lazy index and eager decode_channels agree on
    // the channel set, order, metadata, and — once forced — the exact samples.
    let path = write_xrk("lazy_eager.xrk", &two_channel_xrk());
    let container = open_container(&path).expect("open container");

    let eager = decode_channels(&container).expect("eager decode");
    let lazy = container.channel_index().expect("channel index");

    assert_eq!(lazy.len(), eager.len(), "same channel count");
    assert_eq!(lazy.len(), 2, "both channels present");
    for (l, e) in lazy.iter().zip(&eager) {
        assert_eq!(l.name(), e.name(), "same name/order");
        assert_eq!(l.unit(), e.unit());
        assert_eq!(l.decimals(), e.decimals());
        assert_eq!(l.interpolate(), e.interpolate());
        assert!((l.sample_rate_hz() - e.sample_rate_hz()).abs() < 1e-9);
        assert_eq!(
            l.samples(),
            e.samples(),
            "lazy samples match eager for {}",
            l.name()
        );
    }
}

#[test]
fn test_channel_index_drops_empty_channels() {
    // Given a container with a defined-but-empty channel, both decodes drop it —
    // the lazy index never surfaces a phantom channel.
    let path = write_xrk("lazy_empty.xrk", &defined_but_empty_xrk());
    let container = open_container(&path).expect("open container");

    assert_eq!(container.channel_count(), 2, "two channels are defined");
    let lazy = container.channel_index().expect("channel index");
    let eager = decode_channels(&container).expect("eager decode");
    assert_eq!(lazy.len(), 1, "the empty channel is dropped");
    assert_eq!(
        lazy.len(),
        eager.len(),
        "lazy and eager drop the same channel"
    );
    assert!(
        lazy.iter().all(|c| !c.samples().is_empty()),
        "no surfaced channel is empty"
    );
    assert_eq!(lazy[0].name(), "RPM");
}

/// A container whose trailing `(S` declares four data bytes but only one is
/// present before EOF — the eager decoder reports this as `TruncatedChannel`.
fn truncated_xrk() -> Vec<u8> {
    let cnf = frame("CHS", &chs(0, "RPM", 15, 0, 4, 10_000));
    let mut file = frame("CNF", &cnf);
    file.extend(data_s(0, 100, &1000i32.to_le_bytes())); // one good sample
    file.extend_from_slice(&[b'(', b'S', 0, 0, 0, 0, 0, 0, 0x11]); // truncated (S
    file
}

#[test]
fn test_channel_index_errors_on_truncated_stream() {
    // A corrupt/partial session must be reported by the lazy index exactly as the
    // eager decode reports it — never silently served as complete (issue 7.2).
    let path = write_xrk("lazy_truncated.xrk", &truncated_xrk());
    let container = open_container(&path).expect("open container");

    let eager = decode_channels(&container);
    let lazy = container.channel_index();
    assert!(eager.is_err(), "eager decode rejects the truncated stream");
    assert!(lazy.is_err(), "the lazy index rejects it too");
    assert_eq!(
        format!("{:?}", eager.unwrap_err()),
        format!("{:?}", lazy.unwrap_err()),
        "both paths report the same error"
    );
}
