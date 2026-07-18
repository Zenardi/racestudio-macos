//! Tests for CSV-import unit normalization (issue 5.2) — the strict inverse of
//! the 5.1 writer's km/h scaling.

use racestudio_io::{normalize_unit, normalized_unit};

#[test]
fn test_kmh_speed_channels_normalize_to_ms() {
    for name in ["GPS Speed", "GPS SpdAccuracy"] {
        assert!(
            (normalize_unit(name, "km/h", 36.0) - 10.0).abs() < 1e-12,
            "{name}: 36 km/h → 10 m/s"
        );
        assert_eq!(normalized_unit(name, "km/h"), "m/s");
    }
}

#[test]
fn test_non_speed_channels_pass_through() {
    assert_eq!(normalize_unit("RPM", "rpm", 3000.0), 3000.0);
    assert_eq!(normalized_unit("RPM", "rpm"), "rpm");
    // A speed channel already in m/s is left alone.
    assert_eq!(normalize_unit("GPS Speed", "m/s", 10.0), 10.0);
    assert_eq!(normalized_unit("GPS Speed", "m/s"), "m/s");
    // GPS Latitude in km/h (nonsensical) is NOT a speed channel → unchanged.
    assert_eq!(normalize_unit("GPS Latitude", "km/h", 35.0), 35.0);
}

#[test]
fn test_normalize_is_inverse_of_forward_scale() {
    // The 5.1 forward map scales m/s → km/h (×3.6); normalize must invert it.
    const MS_TO_KMH: f64 = 3.6;
    for v in [0.0, 10.0, 55.5, 100.0] {
        let forward = v * MS_TO_KMH;
        let back = normalize_unit("GPS Speed", "km/h", forward);
        assert!((back - v).abs() < 1e-9, "round-trip {v}");
    }
}

#[test]
fn test_unit_match_is_case_insensitive() {
    assert!((normalize_unit("GPS Speed", "KM/H", 36.0) - 10.0).abs() < 1e-9);
    assert_eq!(normalized_unit("GPS Speed", "Km/h"), "m/s");
}

#[test]
fn test_nan_passes_through() {
    assert!(normalize_unit("GPS Speed", "km/h", f64::NAN).is_nan());
}
