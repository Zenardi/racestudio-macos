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
