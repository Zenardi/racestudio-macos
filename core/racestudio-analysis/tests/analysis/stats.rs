//! Channel-statistics tests (issue 3.4).
//!
//! - **Golden** (`test_min_max_mean_std_match_golden`): every channel's
//!   whole-session `min/max/mean/std/rms/count/range` reproduced against the
//!   numpy-computed `.stats.json` oracle. Statistics depend only on the value
//!   array, so — unlike the delta-t/resample goldens — they carry no
//!   timecode-origin caveat; the tolerance is `1e-9` for channels libxrk stores
//!   at float64/integer precision and float32-epsilon for its `float` channels
//!   (see `tolerance_for`). The `.xrk` is git-ignored (fetched by
//!   `make fixtures`); the test skips when absent.
//! - **Formula / policy** (synthetic): half-open windowing, the single-sample
//!   and empty-range contracts, the `NaN`-hole policy, and exact
//!   mean/std/rms/range values on hand-built inputs.
//! - **Numerical** (`test_welford_matches_naive_within_tolerance`): Welford's
//!   online result agrees with a naive two-pass reference on a large-offset
//!   series that would wreck a single-pass sum-of-squares.
//! - **Per-lap** (`test_per_lap_stats_exclude_other_laps`): each lap's stats
//!   restrict to that lap's 3.1 time window and exclude every other lap.

use std::path::PathBuf;

use crate::support::fixtures::{fixture_path, load_golden, StatsGolden};
use racestudio_analysis::{
    channel_stats, segment_laps, stats_over_range, stats_per_lap, AnalysisError,
};
use racestudio_decode::{decode_session, Session};

const SAMPLE: &str = "aim_official_test.xrk";
const SPEED: &str = "GPS Speed";

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

fn decoded(name: &str) -> Option<Session> {
    let path = xrk_or_skip(name)?;
    Some(decode_session(&path).expect("decode session"))
}

fn decoded_session() -> Option<Session> {
    decoded(SAMPLE)
}

/// A channel's values (across CHS-backed and GPS channels), by name.
fn channel_values(session: &Session, name: &str) -> Option<Vec<f64>> {
    if let Some(channel) = session.channels().iter().find(|c| c.name() == name) {
        return Some(channel.samples().iter().map(|&(_, v)| v).collect());
    }
    session
        .gps()
        .and_then(|gps| gps.channels().iter().find(|c| c.name() == name))
        .map(|channel| channel.samples().iter().map(|&(_, v)| v).collect())
}

/// Relative-or-absolute closeness at tolerance `rel`: `rel` relative for large
/// magnitudes, `rel` absolute near zero. Welford (Rust) and numpy (golden) sum in
/// different orders, so an exact bitwise match is not expected.
fn close(a: f64, b: f64, rel: f64) -> bool {
    (a - b).abs() <= rel * b.abs().max(1.0)
}

/// The cross-check tolerance for a channel given libxrk's storage `dtype`.
///
/// `double` and the integer types store values losslessly relative to the Rust
/// float64 decode, so the two agree to `1e-9` (only summation order differs).
/// `float` (float32) channels are quantized on the libxrk side, so their samples
/// differ from the float64 decode by up to float32 epsilon (~1.2e-7); `1e-6`
/// covers that with margin. This is a reference-storage limit, not a computation
/// error — the exact-formula and Welford-vs-naive tests pin the math at 1e-9.
fn tolerance_for(dtype: &str) -> f64 {
    if dtype == "float" {
        1e-6
    } else {
        1e-9
    }
}

// --------------------------------------------------------------------------- //
// Golden: whole-channel stats vs numpy
// --------------------------------------------------------------------------- //

#[test]
fn test_min_max_mean_std_match_golden() {
    // Both corpus fixtures are cross-checked; fuji additionally exercises the
    // int32-stored channels absent from the aim sample. Each skips independently
    // when its git-ignored `.xrk` is missing.
    check_stats_golden("aim_official_test.xrk", "aim_official_test");
    check_stats_golden("fuji_0033.xrk", "fuji_0033");
}

fn check_stats_golden(xrk: &str, stem: &str) {
    let Some(session) = decoded(xrk) else {
        return;
    };
    let golden: StatsGolden = load_golden(stem, "stats").expect("stats golden");
    assert_eq!(golden.file, xrk);
    assert!(golden.channel_count > 0, "golden lists channels");

    for expected in &golden.channels {
        let values = channel_values(&session, &expected.name)
            .unwrap_or_else(|| panic!("golden channel `{}` present in decode", expected.name));
        let stats =
            channel_stats(&values).unwrap_or_else(|_| panic!("stats for `{}`", expected.name));

        assert_eq!(
            stats.count(),
            expected.count,
            "count for `{}`",
            expected.name
        );
        let rel = tolerance_for(&expected.dtype);
        for (label, got, want) in [
            ("min", stats.min(), expected.min),
            ("max", stats.max(), expected.max),
            ("mean", stats.mean(), expected.mean),
            ("std_pop", stats.std_pop(), expected.std_pop),
            ("std_sample", stats.std_sample(), expected.std_sample),
            ("rms", stats.rms(), expected.rms),
            ("range", stats.range(), expected.range),
        ] {
            assert!(
                close(got, want, rel),
                "{label} for `{}` ({}): computed {got} vs golden {want} (tol {rel})",
                expected.name,
                expected.dtype
            );
        }
    }
}

// --------------------------------------------------------------------------- //
// Per-lap: restrict to the lap's 3.1 window, exclude other laps
// --------------------------------------------------------------------------- //

#[test]
fn test_per_lap_stats_exclude_other_laps() {
    let Some(session) = decoded_session() else {
        return;
    };
    let per_lap = stats_per_lap(&session, SPEED).expect("per-lap stats");
    let laps = segment_laps(&session);
    assert_eq!(per_lap.len(), laps.len(), "one Stats per lap");
    assert!(laps.len() >= 3, "fixture has several laps");

    // Each lap's stats equal channel_stats over exactly that lap's samples (the
    // 3.1 window) — so every other lap's samples are excluded.
    for (lap, stats) in laps.iter().zip(&per_lap) {
        let values: Vec<f64> = lap
            .channel(SPEED)
            .expect("speed channel present in lap")
            .samples()
            .iter()
            .map(|&(_, v)| v)
            .collect();
        let direct = channel_stats(&values).expect("direct lap stats");
        assert_eq!(
            stats.count(),
            values.len(),
            "lap count is the lap's samples"
        );
        assert_eq!(stats.count(), direct.count());
        assert!((stats.mean() - direct.mean()).abs() < 1e-12);
        assert!((stats.min() - direct.min()).abs() < 1e-12);
        assert!((stats.max() - direct.max()).abs() < 1e-12);
        assert!((stats.std_pop() - direct.std_pop()).abs() < 1e-12);
    }

    // Exclusion is real: laps are disjoint subsets, so their counts sum to no
    // more than the whole channel and no single lap spans everything.
    let whole = channel_stats(&channel_values(&session, SPEED).expect("speed channel"))
        .expect("whole-channel stats");
    let lap_total: usize = per_lap.iter().map(|s| s.count()).sum();
    assert!(
        lap_total <= whole.count(),
        "laps are disjoint subsets of the channel"
    );
    assert!(
        per_lap.iter().all(|s| s.count() < whole.count()),
        "no single lap covers the whole channel"
    );

    // The laps genuinely differ — mean speed varies lap to lap — which could not
    // happen if each lap saw the same (whole-channel) samples.
    let max_mean = per_lap.iter().map(|s| s.mean()).fold(f64::MIN, f64::max);
    let min_mean = per_lap.iter().map(|s| s.mean()).fold(f64::MAX, f64::min);
    assert!(max_mean - min_mean > 0.0, "per-lap means vary across laps");
}

#[test]
fn test_stats_per_lap_missing_channel_errors() {
    let Some(session) = decoded_session() else {
        return;
    };
    assert_eq!(
        stats_per_lap(&session, "NoSuchChannel").expect_err("missing channel"),
        AnalysisError::MissingChannel {
            name: "NoSuchChannel".to_string()
        }
    );
}

// --------------------------------------------------------------------------- //
// Windowing: half-open [t0, t1)
// --------------------------------------------------------------------------- //

#[test]
fn test_windowed_range_is_half_open() {
    let series = [(0.0, 1.0), (10.0, 2.0), (20.0, 3.0), (30.0, 4.0)];

    // [10, 30): includes t=10 and t=20, excludes t=0 (left of window) and t=30
    // (right edge is exclusive).
    let mid = stats_over_range(&series, 10.0, 30.0).expect("window [10,30)");
    assert_eq!(mid.count(), 2);
    assert_eq!(mid.min(), 2.0);
    assert_eq!(mid.max(), 3.0);
    assert!((mid.mean() - 2.5).abs() < 1e-12);

    // [0, 20): includes t=0 (left edge inclusive) and t=10, excludes t=20.
    let left = stats_over_range(&series, 0.0, 20.0).expect("window [0,20)");
    assert_eq!(left.count(), 2);
    assert_eq!(left.min(), 1.0);
    assert_eq!(left.max(), 2.0);
}

#[test]
fn test_stats_over_range_computes_expected_values() {
    // Values 10,20,30,40 over t=0..3 s; window covers all four.
    let series = [(0.0, 10.0), (1.0, 20.0), (2.0, 30.0), (3.0, 40.0)];
    let stats = stats_over_range(&series, 0.0, 100.0).expect("full window");
    assert_eq!(stats.count(), 4);
    assert!((stats.mean() - 25.0).abs() < 1e-12);
    assert_eq!(stats.range(), 30.0);
}

// --------------------------------------------------------------------------- //
// Single sample, empty range, NaN policy
// --------------------------------------------------------------------------- //

#[test]
fn test_single_sample_std_is_zero() {
    let stats = channel_stats(&[42.0]).expect("single sample");
    assert_eq!(stats.count(), 1);
    assert_eq!(stats.mean(), 42.0);
    assert_eq!(stats.min(), 42.0);
    assert_eq!(stats.max(), 42.0);
    assert_eq!(stats.range(), 0.0);
    assert_eq!(stats.rms(), 42.0);
    assert_eq!(stats.std_pop(), 0.0);
    assert_eq!(
        stats.std_sample(),
        0.0,
        "sample std of one point is 0, not NaN"
    );
    assert!(!stats.std_sample().is_nan());
}

#[test]
fn test_empty_range_returns_error() {
    assert_eq!(
        channel_stats(&[]).expect_err("empty slice"),
        AnalysisError::EmptyRange
    );

    // A window that selects nothing is empty.
    let series = [(0.0, 1.0), (10.0, 2.0)];
    assert_eq!(
        stats_over_range(&series, 100.0, 200.0).expect_err("empty window"),
        AnalysisError::EmptyRange
    );

    // An all-NaN slice has no finite samples → empty.
    assert_eq!(
        channel_stats(&[f64::NAN, f64::NAN]).expect_err("all NaN"),
        AnalysisError::EmptyRange
    );
}

#[test]
fn test_nan_holes_ignored() {
    let clean = [1.0, 2.0, 3.0, 4.0];
    let holed = [1.0, f64::NAN, 2.0, 3.0, f64::NAN, 4.0];

    let a = channel_stats(&clean).expect("clean");
    let b = channel_stats(&holed).expect("holed");

    assert_eq!(b.count(), 4, "NaN holes are not counted");
    assert_eq!(a.count(), b.count());
    assert!((a.mean() - b.mean()).abs() < 1e-12);
    assert!((a.std_pop() - b.std_pop()).abs() < 1e-12);
    assert!((a.std_sample() - b.std_sample()).abs() < 1e-12);
    assert!((a.rms() - b.rms()).abs() < 1e-12);
    assert_eq!(a.min(), b.min());
    assert_eq!(a.max(), b.max());
    // No statistic is contaminated by the holes.
    assert!(!b.mean().is_nan() && !b.std_pop().is_nan() && !b.rms().is_nan());
}

// --------------------------------------------------------------------------- //
// Exact formulas + Welford stability
// --------------------------------------------------------------------------- //

#[test]
fn test_stats_field_formulas() {
    // [0,0,0,4]: mean=1; var_pop=(1+1+1+9)/4=3 → std_pop=√3; var_sample=12/3=4 →
    // std_sample=2; rms=√((0+0+0+16)/4)=2; range=4.
    let stats = channel_stats(&[0.0, 0.0, 0.0, 4.0]).expect("stats");
    assert_eq!(stats.count(), 4);
    assert_eq!(stats.min(), 0.0);
    assert_eq!(stats.max(), 4.0);
    assert!((stats.mean() - 1.0).abs() < 1e-12);
    assert!((stats.std_pop() - 3.0_f64.sqrt()).abs() < 1e-12);
    assert!((stats.std_sample() - 2.0).abs() < 1e-12);
    assert!((stats.rms() - 2.0).abs() < 1e-12);
    assert_eq!(stats.range(), 4.0);
}

#[test]
fn test_welford_matches_naive_within_tolerance() {
    // A large constant offset (mean² ≫ variance) makes a single-pass
    // Σx² − (Σx)²/n catastrophically cancel: at 1e6 the ~0.08 variance is lost in
    // the ~1e12 subtraction. Welford (used by channel_stats) stays accurate;
    // compare it against an accurate naive TWO-pass reference over the same data.
    // The offset is kept at 1e6 (not higher) so the mean itself stays f64-precise
    // — a 1e9 mean has ~2e-7 irreducible resolution and could not be checked
    // tightly regardless of algorithm.
    let offset = 1.0e6;
    let mut state = 0x0051_ED17_u64;
    let values: Vec<f64> = (0..5000)
        .map(|_| {
            state = state
                .wrapping_mul(6_364_136_223_846_793_005)
                .wrapping_add(1_442_695_040_888_963_407);
            let jitter = ((state >> 40) & 0xFFFF) as f64 / 65_536.0; // 0..1
            offset + jitter
        })
        .collect();

    let stats = channel_stats(&values).expect("welford stats");

    let n = values.len() as f64;
    let mean = values.iter().sum::<f64>() / n;
    let ss: f64 = values.iter().map(|v| (v - mean).powi(2)).sum();
    let std_pop = (ss / n).sqrt();
    let std_sample = (ss / (n - 1.0)).sqrt();

    assert!(
        (stats.mean() - mean).abs() <= 1e-6,
        "mean {} vs naive {mean}",
        stats.mean()
    );
    assert!(
        (stats.std_pop() - std_pop).abs() <= 1e-9,
        "std_pop {} vs naive {std_pop}",
        stats.std_pop()
    );
    assert!(
        (stats.std_sample() - std_sample).abs() <= 1e-9,
        "std_sample {} vs naive {std_sample}",
        stats.std_sample()
    );
}
