//! Tests for lap reconstruction from `Beacon Markers` (issue 5.2).

use racestudio_io::laps_from_beacons;

#[test]
fn test_beacons_reconstruct_start_end_pairs() {
    let laps = laps_from_beacons(&[60.0, 150.0, 210.0]);
    assert_eq!(laps.len(), 3);
    assert_eq!(
        laps.iter().map(|l| l.index()).collect::<Vec<_>>(),
        vec![0, 1, 2]
    );
    // Lap 0: [0, 60]; lap 1: [60, 150] (dur 90); lap 2: [150, 210] (dur 60).
    assert!((laps[0].start_time_s() - 0.0).abs() < 1e-9);
    assert!((laps[0].duration_s() - 60.0).abs() < 1e-9);
    assert!((laps[1].start_time_s() - 60.0).abs() < 1e-9);
    assert!((laps[1].duration_s() - 90.0).abs() < 1e-9);
    assert!((laps[2].end_time_s() - 210.0).abs() < 1e-9);
}

#[test]
fn test_empty_beacons_yields_no_laps() {
    assert!(laps_from_beacons(&[]).is_empty());
}

#[test]
fn test_out_of_order_and_nonfinite_beacons_are_skipped() {
    // A beacon not greater than the previous, or non-finite, is dropped — never a
    // zero/negative-duration lap.
    let laps = laps_from_beacons(&[60.0, 50.0, 150.0, f64::NAN, 200.0]);
    assert_eq!(laps.len(), 3, "50 (≤60) and NaN are skipped");
    for lap in &laps {
        assert!(lap.duration_s() > 0.0, "no non-positive-duration lap");
    }
    assert!((laps[0].duration_s() - 60.0).abs() < 1e-9);
    assert!((laps[1].duration_s() - 90.0).abs() < 1e-9); // 150 − 60
    assert!((laps[2].duration_s() - 50.0).abs() < 1e-9); // 200 − 150
}

#[test]
fn test_leading_nonpositive_beacon_skipped() {
    // A first beacon of 0 (or negative) produces no zero-length lap.
    let laps = laps_from_beacons(&[0.0, 60.0]);
    assert_eq!(laps.len(), 1);
    assert!((laps[0].duration_s() - 60.0).abs() < 1e-9);
}
