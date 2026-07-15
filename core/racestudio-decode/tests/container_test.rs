//! Container + header-metadata decode tests (issue 1.2).
//!
//! These validate `open_container` against the real `aim_official_test.xrk`
//! sample and its libxrk-derived golden (`*.metadata.json`), plus the container
//! error paths. The `.xrk` sample is git-ignored (fetched by `make fixtures`);
//! when it is absent the oracle tests skip with a clear message rather than
//! fail, so a fresh checkout without samples still goes green. The decoder's
//! own logic is covered independently by unit tests in `src/container.rs`.

mod support;

use std::path::PathBuf;

use racestudio_decode::{open_container, DecodeError};
use support::fixtures::{fixture_path, load_golden, MetadataGolden};

/// Resolve a committed `.xrk` sample, or `None` (with a skip note) when the
/// git-ignored sample has not been fetched.
fn xrk_or_skip(name: &str) -> Option<PathBuf> {
    let path = fixture_path(name);
    if path.exists() {
        Some(path)
    } else {
        eprintln!(
            "skipping: {} not present — run `make fixtures` to fetch it",
            path.display()
        );
        None
    }
}

#[test]
fn test_open_valid_container_ok() {
    // Given a real .xrk sample, When opened, Then it parses without error and
    // exposes a populated header (a non-empty driver and a datetime).
    let Some(path) = xrk_or_skip("aim_official_test.xrk") else {
        return;
    };
    let container = open_container(&path).expect("open valid container");
    let meta = container.metadata();
    assert!(!meta.driver.is_empty(), "expected a driver in the header");
    assert!(meta.datetime_utc > 0, "expected a session datetime");
}

#[test]
fn test_metadata_matches_golden() {
    // Given the .xrk sample, When its header is parsed, Then vehicle/track/driver
    // and session/series match the libxrk golden exactly.
    let Some(path) = xrk_or_skip("aim_official_test.xrk") else {
        return;
    };
    let golden: MetadataGolden =
        load_golden("aim_official_test", "metadata").expect("load metadata golden");
    let meta = open_container(&path)
        .expect("open container")
        .metadata()
        .clone();
    assert_eq!(meta.driver, golden.driver, "driver");
    assert_eq!(meta.vehicle, golden.vehicle, "vehicle");
    assert_eq!(meta.track, golden.track, "track (venue)");
    assert_eq!(meta.session, golden.session, "session");
    assert_eq!(meta.series, golden.series, "series (championship)");
}

#[test]
fn test_datetime_matches_golden() {
    // Given the .xrk sample, When the header date/time is parsed, Then it equals
    // the golden epoch (last-wins TMD+TMT, interpreted as UTC).
    let Some(path) = xrk_or_skip("aim_official_test.xrk") else {
        return;
    };
    let golden: MetadataGolden =
        load_golden("aim_official_test", "metadata").expect("load metadata golden");
    let meta = open_container(&path)
        .expect("open container")
        .metadata()
        .clone();
    assert_eq!(meta.log_date, golden.log_date, "log date");
    assert_eq!(meta.log_time, golden.log_time, "log time");
    assert_eq!(
        meta.datetime_utc, golden.datetime_utc,
        "epoch seconds (UTC)"
    );
}

#[test]
fn test_channel_count_exposed() {
    // Given the .xrk sample, When opened, Then the container exposes the
    // structural counts 1.3-1.5 consume (channel definitions, GPS, lap markers),
    // matching the golden.
    let Some(path) = xrk_or_skip("aim_official_test.xrk") else {
        return;
    };
    let golden: MetadataGolden =
        load_golden("aim_official_test", "metadata").expect("load metadata golden");
    let container = open_container(&path).expect("open container");
    assert_eq!(
        container.channel_count(),
        golden.channel_count,
        "channel count"
    );
    assert_eq!(container.has_gps(), golden.has_gps, "gps presence");
    assert_eq!(
        container.lap_marker_count(),
        golden.lap_marker_count,
        "lap-marker count"
    );
}

#[test]
fn test_missing_file_returns_io_error() {
    // Given a path that does not exist, When opened, Then it returns Io — never
    // panics.
    let err = open_container("/no/such/file.xrk").expect_err("missing file must error");
    assert!(
        matches!(err, DecodeError::Io(_)),
        "expected Io, got {err:?}"
    );
}

#[test]
fn test_bad_magic_returns_error() {
    // Given a file whose first bytes are not the `.xrk` magic, When opened, Then
    // it returns BadMagic — never panics.
    let dir = std::path::Path::new(env!("CARGO_TARGET_TMPDIR"));
    let path = dir.join("bad_magic.xrk");
    std::fs::write(&path, b"NOT-AN-XRK-FILE-AT-ALL").expect("write bad fixture");
    let err = open_container(&path).expect_err("bad magic must error");
    assert!(
        matches!(err, DecodeError::BadMagic),
        "expected BadMagic, got {err:?}"
    );
}

#[test]
fn test_truncated_header_returns_error() {
    // Given a file with valid magic but a header cut short, When opened, Then it
    // returns TruncatedHeader — never panics.
    let dir = std::path::Path::new(env!("CARGO_TARGET_TMPDIR"));
    let path = dir.join("truncated.xrk");
    // '<h' + a token + a payload length that runs past EOF, then nothing.
    let bytes = [0x3C, 0x68, b'T', b'M', b'T', 0x20, 0xFF, 0xFF, 0x00, 0x00];
    std::fs::write(&path, bytes).expect("write truncated fixture");
    let err = open_container(&path).expect_err("truncated header must error");
    assert!(
        matches!(err, DecodeError::TruncatedHeader),
        "expected TruncatedHeader, got {err:?}"
    );
}
