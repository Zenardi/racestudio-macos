//! Derived-channel tests (issue 3.6).
//!
//! - **Golden** (`test_heading_matches_libxrk_golden`,
//!   `test_longitudinal_accel_matches_golden`, `test_lateral_accel_matches_golden`,
//!   `test_yaw_rate_matches_golden`): reproduce libxrk's computed GPS channels
//!   over a contiguous window. The golden is self-contained (inputs + expected
//!   outputs), so these run without the `.xrk` sample.
//! - **Convention / formula** (`test_heading_north_is_zero_east_is_ninety`,
//!   `test_yaw_rate_handles_180_wraparound`): the ENU heading convention and the
//!   ±180° yaw wrap on hand-built inputs.
//! - **Gear** (`test_gear_estimate_*`): nearest-centroid gear, stable under
//!   noise, 0 (neutral) when stopped.
//! - **Edge** (`test_fewer_than_two_fixes_no_panic`, dt guards): empty / single
//!   input and non-positive `dt` never panic.

use crate::support::fixtures::{load_golden, DerivedGolden};
use racestudio_analysis::{
    gear_estimate, heading, lateral_accel_g, longitudinal_accel_g, yaw_rate, GearRatios,
};

fn derived_golden() -> DerivedGolden {
    load_golden("aim_official_test", "derived").expect("derived golden")
}

/// Relative-or-absolute closeness: `tol` relative for large magnitudes, `tol`
/// absolute near zero.
fn close(a: f64, b: f64, tol: f64) -> bool {
    (a - b).abs() <= tol * b.abs().max(1.0)
}

// --------------------------------------------------------------------------- //
// Heading
// --------------------------------------------------------------------------- //

#[test]
fn test_heading_matches_libxrk_golden() {
    let golden = derived_golden();
    assert_eq!(golden.file, "aim_official_test.xrk");
    assert!(golden.count >= 100, "golden has a real window");

    let lat: Vec<f64> = golden.samples.iter().map(|s| s.lat).collect();
    let lon: Vec<f64> = golden.samples.iter().map(|s| s.lon).collect();
    let vel: Vec<(f64, f64, f64)> = golden
        .samples
        .iter()
        .map(|s| (s.vel_ecef[0], s.vel_ecef[1], s.vel_ecef[2]))
        .collect();

    let out = heading(&lat, &lon, &vel);

    assert_eq!(out.len(), golden.samples.len());
    for (got, sample) in out.iter().zip(&golden.samples) {
        assert!(
            (got - sample.heading).abs() < 1e-4,
            "heading {got} vs libxrk {} (t={})",
            sample.heading,
            sample.t
        );
    }
}

#[test]
fn test_heading_north_is_zero_east_is_ninety() {
    // At the equator/prime meridian, ENU maps ECEF velocity to headings:
    // due north (+Z) → 0°, due east (+Y) → 90°, due south (−Z) → 180°/−180°,
    // due west (−Y) → −90°.
    assert!(
        heading(&[0.0], &[0.0], &[(0.0, 0.0, 1.0)])[0].abs() < 1e-9,
        "north"
    );
    assert!(
        (heading(&[0.0], &[0.0], &[(0.0, 1.0, 0.0)])[0] - 90.0).abs() < 1e-9,
        "east"
    );
    assert!(
        (heading(&[0.0], &[0.0], &[(0.0, -1.0, 0.0)])[0] + 90.0).abs() < 1e-9,
        "west"
    );
    assert!(
        (heading(&[0.0], &[0.0], &[(0.0, 0.0, -1.0)])[0].abs() - 180.0).abs() < 1e-9,
        "south is ±180"
    );
}

// --------------------------------------------------------------------------- //
// Yaw rate
// --------------------------------------------------------------------------- //

#[test]
fn test_yaw_rate_handles_180_wraparound() {
    // heading 179 → −179 (a +2° turn across the ±180 seam), then back.
    let h = [179.0, -179.0, 179.0];
    let t = [0.0, 1000.0, 2000.0];
    let yaw = yaw_rate(&h, &t);

    assert_eq!(yaw[0], 0.0, "first sample has no predecessor");
    assert!(
        (yaw[1] - 2.0).abs() < 1e-9,
        "−358 wraps to +2 over 1 s: {}",
        yaw[1]
    );
    assert!(
        (yaw[2] + 2.0).abs() < 1e-9,
        "+358 wraps to −2 over 1 s: {}",
        yaw[2]
    );
}

#[test]
fn test_yaw_rate_matches_golden() {
    let golden = derived_golden();
    let head: Vec<f64> = golden.samples.iter().map(|s| s.heading).collect();
    let t: Vec<f64> = golden.samples.iter().map(|s| s.t).collect();

    let out = yaw_rate(&head, &t);

    assert_eq!(out.len(), golden.samples.len());
    for (got, sample) in out.iter().zip(&golden.samples) {
        assert!(
            close(*got, sample.yaw_rate, 1e-9),
            "yaw {got} vs libxrk {} (t={})",
            sample.yaw_rate,
            sample.t
        );
    }
}

// --------------------------------------------------------------------------- //
// Acceleration
// --------------------------------------------------------------------------- //

#[test]
fn test_longitudinal_accel_matches_golden() {
    let golden = derived_golden();
    let speed: Vec<f64> = golden.samples.iter().map(|s| s.speed).collect();
    let t: Vec<f64> = golden.samples.iter().map(|s| s.t).collect();

    let out = longitudinal_accel_g(&speed, &t);

    assert_eq!(out.len(), golden.samples.len());
    for (got, sample) in out.iter().zip(&golden.samples) {
        assert!(
            close(*got, sample.inline_acc, 1e-9),
            "inline_acc {got} vs libxrk {} (t={})",
            sample.inline_acc,
            sample.t
        );
    }
}

#[test]
fn test_lateral_accel_matches_golden() {
    let golden = derived_golden();
    let speed: Vec<f64> = golden.samples.iter().map(|s| s.speed).collect();
    let head: Vec<f64> = golden.samples.iter().map(|s| s.heading).collect();
    let t: Vec<f64> = golden.samples.iter().map(|s| s.t).collect();

    let out = lateral_accel_g(&speed, &head, &t);

    assert_eq!(out.len(), golden.samples.len());
    for (got, sample) in out.iter().zip(&golden.samples) {
        assert!(
            close(*got, sample.lateral_acc, 1e-9),
            "lateral_acc {got} vs libxrk {} (t={})",
            sample.lateral_acc,
            sample.t
        );
    }
}

#[test]
fn test_longitudinal_accel_formula() {
    // speed 0→9.81 m/s over 1 s = 1 g.
    let out = longitudinal_accel_g(&[0.0, 9.81], &[0.0, 1000.0]);
    assert_eq!(out[0], 0.0);
    assert!((out[1] - 1.0).abs() < 1e-9);
}

// --------------------------------------------------------------------------- //
// dt guard (non-positive → Inf → 0, never a panic)
// --------------------------------------------------------------------------- //

#[test]
fn test_nonpositive_dt_is_guarded() {
    // Repeated timecode (dt = 0) → the derivative is guarded to 0, not Inf/NaN.
    let yaw = yaw_rate(&[0.0, 90.0], &[100.0, 100.0]);
    assert_eq!(yaw[1], 0.0, "dt = 0 → 0");

    // Decreasing timecode (dt < 0) → likewise 0.
    let accel = longitudinal_accel_g(&[0.0, 10.0], &[100.0, 50.0]);
    assert_eq!(accel[1], 0.0, "dt < 0 → 0");
}

// --------------------------------------------------------------------------- //
// Gear estimate
// --------------------------------------------------------------------------- //

#[test]
fn test_gear_estimate_zero_when_stopped() {
    let ratios = GearRatios::new([100.0, 60.0, 45.0]);
    // Stopped (speed 0), even with engine revving, is neutral (0).
    let gears = gear_estimate(&[0.0, 3000.0, 3000.0], &[0.0, 0.0, 30.0], &ratios);
    assert_eq!(gears[0], 0, "idle & stopped → neutral");
    assert_eq!(gears[1], 0, "revving but stopped → neutral");
    assert!(gears[2] > 0, "moving → a gear");
}

#[test]
fn test_gear_estimate_nearest_centroid() {
    let ratios = GearRatios::new([100.0, 60.0, 45.0]); // gears 1, 2, 3
                                                       // ratio 30·100 / 30 = 100 → gear 1; 30·60/30 = 60 → gear 2; 45 → gear 3.
    assert_eq!(gear_estimate(&[3000.0], &[30.0], &ratios), vec![1]);
    assert_eq!(gear_estimate(&[1800.0], &[30.0], &ratios), vec![2]);
    assert_eq!(gear_estimate(&[1350.0], &[30.0], &ratios), vec![3]);
}

#[test]
fn test_gear_estimate_is_stable_under_noise() {
    // rpm/speed jittered around gear 2's centroid (ratio 60) stays gear 2.
    let ratios = GearRatios::new([100.0, 60.0, 45.0]);
    let mut state = 0x1234_5678_u64;
    for _ in 0..500 {
        state = state
            .wrapping_mul(6_364_136_223_846_793_005)
            .wrapping_add(1_442_695_040_888_963_407);
        let jitter = ((state >> 40) & 0xFFFF) as f64 / 65_536.0 - 0.5; // −0.5..0.5
        let speed = 25.0 + jitter * 4.0;
        let rpm = 60.0 * speed + jitter * 30.0; // ratio ≈ 60 with noise
        assert_eq!(
            gear_estimate(&[rpm], &[speed], &ratios),
            vec![2],
            "noisy ratio near 60 stays gear 2"
        );
    }
}

#[test]
fn test_gear_estimate_empty_ratios_is_neutral() {
    let ratios = GearRatios::new([]);
    assert_eq!(gear_estimate(&[3000.0], &[30.0], &ratios), vec![0]);
}

#[test]
fn test_gear_estimate_respects_min_speed_threshold() {
    // A raised stopped-threshold treats a slow crawl as neutral.
    let ratios = GearRatios::new([60.0]).with_min_speed(10.0);
    assert_eq!(
        gear_estimate(&[600.0], &[5.0], &ratios),
        vec![0],
        "below threshold → neutral"
    );
    assert_eq!(
        gear_estimate(&[900.0], &[15.0], &ratios),
        vec![1],
        "above threshold → gear (ratio 60)"
    );
}

// --------------------------------------------------------------------------- //
// Fewer than two fixes / empty input never panics
// --------------------------------------------------------------------------- //

#[test]
fn test_fewer_than_two_fixes_no_panic() {
    // Empty input → empty output.
    assert!(heading(&[], &[], &[]).is_empty());
    assert!(yaw_rate(&[], &[]).is_empty());
    assert!(longitudinal_accel_g(&[], &[]).is_empty());
    assert!(lateral_accel_g(&[], &[], &[]).is_empty());
    assert!(gear_estimate(&[], &[], &GearRatios::new([100.0])).is_empty());

    // A single fix → one value; the diff-based channels are 0 (no predecessor).
    assert_eq!(heading(&[0.0], &[0.0], &[(0.0, 0.0, 1.0)]).len(), 1);
    assert_eq!(yaw_rate(&[42.0], &[0.0]), vec![0.0]);
    assert_eq!(longitudinal_accel_g(&[5.0], &[0.0]), vec![0.0]);
    assert_eq!(lateral_accel_g(&[5.0], &[42.0], &[0.0]), vec![0.0]);
}
