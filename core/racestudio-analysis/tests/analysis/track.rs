//! Track detection & track database acceptance tests (issue 9.2).
//!
//! RaceStudio 3 auto-recognizes the circuit from a session's GPS trace against a
//! bundled track database, then sets the start/finish line and sector splits from
//! the track definition rather than from logged beacons. These are the named
//! acceptance behaviours:
//!
//! - **match** — a real GPS trace resolves to the bundled track whose geometry it
//!   lies on ([`test_matches_known_track_from_gps`], golden-backed);
//! - **unknown** — a trace far from every track resolves to `None`
//!   ([`test_unknown_track_returns_none`]);
//! - **auto start/finish** — the detected start/finish comes from the track
//!   definition ([`test_autodetected_start_finish_matches_definition`]);
//! - **sector splits** — the ordered sector gates cut the lap into segments
//!   ([`test_sector_gates_segment_the_lap`]);
//! - **direction-agnostic** — reversing the trace matches the same track
//!   ([`test_matcher_is_direction_agnostic`]).

use crate::support::fixtures::{load_golden, TrackGolden};
use racestudio_analysis::track::{
    auto_splits, bundled_tracks, match_track, match_track_within, track_direction, Direction, Gate,
    LatLon, TrackDb, TrackDef,
};

/// Metres per degree of latitude — the constant the synthetic gate helpers use to
/// size a gate in metres (longitude scaled by `cos(lat)`).
const DEG_M: f64 = 111_320.0;

fn ll(lat: f64, lon: f64) -> LatLon {
    LatLon::new(lat, lon)
}

/// A ~20 m East–West gate centred on `(lat, lon)`: the car crosses it travelling
/// roughly north/south. 10 m to each side.
fn gate_at(lat: f64, lon: f64) -> Gate {
    let dlon = 10.0 / (DEG_M * lat.to_radians().cos());
    Gate::new(ll(lat, lon - dlon), ll(lat, lon + dlon))
}

/// A one-track database placing `track` under a single-entry [`TrackDb`].
fn db_of(track: TrackDef) -> TrackDb {
    TrackDb::new(1, vec![track])
}

// --------------------------------------------------------------------------- //
// Named acceptance behaviours
// --------------------------------------------------------------------------- //

#[test]
fn test_matches_known_track_from_gps() {
    // GIVEN a real GPS trace over the Adria paddock (the committed golden) and the
    // bundled track database,
    // WHEN it is matched,
    // THEN the correct circuit ("adria") is identified within the golden tolerance.
    let golden: TrackGolden = load_golden("aim_official_test", "track").expect("track golden");
    let trace: Vec<LatLon> = golden.trace.iter().map(|p| ll(p.lat, p.lon)).collect();
    let db = bundled_tracks();

    let matched = match_track_within(&trace, &db, golden.tolerance_m);

    assert_eq!(
        matched.map(TrackDef::id),
        Some(golden.expected_match.as_str()),
        "the real GPS trace should resolve to the bundled {} track",
        golden.expected_match
    );
}

#[test]
fn test_unknown_track_returns_none() {
    // GIVEN a GPS trace far out in the Atlantic — near no bundled track,
    // WHEN it is matched,
    // THEN matching fails cleanly with `None` (the caller falls back to beacons).
    let trace: Vec<LatLon> = (0..20).map(|i| ll(0.0, -30.0 + i as f64 * 1e-4)).collect();
    let db = bundled_tracks();

    let matched = match_track(&trace, &db);

    assert!(
        matched.is_none(),
        "a trace near no track must not match, got {:?}",
        matched.map(TrackDef::id)
    );
}

#[test]
fn test_autodetected_start_finish_matches_definition() {
    // GIVEN a track whose start/finish line is defined at (45.0, 12.000), and a lap
    // whose trace crosses exactly that line at t = 2000 ms,
    let track = TrackDef::new(
        "def-track",
        "Definition Track",
        gate_at(45.0, 12.000),
        vec![gate_at(45.0, 12.002)],
    );
    // An eastbound trace along lat 45.0 passing the start/finish line (lon 12.000)
    // at i = 2 (t = 2000 ms) and the sector gate (lon 12.002) at i = 6.
    let trace: Vec<(f64, LatLon)> = (0..=8)
        .map(|i| (i as f64 * 1000.0, ll(45.0, 11.999 + i as f64 * 0.0005)))
        .collect();

    // WHEN splits are applied,
    let splits = auto_splits(&trace, &track).expect("auto splits for a matched lap");

    // THEN the start/finish boundary is read from the definition's line, at the
    // time the trace actually crossed it — not from any beacon marker.
    assert!(
        (splits.start_finish_ms() - 2000.0).abs() < 1e-9,
        "start/finish crossing {} should be at the definition line (2000 ms)",
        splits.start_finish_ms()
    );
    assert_eq!(splits.track_id(), "def-track");
}

#[test]
fn test_sector_gates_segment_the_lap() {
    // GIVEN a track with a start/finish and two ordered sector gates,
    let track = TrackDef::new(
        "sector-track",
        "Sector Track",
        gate_at(45.0, 12.000),
        vec![gate_at(45.0, 12.001), gate_at(45.0, 12.002)],
    );
    // A west→east lap crossing SF, then sector 1, then sector 2 in time order.
    let trace: Vec<(f64, LatLon)> = (0..=8)
        .map(|i| (i as f64 * 500.0, ll(45.0, 12.0 + i as f64 * 0.00025)))
        .collect();

    // WHEN splits are applied,
    let splits = auto_splits(&trace, &track).expect("auto splits");

    // THEN the two sector gates cut the lap into three segments, crossed in order.
    assert_eq!(splits.segment_count(), 3, "two gates → three segments");
    let crossings = splits.sector_crossings_ms();
    assert_eq!(crossings.len(), 2, "one crossing per sector gate");
    assert!(
        crossings[0] < crossings[1],
        "sector crossings are in track order: {crossings:?}"
    );
    assert!(
        splits.start_finish_ms() <= crossings[0],
        "sectors come after the start/finish crossing"
    );
}

#[test]
fn test_matcher_is_direction_agnostic() {
    // GIVEN a track and a lap trace that runs through its gates,
    let track = TrackDef::new(
        "dir-track",
        "Direction Track",
        gate_at(45.0, 12.000),
        vec![gate_at(45.0, 12.001), gate_at(45.0, 12.002)],
    );
    let db = db_of(track);
    let forward: Vec<LatLon> = (0..=8)
        .map(|i| ll(45.0, 12.0 + i as f64 * 0.00025))
        .collect();
    let mut reversed = forward.clone();
    reversed.reverse();

    // WHEN the same lap is matched in each direction,
    let forward_match = match_track(&forward, &db).map(TrackDef::id);
    let reversed_match = match_track(&reversed, &db).map(TrackDef::id);

    // THEN both resolve to the same track — matching is robust to lap direction.
    assert_eq!(forward_match, Some("dir-track"));
    assert_eq!(
        forward_match, reversed_match,
        "reversing the trace must not change the match"
    );
}

// --------------------------------------------------------------------------- //
// Layout & direction (track database metadata).
//
// A venue can be driven in more than one configuration — a shorter layout, or the
// same layout the other way round — and lap times are only comparable within one.
// A definition therefore carries the layout it describes and the direction it is
// driven, and `track_direction` reports the direction a trace was *actually*
// driven so a session can be checked against the definition.
// --------------------------------------------------------------------------- //

/// A closed loop of `n` points around `(lat, lon)`, radius `radius_m`, walked
/// counter-clockwise when `ccw` (increasing bearing: east, then north).
fn loop_trace(lat: f64, lon: f64, radius_m: f64, n: usize, ccw: bool) -> Vec<LatLon> {
    let k = lat.to_radians().cos();
    (0..n)
        .map(|i| {
            let mut a = (i as f64 / n as f64) * std::f64::consts::TAU;
            if !ccw {
                a = -a;
            }
            ll(
                lat + radius_m * a.sin() / DEG_M,
                lon + radius_m * a.cos() / (DEG_M * k),
            )
        })
        .collect()
}

#[test]
fn test_direction_of_a_counter_clockwise_loop() {
    // GIVEN a loop walked with increasing bearing (east then north), WHEN its
    // direction is derived, THEN it reads counter-clockwise.
    let trace = loop_trace(-22.777, -47.120, 100.0, 64, true);

    assert_eq!(track_direction(&trace), Some(Direction::CounterClockwise));
}

#[test]
fn test_direction_of_a_clockwise_loop() {
    let trace = loop_trace(-22.777, -47.120, 100.0, 64, false);

    assert_eq!(track_direction(&trace), Some(Direction::Clockwise));
}

#[test]
fn test_direction_is_the_same_wherever_the_lap_starts() {
    // The direction is a property of the loop, not of where the logger happened to
    // start recording, so rotating the trace must not change it.
    let trace = loop_trace(-22.777, -47.120, 100.0, 64, true);
    let rotated: Vec<LatLon> = trace[20..]
        .iter()
        .chain(trace[..20].iter())
        .copied()
        .collect();

    assert_eq!(track_direction(&rotated), track_direction(&trace));
}

#[test]
fn test_direction_of_a_straight_line_is_unknown() {
    // A trace that encloses no area has no rotation direction — an out-lap down a
    // pit straight must not be reported as either.
    let straight: Vec<LatLon> = (0..20)
        .map(|i| ll(-22.777 + i as f64 * 1e-4, -47.120))
        .collect();

    assert_eq!(track_direction(&straight), None);
}

#[test]
fn test_direction_of_too_few_points_is_unknown() {
    assert_eq!(track_direction(&[]), None);
    assert_eq!(
        track_direction(&[ll(-22.777, -47.120), ll(-22.778, -47.121)]),
        None
    );
}

#[test]
fn test_a_definition_records_no_layout_or_direction_by_default() {
    // Most bundled tracks predate this metadata; absent is reported as absent
    // rather than guessed, so the UI can say "not recorded".
    let track = TrackDef::new("t", "T", gate_at(45.0, 12.0), vec![]);

    assert_eq!(track.layout(), "");
    assert_eq!(track.direction(), None);
    assert_eq!(track.display_name(), "T");
}

#[test]
fn test_a_definition_carries_its_layout_and_direction() {
    let track = TrackDef::new("t", "T", gate_at(45.0, 12.0), vec![])
        .with_layout("Layout 2")
        .with_direction(Direction::CounterClockwise);

    assert_eq!(track.layout(), "Layout 2");
    assert_eq!(track.direction(), Some(Direction::CounterClockwise));
    assert_eq!(track.display_name(), "T — Layout 2");
}

#[test]
fn test_the_bundled_database_has_unique_ids() {
    // Ids key a persisted match, so a duplicate would make a stored detection
    // ambiguous.
    let db = bundled_tracks();
    let mut ids: Vec<&str> = db.tracks().iter().map(TrackDef::id).collect();
    ids.sort_unstable();
    let count = ids.len();
    ids.dedup();

    assert_eq!(
        ids.len(),
        count,
        "duplicate track id in the bundled database"
    );
}

#[test]
fn test_san_marino_is_bundled_with_its_layout_and_direction() {
    // The user's home circuit. Its logger stamps the venue inconsistently (one
    // session arrived named after a different track entirely), so the database is
    // what identifies it.
    let db = bundled_tracks();
    let track = db
        .track("sanmarino-kart-l2")
        .expect("San Marino Kart Layout 2 is bundled");

    assert_eq!(track.name(), "Kartódromo San Marino");
    assert_eq!(track.layout(), "Layout 2");
    assert_eq!(
        track.direction(),
        Some(Direction::CounterClockwise),
        "driven anti-horário"
    );
    assert_eq!(
        track.segment_count(),
        3,
        "two sector gates cut the lap in three"
    );
}

#[test]
fn test_san_marino_matches_a_trace_along_its_own_geometry() {
    // A trace threaded through the definition's own gates must resolve to it —
    // the geometry is derived from 15 beacon crossings that clustered within 2.2 m.
    let db = bundled_tracks();
    let track = db.track("sanmarino-kart-l2").expect("bundled");
    let trace: Vec<LatLon> = std::iter::once(track.start_finish())
        .chain(track.sectors())
        .map(|gate| gate.midpoint())
        .collect();

    let matched = match_track(&trace, &db).expect("its own gates must match");

    assert_eq!(matched.id(), "sanmarino-kart-l2");
}

#[test]
fn test_a_trace_at_another_circuit_does_not_match_san_marino() {
    // Adria is in Italy; San Marino Kart is in Brazil. Thousands of kilometres must
    // not be within tolerance of each other.
    let db = bundled_tracks();
    let adria = db.track("adria").expect("bundled");
    let trace = vec![adria.start_finish().midpoint()];

    let matched = match_track(&trace, &db);

    assert_ne!(matched.map(TrackDef::id), Some("sanmarino-kart-l2"));
}

#[test]
fn test_adria_records_the_direction_its_official_capture_runs() {
    let db = bundled_tracks();
    let adria = db.track("adria").expect("bundled");

    assert_eq!(adria.direction(), Some(Direction::Clockwise));
    assert_eq!(
        adria.layout(),
        "",
        "a single-configuration venue names no layout"
    );
    assert_eq!(adria.display_name(), "Adria International Raceway");
}
