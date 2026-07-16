//! Corpus-wide golden conformance harness (issue 1.8).
//!
//! M1's regression net: decode **every** `fixtures/*.xrk` with
//! [`decode_session`] and assert metadata, channels, GPS, and laps match the
//! committed `fixtures/golden/*.json` (the libxrk oracle) within the documented
//! tolerances (see `docs/DECODE_TOLERANCES.md`). It is **data-driven** — dropping
//! a new `.xrk` + golden pair extends coverage with no code change — and every
//! mismatch is reported as a precise, structured [`Mismatch`] diff (fixture,
//! aspect, location, expected vs actual, delta) so a failure is diagnosable.
//!
//! The `.xrk` samples are git-ignored (fetched by `make fixtures`); when the
//! corpus is empty the corpus tests skip with a clear note — except under the
//! e2e gate (`RS_REQUIRE_CORPUS`, set by `scripts/e2e.sh`), where an empty corpus
//! is a hard failure so the gate never passes vacuously. The per-decoder logic
//! is covered by the 1.2–1.5 tests; this harness is pure conformance.
//!
//! `scripts/e2e.sh` runs this harness corpus-wide (exiting non-zero on any
//! mismatch); `test_e2e_script_exits_nonzero_on_mismatch` proves that contract
//! against a deliberately poisoned corpus, and runs only in the e2e context
//! (`RS_RUN_E2E_SCRIPT_TEST=1`, set by `scripts/e2e.sh`).

mod support;

use std::collections::HashSet;
use std::fmt;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::sync::OnceLock;

use serde::de::DeserializeOwned;

use racestudio_decode::{decode_session, open_container, Channel, GpsData, LapData, Metadata};
use support::fixtures::{ChannelsGolden, GpsGolden, LapsGolden, MetadataGolden};

// Tolerances — the single source of truth is docs/DECODE_TOLERANCES.md.
const RATE_TOL_HZ: f64 = 1e-3; // channel native sample rate
const LAP_TIME_TOL_S: f64 = 1e-3; // lap durations / start times (ms-precise beacon markers)
                                  // Floating-point slack below any realistic display quantum, so the exact
                                  // display-precision comparison ignores representation noise but not a one-unit
                                  // difference in the last decimal (e.g. it stays well under 1e-8 for 8-dp lat/lon).
const FP_NOISE: f64 = 1e-9;

/// The fixtures directory, honouring `RS_FIXTURES_DIR` (used by the e2e script's
/// poisoned-corpus self-test) and defaulting to the repo `fixtures/`.
fn fixtures_dir() -> PathBuf {
    std::env::var_os("RS_FIXTURES_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(support::fixtures::fixtures_dir)
}

/// Load a golden JSON from the (possibly overridden) fixtures dir.
fn load_golden<T: DeserializeOwned>(name: &str, aspect: &str) -> Result<T, String> {
    let path = fixtures_dir()
        .join("golden")
        .join(format!("{name}.{aspect}.json"));
    let bytes = std::fs::read(&path)
        .map_err(|err| format!("golden not found: {} ({err})", path.display()))?;
    serde_json::from_slice(&bytes)
        .map_err(|err| format!("golden {} is not valid JSON: {err}", path.display()))
}

/// Whether `path` begins with the `.xrk` header magic (`<h`) — a genuine sample,
/// not a placeholder / LFS pointer / partial download. Reads only the two magic
/// bytes rather than the whole (potentially multi-MB) file.
fn is_genuine_xrk(path: &Path) -> bool {
    let mut magic = [0u8; 2];
    std::fs::File::open(path)
        .and_then(|mut f| f.read_exact(&mut magic))
        .is_ok()
        && &magic == b"<h"
}

/// The corpus: sorted stems of every genuine `<name>.xrk` in the fixtures dir.
fn corpus() -> Vec<String> {
    let mut names = Vec::new();
    let Ok(entries) = std::fs::read_dir(fixtures_dir()) else {
        return names;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.extension().and_then(|e| e.to_str()) != Some("xrk") {
            continue;
        }
        if is_genuine_xrk(&path) {
            if let Some(stem) = path.file_stem().and_then(|s| s.to_str()) {
                names.push(stem.to_string());
            }
        }
    }
    names.sort();
    names
}

/// The corpus for a test, or `None` (skip) when no genuine `.xrk` samples exist.
///
/// A developer running `cargo test` without fetched samples skips gracefully. But
/// the e2e gate must never pass vacuously: when `RS_REQUIRE_CORPUS` is set (as
/// `scripts/e2e.sh` does), an empty corpus is a hard failure rather than a skip —
/// otherwise placeholder/absent samples would make the conformance gate green
/// having validated nothing (the pre-1.8 script hard-failed on a missing oracle).
fn corpus_or_skip() -> Option<Vec<String>> {
    let names = corpus();
    if names.is_empty() {
        assert!(
            std::env::var_os("RS_REQUIRE_CORPUS").is_none(),
            "no genuine .xrk samples in {} but RS_REQUIRE_CORPUS is set — the e2e \
             conformance gate must not pass vacuously; run `make fixtures`",
            fixtures_dir().display()
        );
        eprintln!(
            "skipping: no real .xrk samples in {} — run `make fixtures`",
            fixtures_dir().display()
        );
        return None;
    }
    Some(names)
}

/// One field-level discrepancy between decoded output and the golden oracle.
#[derive(Debug, Clone, PartialEq)]
struct Mismatch {
    fixture: String,
    aspect: String,
    location: String,
    field: String,
    expected: String,
    actual: String,
    delta: Option<f64>,
}

impl fmt::Display for Mismatch {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "[{}] {} · {} · {}: expected {}, actual {}",
            self.fixture, self.aspect, self.location, self.field, self.expected, self.actual
        )?;
        if let Some(delta) = self.delta {
            write!(f, " (Δ={delta:e})")?;
        }
        Ok(())
    }
}

/// Render a batch of mismatches as a multi-line, diagnosable report.
fn render(mismatches: &[Mismatch]) -> String {
    let mut out = format!("{} mismatch(es) vs the libxrk golden:\n", mismatches.len());
    for m in mismatches {
        out.push_str("  - ");
        out.push_str(&m.to_string());
        out.push('\n');
    }
    out
}

/// Whether `actual` matches the golden value to the golden's own display
/// precision — i.e. `actual`, rounded to `decimals`, equals the stored value.
///
/// The golden stores `round(raw, decimals)`, so the tolerance is **half a
/// display quantum** (`0.5 * 10^-decimals`) plus a little FP slack, uniformly for
/// every channel: exact-to-the-last-decimal for low-precision channels AND for
/// 8-dp lat/lon (≈1e-8), rather than a flat 1e-6 that left 8-dp channels ~100×
/// looser than documented. `None`/non-finite compare equal (the golden stores
/// `null` for a non-finite summary).
fn assert_within_tolerance(actual: Option<f64>, expected: Option<f64>, decimals: i64) -> bool {
    match (actual, expected) {
        (Some(a), Some(e)) if a.is_finite() => {
            // Round with the SAME mode the golden generator uses — Python's
            // `round()` is round-half-to-even (banker's), so use `round_ties_even`
            // rather than `f64::round` (half-away-from-zero), which would diverge
            // at exact `.5` boundaries (e.g. fuji YawRate min = -70.25 → -70.2).
            let scale = 10f64.powi(decimals as i32);
            let half_quantum = 0.5 / scale;
            ((a * scale).round_ties_even() / scale - e).abs() < half_quantum + FP_NOISE
        }
        (None, None) => true,
        (Some(a), None) => !a.is_finite(),
        _ => false,
    }
}

/// First/last/min/max of a channel's samples.
///
/// `min`/`max` match how the golden is generated (`np.min`/`np.max` in
/// `gen_goldens.py`): NumPy **propagates** a non-finite sample, so any NaN/±Inf
/// in the channel collapses the golden min/max to `null`. This mirrors that —
/// `None` when any sample is non-finite — rather than silently skipping the
/// non-finite values (which would spuriously mismatch a null golden).
fn stats(samples: &[(f64, f64)]) -> (Option<f64>, Option<f64>, Option<f64>, Option<f64>) {
    let first = samples.first().map(|&(_, v)| v);
    let last = samples.last().map(|&(_, v)| v);
    let (min, max) = if samples.is_empty() || samples.iter().any(|&(_, v)| !v.is_finite()) {
        (None, None)
    } else {
        let min = samples
            .iter()
            .map(|&(_, v)| v)
            .fold(f64::INFINITY, f64::min);
        let max = samples
            .iter()
            .map(|&(_, v)| v)
            .fold(f64::NEG_INFINITY, f64::max);
        (Some(min), Some(max))
    };
    (first, last, min, max)
}

fn value_mismatch(
    fixture: &str,
    aspect: &str,
    location: &str,
    field: &str,
    actual: Option<f64>,
    expected: Option<f64>,
) -> Mismatch {
    let delta = match (actual, expected) {
        (Some(a), Some(e)) if a.is_finite() => Some(a - e),
        _ => None,
    };
    Mismatch {
        fixture: fixture.to_string(),
        aspect: aspect.to_string(),
        location: location.to_string(),
        field: field.to_string(),
        expected: format!("{expected:?}"),
        actual: format!("{actual:?}"),
        delta,
    }
}

fn eq_mismatch<T: fmt::Debug>(
    fixture: &str,
    aspect: &str,
    location: &str,
    field: &str,
    actual: T,
    expected: T,
) -> Mismatch {
    Mismatch {
        fixture: fixture.to_string(),
        aspect: aspect.to_string(),
        location: location.to_string(),
        field: field.to_string(),
        expected: format!("{expected:?}"),
        actual: format!("{actual:?}"),
        delta: None,
    }
}

// --------------------------------------------------------------------------- //
// Per-aspect comparisons (each returns the list of discrepancies).
// --------------------------------------------------------------------------- //

/// Metadata strings + datetime (from `Session`) and the container structural
/// counts (from `open_container`) vs the golden.
fn compare_metadata(
    fixture: &str,
    meta: &Metadata,
    counts: (usize, bool, usize),
    g: &MetadataGolden,
) -> Vec<Mismatch> {
    let mut out = Vec::new();
    let mut str_field = |field: &str, actual: &str, expected: &str| {
        if actual != expected {
            out.push(eq_mismatch(
                fixture,
                "metadata",
                "header",
                field,
                actual.to_string(),
                expected.to_string(),
            ));
        }
    };
    str_field("driver", &meta.driver, &g.driver);
    str_field("vehicle", &meta.vehicle, &g.vehicle);
    str_field("track", &meta.track, &g.track);
    str_field("session", &meta.session, &g.session);
    str_field("series", &meta.series, &g.series);
    str_field("log_date", &meta.log_date, &g.log_date);
    str_field("log_time", &meta.log_time, &g.log_time);
    if meta.datetime_utc != g.datetime_utc {
        out.push(eq_mismatch(
            fixture,
            "metadata",
            "header",
            "datetime_utc",
            meta.datetime_utc,
            g.datetime_utc,
        ));
    }
    let (channel_count, has_gps, lap_marker_count) = counts;
    if channel_count != g.channel_count {
        out.push(eq_mismatch(
            fixture,
            "metadata",
            "structural",
            "channel_count",
            channel_count,
            g.channel_count,
        ));
    }
    if has_gps != g.has_gps {
        out.push(eq_mismatch(
            fixture,
            "metadata",
            "structural",
            "has_gps",
            has_gps,
            g.has_gps,
        ));
    }
    if lap_marker_count != g.lap_marker_count {
        out.push(eq_mismatch(
            fixture,
            "metadata",
            "structural",
            "lap_marker_count",
            lap_marker_count,
            g.lap_marker_count,
        ));
    }
    out
}

/// Decoded channels vs the golden's CHS-backed channels (the 1.3 oracle set).
///
/// `gps_names` are the channel names owned by the GPS aspect — libxrk's computed
/// GPS channels (`GPS_InlineAcc`, …) carry a `sample_rate_hz` in some goldens, but
/// `decode_channels` never emits them (they are synthesized by `decode_gps` and
/// validated under the `gps` aspect), so they are excluded here to avoid
/// double-counting.
fn compare_channels(
    fixture: &str,
    channels: &[Channel],
    g: &ChannelsGolden,
    gps_names: &HashSet<String>,
) -> Vec<Mismatch> {
    let mut out = Vec::new();
    let mut expected: Vec<_> = g
        .channels
        .iter()
        .filter(|c| c.sample_rate_hz.is_some() && !gps_names.contains(&c.name))
        .collect();
    expected.sort_by(|a, b| a.name.cmp(&b.name));
    let mut actual: Vec<&Channel> = channels.iter().collect();
    actual.sort_by(|a, b| a.name().cmp(b.name()));

    if actual.len() != expected.len() {
        out.push(eq_mismatch(
            fixture,
            "channels",
            "corpus",
            "channel_count",
            actual.len(),
            expected.len(),
        ));
        return out; // counts differ: per-channel alignment would be misleading
    }
    for (ch, gc) in actual.iter().zip(expected.iter()) {
        let loc = &gc.name;
        if ch.name() != gc.name {
            out.push(eq_mismatch(
                fixture,
                "channels",
                loc,
                "name",
                ch.name().to_string(),
                gc.name.clone(),
            ));
            continue;
        }
        if ch.unit() != gc.units {
            out.push(eq_mismatch(
                fixture,
                "channels",
                loc,
                "unit",
                ch.unit().to_string(),
                gc.units.clone(),
            ));
        }
        let rate = gc.sample_rate_hz.unwrap_or(0.0);
        if (ch.sample_rate_hz() - rate).abs() >= RATE_TOL_HZ {
            out.push(value_mismatch(
                fixture,
                "channels",
                loc,
                "sample_rate_hz",
                Some(ch.sample_rate_hz()),
                Some(rate),
            ));
        }
        if ch.samples().len() != gc.samples {
            out.push(eq_mismatch(
                fixture,
                "channels",
                loc,
                "samples",
                ch.samples().len(),
                gc.samples,
            ));
        }
        let (first, last, min, max) = stats(ch.samples());
        for (field, a, e) in [
            ("first", first, gc.first),
            ("last", last, gc.last),
            ("min", min, gc.min),
            ("max", max, gc.max),
        ] {
            if !assert_within_tolerance(a, e, gc.decimals) {
                out.push(value_mismatch(fixture, "channels", loc, field, a, e));
            }
        }
        // Absolute channel timecodes (t_first_ms/t_last_ms) are intentionally not
        // compared: the decoder keeps raw logger timecodes while libxrk applies a
        // recording-start offset (a constant per session). Value/rate/count
        // conformance is the 1.3 contract; see docs/DECODE_TOLERANCES.md.
    }
    out
}

/// Decoded GPS vs the golden GPS channel inventory.
fn compare_gps(fixture: &str, gps: Option<&GpsData>, g: &GpsGolden) -> Vec<Mismatch> {
    let mut out = Vec::new();
    let present = gps.is_some();
    if present != g.has_gps {
        out.push(eq_mismatch(
            fixture, "gps", "corpus", "has_gps", present, g.has_gps,
        ));
        return out;
    }
    let Some(data) = gps else {
        return out; // both agree there is no GPS
    };
    if data.len() != g.fix_count {
        out.push(eq_mismatch(
            fixture,
            "gps",
            "corpus",
            "fix_count",
            data.len(),
            g.fix_count,
        ));
    }
    // Assert the channel inventory matches in both directions: the per-channel
    // loop below only checks golden channels are present, so a count check is
    // what catches a spurious/duplicate decoded channel absent from the golden.
    if data.channels().len() != g.channels.len() {
        out.push(eq_mismatch(
            fixture,
            "gps",
            "corpus",
            "channel_count",
            data.channels().len(),
            g.channels.len(),
        ));
    }
    for gc in &g.channels {
        let loc = &gc.name;
        let Some(ch) = data.channel(&gc.name) else {
            out.push(eq_mismatch(fixture, "gps", loc, "present", false, true));
            continue;
        };
        let kind = format!("{:?}", ch.kind());
        if kind != gc.kind {
            out.push(eq_mismatch(
                fixture,
                "gps",
                loc,
                "kind",
                kind,
                gc.kind.clone(),
            ));
        }
        if ch.unit() != gc.unit {
            out.push(eq_mismatch(
                fixture,
                "gps",
                loc,
                "unit",
                ch.unit().to_string(),
                gc.unit.clone(),
            ));
        }
        if ch.samples().len() != gc.samples {
            out.push(eq_mismatch(
                fixture,
                "gps",
                loc,
                "samples",
                ch.samples().len(),
                gc.samples,
            ));
        }
        let (first, last, min, max) = stats(ch.samples());
        for (field, a, e) in [
            ("first", first, gc.first),
            ("last", last, gc.last),
            ("min", min, gc.min),
            ("max", max, gc.max),
        ] {
            if !assert_within_tolerance(a, e, gc.decimals) {
                out.push(value_mismatch(fixture, "gps", loc, field, a, e));
            }
        }
    }
    out
}

/// Decoded laps vs the golden beacon lap table.
fn compare_laps(fixture: &str, laps: &LapData, g: &LapsGolden) -> Vec<Mismatch> {
    let mut out = Vec::new();
    if laps.len() != g.lap_count {
        out.push(eq_mismatch(
            fixture,
            "laps",
            "corpus",
            "lap_count",
            laps.len(),
            g.lap_count,
        ));
    }
    if laps.best_lap_index() != g.best_lap_index {
        out.push(eq_mismatch(
            fixture,
            "laps",
            "corpus",
            "best_lap_index",
            laps.best_lap_index(),
            g.best_lap_index,
        ));
    }
    if laps.len() != g.laps.len() {
        return out; // count differs: per-lap alignment would be misleading
    }
    for (lap, gl) in laps.laps().iter().zip(g.laps.iter()) {
        let loc = format!("lap {}", gl.index);
        if lap.index() != gl.index {
            out.push(eq_mismatch(
                fixture,
                "laps",
                &loc,
                "index",
                lap.index(),
                gl.index,
            ));
            continue;
        }
        let dur_expected = gl.duration_ms as f64 / 1000.0;
        if (lap.duration_s() - dur_expected).abs() >= LAP_TIME_TOL_S {
            out.push(value_mismatch(
                fixture,
                "laps",
                &loc,
                "duration_s",
                Some(lap.duration_s()),
                Some(dur_expected),
            ));
        }
        let start_expected = gl.start_ms as f64 / 1000.0;
        if (lap.start_time_s() - start_expected).abs() >= LAP_TIME_TOL_S {
            out.push(value_mismatch(
                fixture,
                "laps",
                &loc,
                "start_time_s",
                Some(lap.start_time_s()),
                Some(start_expected),
            ));
        }
    }
    out
}

/// Decode one fixture and gather every mismatch across all four aspects.
fn conformance(fixture: &str) -> Vec<Mismatch> {
    let path = fixtures_dir().join(format!("{fixture}.xrk"));
    let session = match decode_session(&path) {
        Ok(session) => session,
        Err(err) => {
            return vec![eq_mismatch(
                fixture,
                "decode",
                "session",
                "error",
                err.to_string(),
                "Ok".to_string(),
            )];
        }
    };
    let container = open_container(&path).expect("open container (already decoded once)");
    let counts = (
        container.channel_count(),
        container.has_gps(),
        container.lap_marker_count(),
    );

    let mut out = Vec::new();
    match load_golden::<MetadataGolden>(fixture, "metadata") {
        Ok(g) => out.extend(compare_metadata(fixture, session.metadata(), counts, &g)),
        Err(err) => out.push(eq_mismatch(
            fixture,
            "metadata",
            "golden",
            "load",
            err,
            "loaded".to_string(),
        )),
    }
    // Load the GPS golden first: its channel names are owned by the `gps` aspect
    // and excluded from the `channels` comparison.
    let gps_golden = load_golden::<GpsGolden>(fixture, "gps");
    let gps_names: HashSet<String> = match &gps_golden {
        Ok(g) => g.channels.iter().map(|c| c.name.clone()).collect(),
        Err(_) => HashSet::new(),
    };
    match load_golden::<ChannelsGolden>(fixture, "channels") {
        Ok(g) => out.extend(compare_channels(
            fixture,
            session.channels(),
            &g,
            &gps_names,
        )),
        Err(err) => out.push(eq_mismatch(
            fixture,
            "channels",
            "golden",
            "load",
            err,
            "loaded".to_string(),
        )),
    }
    match gps_golden {
        Ok(g) => out.extend(compare_gps(fixture, session.gps(), &g)),
        Err(err) => out.push(eq_mismatch(
            fixture,
            "gps",
            "golden",
            "load",
            err,
            "loaded".to_string(),
        )),
    }
    match load_golden::<LapsGolden>(fixture, "laps") {
        Ok(g) => out.extend(compare_laps(fixture, session.laps(), &g)),
        Err(err) => out.push(eq_mismatch(
            fixture,
            "laps",
            "golden",
            "load",
            err,
            "loaded".to_string(),
        )),
    }
    out
}

/// Every mismatch across the whole corpus, computed **once** — each fixture is
/// decoded a single time, and the four per-aspect tests share this result
/// instead of re-decoding the corpus once per aspect.
fn all_mismatches() -> &'static [Mismatch] {
    static CACHE: OnceLock<Vec<Mismatch>> = OnceLock::new();
    CACHE.get_or_init(|| {
        corpus()
            .iter()
            .flat_map(|fixture| conformance(fixture))
            .collect()
    })
}

/// One aspect's mismatches — plus any top-level `decode` failures, which belong
/// to no single aspect but must fail every aspect gate (otherwise a fixture that
/// fails to decode at all would be silently dropped by the aspect filter).
fn corpus_mismatches(aspect: &str) -> Vec<Mismatch> {
    all_mismatches()
        .iter()
        .filter(|m| m.aspect == aspect || m.aspect == "decode")
        .cloned()
        .collect()
}

// --------------------------------------------------------------------------- //
// Named acceptance tests
// --------------------------------------------------------------------------- //

#[test]
fn test_every_fixture_has_a_golden() {
    // Every genuine .xrk sample is paired with all four goldens, so the
    // data-driven corpus is complete.
    let Some(corpus) = corpus_or_skip() else {
        return;
    };
    let mut missing = Vec::new();
    for fixture in &corpus {
        for aspect in ["metadata", "channels", "gps", "laps"] {
            let path = fixtures_dir()
                .join("golden")
                .join(format!("{fixture}.{aspect}.json"));
            if !path.exists() {
                missing.push(path.display().to_string());
            }
        }
    }
    assert!(
        missing.is_empty(),
        "missing goldens:\n  {}",
        missing.join("\n  ")
    );
}

#[test]
fn test_metadata_matches_golden_corpus_wide() {
    if corpus_or_skip().is_none() {
        return;
    }
    let mismatches = corpus_mismatches("metadata");
    assert!(mismatches.is_empty(), "{}", render(&mismatches));
}

#[test]
fn test_all_channels_match_golden_within_tolerance() {
    if corpus_or_skip().is_none() {
        return;
    }
    let mismatches = corpus_mismatches("channels");
    assert!(mismatches.is_empty(), "{}", render(&mismatches));
}

#[test]
fn test_all_gps_match_golden_within_tolerance() {
    if corpus_or_skip().is_none() {
        return;
    }
    let mismatches = corpus_mismatches("gps");
    assert!(mismatches.is_empty(), "{}", render(&mismatches));
}

#[test]
fn test_all_laps_match_golden() {
    if corpus_or_skip().is_none() {
        return;
    }
    let mismatches = corpus_mismatches("laps");
    assert!(mismatches.is_empty(), "{}", render(&mismatches));
}

#[test]
fn test_mismatch_emits_precise_diff() {
    // The diff carries fixture, aspect, location, field, expected vs actual, and a
    // numeric delta — deterministic, so it runs without any fixture present.
    let meta = Metadata {
        driver: "REAL DRIVER".to_string(),
        ..Metadata::default()
    };
    let golden = MetadataGolden {
        file: "synthetic.xrk".to_string(),
        driver: "WRONG DRIVER".to_string(),
        vehicle: String::new(),
        track: String::new(),
        session: String::new(),
        series: String::new(),
        log_date: String::new(),
        log_time: String::new(),
        datetime_utc: 0,
        channel_count: 0,
        has_gps: false,
        lap_marker_count: 0,
    };
    let mismatches = compare_metadata("synthetic", &meta, (0, false, 0), &golden);
    assert_eq!(mismatches.len(), 1, "exactly the driver mismatch");
    let text = mismatches[0].to_string();
    for needle in [
        "synthetic",
        "metadata",
        "driver",
        "REAL DRIVER",
        "WRONG DRIVER",
    ] {
        assert!(text.contains(needle), "diff missing {needle:?}: {text}");
    }

    // A value field carries a numeric delta.
    let numeric = value_mismatch(
        "synthetic",
        "channels",
        "RPM",
        "first",
        Some(10.0),
        Some(9.0),
    );
    assert_eq!(numeric.delta, Some(1.0));
    assert!(
        numeric.to_string().contains("Δ="),
        "value diff shows a delta"
    );

    // A batch renders as a diagnosable multi-line report.
    let report = render(&mismatches);
    assert!(report.contains("1 mismatch(es)") && report.contains("driver"));
}

#[test]
fn test_e2e_script_exits_nonzero_on_mismatch() {
    // Proof of the script contract: e2e.sh exits non-zero when a golden mismatches.
    // Runs only in the e2e context (RS_RUN_E2E_SCRIPT_TEST, set by scripts/e2e.sh)
    // so the coverage gate never spawns a nested build.
    if std::env::var_os("RS_RUN_E2E_SCRIPT_TEST").is_none() {
        eprintln!("skipping: set RS_RUN_E2E_SCRIPT_TEST=1 (scripts/e2e.sh does) to run the script self-test");
        return;
    }
    // Need a real sample to build a decodable-but-poisoned corpus.
    let Some(corpus) = corpus_or_skip() else {
        return;
    };
    let fixture = &corpus[0];

    let root = support::fixtures::fixtures_dir()
        .parent()
        .expect("repo root")
        .to_path_buf();
    let poisoned = Path::new(env!("CARGO_TARGET_TMPDIR")).join("poisoned_corpus");
    let golden_dir = poisoned.join("golden");
    // Start from a clean dir so a stale sample from a prior run (if the
    // first-sorted fixture ever changes) cannot linger and be decoded here.
    let _ = std::fs::remove_dir_all(&poisoned);
    std::fs::create_dir_all(&golden_dir).expect("mk poisoned corpus");

    // Copy the real .xrk so decode succeeds…
    std::fs::copy(
        fixtures_dir().join(format!("{fixture}.xrk")),
        poisoned.join(format!("{fixture}.xrk")),
    )
    .expect("copy sample");
    // …and copy every golden, corrupting the metadata driver to force a mismatch.
    // Mutate the parsed JSON value (not a string replace) so it is robust to an
    // empty or key-colliding driver string.
    for aspect in ["metadata", "channels", "gps", "laps"] {
        let name = format!("{fixture}.{aspect}.json");
        let text = std::fs::read_to_string(fixtures_dir().join("golden").join(&name))
            .expect("read golden");
        let text = if aspect == "metadata" {
            let mut value: serde_json::Value =
                serde_json::from_str(&text).expect("parse metadata golden");
            value["driver"] = serde_json::Value::String("__POISONED_DRIVER__".to_string());
            serde_json::to_string_pretty(&value).expect("serialize poisoned golden")
        } else {
            text
        };
        std::fs::write(golden_dir.join(&name), text).expect("write poisoned golden");
    }

    let output = std::process::Command::new("bash")
        .arg(root.join("scripts/e2e.sh"))
        .arg("--goldens-only")
        // Drop the guard var so the nested harness's own script self-test skips
        // via the env guard, not only via e2e.sh's `--skip` (defence in depth
        // against unbounded recursion).
        .env_remove("RS_RUN_E2E_SCRIPT_TEST")
        .env("RS_FIXTURES_DIR", &poisoned)
        .current_dir(&root)
        .output()
        .expect("run e2e.sh --goldens-only");

    assert!(
        !output.status.success(),
        "e2e.sh must exit non-zero on a mismatch (status {:?})",
        output.status.code()
    );
    let combined = format!(
        "{}{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    // Require the specific poisoned-driver diff (not just "FAILED", which cargo
    // prints on any failure) so the test proves the poison drove the exit.
    assert!(
        combined.contains("driver") && combined.contains("__POISONED_DRIVER__"),
        "e2e.sh output should name the poisoned driver mismatch:\n{combined}"
    );
}
