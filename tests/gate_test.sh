#!/usr/bin/env bash
#
# Tests for scripts/coverage.sh — the Rust quality + coverage gate (issue 0.2).
#
# The gate script is the unit under test. Each test drives it against a purpose
# built fixture crate (fmt-clean, clippy-clean, fully/partly covered, or
# deliberately broken) and asserts the gate's exit code and output. Behaviours,
# named per the issue, are written Given-When-Then; there is no logic in the
# assertions beyond string/exit-code checks.
#
# Written for the macOS system bash (3.2): fixture heredocs are attached to a
# simple command (not inside $(...)) to avoid the 3.2 here-doc-in-subshell bug.
#
# Usage: bash tests/gate_test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
GATE="$ROOT/scripts/coverage.sh"

PASS=0
FAIL=0
ok()  { printf '  ok   - %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL - %s: %s\n' "$1" "${2:-}"; FAIL=$((FAIL + 1)); }

TMPROOT="$(mktemp -d)"
cleanup() { rm -rf "$TMPROOT"; }
trap cleanup EXIT

# new_fixture <name> [--fmt]  — reads src/lib.rs from stdin, sets FIXTURE_DIR.
# With --fmt the crate is normalised with `cargo fmt` so the gate's fmt step
# passes (used by every fixture except the deliberately mis-formatted one).
new_fixture() {
  local name="$1" do_fmt="${2:-}"
  FIXTURE_DIR="$TMPROOT/$name"
  mkdir -p "$FIXTURE_DIR/src"
  cat > "$FIXTURE_DIR/Cargo.toml" <<EOF
[package]
name = "$name"
version = "0.1.0"
edition = "2021"
EOF
  cat > "$FIXTURE_DIR/src/lib.rs"
  if [[ "$do_fmt" == "--fmt" ]]; then
    ( cd "$FIXTURE_DIR" && cargo fmt ) >/dev/null 2>&1
  fi
}

# run_gate <workspace> <threshold> [args...] -> sets GATE_EXIT, GATE_OUT
run_gate() {
  local ws="$1" thr="$2"
  shift 2
  GATE_OUT="$(COVERAGE_THRESHOLD="$thr" RUST_WORKSPACE="$ws" bash "$GATE" "$@" 2>&1)"
  GATE_EXIT=$?
}

# print_config [threshold-env] -> sets CFG_OUT
print_config() {
  if [[ -n "${1:-}" ]]; then
    CFG_OUT="$(COVERAGE_THRESHOLD="$1" bash "$GATE" --print-config 2>&1)"
  else
    CFG_OUT="$(bash "$GATE" --print-config 2>&1)"
  fi
}

# ---------------------------------------------------------------------------

test_threshold_defaults_to_95() {
  # Given no COVERAGE_THRESHOLD, When printing config, Then threshold is 95.
  print_config ""
  if grep -q '^THRESHOLD=95$' <<<"$CFG_OUT"; then
    ok "test_threshold_defaults_to_95"
  else
    bad "test_threshold_defaults_to_95" "config: $CFG_OUT"
  fi
}

test_threshold_env_override_respected() {
  # Given COVERAGE_THRESHOLD=80, When printing config, Then threshold is 80.
  print_config "80"
  if grep -q '^THRESHOLD=80$' <<<"$CFG_OUT"; then
    ok "test_threshold_env_override_respected"
  else
    bad "test_threshold_env_override_respected" "config: $CFG_OUT"
  fi
}

test_gate_passes_at_or_above_threshold() {
  # Given a fully-covered, clean crate and threshold 90, Then the gate exits 0
  # and prints PASS.
  new_fixture covpass --fmt <<'RS'
pub fn add(a: i32, b: i32) -> i32 {
    a + b
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn adds() {
        assert_eq!(add(2, 3), 5);
    }
}
RS
  run_gate "$FIXTURE_DIR" 90
  if [[ "$GATE_EXIT" -eq 0 ]] && grep -qi 'PASS' <<<"$GATE_OUT"; then
    ok "test_gate_passes_at_or_above_threshold"
  else
    bad "test_gate_passes_at_or_above_threshold" "exit=$GATE_EXIT"
  fi
}

test_gate_fails_below_threshold() {
  # Given a crate with an uncovered branch (~87%) and threshold 95, Then the
  # gate exits non-zero and prints the measured percentage.
  new_fixture covfail --fmt <<'RS'
pub fn classify(n: i32) -> &'static str {
    if n > 0 {
        "pos"
    } else {
        "nonpos"
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_positive() {
        assert_eq!(classify(1), "pos");
    }
}
RS
  run_gate "$FIXTURE_DIR" 95
  if [[ "$GATE_EXIT" -ne 0 ]] && grep -qE '[0-9]+\.[0-9]+%' <<<"$GATE_OUT"; then
    ok "test_gate_fails_below_threshold"
  else
    bad "test_gate_fails_below_threshold" "exit=$GATE_EXIT (expected non-zero + a percentage)"
  fi
}

test_clippy_warning_denied_fails_gate() {
  # Given a crate with a clippy lint and -D warnings, Then the gate fails at the
  # clippy step (before the coverage step).
  new_fixture clippylint --fmt <<'RS'
pub fn one() -> i32 {
    return 1;
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn is_one() {
        assert_eq!(one(), 1);
    }
}
RS
  run_gate "$FIXTURE_DIR" 90
  if [[ "$GATE_EXIT" -ne 0 ]] \
    && grep -qi 'clippy' <<<"$GATE_OUT" \
    && ! grep -qi 'llvm-cov' <<<"$GATE_OUT"; then
    ok "test_clippy_warning_denied_fails_gate"
  else
    bad "test_clippy_warning_denied_fails_gate" "exit=$GATE_EXIT"
  fi
}

test_fmt_diff_fails_gate() {
  # Given a mis-formatted crate, Then the gate fails at the fmt step (before the
  # clippy step).
  new_fixture fmtbad <<'RS'
pub fn two()->i32{2}

#[cfg(test)]
mod tests{use super::*;
#[test] fn t(){assert_eq!(two(),2);}}
RS
  run_gate "$FIXTURE_DIR" 90
  if [[ "$GATE_EXIT" -ne 0 ]] \
    && grep -qi 'fmt' <<<"$GATE_OUT" \
    && ! grep -qi 'clippy' <<<"$GATE_OUT"; then
    ok "test_fmt_diff_fails_gate"
  else
    bad "test_fmt_diff_fails_gate" "exit=$GATE_EXIT"
  fi
}

# ---------------------------------------------------------------------------

echo "Running gate tests against: $GATE"
test_threshold_defaults_to_95
test_threshold_env_override_respected
test_gate_passes_at_or_above_threshold
test_gate_fails_below_threshold
test_clippy_warning_denied_fails_gate
test_fmt_diff_fails_gate

echo
echo "gate tests: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
