//! Lap-timing decode tests (issue 1.5).
//!
//! These validate `decode_laps` against the real `aim_official_test.xrk` sample
//! and its libxrk-derived golden (`*.laps.json`), plus the no-marker and
//! truncated paths. As in 1.2–1.4, the `.xrk` sample is git-ignored (fetched by
//! `make fixtures`); when it is absent the oracle tests skip with a clear message
//! rather than fail. The decoder's own logic is covered independently by the unit
//! tests in `src/laps.rs`.
//!
//! The golden is the **beacon lap table** decoded from the container's LAP
//! markers (AiM's own recorded lap times); its lap count matches libxrk's
//! `log.laps` (which is GPS-refined and so has slightly different per-lap times).

mod support;

use std::path::PathBuf;

use racestudio_decode::{decode_laps, open_container, DecodeError, LapData};
use support::fixtures::{fixture_path, load_golden, LapsGolden};

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

fn golden() -> LapsGolden {
    load_golden("aim_official_test", "laps").expect("load laps golden")
}

fn decode() -> Option<LapData> {
    let path = xrk_or_skip(SAMPLE)?;
    let container = open_container(&path).expect("open container");
    Some(decode_laps(&container).expect("decode laps"))
}

#[test]
fn test_lap_count_matches_golden() {
    // Given the .xrk sample, When laps are decoded, Then the lap count equals the
    // golden's.
    let Some(data) = decode() else {
        return;
    };
    assert_eq!(data.laps().len(), golden().lap_count, "lap count");
    assert_eq!(
        data.laps().len(),
        golden().laps.len(),
        "lap count vs entries"
    );
}

#[test]
fn test_lap_durations_within_tolerance() {
    // Each lap's index and duration match the golden within 1e-3 s (the beacon
    // markers are millisecond-precise), and start times are cumulative.
    let Some(data) = decode() else {
        return;
    };
    let g = golden();
    assert_eq!(data.laps().len(), g.laps.len(), "precondition: same count");
    for (lap, gl) in data.laps().iter().zip(g.laps.iter()) {
        assert_eq!(lap.index(), gl.index, "lap index");
        let expected_s = gl.duration_ms as f64 / 1000.0;
        assert!(
            (lap.duration_s() - expected_s).abs() < 1e-3,
            "duration for lap {}: {} vs {}",
            gl.index,
            lap.duration_s(),
            expected_s
        );
        let expected_start_s = gl.start_ms as f64 / 1000.0;
        assert!(
            (lap.start_time_s() - expected_start_s).abs() < 1e-3,
            "start for lap {}: {} vs {}",
            gl.index,
            lap.start_time_s(),
            expected_start_s
        );
    }
}

#[test]
fn test_best_lap_matches_golden() {
    // The best (fastest) lap's index and time match the golden.
    let Some(data) = decode() else {
        return;
    };
    let g = golden();
    assert_eq!(data.best_lap_index(), g.best_lap_index, "best lap index");
    let best = data.best_lap().expect("a best lap");
    let gbest = &g.laps[g.best_lap_index.expect("golden best index") as usize];
    assert_eq!(best.index(), gbest.index, "best lap points to fastest lap");
    assert!(
        (best.duration_s() - gbest.duration_ms as f64 / 1000.0).abs() < 1e-3,
        "best lap time"
    );
    // The best lap really is the minimum duration.
    let min = data
        .laps()
        .iter()
        .map(|l| l.duration_s())
        .fold(f64::INFINITY, f64::min);
    assert!(
        (best.duration_s() - min).abs() < 1e-9,
        "best == min duration"
    );
}

#[test]
fn test_outlap_inlap_handling_matches_libxrk() {
    // libxrk keeps only whole-lap (segment-0) markers and dedups; the raw marker
    // count exceeds the decoded lap count, and the out/in laps (first/last) are
    // the longest, so they are never selected as the best lap.
    let Some(data) = decode() else {
        return;
    };
    let Some(path) = xrk_or_skip(SAMPLE) else {
        return;
    };
    let container = open_container(&path).expect("open");
    assert!(
        container.lap_marker_count() > data.laps().len(),
        "raw markers ({}) exceed decoded laps ({}) after segment/dup filtering",
        container.lap_marker_count(),
        data.laps().len()
    );
    let best = data.best_lap_index().expect("best");
    let last = data.laps().len() as u32 - 1;
    assert_ne!(best, 0, "outlap is not the best lap");
    assert_ne!(best, last, "inlap is not the best lap");
}

#[test]
fn test_no_markers_returns_zero_laps() {
    // A valid container with no LAP markers → empty LapData, no best lap, no panic.
    let dir = std::path::Path::new(env!("CARGO_TARGET_TMPDIR"));
    let path = dir.join("no_laps.xrk");
    std::fs::write(&path, synth::frame("RCR", b"DRIVER\0")).expect("write header-only fixture");
    let container = open_container(&path).expect("open");
    let data = decode_laps(&container).expect("decode");
    assert!(data.laps().is_empty(), "no markers → zero laps");
    assert_eq!(data.best_lap_index(), None, "no best lap");
    assert!(data.is_empty());
}

#[test]
fn test_truncated_lap_table_returns_error() {
    // A LAP marker whose payload is too short for the marker fields → TruncatedLaps.
    let dir = std::path::Path::new(env!("CARGO_TARGET_TMPDIR"));
    let path = dir.join("truncated_laps.xrk");
    std::fs::write(&path, synth::frame("LAP", &[0u8; 8])).expect("write short lap fixture");
    let container = open_container(&path).expect("open");
    let err = decode_laps(&container).expect_err("truncated lap table must error");
    assert!(
        matches!(err, DecodeError::TruncatedLaps),
        "expected TruncatedLaps, got {err:?}"
    );
}

/// Minimal `.xrk` framing helper for the synthetic fixtures.
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
