//! Lap segmentation & alignment tests (issue 3.1).
//!
//! Two families:
//!
//! - **Golden oracle** (`test_lap_count_matches_golden`,
//!   `test_lap_start_end_times_match_golden`): decode the real
//!   `aim_official_test.xrk`, segment it, and check the lap count and cumulative
//!   start/end times against the committed beacon-lap golden (`*.laps.json`, the
//!   same table libxrk's `log.laps` count is cross-validated against, issue 1.5).
//!   The `.xrk` sample is git-ignored (fetched by `make fixtures`); when absent
//!   these skip with a clear message rather than fail.
//!
//! - **Synthetic** (everything else): construct [`Lap`]s directly from in-memory
//!   samples so the distance/alignment maths is tested in isolation — no `.xrk`,
//!   deterministic, one reason to fail.

use std::path::PathBuf;

use crate::support::fixtures::{fixture_path, load_golden, LapsGolden};
use racestudio_analysis::{
    align_by_distance, align_by_time, distance_axis, segment_laps, AnalysisError, Lap, LapAxis,
    LapChannel,
};
use racestudio_decode::{decode_session, Session};

const SAMPLE: &str = "aim_official_test.xrk";

/// Resolve the real `.xrk` sample, or `None` (with a skip note) when the
/// git-ignored sample is absent or is a placeholder / partial download.
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

fn golden() -> LapsGolden {
    load_golden("aim_official_test", "laps").expect("load laps golden")
}

fn decoded_session() -> Option<Session> {
    let path = xrk_or_skip(SAMPLE)?;
    Some(decode_session(&path).expect("decode session"))
}

// --------------------------------------------------------------------------- //
// Synthetic-lap builders
// --------------------------------------------------------------------------- //

fn channel(name: &str, samples: &[(f64, f64)]) -> LapChannel {
    LapChannel::new(name, samples.to_vec())
}

/// A lap starting at `start_ms` whose absolute sample times are `start_ms + dt`,
/// carrying a `GPS Speed` (m/s) channel and one named value channel.
fn lap_with(
    number: u32,
    start_ms: f64,
    speed: &[(f64, f64)],
    value_name: &str,
    value: &[(f64, f64)],
) -> Lap {
    let end_ms = speed
        .iter()
        .chain(value)
        .map(|&(t, _)| t)
        .fold(start_ms, f64::max)
        + 1.0;
    Lap::new(
        number,
        start_ms,
        end_ms,
        vec![channel("GPS Speed", speed), channel(value_name, value)],
    )
}

fn is_monotonic(values: &[f64]) -> bool {
    values.windows(2).all(|w| w[1] >= w[0])
}

// --------------------------------------------------------------------------- //
// Golden oracle: segmentation
// --------------------------------------------------------------------------- //

#[test]
fn test_lap_count_matches_golden() {
    // Given the real session, When segmented, Then the lap count equals the
    // golden beacon-lap count.
    let Some(session) = decoded_session() else {
        return;
    };
    let laps = segment_laps(&session);
    let g = golden();
    assert_eq!(laps.len(), g.lap_count, "lap count vs golden");
    assert_eq!(laps.len(), g.laps.len(), "lap count vs golden entries");
}

#[test]
fn test_lap_start_end_times_match_golden() {
    // Each lap's number and cumulative [start, end) ms window matches the golden
    // within a rounding tolerance (the golden stores integer ms).
    let Some(session) = decoded_session() else {
        return;
    };
    let laps = segment_laps(&session);
    let g = golden();
    assert_eq!(laps.len(), g.laps.len(), "precondition: same count");
    for (lap, gl) in laps.iter().zip(g.laps.iter()) {
        assert_eq!(lap.number(), gl.index, "lap number");
        assert!(
            (lap.start_time_ms() - gl.start_ms as f64).abs() < 1e-3,
            "start for lap {}: {} vs {}",
            gl.index,
            lap.start_time_ms(),
            gl.start_ms
        );
        assert!(
            (lap.end_time_ms() - gl.end_ms as f64).abs() < 1e-3,
            "end for lap {}: {} vs {}",
            gl.index,
            lap.end_time_ms(),
            gl.end_ms
        );
        assert!(
            (lap.duration_ms() - gl.duration_ms as f64).abs() < 1e-3,
            "duration for lap {}",
            gl.index
        );
    }
}

#[test]
fn test_segment_slices_channel_samples_into_lap_window() {
    // Every sample of every channel in a lap lies within that lap's half-open
    // [start, end) time window — proving the segmentation actually slices.
    let Some(session) = decoded_session() else {
        return;
    };
    let laps = segment_laps(&session);
    assert!(!laps.is_empty(), "expected the real session to have laps");
    for lap in &laps {
        for ch in lap.channels() {
            for &(t, _) in ch.samples() {
                assert!(
                    t >= lap.start_time_ms() && t < lap.end_time_ms(),
                    "sample t={t} outside lap {} window [{}, {})",
                    lap.number(),
                    lap.start_time_ms(),
                    lap.end_time_ms()
                );
            }
        }
    }
}

// --------------------------------------------------------------------------- //
// Distance axis
// --------------------------------------------------------------------------- //

#[test]
fn test_distance_axis_is_monotonic() {
    // A non-negative speed channel integrates to a monotonically non-decreasing
    // distance axis, one point per speed sample, starting at zero.
    let speed = [
        (0.0, 10.0),
        (1000.0, 20.0),
        (2000.0, 0.0),
        (3000.0, 15.0),
        (4000.0, 30.0),
    ];
    let lap = lap_with(0, 0.0, &speed, "RPM", &[(0.0, 5000.0)]);

    let axis = distance_axis(&lap, "GPS Speed");

    assert_eq!(
        axis.len(),
        speed.len(),
        "one distance point per speed sample"
    );
    assert_eq!(axis.first().copied(), Some(0.0), "distance starts at 0");
    assert!(is_monotonic(&axis), "distance axis must be non-decreasing");
    assert!(
        axis.last().copied().unwrap_or(0.0) > 0.0,
        "some distance accumulated"
    );
}

#[test]
fn test_distance_axis_missing_speed_channel_is_empty() {
    // A lap without the requested speed channel yields an empty axis, not a panic.
    let lap = Lap::new(0, 0.0, 10.0, vec![channel("RPM", &[(0.0, 1.0)])]);
    assert!(distance_axis(&lap, "GPS Speed").is_empty());
}

// --------------------------------------------------------------------------- //
// Time-domain alignment
// --------------------------------------------------------------------------- //

#[test]
fn test_align_by_time_shares_axis() {
    // Two laps re-based to their own starts share one time-from-start axis; each
    // lap's channel values are paired point-for-point on it.
    let a = lap_with(
        0,
        1000.0,
        &[(1000.0, 5.0), (1100.0, 6.0), (1200.0, 7.0)],
        "RPM",
        &[(1000.0, 10.0), (1100.0, 20.0), (1200.0, 30.0)],
    );
    let b = lap_with(
        1,
        5000.0,
        &[(5000.0, 5.0), (5100.0, 6.0), (5200.0, 7.0)],
        "RPM",
        &[(5000.0, 40.0), (5100.0, 50.0), (5200.0, 60.0)],
    );

    let alignment = align_by_time(&a, &b, "RPM").expect("align by time");

    assert_eq!(alignment.axis_kind(), LapAxis::Time);
    assert_eq!(alignment.len(), 3);
    assert_eq!(alignment.a().len(), alignment.axis().len(), "a shares axis");
    assert_eq!(alignment.b().len(), alignment.axis().len(), "b shares axis");
    assert_eq!(
        alignment.axis(),
        &[0.0, 100.0, 200.0],
        "time from lap start"
    );
    assert!(is_monotonic(alignment.axis()));
    assert_eq!(alignment.a(), &[10.0, 20.0, 30.0], "lap a values");
    assert_eq!(
        alignment.b(),
        &[40.0, 50.0, 60.0],
        "lap b values on same axis"
    );
}

#[test]
fn test_align_by_time_interpolates_offset_axis() {
    // When lap b is sampled at different times, its values are linearly
    // interpolated onto lap a's axis.
    let a = lap_with(
        0,
        0.0,
        &[(0.0, 5.0), (100.0, 5.0)],
        "RPM",
        &[(0.0, 0.0), (100.0, 100.0)],
    );
    // b's RPM: 0 at t=0, 200 at t=200 → at t=100 (a's second point) → 100.
    let b = lap_with(
        1,
        0.0,
        &[(0.0, 5.0), (200.0, 5.0)],
        "RPM",
        &[(0.0, 0.0), (200.0, 200.0)],
    );

    let alignment = align_by_time(&a, &b, "RPM").expect("align by time");
    assert_eq!(alignment.b(), &[0.0, 100.0], "b interpolated at a's times");
}

#[test]
fn test_align_by_time_missing_channel_errors() {
    let a = lap_with(0, 0.0, &[(0.0, 5.0)], "RPM", &[(0.0, 10.0)]);
    let b = lap_with(1, 0.0, &[(0.0, 5.0)], "RPM", &[(0.0, 20.0)]);
    let err = align_by_time(&a, &b, "Throttle").expect_err("missing channel");
    assert_eq!(
        err,
        AnalysisError::MissingChannel {
            name: "Throttle".to_string()
        }
    );
}

#[test]
fn test_align_by_time_empty_channel_errors() {
    let a = Lap::new(0, 0.0, 10.0, vec![channel("RPM", &[])]);
    let b = Lap::new(1, 0.0, 10.0, vec![channel("RPM", &[(0.0, 1.0)])]);
    assert_eq!(
        align_by_time(&a, &b, "RPM").expect_err("empty lap"),
        AnalysisError::EmptyLap
    );
}

// --------------------------------------------------------------------------- //
// Distance-domain alignment
// --------------------------------------------------------------------------- //

#[test]
fn test_align_by_distance_truncates_to_shorter_lap() {
    // Lap a has five channel samples, lap b three; distance alignment truncates
    // to the shorter lap, spanning the shorter lap's distance range.
    let a = lap_with(
        0,
        0.0,
        &[
            (0.0, 10.0),
            (1000.0, 10.0),
            (2000.0, 10.0),
            (3000.0, 10.0),
            (4000.0, 10.0),
        ],
        "RPM",
        &[
            (0.0, 1000.0),
            (1000.0, 2000.0),
            (2000.0, 3000.0),
            (3000.0, 4000.0),
            (4000.0, 5000.0),
        ],
    );
    let b = lap_with(
        1,
        0.0,
        &[(0.0, 10.0), (1000.0, 10.0), (2000.0, 10.0)],
        "RPM",
        &[(0.0, 1500.0), (1000.0, 2500.0), (2000.0, 3500.0)],
    );

    let alignment = align_by_distance(&a, &b, "RPM").expect("align by distance");

    assert_eq!(alignment.axis_kind(), LapAxis::Distance);
    assert_eq!(alignment.len(), 3, "truncated to the shorter lap");
    assert_eq!(alignment.a().len(), 3);
    assert_eq!(alignment.b().len(), 3);
    assert_eq!(alignment.axis().first().copied(), Some(0.0), "spans from 0");
    assert!(
        is_monotonic(alignment.axis()),
        "distance axis non-decreasing"
    );
}

#[test]
fn test_align_by_distance_missing_speed_channel_errors() {
    // Distance alignment needs a GPS Speed channel to integrate.
    let a = Lap::new(0, 0.0, 10.0, vec![channel("RPM", &[(0.0, 1.0)])]);
    let b = Lap::new(1, 0.0, 10.0, vec![channel("RPM", &[(0.0, 2.0)])]);
    assert_eq!(
        align_by_distance(&a, &b, "RPM").expect_err("no speed channel"),
        AnalysisError::MissingChannel {
            name: "GPS Speed".to_string()
        }
    );
}

#[test]
fn test_align_by_distance_missing_value_channel_errors() {
    // Speed is present but the requested value channel is not.
    let a = lap_with(0, 0.0, &[(0.0, 5.0)], "RPM", &[(0.0, 10.0)]);
    let b = lap_with(1, 0.0, &[(0.0, 5.0)], "RPM", &[(0.0, 20.0)]);
    assert_eq!(
        align_by_distance(&a, &b, "Throttle").expect_err("missing value channel"),
        AnalysisError::MissingChannel {
            name: "Throttle".to_string()
        }
    );
}

#[test]
fn test_align_by_distance_empty_value_channel_errors() {
    // Speed present, value channel present but with no samples → EmptyLap.
    let a = Lap::new(
        0,
        0.0,
        10.0,
        vec![channel("GPS Speed", &[(0.0, 5.0)]), channel("RPM", &[])],
    );
    let b = lap_with(1, 0.0, &[(0.0, 5.0)], "RPM", &[(0.0, 20.0)]);
    assert_eq!(
        align_by_distance(&a, &b, "RPM").expect_err("empty value channel"),
        AnalysisError::EmptyLap
    );
}

#[test]
fn test_lap_and_alignment_accessors() {
    // Exercise the value-type accessors directly (fixture-free).
    let lap = lap_with(
        3,
        100.0,
        &[(100.0, 5.0)],
        "RPM",
        &[(100.0, 10.0), (150.0, 12.0)],
    );
    assert_eq!(lap.number(), 3);
    assert_eq!(lap.start_time_ms(), 100.0);
    assert_eq!(lap.duration_ms(), lap.end_time_ms() - lap.start_time_ms());
    assert_eq!(lap.channels().len(), 2);
    let rpm = lap.channel("RPM").expect("RPM channel present");
    assert_eq!(rpm.name(), "RPM");
    assert_eq!(rpm.samples().len(), 2);
    assert!(lap.channel("Missing").is_none());

    let alignment = align_by_time(&lap, &lap, "RPM").expect("align");
    assert!(!alignment.is_empty(), "an aligned pair is non-empty");
}

// --------------------------------------------------------------------------- //
// Edge cases
// --------------------------------------------------------------------------- //

#[test]
fn test_zero_laps_returns_empty() {
    // A valid session with no lap markers segments to an empty lap list, not an
    // error. Built from a synthetic marker-free `.xrk` so it needs no fixture.
    let dir = std::path::Path::new(env!("CARGO_TARGET_TMPDIR"));
    let path = dir.join("no_laps.xrk");
    std::fs::write(&path, synth::frame("RCR", b"DRIVER\0")).expect("write header-only fixture");
    let session = decode_session(&path).expect("decode synthetic session");

    let laps = segment_laps(&session);

    assert!(laps.is_empty(), "no markers → zero laps");
}

#[test]
fn test_single_sample_lap_no_panic() {
    // A lap with a single sample per channel is handled without panic across the
    // distance and alignment paths.
    let lap = lap_with(0, 0.0, &[(0.0, 12.0)], "RPM", &[(0.0, 42.0)]);

    let axis = distance_axis(&lap, "GPS Speed");
    assert_eq!(axis, vec![0.0], "single speed sample → distance 0");

    let by_time = align_by_time(&lap, &lap, "RPM").expect("align by time");
    assert_eq!(by_time.len(), 1);
    assert_eq!(by_time.a(), &[42.0]);
    assert_eq!(by_time.b(), &[42.0]);

    let by_distance = align_by_distance(&lap, &lap, "RPM").expect("align by distance");
    assert_eq!(by_distance.len(), 1);
    assert_eq!(by_distance.a(), &[42.0]);
}

#[test]
fn test_value_types_clone_eq_debug() {
    // Exercise the derived Clone / PartialEq / Debug impls on the public value
    // types (both eq and ne branches), so coverage counts them — these are part
    // of the public surface a consumer relies on.
    let channel = LapChannel::new("RPM", vec![(0.0, 1.0), (1.0, 2.0)]);
    assert_eq!(channel, channel.clone());
    assert_ne!(channel, LapChannel::new("RPM", vec![(0.0, 9.0)]));
    assert!(format!("{channel:?}").contains("RPM"));

    let lap = Lap::new(2, 0.0, 10.0, vec![channel.clone()]);
    assert_eq!(lap, lap.clone());
    assert_ne!(lap, Lap::new(3, 0.0, 10.0, vec![channel]));
    assert!(format!("{lap:?}").contains("Lap"));

    let a = lap_with(
        0,
        0.0,
        &[(0.0, 5.0), (100.0, 6.0)],
        "RPM",
        &[(0.0, 1.0), (100.0, 2.0)],
    );
    let b = lap_with(
        1,
        0.0,
        &[(0.0, 5.0), (100.0, 6.0)],
        "RPM",
        &[(0.0, 3.0), (100.0, 4.0)],
    );
    let alignment = align_by_time(&a, &b, "RPM").expect("align");
    assert_eq!(alignment, alignment.clone());
    assert_ne!(alignment, align_by_time(&a, &a, "RPM").expect("align"));
    assert!(format!("{alignment:?}").contains("Alignment"));

    // LapAxis: Copy / PartialEq / Eq / Debug.
    let kind = alignment.axis_kind();
    let copied = kind;
    assert_eq!(kind, copied);
    assert_eq!(kind, LapAxis::Time);
    assert_ne!(LapAxis::Time, LapAxis::Distance);
    assert!(format!("{:?}", LapAxis::Distance).contains("Distance"));
}

/// Minimal `.xrk` framing helper for the synthetic marker-free fixture.
mod synth {
    const MAGIC: [u8; 2] = [0x3C, 0x68];

    pub fn frame(token: &str, payload: &[u8]) -> Vec<u8> {
        let mut tb = token.as_bytes().to_vec();
        while tb.len() < 4 {
            tb.push(0);
        }
        let tok = u32::from_le_bytes([tb[0], tb[1], tb[2], tb[3]]);
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
}
