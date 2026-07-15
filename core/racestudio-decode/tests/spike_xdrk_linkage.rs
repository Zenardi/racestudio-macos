//! Spike + ADR gate for issue 1.1 — decide the `.xrk` decode strategy.
//!
//! This is a *decision* spike, not decoder code. These tests assert that the
//! spike's conclusion is **recorded and reproducible**:
//!
//! - a committed evidence artifact (`docs/spike/xdrk-linkage.md`) capturing the
//!   `xdrk`-crate linkage finding,
//! - an ADR (`docs/adr/0002-xrk-decode-strategy.md`) that records the decision,
//! - a probe script (`scripts/spike_xdrk_linkage.sh`) documenting exactly how
//!   the evidence was gathered.
//!
//! They deliberately do **not** build or link the third-party `xdrk` crate —
//! doing so would pull AiM's proprietary, x86_64-only C library into our build
//! graph, the very thing this spike rejects. The live end-to-end probe is a
//! separate `#[ignore]`d test (`live_probe_confirms_finding`) so the default
//! `cargo test` run stays offline and deterministic.

use std::fs;
use std::path::{Path, PathBuf};

const ADR: &str = "docs/adr/0002-xrk-decode-strategy.md";
const EVIDENCE: &str = "docs/spike/xdrk-linkage.md";
const PROBE: &str = "scripts/spike_xdrk_linkage.sh";

/// Repo root, two levels above this crate's manifest dir
/// (`core/racestudio-decode`).
fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .and_then(Path::parent)
        .expect("repo root above core/racestudio-decode")
        .to_path_buf()
}

/// Read a repo-relative artifact, failing with a clear, actionable message
/// (naming the path) rather than a silent empty string when it is missing.
fn read(rel: &str) -> String {
    let path = repo_root().join(rel);
    fs::read_to_string(&path)
        .unwrap_or_else(|err| panic!("required artifact missing: {} ({err})", path.display()))
}

#[test]
fn test_adr_file_exists_and_has_decision() {
    // Given the decode-strategy ADR, When read, Then it follows the ADR
    // template (Context / Decision / Consequences) and records an Accepted
    // status — a real decision, not a placeholder.
    let adr = read(ADR).to_lowercase();
    assert!(
        adr.contains("## context"),
        "ADR must have a Context section"
    );
    assert!(
        adr.contains("## decision"),
        "ADR must have a Decision section"
    );
    assert!(
        adr.contains("## consequences"),
        "ADR must have a Consequences section"
    );
    assert!(
        adr.contains("status") && adr.contains("accepted"),
        "ADR must record an Accepted status"
    );
}

#[test]
fn test_selected_strategy_is_clean_room_port() {
    // Given the three options, When the decision is read, Then it selects the
    // clean-room Rust port, rejects the alternatives, and names the crate that
    // 1.2 will build.
    let adr = read(ADR).to_lowercase();
    assert!(
        adr.contains("clean-room"),
        "decision must select the clean-room Rust port"
    );
    assert!(
        adr.contains("xdrk"),
        "ADR must weigh the xdrk-wrapper option"
    );
    assert!(
        adr.contains("python"),
        "ADR must weigh (and reject) the Python-FFI option"
    );
    assert!(
        adr.contains("reject"),
        "ADR must record which options are rejected"
    );
    assert!(
        adr.contains("racestudio-decode"),
        "decision must name the target crate skeleton for 1.2"
    );
}

#[test]
fn test_xdrk_linkage_finding_is_recorded() {
    // Given the xdrk spike, When its linkage is inspected, Then the evidence
    // artifact records — with quoted proof — that xdrk links AiM's proprietary,
    // non-macOS C library, i.e. it is not native.
    let evidence = read(EVIDENCE);
    let low = evidence.to_lowercase();
    // The smoking gun: xdrk's build.rs links AiM's vendored lib.
    assert!(
        evidence.contains("cargo:rustc-link-lib=xdrk-x86_64"),
        "evidence must quote xdrk's proprietary link directive"
    );
    assert!(
        low.contains("libxdrk-x86_64") && low.contains("libmatlabxrk"),
        "evidence must name the vendored proprietary libraries"
    );
    assert!(
        low.contains("proprietary"),
        "evidence must state the vendored libs are proprietary"
    );
    assert!(
        low.contains("non-native") || low.contains("not native"),
        "evidence must record the non-native verdict"
    );
    assert!(
        low.contains("arm64") || low.contains("aarch64") || low.contains("no macos"),
        "evidence must note there is no native macOS/arm64 artifact"
    );
}

#[test]
fn test_oracle_is_libxrk_golden_json() {
    // Given the decode oracle plan, When the ADR is read, Then it names libxrk's
    // committed golden JSON as the reference and records the float-comparison
    // tolerance strategy the decoders (1.2–1.6) will assert with.
    let adr = read(ADR).to_lowercase();
    assert!(adr.contains("libxrk"), "the oracle must be libxrk");
    assert!(
        adr.contains("fixtures/golden"),
        "oracle values live in fixtures/golden/*.json"
    );
    assert!(
        adr.contains("gen_goldens.py"),
        "ADR must name the golden generator"
    );
    assert!(
        adr.contains("tolerance") || adr.contains("epsilon"),
        "ADR must record a float-comparison tolerance strategy"
    );
}

#[test]
fn test_spike_probe_is_reproducible() {
    // Given the linkage finding, When someone wants to reproduce it, Then a
    // committed, executable probe script documents the exact inspection commands
    // and the evidence artifact points back at it.
    let probe_path = repo_root().join(PROBE);
    assert!(probe_path.is_file(), "probe script must exist at {PROBE}");
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mode = fs::metadata(&probe_path)
            .expect("probe metadata")
            .permissions()
            .mode();
        assert!(mode & 0o111 != 0, "probe script must be executable");
    }
    let probe = read(PROBE);
    assert!(
        probe.contains("cargo add xdrk"),
        "probe must add the xdrk crate to a throwaway project"
    );
    assert!(
        probe.contains("rustc-link-lib"),
        "probe must inspect the crate's link directives"
    );
    let evidence = read(EVIDENCE);
    assert!(
        evidence.contains("spike_xdrk_linkage.sh"),
        "evidence must reference the probe script that produced it"
    );
}

#[test]
#[ignore = "network: downloads the third-party xdrk crate. Run manually with \
            `cargo test -p racestudio-decode -- --ignored`"]
fn live_probe_confirms_finding() {
    // Runs the reproducible probe end-to-end and asserts its verdict. Ignored by
    // default so `cargo test`/CI stay offline and never pull the proprietary
    // library into the build graph.
    let probe = repo_root().join(PROBE);
    let output = std::process::Command::new("bash")
        .arg(&probe)
        .output()
        .expect("run probe script");
    let combined = format!(
        "{}{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(
        combined.to_uppercase().contains("NON-NATIVE"),
        "probe must confirm xdrk is non-native; got:\n{combined}"
    );
}
