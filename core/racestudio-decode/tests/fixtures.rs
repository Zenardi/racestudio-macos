//! Tests for the golden-fixture loader (issue 0.5).
//!
//! These exercise the shared `support::fixtures` helpers that every M1+ decode
//! test will use to resolve `.xrk` paths and load the libxrk-derived golden
//! JSON (the decode oracle). No decoding happens here — just fixture plumbing.

mod support;

use support::fixtures::{fixture_path, load_golden, ChannelsGolden};

#[test]
fn test_fixture_path_resolves_from_workspace_root() {
    // Given a fixture name, When resolved, Then it points at <repo>/fixtures/<name>
    // and the committed golden directory sits alongside it.
    let path = fixture_path("aim_official_test.xrk");
    assert!(
        path.ends_with("fixtures/aim_official_test.xrk"),
        "resolved to {}",
        path.display()
    );
    let golden_dir = path.parent().expect("fixtures dir").join("golden");
    assert!(
        golden_dir.is_dir(),
        "missing golden dir at {}",
        golden_dir.display()
    );
}

#[test]
fn test_load_golden_deserializes_channels_json() {
    // Given the committed channels golden, When loaded, Then it deserializes into
    // a typed summary with a consistent channel count.
    let golden: ChannelsGolden =
        load_golden("aim_official_test", "channels").expect("load channels golden");
    assert_eq!(golden.channel_count, golden.channels.len());
    assert!(golden.channel_count > 0, "no channels in golden");
    assert!(
        golden.channels.iter().any(|c| c.name == "AccelerometerX"),
        "expected AccelerometerX channel in golden"
    );
}

#[test]
fn test_missing_fixture_errors_clearly() {
    // Given a fixture that does not exist, When loaded, Then the error names the
    // missing file and points at how to regenerate it (not a silent empty result).
    let error = load_golden::<ChannelsGolden>("does_not_exist", "channels")
        .expect_err("missing golden should error");
    assert!(
        error.contains("does_not_exist.channels.json"),
        "error should name the missing file: {error}"
    );
    assert!(
        error.contains("make fixtures") || error.to_lowercase().contains("not found"),
        "error should be actionable: {error}"
    );
}
