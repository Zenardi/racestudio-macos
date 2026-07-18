//! Tests for the synthesized `GPS Heading` (issue 5.1) — a direct port of
//! `xrk2csv.compute_heading`: great-circle bearing between consecutive fixes,
//! near-stationary segments held at the last valid heading, never `NaN`.

use racestudio_io::compute_heading;

/// A degree of longitude at the equator is ~111 km, so a 0.001° step is ~111 m —
/// far above the 5 cm stationary threshold.
const STEP_DEG: f64 = 0.001;

#[test]
fn test_heading_northeast_bearing() {
    // Moving equally north and east from the equator → a 45° bearing.
    let heading = compute_heading(&[0.0, STEP_DEG], &[0.0, STEP_DEG]);
    assert_eq!(heading.len(), 2);
    assert!(
        (heading[0] - 45.0).abs() < 0.5,
        "north-east bearing ~45°, got {}",
        heading[0]
    );
}

#[test]
fn test_heading_holds_last_valid_when_stationary() {
    // Segment 0 moves due east (bearing 90°); segment 1 is stationary, so its
    // undefined bearing is held at the last valid heading rather than going NaN.
    let heading = compute_heading(&[0.0, 0.0, 0.0], &[0.0, STEP_DEG, STEP_DEG]);
    assert_eq!(heading.len(), 3);
    for (i, &h) in heading.iter().enumerate() {
        assert!((h - 90.0).abs() < 0.5, "heading[{i}] held at ~90°, got {h}");
    }
}

#[test]
fn test_heading_leading_stationary_is_backfilled() {
    // Segment 0 is stationary (undefined) and precedes any valid heading, so it
    // is back-filled from the first valid bearing (90°) — never left NaN.
    let heading = compute_heading(&[0.0, 0.0, 0.0], &[0.0, 0.0, STEP_DEG]);
    assert_eq!(heading.len(), 3);
    assert!(
        (heading[0] - 90.0).abs() < 0.5,
        "leading stationary back-filled to ~90°, got {}",
        heading[0]
    );
}

#[test]
fn test_heading_all_stationary_is_zero() {
    // Every segment is stationary → every bearing is undefined → all masked to 0
    // (nan→0), never NaN.
    let heading = compute_heading(&[35.0, 35.0, 35.0], &[139.0, 139.0, 139.0]);
    assert_eq!(heading, vec![0.0, 0.0, 0.0]);
}

#[test]
fn test_heading_fewer_than_two_points_is_zero() {
    assert_eq!(compute_heading(&[35.0], &[139.0]), vec![0.0]);
    assert_eq!(compute_heading(&[], &[]), Vec::<f64>::new());
}

#[test]
fn test_heading_all_nan_latitude_does_not_panic() {
    // An all-NaN latitude makes the mean-latitude undefined (nanmean over no
    // finite values); the result must still be finite, never a panic.
    let heading = compute_heading(&[f64::NAN, f64::NAN], &[139.0, 139.001]);
    assert_eq!(heading.len(), 2);
    for &h in &heading {
        assert!(h.is_finite(), "NaN latitude must not leak into the heading");
    }
}

#[test]
fn test_heading_is_never_nan_and_in_range() {
    // A mixed moving/stationary track: every output is finite and within 0..360.
    let lat = [0.0, 0.001, 0.001, 0.002, 0.002];
    let lon = [0.0, 0.001, 0.001, 0.000, 0.000];
    let heading = compute_heading(&lat, &lon);
    assert_eq!(heading.len(), lat.len());
    for &h in &heading {
        assert!(h.is_finite(), "heading must never be NaN, got {h}");
        assert!((0.0..360.0).contains(&h), "heading in [0,360), got {h}");
    }
}
