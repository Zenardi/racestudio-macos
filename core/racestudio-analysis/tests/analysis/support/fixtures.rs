//! Golden-fixture loader for the analysis tests (issue 3.1).
//!
//! Resolves the repo-root `fixtures/` directory and deserializes the
//! libxrk-derived golden JSON. The lap golden (`*.laps.json`) is the beacon lap
//! table (issue 1.5) — its lap count and cumulative start/end times are the
//! oracle for [`segment_laps`](racestudio_analysis::segment_laps). `.xrk` samples
//! are fetched by `scripts/fetch_fixtures.sh`; the small goldens under
//! `fixtures/golden/` are committed.

use std::fs;
use std::path::PathBuf;

use serde::de::DeserializeOwned;
use serde::Deserialize;

/// Repo root, derived from this crate's manifest dir (`core/racestudio-analysis`).
fn workspace_root() -> PathBuf {
    let manifest = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    manifest
        .parent()
        .and_then(|core| core.parent())
        .expect("workspace root above core/racestudio-analysis")
        .to_path_buf()
}

/// The repo-root `fixtures/` directory.
pub fn fixtures_dir() -> PathBuf {
    workspace_root().join("fixtures")
}

/// Absolute path to a fixture file, e.g. `fixture_path("aim_official_test.xrk")`.
pub fn fixture_path(name: &str) -> PathBuf {
    fixtures_dir().join(name)
}

/// Load and deserialize a golden JSON, e.g.
/// `load_golden::<LapsGolden>("aim_official_test", "laps")` reads
/// `fixtures/golden/aim_official_test.laps.json`.
pub fn load_golden<T: DeserializeOwned>(name: &str, aspect: &str) -> Result<T, String> {
    let file_name = format!("{name}.{aspect}.json");
    let path = fixtures_dir().join("golden").join(&file_name);
    let bytes = fs::read(&path).map_err(|err| {
        format!(
            "golden fixture not found: {file_name} (looked in {}): {err}. \
             Run `make fixtures` to generate it.",
            path.display()
        )
    })?;
    serde_json::from_slice(&bytes)
        .map_err(|err| format!("golden fixture {} is not valid JSON: {err}", path.display()))
}

/// `<name>.decimated.json` — the brute-force min/max decimation envelope of one
/// channel of the synthetic 5M fixture at a fixed bucket count (issue 7.2). The
/// independent oracle for [`min_max_decimate`](racestudio_analysis::min_max_decimate):
/// `envelope` holds two `[time_ms, value]` points per bucket in time order,
/// computed by `scripts/fetch_fixtures.sh --synthetic` straight from the source
/// samples — so it never re-uses the Rust implementation under test.
#[derive(Debug, Deserialize)]
pub struct DecimatedGolden {
    pub file: String,
    /// The channel whose envelope was captured.
    pub channel: String,
    /// The bucket count the envelope was decimated to.
    pub buckets: usize,
    /// The channel's decoded sample count (a lazy-decode cross-check).
    pub sample_count: usize,
    /// Two `[time_ms, value]` envelope points per bucket, in time order.
    pub envelope: Vec<[f64; 2]>,
}

/// `<name>.laps.json` — beacon lap table (issue 1.5): per-lap cumulative times
/// decoded from the container's LAP markers, plus the best (fastest) lap index.
#[derive(Debug, Deserialize)]
pub struct LapsGolden {
    pub file: String,
    pub lap_count: usize,
    pub best_lap_index: Option<u32>,
    pub laps: Vec<LapGolden>,
}

#[derive(Debug, Deserialize)]
pub struct LapGolden {
    pub index: u32,
    pub start_ms: i64,
    pub end_ms: i64,
    pub duration_ms: i64,
}

/// `<name>.delta_t.json` — delta-t of a reference lap vs a comparison lap
/// (issue 3.2), sampled as `(distance, dt_seconds)` at a set of grid distances.
/// Computed from the fixture decoded by the libxrk-validated decoder (M1).
#[derive(Debug, Deserialize)]
pub struct DeltaGolden {
    pub file: String,
    pub reference_index: usize,
    pub comparison_index: usize,
    pub points: Vec<DeltaPoint>,
}

#[derive(Debug, Deserialize)]
pub struct DeltaPoint {
    pub distance: f64,
    pub dt: f64,
}

/// `<name>.resample.json` — one interpolated channel resampled onto a uniform
/// integer-millisecond timebase via libxrk's `resample_to_timecodes` (issue 3.3
/// linear-interpolation oracle).
#[derive(Debug, Deserialize)]
pub struct ResampleGolden {
    pub file: String,
    pub channel: Option<String>,
    pub points: Vec<ResamplePoint>,
}

#[derive(Debug, Deserialize)]
pub struct ResamplePoint {
    pub t: f64,
    pub v: f64,
}

/// `<name>.stats.json` — per-channel whole-session summary statistics (issue
/// 3.4) computed independently with numpy over the libxrk-decoded fixture. The
/// oracle for [`channel_stats`](racestudio_analysis::channel_stats): statistics
/// depend only on the value array, so they are free of the timecode-origin
/// offset between decoders and match to full precision.
#[derive(Debug, Deserialize)]
pub struct StatsGolden {
    pub file: String,
    pub channel_count: usize,
    pub channels: Vec<StatsChannel>,
}

#[derive(Debug, Deserialize)]
pub struct StatsChannel {
    pub name: String,
    /// libxrk's storage type (`double`, `float`, `int16`, `uint16`, …). Drives
    /// the cross-check tolerance: `float` (float32) channels differ from the Rust
    /// float64 decode by up to float32 epsilon.
    pub dtype: String,
    pub count: usize,
    pub min: f64,
    pub max: f64,
    pub mean: f64,
    /// Population standard deviation (divides by `n`).
    pub std_pop: f64,
    /// Sample standard deviation (divides by `n - 1`; `0.0` for a single sample).
    pub std_sample: f64,
    pub rms: f64,
    pub range: f64,
}

/// `<name>.distance.json` — the session-wide cumulative distance axis (issue
/// 8.2), the oracle for the quantity the FFI distance accessors share. `track` is
/// the clamped trapezoidal integral of the `GPS Speed` channel (m/s → m) at a set
/// of fix indices — the oracle for
/// [`cumulative_distance`](racestudio_analysis::cumulative_distance) and, once
/// [`to_distance_grid`](racestudio_analysis::to_distance_grid)-interpolated onto a
/// channel timebase, `samples_with_distance` / `gps_track`. Distances are measured
/// **relative to `ref_index`** (past the session's initial GPS gap), which cancels
/// the constant timecode-origin offset between the two decoders — so relative
/// distance matches to full precision despite that offset.
#[derive(Debug, Deserialize)]
pub struct DistanceGolden {
    pub file: String,
    pub speed_channel: Option<String>,
    /// Reference fix: distances are measured from `cumulative_distance[ref_index]`,
    /// skipping the initial GPS gap so the decoder-origin offset cancels.
    pub ref_index: usize,
    pub fix_count: usize,
    pub total_distance_m: f64,
    pub track: Vec<DistancePoint>,
}

/// One `(fix index, cumulative distance m)` point of the `track` axis.
#[derive(Debug, Deserialize)]
pub struct DistancePoint {
    pub i: usize,
    pub distance: f64,
}

/// `<name>.track.json` — a real GPS trace plus the id of the bundled track it is
/// expected to match (issue 9.2). The oracle for
/// [`match_track`](racestudio_analysis::track::match_track): `trace` is a
/// committed window of real `(lat, lon)` fixes decoded from the fixture, and
/// `expected_match` is the [`bundled_tracks`](racestudio_analysis::track::bundled_tracks)
/// id whose start/finish + sector gates lie on that trace. `tolerance_m` records
/// the closest-approach tolerance the match holds at. Committed (independent of
/// the git-ignored `.xrk`) so the real-data match test always runs.
#[derive(Debug, Deserialize)]
pub struct TrackGolden {
    pub file: String,
    /// The bundled track id the trace is expected to resolve to.
    pub expected_match: String,
    /// Closest-approach tolerance (metres) the recorded match holds at.
    pub tolerance_m: f64,
    /// The real GPS trace, in fix order.
    pub trace: Vec<LatLonGolden>,
}

/// One `(latitude, longitude)` point of a [`TrackGolden`] trace.
#[derive(Debug, Deserialize)]
pub struct LatLonGolden {
    pub lat: f64,
    pub lon: f64,
}

/// `<name>.derived.json` — a contiguous window of GPS-derived channels (issue
/// 3.6). Heading is reconstructed via libxrk's own `gps.ecef_velocity_to_enu`;
/// the acceleration/yaw outputs match libxrk's stored `GPS_*` channels to
/// float32. Each sample carries both the inputs (`t`, `lat`, `lon`, `vel_ecef`,
/// `speed`, `heading`) and the expected outputs (`heading`, `inline_acc`,
/// `yaw_rate`, `lateral_acc`), so the pure functions are validated directly.
#[derive(Debug, Deserialize)]
pub struct DerivedGolden {
    pub file: String,
    pub start_index: usize,
    pub count: usize,
    pub samples: Vec<DerivedSample>,
}

#[derive(Debug, Deserialize)]
pub struct DerivedSample {
    /// Timecode (milliseconds).
    pub t: f64,
    pub lat: f64,
    pub lon: f64,
    /// ECEF velocity `(vx, vy, vz)` in cm/s (heading is unit-independent).
    pub vel_ecef: [f64; 3],
    pub speed: f64,
    pub heading: f64,
    pub inline_acc: f64,
    pub yaw_rate: f64,
    pub lateral_acc: f64,
}
