//! GPS-decode tests (issue 1.4).
//!
//! These validate `decode_gps` against the real `aim_official_test.xrk` sample
//! and its libxrk-derived golden (`*.gps.json`), plus the no-GPS and truncated
//! paths. As in 1.2/1.3, the `.xrk` sample is git-ignored (fetched by
//! `make fixtures`); when it is absent the oracle tests skip with a clear message
//! rather than fail. The decoder's own logic is covered independently by the unit
//! tests in `src/gps.rs`.

mod support;

use std::path::PathBuf;

use racestudio_decode::{decode_gps, open_container, DecodeError, GpsChannelKind, GpsData};
use support::fixtures::{fixture_path, load_golden, GpsChannelSummary, GpsGolden};

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

fn golden() -> GpsGolden {
    load_golden("aim_official_test", "gps").expect("load gps golden")
}

fn decode() -> Option<GpsData> {
    let path = xrk_or_skip(SAMPLE)?;
    let container = open_container(&path).expect("open container");
    Some(
        decode_gps(&container)
            .expect("decode gps")
            .expect("sample has gps"),
    )
}

fn gch<'a>(g: &'a GpsGolden, name: &str) -> &'a GpsChannelSummary {
    g.channels
        .iter()
        .find(|c| c.name == name)
        .unwrap_or_else(|| panic!("golden channel {name}"))
}

/// Round to the golden's precision, then compare within 1e-6 (the golden itself
/// is rounded to `decimals`). `None`/non-finite compare equal.
fn approx(actual: Option<f64>, golden: Option<f64>, decimals: i64) -> bool {
    match (actual, golden) {
        (Some(a), Some(g)) if a.is_finite() => {
            let scale = 10f64.powi(decimals as i32);
            ((a * scale).round() / scale - g).abs() < 1e-6
        }
        (None, None) => true,
        (Some(a), None) => !a.is_finite(),
        _ => false,
    }
}

/// First/last/min/max of a GPS channel's finite sample values.
fn stats(samples: &[(f64, f64)]) -> (Option<f64>, Option<f64>, Option<f64>, Option<f64>) {
    let finite: Vec<f64> = samples
        .iter()
        .map(|&(_, v)| v)
        .filter(|v| v.is_finite())
        .collect();
    let first = samples.first().map(|&(_, v)| v);
    let last = samples.last().map(|&(_, v)| v);
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

/// Assert a named GPS channel matches the golden (count + first/last/min/max).
fn assert_channel_matches(data: &GpsData, name: &str) {
    let g = golden();
    let gc = gch(&g, name);
    let ch = data
        .channel(name)
        .unwrap_or_else(|| panic!("decoded channel {name}"));
    assert_eq!(ch.unit(), gc.unit, "unit for {name}");
    assert_eq!(ch.samples().len(), gc.samples, "sample count for {name}");
    let (first, last, min, max) = stats(ch.samples());
    assert!(
        approx(first, gc.first, gc.decimals),
        "first {name}: {first:?} vs {:?}",
        gc.first
    );
    assert!(
        approx(last, gc.last, gc.decimals),
        "last {name}: {last:?} vs {:?}",
        gc.last
    );
    assert!(
        approx(min, gc.min, gc.decimals),
        "min {name}: {min:?} vs {:?}",
        gc.min
    );
    assert!(
        approx(max, gc.max, gc.decimals),
        "max {name}: {max:?} vs {:?}",
        gc.max
    );
}

#[test]
fn test_latlon_match_golden_8dp() {
    // Given the .xrk sample, When GPS is decoded, Then latitude and longitude
    // match the libxrk golden to 8 decimal places, via both the per-sample fixes
    // and the named channels.
    let Some(data) = decode() else {
        return;
    };
    assert_channel_matches(&data, "GPS Latitude");
    assert_channel_matches(&data, "GPS Longitude");

    // The structured fixes expose the same lat/lon.
    let g = golden();
    let fix = data.fixes().first().expect("at least one fix");
    let scale = 1e8;
    assert!(
        ((fix.latitude * scale).round() / scale - gch(&g, "GPS Latitude").first.unwrap()).abs()
            < 1e-8,
        "first fix latitude"
    );
    assert!(
        ((fix.longitude * scale).round() / scale - gch(&g, "GPS Longitude").first.unwrap()).abs()
            < 1e-8,
        "first fix longitude"
    );
}

#[test]
fn test_speed_in_ms_matches_golden() {
    // Speed is stored in m/s and matches the golden within 1e-6; the km/h
    // accessor is exactly 3.6× the m/s value.
    let Some(data) = decode() else {
        return;
    };
    assert_channel_matches(&data, "GPS Speed");
    let fix = data.fixes().first().expect("a fix");
    assert!(
        (fix.speed_kmh() - fix.speed_ms * 3.6).abs() < 1e-9,
        "km/h accessor"
    );
}

#[test]
fn test_altitude_matches_golden() {
    let Some(data) = decode() else {
        return;
    };
    assert_channel_matches(&data, "GPS Altitude");
}

#[test]
fn test_accuracy_and_sats_match_golden() {
    // Position/velocity accuracy match within tolerance; satellite count is exact.
    let Some(data) = decode() else {
        return;
    };
    assert_channel_matches(&data, "GPS_Position_Accuracy");
    assert_channel_matches(&data, "GPS_Velocity_Accuracy");
    assert_channel_matches(&data, "GPS_Satellites");

    // Satellite count is exact integer equality via the structured fix.
    let g = golden();
    let sats = gch(&g, "GPS_Satellites");
    let first_sats = f64::from(data.fixes().first().expect("a fix").satellites);
    assert_eq!(
        first_sats,
        sats.first.unwrap(),
        "first satellite count exact"
    );
}

#[test]
fn test_raw_vs_computed_channels_distinguished() {
    // Raw NAV-SOL channels are Raw; libxrk-derived channels are Computed.
    let Some(data) = decode() else {
        return;
    };
    for name in [
        "GPS Latitude",
        "GPS Longitude",
        "GPS Altitude",
        "GPS Speed",
        "GPS_Satellites",
        "GPS_Fix",
        "GPS_pDOP",
        "GPS_Position_Accuracy",
        "GPS_Velocity_Accuracy",
    ] {
        assert_eq!(
            data.channel(name).unwrap().kind(),
            GpsChannelKind::Raw,
            "{name} is Raw"
        );
    }
    for name in ["GPS_InlineAcc", "GPS_LateralAcc", "GPS_Yaw_Rate"] {
        assert_eq!(
            data.channel(name).unwrap().kind(),
            GpsChannelKind::Computed,
            "{name} is Computed"
        );
    }
    // The golden agrees on the Raw/Computed split.
    let g = golden();
    for gc in &g.channels {
        let kind = data.channel(&gc.name).expect("channel present").kind();
        let expected = if gc.kind == "Raw" {
            GpsChannelKind::Raw
        } else {
            GpsChannelKind::Computed
        };
        assert_eq!(kind, expected, "kind for {}", gc.name);
    }
}

#[test]
fn test_no_gps_group_returns_none() {
    // A valid container with no GPS messages → Ok(None), never a panic.
    let dir = std::path::Path::new(env!("CARGO_TARGET_TMPDIR"));
    let path = dir.join("no_gps.xrk");
    std::fs::write(&path, synth::frame("RCR", b"DRIVER\0")).expect("write header-only fixture");
    let container = open_container(&path).expect("open container");
    assert!(
        decode_gps(&container).expect("decode").is_none(),
        "no gps → None"
    );
}

#[test]
fn test_truncated_gps_returns_error() {
    // A GPS message whose payload is not a whole 56-byte record → TruncatedGps.
    let dir = std::path::Path::new(env!("CARGO_TARGET_TMPDIR"));
    let path = dir.join("truncated_gps.xrk");
    let file = synth::frame("GPS", &[0u8; 40]); // 40 bytes, not a multiple of 56
    std::fs::write(&path, file).expect("write truncated gps fixture");
    let container = open_container(&path).expect("open container");
    let err = decode_gps(&container).expect_err("truncated gps must error");
    assert!(
        matches!(err, DecodeError::TruncatedGps),
        "expected TruncatedGps, got {err:?}"
    );
}

/// Minimal `.xrk` framing helper for the synthetic fixtures.
mod synth {
    const MAGIC: [u8; 2] = [0x3C, 0x68];

    pub fn frame(token: &str, payload: &[u8]) -> Vec<u8> {
        let mut bytes = token.as_bytes().to_vec();
        while bytes.len() < 4 {
            bytes.push(0);
        }
        let tok = u32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]);
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
