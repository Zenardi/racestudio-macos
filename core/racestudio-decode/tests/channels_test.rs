//! Channel-decode tests (issue 1.3).
//!
//! These validate `decode_channels` against the real `aim_official_test.xrk`
//! sample and its libxrk-derived golden (`*.channels.json`), plus the malformed
//! and empty channel-table paths. As in 1.2, the `.xrk` sample is git-ignored
//! (fetched by `make fixtures`); when it is absent the oracle tests skip with a
//! clear message rather than fail. The decoder's own logic is covered
//! independently by the unit tests in `src/channels.rs`.
//!
//! The golden's channel summaries include GPS-synthesized channels (milestone
//! 1.4), which have no `CHS` definition and so no `sample_rate_hz`. 1.3 decodes
//! exactly the `CHS`-backed channels, so the oracle set is the golden channels
//! with `sample_rate_hz.is_some()`.

mod support;

use std::path::PathBuf;

use racestudio_decode::{decode_channels, open_container, Channel, DecodeError};
use support::fixtures::{fixture_path, load_golden, ChannelSummary, ChannelsGolden};

const SAMPLE: &str = "aim_official_test.xrk";

/// Resolve a real `.xrk` sample, or `None` (with a skip note) when the
/// git-ignored sample is absent or is not a genuine `.xrk` (placeholder / LFS
/// pointer / partial download).
fn xrk_or_skip(name: &str) -> Option<PathBuf> {
    let path = fixture_path(name);
    match std::fs::read(&path) {
        Ok(bytes) if bytes.starts_with(b"<h") => Some(path),
        _ => {
            eprintln!(
                "skipping: {} is not a real .xrk sample — run `make fixtures` to fetch it",
                path.display()
            );
            None
        }
    }
}

/// The golden's `CHS`-backed channels (the 1.3 oracle set), sorted by name.
fn oracle_channels() -> Vec<ChannelSummary> {
    let golden: ChannelsGolden =
        load_golden("aim_official_test", "channels").expect("load channels golden");
    let mut chs: Vec<ChannelSummary> = golden
        .channels
        .into_iter()
        .filter(|c| c.sample_rate_hz.is_some())
        .collect();
    chs.sort_by(|a, b| a.name.cmp(&b.name));
    chs
}

/// Decode the sample's channels, sorted by name.
fn decode_sorted(path: &PathBuf) -> Vec<Channel> {
    let container = open_container(path).expect("open container");
    let mut channels = decode_channels(&container).expect("decode channels");
    channels.sort_by(|a, b| a.name().cmp(b.name()));
    channels
}

/// Round to the channel's own precision, then compare within 1e-6 (matching how
/// the golden itself is rounded to `decimals`). `None`/non-finite compare equal.
fn approx(actual: Option<f64>, golden: Option<f64>, decimals: i64) -> bool {
    match (actual, golden) {
        (Some(a), Some(g)) if a.is_finite() => {
            let scale = 10f64.powi(decimals as i32);
            (a * scale).round() / scale - g < 1e-6 && g - (a * scale).round() / scale < 1e-6
        }
        (None, None) => true,
        (Some(a), None) => !a.is_finite(),
        _ => false,
    }
}

/// First/last/min/max of a channel's finite sample values.
fn stats(ch: &Channel) -> (Option<f64>, Option<f64>, Option<f64>, Option<f64>) {
    let finite: Vec<f64> = ch
        .samples()
        .iter()
        .map(|&(_, v)| v)
        .filter(|v| v.is_finite())
        .collect();
    let first = ch.samples().first().map(|&(_, v)| v);
    let last = ch.samples().last().map(|&(_, v)| v);
    let min = finite
        .iter()
        .copied()
        .fold(None, |m, v| Some(m.map_or(v, |m: f64| m.min(v))));
    let max = finite
        .iter()
        .copied()
        .fold(None, |m, v| Some(m.map_or(v, |m: f64| m.max(v))));
    (first, last, min, max)
}

#[test]
fn test_channel_count_matches_golden() {
    // Given the .xrk sample, When channels are decoded, Then their count equals
    // the CHS-backed channel count in the libxrk golden.
    let Some(path) = xrk_or_skip(SAMPLE) else {
        return;
    };
    assert_eq!(
        decode_sorted(&path).len(),
        oracle_channels().len(),
        "channel count"
    );
}

#[test]
fn test_channel_names_match_golden() {
    // Given the .xrk sample, When channels are decoded, Then their names equal
    // the golden's CHS-backed names exactly.
    let Some(path) = xrk_or_skip(SAMPLE) else {
        return;
    };
    let ours: Vec<String> = decode_sorted(&path)
        .iter()
        .map(|c| c.name().to_string())
        .collect();
    let expected: Vec<String> = oracle_channels().iter().map(|c| c.name.clone()).collect();
    assert_eq!(ours, expected, "channel names");
}

#[test]
fn test_channel_units_match_golden() {
    // Given the .xrk sample, When channels are decoded, Then each channel's unit
    // and native sample rate match the golden.
    let Some(path) = xrk_or_skip(SAMPLE) else {
        return;
    };
    let ours = decode_sorted(&path);
    let golden = oracle_channels();
    assert_eq!(ours.len(), golden.len(), "channel count (precondition)");
    for (ch, g) in ours.iter().zip(golden.iter()) {
        assert_eq!(ch.name(), g.name, "name alignment");
        assert_eq!(ch.unit(), g.units, "unit for {}", g.name);
        let expected_hz = g.sample_rate_hz.expect("oracle channel has a sample rate");
        assert!(
            (ch.sample_rate_hz() - expected_hz).abs() < 1e-3,
            "sample_rate_hz for {}: got {}, want {}",
            g.name,
            ch.sample_rate_hz(),
            expected_hz
        );
    }
}

#[test]
fn test_samples_within_tolerance() {
    // Given the .xrk sample, When channels are decoded, Then per-channel sample
    // count and first/last/min/max match the golden within the channel's own
    // precision (libxrk stores raw values; the golden rounds to `decimals`).
    let Some(path) = xrk_or_skip(SAMPLE) else {
        return;
    };
    let ours = decode_sorted(&path);
    let golden = oracle_channels();
    assert_eq!(ours.len(), golden.len(), "channel count (precondition)");
    for (ch, g) in ours.iter().zip(golden.iter()) {
        assert_eq!(ch.samples().len(), g.samples, "sample count for {}", g.name);
        let (first, last, min, max) = stats(ch);
        assert!(
            approx(first, g.first, g.decimals),
            "first for {}: {:?} vs {:?}",
            g.name,
            first,
            g.first
        );
        assert!(
            approx(last, g.last, g.decimals),
            "last for {}: {:?} vs {:?}",
            g.name,
            last,
            g.last
        );
        assert!(
            approx(min, g.min, g.decimals),
            "min for {}: {:?} vs {:?}",
            g.name,
            min,
            g.min
        );
        assert!(
            approx(max, g.max, g.decimals),
            "max for {}: {:?} vs {:?}",
            g.name,
            max,
            g.max
        );
    }
}

#[test]
fn test_truncated_block_returns_error() {
    // Given a container whose channel data message is cut short at EOF, When
    // channels are decoded, Then a typed error is returned — never a panic.
    let dir = std::path::Path::new(env!("CARGO_TARGET_TMPDIR"));
    let path = dir.join("truncated_channel.xrk");
    // CNF { CHS(index 0, size 4) } then a '(S' whose 4 data bytes run past EOF.
    let mut cnf = Vec::new();
    cnf.extend(synth::frame("CHS", &synth::chs(0, 4)));
    let mut file = synth::frame("CNF", &cnf);
    file.extend_from_slice(&[b'(', b'S', 0, 0, 0, 0, 0, 0, 0x11]); // tc + chan 0 + only 1 of 4 data bytes
    std::fs::write(&path, &file).expect("write truncated fixture");

    let container = open_container(&path).expect("container header is valid");
    let err = decode_channels(&container).expect_err("truncated channel must error");
    assert!(
        matches!(
            err,
            DecodeError::TruncatedChannel | DecodeError::BadSampleCount
        ),
        "expected a truncated/bad-count error, got {err:?}"
    );
}

#[test]
fn test_empty_channel_table_is_ok() {
    // Given a valid container with no channel definitions, When channels are
    // decoded, Then the result is an empty channel list (not an error).
    let dir = std::path::Path::new(env!("CARGO_TARGET_TMPDIR"));
    let path = dir.join("no_channels.xrk");
    std::fs::write(&path, synth::frame("RCR", b"DRIVER\0")).expect("write header-only fixture");

    let container = open_container(&path).expect("open header-only container");
    let channels = decode_channels(&container).expect("empty channel table is ok");
    assert!(channels.is_empty(), "no CHS definitions -> no channels");
}

/// Minimal `.xrk` framing helpers for the synthetic (malformed/empty) fixtures.
mod synth {
    const MAGIC: [u8; 2] = [0x3C, 0x68];

    pub fn frame(token: &str, payload: &[u8]) -> Vec<u8> {
        let tok = token_to_u32(token);
        let mut out = Vec::new();
        out.extend_from_slice(&MAGIC);
        out.extend_from_slice(&tok.to_le_bytes());
        out.extend_from_slice(&(payload.len() as i32).to_le_bytes());
        out.push(0);
        out.push(b'>');
        out.extend_from_slice(payload);
        out.push(b'<');
        out.extend_from_slice(&tok.to_le_bytes());
        let checksum = (payload.iter().map(|&b| u32::from(b)).sum::<u32>() & 0xFFFF) as u16;
        out.extend_from_slice(&checksum.to_le_bytes());
        out.push(b'>');
        out
    }

    fn token_to_u32(token: &str) -> u32 {
        let mut bytes = token.as_bytes().to_vec();
        while bytes.len() < 4 {
            bytes.push(0);
        }
        u32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]])
    }

    /// A 112-byte CHS payload: index, unit type 6 (number), decoder 0 (i32),
    /// the given per-sample data size.
    pub fn chs(index: u16, data_size: u8) -> Vec<u8> {
        let mut p = vec![0u8; 112];
        p[0..2].copy_from_slice(&index.to_le_bytes());
        p[12] = 6; // unit type: number
        p[20] = 0; // decoder type: i32
        p[72] = data_size;
        p
    }
}
