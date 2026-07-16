//! Resampling & interpolation tests (issue 3.3).
//!
//! - **Formula / behaviour** (`test_uniform_*`, `test_endpoints_preserved`,
//!   gap and non-monotonic policies): the acceptance contract on hand-built
//!   series.
//! - **Property** (`prop_*`): output monotonicity for arbitrary sorted input,
//!   and idempotence when resampling an already-uniform series — swept
//!   deterministically over the large input space the issue calls for.
//! - **Golden** (`test_matches_libxrk_resample_golden`): cross-check one channel
//!   against libxrk's `resample_to_timecodes` over the real fixture. The `.xrk`
//!   is git-ignored (fetched by `make fixtures`); the test skips when absent.

use std::path::PathBuf;

use crate::support::fixtures::{fixture_path, load_golden, ResampleGolden};
use racestudio_analysis::{
    resample_uniform, resample_uniform_max_gap, to_distance_grid, AnalysisError,
};
use racestudio_decode::{decode_session, Session};

const SAMPLE: &str = "aim_official_test.xrk";

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

fn decoded_session() -> Option<Session> {
    let path = xrk_or_skip(SAMPLE)?;
    Some(decode_session(&path).expect("decode session"))
}

// --------------------------------------------------------------------------- //
// Uniform-rate resampling: formula, endpoints, monotonicity
// --------------------------------------------------------------------------- //

#[test]
fn test_uniform_output_length_formula() {
    let series = [(0.0, 0.0), (10.0, 100.0)];
    // n = floor((t_end - t_start) * hz) + 1.
    assert_eq!(resample_uniform(&series, 1.0).len(), 11, "floor(10*1)+1");
    assert_eq!(resample_uniform(&series, 0.25).len(), 3, "floor(2.5)+1");
    assert_eq!(resample_uniform(&series, 2.0).len(), 21, "floor(20)+1");
}

#[test]
fn test_endpoints_preserved() {
    let series = [(2.0, 5.0), (7.0, 9.0), (10.0, 3.0)];
    let out = resample_uniform(&series, 0.7);
    assert_eq!(
        out.first().copied(),
        Some((2.0, 5.0)),
        "first == input start"
    );
    assert_eq!(out.last().copied(), Some((10.0, 3.0)), "last == input end");
}

#[test]
fn test_output_axis_strictly_monotonic() {
    let series = [(0.0, 1.0), (3.0, 2.0), (10.0, 5.0)];
    let out = resample_uniform(&series, 0.9);
    assert!(out.len() > 2);
    assert!(
        out.windows(2).all(|w| w[1].0 > w[0].0),
        "output times strictly increasing"
    );
}

#[test]
fn test_resample_empty_and_single() {
    assert!(resample_uniform(&[], 1.0).is_empty(), "empty → empty");
    assert_eq!(
        resample_uniform(&[(5.0, 9.0)], 2.0),
        vec![(5.0, 9.0)],
        "single point preserved"
    );
}

#[test]
fn test_resample_invalid_hz_is_empty() {
    let series = [(0.0, 0.0), (1.0, 1.0)];
    assert!(resample_uniform(&series, 0.0).is_empty(), "hz 0");
    assert!(resample_uniform(&series, -1.0).is_empty(), "hz negative");
    assert!(resample_uniform(&series, f64::NAN).is_empty(), "hz NaN");
}

// --------------------------------------------------------------------------- //
// Property tests
// --------------------------------------------------------------------------- //

/// A tiny deterministic LCG so the sweeps cover a wide, reproducible input space
/// without pulling in a randomness/property-testing dependency.
fn lcg(state: &mut u64) -> u64 {
    *state = state
        .wrapping_mul(6_364_136_223_846_793_005)
        .wrapping_add(1_442_695_040_888_963_407);
    *state >> 16
}

#[test]
fn prop_resample_monotonic_for_any_sorted_input() {
    // For any strictly-time-sorted input and any positive rate, the output time
    // axis is strictly increasing. Swept over 400 generated series and rates.
    let mut state = 0x1234_5678_u64;
    for _ in 0..400 {
        let len = 1 + (lcg(&mut state) % 14) as usize;
        let mut t = 0.0f64;
        let series: Vec<(f64, f64)> = (0..len)
            .map(|_| {
                t += 1.0 + (lcg(&mut state) % 100) as f64; // strictly increasing time
                let value = (lcg(&mut state) % 4000) as f64 / 2.0 - 1000.0; // -1000..1000
                (t, value)
            })
            .collect();
        let hz = 0.005 + (lcg(&mut state) % 995) as f64 / 1000.0; // 0.005..~1.0

        let out = resample_uniform(&series, hz);

        assert!(
            out.windows(2).all(|w| w[1].0 > w[0].0),
            "output time axis must be strictly increasing (len {len}, hz {hz})"
        );
    }
}

#[test]
fn prop_idempotent_on_uniform_input() {
    // Resampling an already-uniform series at its own rate reproduces it (length,
    // times, and values) — swept across origins, lengths, and steps.
    let mut state = 0x0BAD_F00D_u64;
    for &t0 in &[-100.0, -12.5, 0.0, 1.0, 37.25, 99.0] {
        for n in 2..=24usize {
            for &step in &[0.25, 0.5, 1.0, 2.0, 3.75, 10.0] {
                let hz = 1.0 / step;
                let series: Vec<(f64, f64)> = (0..n)
                    .map(|i| {
                        let value = (lcg(&mut state) % 20_000) as f64 / 100.0 - 100.0; // -100..100
                        (t0 + i as f64 * step, value)
                    })
                    .collect();

                let out = resample_uniform(&series, hz);

                assert_eq!(
                    out.len(),
                    n,
                    "length unchanged (t0 {t0}, n {n}, step {step})"
                );
                for (input, output) in series.iter().zip(&out) {
                    assert!((input.0 - output.0).abs() < 1e-6, "time preserved");
                    assert!((input.1 - output.1).abs() < 1e-6, "value preserved");
                }
            }
        }
    }
}

// --------------------------------------------------------------------------- //
// Gap policy
// --------------------------------------------------------------------------- //

#[test]
fn test_large_gap_not_interpolated() {
    // A 1→100 jump is a large gap; resampling with max_gap = 5 must hole it
    // (NaN) rather than draw a straight line through it.
    let series = [(0.0, 0.0), (1.0, 10.0), (100.0, 20.0)];
    let out = resample_uniform_max_gap(&series, 2.0, 5.0);

    // A point inside the small 0→1 gap is interpolated normally.
    let small = out
        .iter()
        .find(|&&(t, _)| (t - 0.5).abs() < 1e-9)
        .expect("a sample at t=0.5");
    assert!(
        !small.1.is_nan() && (small.1 - 5.0).abs() < 1e-9,
        "small gap lerped"
    );

    // Points strictly inside the large gap are holes.
    assert!(out.iter().any(|&(_, v)| v.is_nan()), "large gap holed");
    // Endpoints are real samples, never holes.
    assert!(!out.first().expect("first").1.is_nan());
    assert!(!out.last().expect("last").1.is_nan());

    // Without a gap limit, nothing is holed.
    let full = resample_uniform(&series, 2.0);
    assert!(
        full.iter().all(|&(_, v)| !v.is_nan()),
        "default interpolates across every gap"
    );
}

// --------------------------------------------------------------------------- //
// Distance-grid resampling
// --------------------------------------------------------------------------- //

#[test]
fn test_to_distance_grid_maps_values() {
    let series = [(0.0, 1.0), (1.0, 2.0), (2.0, 3.0)];
    let dist = [0.0, 5.0, 10.0];
    let out = to_distance_grid(&series, &dist, &[0.0, 2.5, 5.0, 10.0]).expect("mapped");
    assert_eq!(
        out,
        vec![1.0, 1.5, 2.0, 3.0],
        "value interpolated over distance"
    );
}

#[test]
fn test_non_monotonic_distance_rejected() {
    let series = [(0.0, 1.0), (1.0, 2.0), (2.0, 3.0)];
    let dist = [0.0, 5.0, 3.0]; // 5 → 3 decreases
    let grid = [0.0, 2.0, 4.0];
    assert_eq!(
        to_distance_grid(&series, &dist, &grid).expect_err("non-monotonic distance"),
        AnalysisError::DistanceNotMonotonic
    );
}

#[test]
fn test_to_distance_grid_empty_series_is_holes() {
    let out = to_distance_grid(&[], &[], &[1.0, 2.0]).expect("ok");
    assert_eq!(out.len(), 2);
    assert!(out.iter().all(|v| v.is_nan()), "no data → holes");
}

// --------------------------------------------------------------------------- //
// Golden (libxrk resample_to_timecodes)
// --------------------------------------------------------------------------- //

#[test]
fn test_matches_libxrk_resample_golden() {
    let Some(session) = decoded_session() else {
        return;
    };
    let golden: ResampleGolden = load_golden("aim_official_test", "resample").expect("golden");
    let channel_name = golden.channel.clone().expect("golden channel");
    let channel = session
        .channels()
        .iter()
        .find(|c| c.name() == channel_name)
        .expect("golden channel present in decode");

    let series: Vec<(f64, f64)> = channel.samples().to_vec();
    let times: Vec<f64> = series.iter().map(|&(t, _)| t).collect();
    // Golden target times are relative to the channel's first sample (the two
    // decoders share values/spacing but differ by a constant timecode origin).
    let origin = times[0];
    let targets: Vec<f64> = golden.points.iter().map(|p| origin + p.t).collect();

    let out = to_distance_grid(&series, &times, &targets).expect("resample onto target times");

    assert_eq!(out.len(), golden.points.len());
    for (value, point) in out.iter().zip(&golden.points) {
        assert!(
            (value - point.v).abs() < 1e-3,
            "resample at t={}: computed {value} vs libxrk {}",
            point.t,
            point.v
        );
    }
}
