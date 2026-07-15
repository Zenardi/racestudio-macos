//! Golden-fixture loader shared by decode tests (issue 0.5).
//!
//! Resolves the repo-root `fixtures/` directory and deserializes the
//! libxrk-derived golden JSON. `.xrk` samples are fetched by
//! `scripts/fetch_fixtures.sh`; the small goldens under `fixtures/golden/` are
//! committed and act as the decode oracle for M1+.

use std::fs;
use std::path::PathBuf;

use serde::de::DeserializeOwned;
use serde::Deserialize;

/// Repo root, derived from this crate's manifest dir (`core/racestudio-decode`).
fn workspace_root() -> PathBuf {
    let manifest = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    manifest
        .parent()
        .and_then(|core| core.parent())
        .expect("workspace root above core/racestudio-decode")
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
/// `load_golden::<ChannelsGolden>("aim_official_test", "channels")` reads
/// `fixtures/golden/aim_official_test.channels.json`.
///
/// Returns a clear, actionable error (naming the file and how to regenerate it)
/// rather than a silent empty result when the golden is missing or malformed.
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

// --------------------------------------------------------------------------- //
// Golden schemas (mirror scripts/gen_goldens.py output).
// --------------------------------------------------------------------------- //

/// `<name>.channels.json` — channel inventory + per-channel summary stats.
#[derive(Debug, Deserialize)]
pub struct ChannelsGolden {
    pub file: String,
    pub channel_count: usize,
    pub channels: Vec<ChannelSummary>,
}

#[derive(Debug, Deserialize)]
pub struct ChannelSummary {
    pub name: String,
    pub units: String,
    pub decimals: i64,
    pub samples: usize,
    pub t_first_ms: Option<i64>,
    pub t_last_ms: Option<i64>,
    pub min: Option<f64>,
    pub max: Option<f64>,
    pub first: Option<f64>,
    pub last: Option<f64>,
}

/// `<name>.metadata.json` — container header metadata + structural counts
/// (issue 1.2). Metadata strings come from libxrk's `log.metadata`; the counts
/// come from a byte-level walk of the message framing.
#[derive(Debug, Deserialize)]
pub struct MetadataGolden {
    pub file: String,
    pub driver: String,
    pub vehicle: String,
    pub track: String,
    pub session: String,
    pub series: String,
    pub log_date: String,
    pub log_time: String,
    pub datetime_utc: i64,
    pub channel_count: usize,
    pub has_gps: bool,
    pub lap_marker_count: usize,
}

/// `<name>.laps.json` — lap beacons.
#[derive(Debug, Deserialize)]
pub struct LapsGolden {
    pub file: String,
    pub lap_count: usize,
    pub laps: Vec<Lap>,
}

#[derive(Debug, Deserialize)]
pub struct Lap {
    pub num: i64,
    pub start_ms: i64,
    pub end_ms: i64,
    pub duration_ms: i64,
}
