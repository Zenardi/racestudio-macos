//! Min/max decimation tests (issue 7.2).
//!
//! [`min_max_decimate`] reduces a dense channel to a per-bucket min/max envelope
//! for rendering — one vertical min/max pair per pixel column — with no visual
//! loss. These tests pin the contract:
//!
//! - **Oracle** (`test_decimation_bucket_min_max_matches_bruteforce`): each
//!   bucket's emitted min and max equal the exact min/max of the source samples
//!   in that bucket, verified against a brute-force reference within `1e-9`.
//! - **Spike-preserving** (`test_spike_survives_decimation`): a single injected
//!   spike survives at every zoom level whose bucket contains it.
//! - **Single-pass at scale** (`test_decimation_is_single_pass_on_5m`): 5M
//!   in-memory samples still match the oracle bucket-for-bucket, and the buckets
//!   partition `[0, n)` contiguously — the O(n) single pass.
//! - **Degenerate cases** (`test_buckets_ge_len_returns_input`,
//!   `test_empty_channel_decimates_to_empty`): a bucket count ≥ sample count, a
//!   zero bucket count, and an empty channel return the input unchanged and never
//!   panic or divide by zero.
//! - **Golden** (`test_synthetic_5m_channel_matches_golden`): the lazily decoded
//!   `synthetic_5m.xrk` channel, decimated to the committed bucket count, matches
//!   the brute-force `synthetic_5m.decimated.json` oracle. The `.xrk` is
//!   git-ignored (`scripts/fetch_fixtures.sh --synthetic`); the test skips when
//!   it is absent.
//! - **Bench config** (`test_bench_thresholds_configured`): the committed bench
//!   regression-threshold config names the three tracked benchmarks, each with a
//!   positive regression margin and wall-clock ceiling the CI gate enforces.

use std::path::PathBuf;

use crate::support::fixtures::{fixture_path, load_golden, DecimatedGolden};
use racestudio_analysis::min_max_decimate;
use racestudio_decode::open_container;

const SYNTHETIC: &str = "synthetic_5m.xrk";

/// A deterministic, well-spread waveform on a strictly increasing 100 Hz (ms)
/// time axis: a sine plus a sawtooth so every bucket has a genuine `min != max`.
/// Generated in-memory so the property tests need no fixture.
fn synthetic(n: usize) -> Vec<(f64, f64)> {
    (0..n)
        .map(|i| {
            let t = i as f64 * 10.0;
            let v = (i as f64 * 0.017).sin() * 100.0 + ((i % 251) as f64) * 0.3;
            (t, v)
        })
        .collect()
}

/// The exact `(min value, max value)` of the source samples in bucket `b`, over
/// the same even index partition the implementation uses — the brute-force
/// oracle (issue 7.2 Goal).
fn bucket_extents(samples: &[(f64, f64)], buckets: usize, b: usize) -> (f64, f64, usize, usize) {
    let n = samples.len();
    let start = b * n / buckets;
    let end = (b + 1) * n / buckets;
    let (mut lo, mut hi) = (f64::INFINITY, f64::NEG_INFINITY);
    for sample in &samples[start..end] {
        lo = lo.min(sample.1);
        hi = hi.max(sample.1);
    }
    (lo, hi, start, end)
}

/// A real `synthetic_5m.xrk` path, or `None` (with a skip note) when the
/// git-ignored fixture is absent — matching the other decode/analysis goldens.
fn xrk_or_skip(name: &str) -> Option<PathBuf> {
    let path = fixture_path(name);
    match std::fs::read(&path) {
        Ok(bytes) if bytes.starts_with(b"<h") => Some(path),
        _ => {
            eprintln!(
                "skipping: {} is not a real .xrk sample — run \
                 `bash scripts/fetch_fixtures.sh --synthetic` to generate it",
                path.display()
            );
            None
        }
    }
}

#[test]
fn test_decimation_bucket_min_max_matches_bruteforce() {
    // Given a dense channel decimated to a fixed bucket count, each bucket emits
    // exactly two real source points whose min/max equal the brute-force min/max.
    let samples = synthetic(10_000);
    let buckets = 640;
    let out = min_max_decimate(&samples, buckets);

    assert_eq!(out.len(), buckets * 2, "two envelope points per bucket");
    for b in 0..buckets {
        let (lo, hi, start, end) = bucket_extents(&samples, buckets, b);
        let p0 = out[2 * b];
        let p1 = out[2 * b + 1];
        assert!(
            (p0.1.min(p1.1) - lo).abs() < 1e-9,
            "bucket {b}: emitted min {} != oracle {lo}",
            p0.1.min(p1.1)
        );
        assert!(
            (p0.1.max(p1.1) - hi).abs() < 1e-9,
            "bucket {b}: emitted max {} != oracle {hi}",
            p0.1.max(p1.1)
        );
        assert!(
            p0.0 <= p1.0,
            "bucket {b}: envelope points out of time order"
        );
        assert!(
            samples[start..end].contains(&p0),
            "bucket {b}: p0 not a source sample"
        );
        assert!(
            samples[start..end].contains(&p1),
            "bucket {b}: p1 not a source sample"
        );
    }
}

#[test]
fn test_spike_survives_decimation() {
    // Given a lone towering spike, its bucket's max is the spike, so it appears in
    // the envelope at every zoom level whose bucket renders it.
    let mut samples = synthetic(100_000);
    let spike_value = 1.0e6;
    samples[54_321].1 = spike_value;
    for &buckets in &[100usize, 1_000, 10_000, 50_000] {
        let out = min_max_decimate(&samples, buckets);
        assert!(
            out.iter().any(|p| (p.1 - spike_value).abs() < 1e-9),
            "spike lost when decimating to {buckets} buckets"
        );
    }
}

#[test]
fn test_decimation_is_single_pass_on_5m() {
    // Given 5M in-memory samples, the envelope still matches the oracle bucket for
    // bucket, and the buckets partition [0, n) with no gap or overlap — the
    // single-pass O(n) contract. No fixture needed.
    let n = 5_000_000;
    let samples = synthetic(n);
    let buckets = 1_920;
    let out = min_max_decimate(&samples, buckets);

    assert_eq!(out.len(), buckets * 2);
    let mut covered = 0usize;
    for b in 0..buckets {
        let (lo, hi, start, end) = bucket_extents(&samples, buckets, b);
        assert!(start < end, "bucket {b} is empty");
        assert_eq!(
            start, covered,
            "bucket {b} is not contiguous with its predecessor"
        );
        covered = end;
        let p0 = out[2 * b];
        let p1 = out[2 * b + 1];
        assert!(
            (p0.1.min(p1.1) - lo).abs() < 1e-9,
            "bucket {b} min mismatch"
        );
        assert!(
            (p0.1.max(p1.1) - hi).abs() < 1e-9,
            "bucket {b} max mismatch"
        );
    }
    assert_eq!(covered, n, "buckets must cover every sample exactly once");
}

#[test]
fn test_buckets_ge_len_returns_input() {
    // Given a bucket count equal to, greater than, or zero, decimation returns the
    // input unchanged rather than decimating or dividing by zero.
    let samples = synthetic(8);
    assert_eq!(min_max_decimate(&samples, 8), samples, "buckets == len");
    assert_eq!(min_max_decimate(&samples, 50), samples, "buckets > len");
    assert_eq!(min_max_decimate(&samples, 0), samples, "zero buckets");
}

#[test]
fn test_empty_channel_decimates_to_empty() {
    // Given an empty channel, decimation is empty for any bucket count and never
    // panics.
    let empty: Vec<(f64, f64)> = Vec::new();
    assert!(min_max_decimate(&empty, 100).is_empty());
    assert!(min_max_decimate(&empty, 0).is_empty());
}

#[test]
fn test_decimation_is_nan_safe() {
    // Given a bucket that starts on a NaN sample (a blank cell — Channel::new
    // allows NaN), the bucket's real min and max still survive; `<`/`>` alone
    // would freeze on the leading NaN and drop them.
    let samples = vec![(0.0, f64::NAN), (1.0, 5.0), (2.0, -100.0), (3.0, 50.0)];
    let out = min_max_decimate(&samples, 1);
    assert_eq!(out.len(), 2);
    let values: Vec<f64> = out.iter().map(|p| p.1).collect();
    assert!(
        values.contains(&-100.0),
        "real min survives a leading NaN: {values:?}"
    );
    assert!(
        values.contains(&50.0),
        "real max survives a leading NaN: {values:?}"
    );

    // Given an all-NaN bucket, decimation yields NaN points without panicking.
    let all_nan = vec![(0.0, f64::NAN), (1.0, f64::NAN), (2.0, f64::NAN)];
    let out = min_max_decimate(&all_nan, 1);
    assert_eq!(out.len(), 2);
    assert!(
        out.iter().all(|p| p.1.is_nan()),
        "an all-NaN bucket emits NaN"
    );
}

#[test]
fn test_synthetic_5m_channel_matches_golden() {
    // Given the lazily decoded synthetic 5M fixture, decimating the golden channel
    // to the committed bucket count reproduces the brute-force envelope oracle.
    let Some(path) = xrk_or_skip(SYNTHETIC) else {
        return;
    };
    let golden: DecimatedGolden =
        load_golden("synthetic_5m", "decimated").expect("decimated golden");
    let container = open_container(&path).expect("open synthetic 5M container");

    let index = container.channel_index().expect("channel index");
    // Opening the index must not have materialized any samples (issue 7.2).
    assert!(
        index.iter().all(|channel| !channel.is_materialized()),
        "opening the channel index must stay lazy"
    );

    let channel = index
        .iter()
        .find(|channel| channel.name() == golden.channel)
        .unwrap_or_else(|| panic!("golden channel {:?} not in index", golden.channel));
    assert_eq!(channel.samples().len(), golden.sample_count, "sample count");

    let envelope = min_max_decimate(channel.samples(), golden.buckets);
    assert_eq!(envelope.len(), golden.envelope.len(), "envelope length");
    for (i, (got, want)) in envelope.iter().zip(&golden.envelope).enumerate() {
        assert!(
            (got.0 - want[0]).abs() < 1e-6 && (got.1 - want[1]).abs() < 1e-6,
            "envelope point {i}: got {got:?}, want [{}, {}]",
            want[0],
            want[1]
        );
    }
}

#[test]
fn test_bench_thresholds_configured() {
    // Given the committed bench harness, its regression-threshold config names the
    // three tracked benchmarks, each with a positive regression margin and a
    // wall-clock ceiling the CI gate enforces (issue 7.2).
    let path = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../scripts/bench_thresholds.json"
    );
    let text = std::fs::read_to_string(path)
        .unwrap_or_else(|err| panic!("scripts/bench_thresholds.json not readable: {err}"));
    let config: serde_json::Value =
        serde_json::from_str(&text).expect("bench config is valid JSON");
    let benches = config
        .get("benchmarks")
        .and_then(serde_json::Value::as_object)
        .expect("config has a `benchmarks` map");

    for key in [
        "decode_open",
        "single_channel_decimation",
        "full_session_decimation",
    ] {
        let entry = benches
            .get(key)
            .unwrap_or_else(|| panic!("bench config missing benchmark {key:?}"));
        let pct = entry
            .get("max_regression_pct")
            .and_then(serde_json::Value::as_f64)
            .unwrap_or(0.0);
        let seconds = entry
            .get("max_seconds")
            .and_then(serde_json::Value::as_f64)
            .unwrap_or(0.0);
        assert!(pct > 0.0, "{key} needs a positive regression margin");
        assert!(seconds > 0.0, "{key} needs a positive wall-clock ceiling");
    }
}
