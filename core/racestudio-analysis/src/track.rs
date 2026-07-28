//! Track detection & track database (issue 9.2).
//!
//! RaceStudio 3 auto-recognizes the circuit from a session's GPS trace against a
//! bundled track database, then places the start/finish line and sector splits
//! from the track definition instead of from hand-placed beacons. This module is
//! the analysis half of that:
//!
//! - a bundled, versioned [`TrackDb`] of [`TrackDef`]s — a start/finish [`Gate`]
//!   plus ordered sector gates, each a short `(lat, lon)` line the car crosses
//!   ([`bundled_tracks`]);
//! - a matcher [`match_track`] that identifies the circuit from a GPS trace by
//!   **closest-approach** distance of the trace to every gate, so it is robust to
//!   lap direction (distances do not depend on the order the points are visited);
//! - [`auto_splits`], which reads the start/finish and sector-boundary crossing
//!   times of one lap off the matched track's geometry — the auto-splits the UI
//!   surfaces in place of beacon markers.
//!
//! Distances are metric on a **local tangent plane** anchored at each gate: a
//! circuit gate spans metres and a lap point sits within tens of metres of it, so
//! the equirectangular approximation (longitude scaled by `cos(latitude)`) is
//! accurate to well under a metre at that scale. Every entry point is total —
//! empty or unreachable input yields `None`, never a panic — mirroring the rest
//! of the analysis crate.

/// Metres per degree of latitude (WGS84 mean). Longitude metres scale this by
/// `cos(latitude)`. The tangent-plane projection only needs a local scale, so the
/// mean value is exact enough over a gate-sized neighbourhood.
const DEG_M: f64 = 111_320.0;

/// The current bundled-track-database schema version. Bumped when the shape of a
/// [`TrackDef`] changes so a persisted match can be revalidated.
pub const TRACK_DB_VERSION: u32 = 1;

/// The default closest-approach tolerance (metres) [`match_track`] and
/// [`auto_splits`] hold a gate crossing to. Generous enough for GPS scatter
/// (u-blox position accuracy is typically a few metres and a fresh racing line
/// differs from the stored gate by about a car width), yet far tighter than the
/// kilometres separating distinct circuits — so a different track is rejected.
pub const MATCH_TOLERANCE_M: f64 = 40.0;

/// A geographic point in WGS84 degrees.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct LatLon {
    /// Latitude in degrees.
    pub lat: f64,
    /// Longitude in degrees.
    pub lon: f64,
}

impl LatLon {
    /// A point from its latitude and longitude (degrees).
    #[must_use]
    pub fn new(lat: f64, lon: f64) -> Self {
        Self { lat, lon }
    }
}

/// A gate the car crosses: a short line segment between two `(lat, lon)`
/// endpoints. A [`TrackDef`]'s start/finish line and each sector boundary are
/// gates; the car's trace is matched by how close it comes to the segment.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Gate {
    a: LatLon,
    b: LatLon,
}

impl Gate {
    /// A gate from its two endpoints.
    #[must_use]
    pub fn new(a: LatLon, b: LatLon) -> Self {
        Self { a, b }
    }

    /// The gate's first endpoint.
    #[must_use]
    pub fn a(&self) -> LatLon {
        self.a
    }

    /// The gate's second endpoint.
    #[must_use]
    pub fn b(&self) -> LatLon {
        self.b
    }

    /// The gate's midpoint — the nominal line position.
    #[must_use]
    pub fn midpoint(&self) -> LatLon {
        LatLon::new(
            (self.a.lat + self.b.lat) / 2.0,
            (self.a.lon + self.b.lon) / 2.0,
        )
    }

    /// The distance (metres) from `point` to this gate segment, on a local tangent
    /// plane anchored at endpoint `a`.
    #[must_use]
    fn distance_m(&self, point: LatLon) -> f64 {
        let (bx, by) = to_local(self.a, self.b);
        let (px, py) = to_local(self.a, point);
        point_segment_distance(px, py, 0.0, 0.0, bx, by)
    }

    /// The `(index, distance_m)` of the trace point closest to this gate, or `None`
    /// for an empty trace.
    fn closest<P: Positioned>(&self, trace: &[P]) -> Option<(usize, f64)> {
        trace
            .iter()
            .map(|p| self.distance_m(p.position()))
            .enumerate()
            .reduce(|best, next| if next.1 < best.1 { next } else { best })
    }
}

/// One circuit definition: an id, a display name, the start/finish [`Gate`], and
/// the ordered sector-boundary gates. `N` sector gates cut a lap into `N + 1`
/// segments (the start/finish closes the loop).
#[derive(Debug, Clone, PartialEq)]
pub struct TrackDef {
    id: String,
    name: String,
    start_finish: Gate,
    sectors: Vec<Gate>,
}

impl TrackDef {
    /// A track definition from its id, display name, start/finish gate, and ordered
    /// sector gates.
    #[must_use]
    pub fn new(
        id: impl Into<String>,
        name: impl Into<String>,
        start_finish: Gate,
        sectors: Vec<Gate>,
    ) -> Self {
        Self {
            id: id.into(),
            name: name.into(),
            start_finish,
            sectors,
        }
    }

    /// The stable track id (e.g. `adria`).
    #[must_use]
    pub fn id(&self) -> &str {
        &self.id
    }

    /// The human-readable circuit name.
    #[must_use]
    pub fn name(&self) -> &str {
        &self.name
    }

    /// The start/finish gate.
    #[must_use]
    pub fn start_finish(&self) -> &Gate {
        &self.start_finish
    }

    /// The ordered sector-boundary gates (the interior splits).
    #[must_use]
    pub fn sectors(&self) -> &[Gate] {
        &self.sectors
    }

    /// The number of segments a lap is cut into: one more than the sector gates.
    #[must_use]
    pub fn segment_count(&self) -> usize {
        self.sectors.len() + 1
    }

    /// Every gate that a trace must reach for a match: the start/finish gate first,
    /// then the sector gates in order.
    fn gates(&self) -> impl Iterator<Item = &Gate> {
        std::iter::once(&self.start_finish).chain(self.sectors.iter())
    }
}

/// A bundled, versioned set of [`TrackDef`]s.
#[derive(Debug, Clone, PartialEq)]
pub struct TrackDb {
    version: u32,
    tracks: Vec<TrackDef>,
}

impl TrackDb {
    /// A database from its schema version and tracks.
    #[must_use]
    pub fn new(version: u32, tracks: Vec<TrackDef>) -> Self {
        Self { version, tracks }
    }

    /// The database schema version.
    #[must_use]
    pub fn version(&self) -> u32 {
        self.version
    }

    /// The tracks in the database.
    #[must_use]
    pub fn tracks(&self) -> &[TrackDef] {
        &self.tracks
    }

    /// The track with the given id, if present.
    #[must_use]
    pub fn track(&self, id: &str) -> Option<&TrackDef> {
        self.tracks.iter().find(|t| t.id == id)
    }
}

/// The auto-detected splits for one lap on a matched track (issue 9.2): the
/// crossing time of the definition's start/finish line, and the crossing time at
/// each sector gate in track order. These replace beacon markers.
#[derive(Debug, Clone, PartialEq)]
pub struct AutoSplits {
    track_id: String,
    start_finish_ms: f64,
    sector_crossings_ms: Vec<f64>,
}

impl AutoSplits {
    /// The id of the track the splits were read from.
    #[must_use]
    pub fn track_id(&self) -> &str {
        &self.track_id
    }

    /// The timecode (ms) at which the trace crosses the definition's start/finish
    /// line.
    #[must_use]
    pub fn start_finish_ms(&self) -> f64 {
        self.start_finish_ms
    }

    /// The timecode (ms) at each sector-gate crossing, in track order — the
    /// interior boundaries that segment the lap.
    #[must_use]
    pub fn sector_crossings_ms(&self) -> &[f64] {
        &self.sector_crossings_ms
    }

    /// The number of segments the lap is cut into: one more than the sector
    /// crossings.
    #[must_use]
    pub fn segment_count(&self) -> usize {
        self.sector_crossings_ms.len() + 1
    }
}

/// Something with a geographic position — a bare [`LatLon`] or a time-tagged
/// `(timecode_ms, LatLon)` fix — so the geometry helpers work over either.
trait Positioned {
    fn position(&self) -> LatLon;
}

impl Positioned for LatLon {
    fn position(&self) -> LatLon {
        *self
    }
}

impl Positioned for (f64, LatLon) {
    fn position(&self) -> LatLon {
        self.1
    }
}

/// Identify the circuit a GPS `trace` was recorded on, at the default
/// [`MATCH_TOLERANCE_M`] tolerance.
///
/// Returns the matched [`TrackDef`], or `None` when no track's gates are all
/// within tolerance of the trace — the caller then falls back to beacon/lap-marker
/// segmentation. See [`match_track_within`] for the matching rule.
#[must_use]
pub fn match_track<'a>(trace: &[LatLon], db: &'a TrackDb) -> Option<&'a TrackDef> {
    match_track_within(trace, db, MATCH_TOLERANCE_M)
}

/// Identify the circuit a GPS `trace` was recorded on, at a caller-supplied
/// closest-approach `tolerance_m`.
///
/// A track is a **candidate** when the trace comes within `tolerance_m` of *every*
/// one of its gates (start/finish + sectors) — measured as the trace's closest
/// approach to each gate, which is independent of the direction the lap was
/// driven. Among candidates the one whose worst gate is closest wins; ties keep
/// the earlier track in the database. An empty trace, a database with no tracks,
/// or a non-finite tolerance yields `None` (never a panic).
#[must_use]
pub fn match_track_within<'a>(
    trace: &[LatLon],
    db: &'a TrackDb,
    tolerance_m: f64,
) -> Option<&'a TrackDef> {
    if trace.is_empty() || !tolerance_m.is_finite() {
        return None;
    }
    db.tracks
        .iter()
        .filter_map(|track| worst_gate_approach(track, trace).map(|worst| (track, worst)))
        .filter(|&(_, worst)| worst <= tolerance_m)
        .reduce(|best, next| if next.1 < best.1 { next } else { best })
        .map(|(track, _)| track)
}

/// The largest closest-approach distance (metres) over all of `track`'s gates —
/// the worst gate the trace reaches. `None` for an empty trace (no gate can be
/// scored). A track always has at least the start/finish gate, so a non-empty
/// trace always produces a value.
fn worst_gate_approach(track: &TrackDef, trace: &[LatLon]) -> Option<f64> {
    track.gates().try_fold(0.0_f64, |worst, gate| {
        let approach = gate.closest(trace)?.1;
        // A non-finite approach (a NaN fix in the caller-supplied trace) must
        // disqualify the track, not be silently discarded by `f64::max` — else a
        // gate with an undefined distance could pull the worst-case below tolerance
        // and produce a false match.
        approach.is_finite().then(|| worst.max(approach))
    })
}

/// Read the start/finish and sector-boundary crossing times of one lap off
/// `track`'s geometry, at the default [`MATCH_TOLERANCE_M`] tolerance.
///
/// `trace` is the lap's `(timecode_ms, position)` fixes in time order. Returns
/// `None` — so the caller falls back to beacons — when the trace is empty or does
/// not come within tolerance of every gate. See [`auto_splits_within`].
#[must_use]
pub fn auto_splits(trace: &[(f64, LatLon)], track: &TrackDef) -> Option<AutoSplits> {
    auto_splits_within(trace, track, MATCH_TOLERANCE_M)
}

/// Read the start/finish and sector-boundary crossing times of one lap off
/// `track`'s geometry, at a caller-supplied `tolerance_m`.
///
/// The crossing time of a gate is the timecode of the trace fix that comes closest
/// to it. Every gate must be reached within `tolerance_m`, else `None` is returned
/// (the lap did not cover the track — fall back to beacons). Never panics.
#[must_use]
pub fn auto_splits_within(
    trace: &[(f64, LatLon)],
    track: &TrackDef,
    tolerance_m: f64,
) -> Option<AutoSplits> {
    if trace.is_empty() || !tolerance_m.is_finite() {
        return None;
    }
    // The car crosses the gates in track order, so resolve each crossing at or
    // after the previous one — walking the trace once, gate by gate. This keeps the
    // crossing times monotonically non-decreasing even when the lap sweeps past a
    // later gate's vicinity early or revisits a gate (a spin, or two gates that sit
    // close together), so no segment can come out negative-length.
    let crossing = |gate: &Gate, from: usize| -> Option<usize> {
        let (offset, distance) = gate.closest(&trace[from..])?;
        (distance <= tolerance_m).then_some(from + offset)
    };
    let mut cursor = crossing(track.start_finish(), 0)?;
    let start_finish_ms = trace[cursor].0;
    let mut sector_crossings_ms = Vec::with_capacity(track.sectors().len());
    for gate in track.sectors() {
        cursor = crossing(gate, cursor)?;
        sector_crossings_ms.push(trace[cursor].0);
    }
    Some(AutoSplits {
        track_id: track.id.clone(),
        start_finish_ms,
        sector_crossings_ms,
    })
}

/// The bundled, versioned track database (issue 9.2).
///
/// Ships with real circuit geometry so a session recorded at one of these tracks
/// is recognized without any manual beacon placement. Currently:
///
/// - **`adria`** — Adria International Raceway (Italy); gates on the real GPS trace
///   of the `aim_official_test` fixture, the golden-tested match.
/// - **`vallelunga`** — Autodromo Vallelunga (Italy); a second entry ~370 km away
///   so the matcher must discriminate between circuits rather than match the only
///   row present. Its gate geometry is an approximate seed (pending a surveyed
///   trace); a session there still falls back to beacons if it lands outside
///   [`MATCH_TOLERANCE_M`].
#[must_use]
pub fn bundled_tracks() -> TrackDb {
    let ll = LatLon::new;
    let adria = TrackDef::new(
        "adria",
        "Adria International Raceway",
        Gate::new(
            ll(45.0453313357, 12.1489008455),
            ll(45.0453313357, 12.1491551275),
        ),
        vec![
            Gate::new(
                ll(45.0456203571, 12.1493728302),
                ll(45.0456203571, 12.1496271135),
            ),
            Gate::new(
                ll(45.0467156572, 12.1497640068),
                ll(45.0467156572, 12.1500182950),
            ),
            Gate::new(
                ll(45.0464834177, 12.1517181146),
                ll(45.0464834177, 12.1519724018),
            ),
        ],
    );
    let vallelunga = TrackDef::new(
        "vallelunga",
        "Autodromo Vallelunga",
        Gate::new(
            ll(42.1570000000, 12.3648000000),
            ll(42.1570000000, 12.3652000000),
        ),
        vec![
            Gate::new(
                ll(42.1580000000, 12.3658000000),
                ll(42.1580000000, 12.3662000000),
            ),
            Gate::new(
                ll(42.1560000000, 12.3668000000),
                ll(42.1560000000, 12.3672000000),
            ),
        ],
    );
    TrackDb::new(TRACK_DB_VERSION, vec![adria, vallelunga])
}

// --------------------------------------------------------------------------- //
// Geometry
// --------------------------------------------------------------------------- //

/// Project `point` onto a local East/North tangent plane (metres) anchored at
/// `origin` — the equirectangular approximation, exact enough over a gate-sized
/// neighbourhood.
fn to_local(origin: LatLon, point: LatLon) -> (f64, f64) {
    let east = (point.lon - origin.lon) * DEG_M * origin.lat.to_radians().cos();
    let north = (point.lat - origin.lat) * DEG_M;
    (east, north)
}

/// The Euclidean distance from `(px, py)` to the segment `(ax, ay)`–`(bx, by)` in
/// a planar frame. A degenerate (zero-length) segment reduces to point distance.
fn point_segment_distance(px: f64, py: f64, ax: f64, ay: f64, bx: f64, by: f64) -> f64 {
    let (dx, dy) = (bx - ax, by - ay);
    let len2 = dx * dx + dy * dy;
    let t = if len2 == 0.0 {
        0.0
    } else {
        (((px - ax) * dx + (py - ay) * dy) / len2).clamp(0.0, 1.0)
    };
    let (cx, cy) = (ax + t * dx, ay + t * dy);
    ((px - cx).powi(2) + (py - cy).powi(2)).sqrt()
}

#[cfg(test)]
mod tests {
    use super::*;

    /// ~20 m East–West gate centred on `(lat, lon)`.
    fn gate_at(lat: f64, lon: f64) -> Gate {
        let dlon = 10.0 / (DEG_M * lat.to_radians().cos());
        Gate::new(LatLon::new(lat, lon - dlon), LatLon::new(lat, lon + dlon))
    }

    #[test]
    fn test_point_segment_distance_projects_and_clamps() {
        // Perpendicular foot inside the segment: distance is the perpendicular.
        assert!((point_segment_distance(5.0, 3.0, 0.0, 0.0, 10.0, 0.0) - 3.0).abs() < 1e-9);
        // Foot past the far end clamps to that endpoint.
        assert!((point_segment_distance(20.0, 0.0, 0.0, 0.0, 10.0, 0.0) - 10.0).abs() < 1e-9);
        // Foot before the near end clamps to the origin endpoint.
        assert!((point_segment_distance(-4.0, 0.0, 0.0, 0.0, 10.0, 0.0) - 4.0).abs() < 1e-9);
    }

    #[test]
    fn test_point_segment_distance_degenerate_segment_is_point_distance() {
        // Zero-length segment → distance to the single point (3, 4) = 5.
        assert!((point_segment_distance(3.0, 4.0, 0.0, 0.0, 0.0, 0.0) - 5.0).abs() < 1e-9);
    }

    #[test]
    fn test_to_local_scales_longitude_by_cos_latitude() {
        // One degree of longitude at 60° is half a degree of latitude in metres.
        let (east, _) = to_local(LatLon::new(60.0, 0.0), LatLon::new(60.0, 1.0));
        assert!((east - DEG_M * 0.5).abs() < 1e-6, "east {east}");
        let (_, north) = to_local(LatLon::new(60.0, 0.0), LatLon::new(61.0, 0.0));
        assert!((north - DEG_M).abs() < 1e-9, "north {north}");
    }

    #[test]
    fn test_gate_midpoint_is_the_average_of_endpoints() {
        let gate = Gate::new(LatLon::new(45.0, 12.0), LatLon::new(45.0, 12.001));
        let mid = gate.midpoint();
        assert!((mid.lat - 45.0).abs() < 1e-12);
        assert!((mid.lon - 12.0005).abs() < 1e-12);
        // Endpoint accessors round-trip.
        assert_eq!(gate.a(), LatLon::new(45.0, 12.0));
        assert_eq!(gate.b(), LatLon::new(45.0, 12.001));
    }

    #[test]
    fn test_gate_closest_empty_trace_is_none() {
        let gate = gate_at(45.0, 12.0);
        assert!(gate.closest::<LatLon>(&[]).is_none());
    }

    #[test]
    fn test_gate_closest_picks_the_nearest_point() {
        let gate = gate_at(45.0, 12.0);
        let trace = [
            LatLon::new(45.0, 12.010), // far east
            LatLon::new(45.0, 12.000), // on the gate
            LatLon::new(45.0, 11.990), // far west
        ];
        let (index, distance) = gate.closest(&trace).expect("non-empty");
        assert_eq!(index, 1, "the on-gate point is closest");
        assert!(distance < 1e-6, "closest distance ~0, got {distance}");
    }

    #[test]
    fn test_bundled_tracks_is_versioned_and_well_formed() {
        let db = bundled_tracks();
        assert_eq!(db.version(), TRACK_DB_VERSION);
        assert!(db.tracks().len() >= 2, "at least Adria + one discriminant");
        for track in db.tracks() {
            assert!(!track.id().is_empty(), "every track has an id");
            assert!(!track.name().is_empty(), "every track has a name");
            // segment_count is one more than the sector gates.
            assert_eq!(track.segment_count(), track.sectors().len() + 1);
        }
        assert_eq!(
            db.track("adria").map(TrackDef::name),
            Some("Adria International Raceway")
        );
        assert!(db.track("nonesuch").is_none());
    }

    #[test]
    fn test_match_within_rejects_empty_trace_and_nonfinite_tolerance() {
        let db = bundled_tracks();
        assert!(match_track(&[], &db).is_none(), "empty trace never matches");
        let trace = [LatLon::new(45.0453313357, 12.149)];
        assert!(
            match_track_within(&trace, &db, f64::NAN).is_none(),
            "a non-finite tolerance never matches"
        );
    }

    #[test]
    fn test_match_within_needs_every_gate_reached() {
        // A trace on the start/finish gate but nowhere near the sector gates: the
        // worst gate is far, so no match even at a wide tolerance.
        let db = TrackDb::new(
            1,
            vec![TrackDef::new(
                "t",
                "T",
                gate_at(45.0, 12.000),
                vec![gate_at(45.0, 12.050)], // ~3.9 km east — unreached
            )],
        );
        let trace = [LatLon::new(45.0, 12.000)];
        assert!(
            match_track_within(&trace, &db, 100.0).is_none(),
            "one unreached gate blocks the match"
        );
    }

    #[test]
    fn test_match_within_picks_the_closer_of_two_candidates() {
        // Two tracks whose gates both sit within tolerance of the trace; the one the
        // trace passes through more tightly wins.
        let trace = [LatLon::new(45.0, 12.0000)];
        let near = TrackDef::new("near", "Near", gate_at(45.0, 12.00000), vec![]);
        let far = TrackDef::new("far", "Far", gate_at(45.0, 12.00020), vec![]); // ~16 m
        let db = TrackDb::new(1, vec![far.clone(), near.clone()]);
        assert_eq!(
            match_track_within(&trace, &db, 100.0).map(TrackDef::id),
            Some("near"),
            "the tighter-fitting track wins regardless of database order"
        );
    }

    #[test]
    fn test_auto_splits_rejects_empty_and_unreachable() {
        let track = TrackDef::new("t", "T", gate_at(45.0, 12.0), vec![gate_at(45.0, 12.001)]);
        assert!(auto_splits(&[], &track).is_none(), "empty trace → None");
        // A trace far from the gates never crosses them.
        let away = [
            (0.0, LatLon::new(10.0, 10.0)),
            (1.0, LatLon::new(10.0, 10.001)),
        ];
        assert!(
            auto_splits(&away, &track).is_none(),
            "unreached gates → None"
        );
        assert!(
            auto_splits_within(&away, &track, f64::INFINITY).is_none(),
            "a non-finite tolerance is rejected before any crossing search"
        );
    }

    #[test]
    fn test_auto_splits_no_sector_gates_still_reads_start_finish() {
        // A track with only a start/finish gate: one segment, no interior crossings.
        let track = TrackDef::new("t", "T", gate_at(45.0, 12.0), vec![]);
        let trace = [
            (0.0, LatLon::new(45.0, 11.999)),
            (1000.0, LatLon::new(45.0, 12.000)),
            (2000.0, LatLon::new(45.0, 12.001)),
        ];
        let splits = auto_splits(&trace, &track).expect("start/finish reached");
        assert!((splits.start_finish_ms() - 1000.0).abs() < 1e-9);
        assert!(splits.sector_crossings_ms().is_empty());
        assert_eq!(splits.segment_count(), 1);
        assert_eq!(splits.track_id(), "t");
    }

    #[test]
    fn test_auto_splits_crossings_stay_ordered_when_the_trace_passes_a_later_gate_early() {
        // The lap sweeps past sector 2's location early (t = 1000) before it has
        // crossed sector 1 (t = 2000), then reaches sector 2 for real (t = 3000).
        // Resolving each gate independently against the whole trace would snap
        // sector 2 to the early pass (t = 1000) — behind sector 1 — for a negative
        // segment. The in-order walk keeps the crossings monotonic.
        let track = TrackDef::new(
            "t",
            "T",
            gate_at(45.0, 12.000),
            vec![gate_at(45.0, 12.001), gate_at(45.0, 12.002)],
        );
        let trace = [
            (0.0, LatLon::new(45.0, 12.000)),
            (1000.0, LatLon::new(45.0, 12.002)), // near sector 2, early
            (2000.0, LatLon::new(45.0, 12.001)), // sector 1
            (3000.0, LatLon::new(45.0, 12.002)), // sector 2, in order
        ];

        let splits = auto_splits(&trace, &track).expect("gates reachable in order");

        assert_eq!(
            splits.sector_crossings_ms(),
            &[2000.0, 3000.0],
            "crossings are monotonic and in track order, not snapped to the early pass"
        );
        assert!(splits.start_finish_ms() <= splits.sector_crossings_ms()[0]);
    }

    #[test]
    fn test_match_within_rejects_a_trace_with_a_non_finite_point() {
        // A NaN fix must not be silently absorbed into a false-positive match: a
        // gate whose closest approach is undefined disqualifies the track (the
        // caller falls back to beacons) rather than scoring as distance 0.
        let db = TrackDb::new(
            1,
            vec![TrackDef::new("t", "T", gate_at(45.0, 12.0), vec![])],
        );
        let trace = [LatLon::new(f64::NAN, f64::NAN), LatLon::new(45.0, 12.0)];
        assert!(
            match_track_within(&trace, &db, 100.0).is_none(),
            "a non-finite trace point must not yield a false match"
        );
    }
}
