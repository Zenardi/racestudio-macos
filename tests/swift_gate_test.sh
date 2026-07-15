#!/usr/bin/env bash
#
# Tests for the Swift half of the coverage gate (issue 0.3):
#   scripts/swift_test.sh   — the Command-Line-Tools framework-path wrapper
#   scripts/coverage.sh      — Swift section (swift test + llvm-cov, scoped to
#                              Sources/RaceStudioCore; swiftlint)
#
# Behaviours are named per the issue and written Given-When-Then. Threshold
# arithmetic is exercised with synthetic llvm-cov JSON (deterministic); scoping
# and shell-exclusion are exercised against a single real `swift test` coverage
# run so the assertions reflect actual tooling behaviour.
#
# Written for the macOS system bash (3.2). Usage: bash tests/swift_gate_test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
GATE="$ROOT/scripts/coverage.sh"
SWIFT_TEST="$ROOT/scripts/swift_test.sh"

PASS=0
FAIL=0
ok()  { printf '  ok   - %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL - %s: %s\n' "$1" "${2:-}"; FAIL=$((FAIL + 1)); }

# Build the Swift coverage data exactly once, lazily, for the scoping tests.
SWIFT_BUILT=0
ensure_swift_built() {
  if [[ "$SWIFT_BUILT" -eq 0 ]]; then
    bash "$GATE" --swift-build >/dev/null 2>&1
    SWIFT_BUILT=$?
    [[ "$SWIFT_BUILT" -eq 0 ]] && SWIFT_BUILT=1 || SWIFT_BUILT=0
  fi
}

# Extract the measured filenames (repo-relative) from an llvm-cov export JSON on
# stdin. Capture stdin to a temp file first so the heredoc-supplied Python script
# does not collide with the JSON on stdin.
export_filenames() {
  local tmp
  tmp="$(mktemp)"
  cat > "$tmp"
  python3 - "$tmp" <<'PY'
import sys, json
with open(sys.argv[1]) as fh:
    d = json.load(fh)
for f in d["data"][0].get("files", []):
    name = f["filename"]
    print(name.split("/app/", 1)[-1] if "/app/" in name else name)
PY
  rm -f "$tmp"
}

# ---------------------------------------------------------------------------

test_swift_test_injects_clt_framework_paths() {
  # Given a Command-Line-Tools environment, When swift_test.sh computes its
  # flags, Then it injects the swift-testing framework search path + rpaths.
  # Skips gracefully on hosts without the CLT swift-testing framework (e.g. a
  # pure-Xcode runner), where the wrapper is correctly a no-op.
  local fw="/Library/Developer/CommandLineTools/Library/Developer/Frameworks/Testing.framework"
  if [[ ! -d "$fw" ]]; then
    ok "test_swift_test_injects_clt_framework_paths (skipped — no CLT swift-testing on host)"
    return
  fi
  local out
  out="$(SWIFT_TEST_FORCE_CLT=1 bash "$SWIFT_TEST" --print-flags 2>&1)"
  if grep -q -- '-F' <<<"$out" \
    && grep -q 'Frameworks' <<<"$out" \
    && grep -q -- '-rpath' <<<"$out"; then
    ok "test_swift_test_injects_clt_framework_paths"
  else
    bad "test_swift_test_injects_clt_framework_paths" "flags: $out"
  fi
}

test_swiftlint_clean() {
  # Given the committed config, When swiftlint runs on app, Then it is clean.
  local out exit
  out="$(bash "$GATE" --swift-lint 2>&1)"
  exit=$?
  if [[ "$exit" -eq 0 ]] && grep -qi '0 violations' <<<"$out"; then
    ok "test_swiftlint_clean"
  else
    bad "test_swiftlint_clean" "exit=$exit out=$(tail -1 <<<"$out")"
  fi
}

test_swift_gate_fails_below_threshold() {
  # Given RaceStudioCore coverage below threshold, Then the gate exits non-zero
  # and prints the measured percentage.
  local out exit
  out="$(printf '%s' '{"data":[{"totals":{"lines":{"count":10,"covered":9,"percent":90.0}}}]}' \
    | bash "$GATE" --swift-parse-json 95 2>&1)"
  exit=$?
  if [[ "$exit" -ne 0 ]] && grep -q 'RaceStudioCore' <<<"$out" && grep -qE '90(\.0+)?' <<<"$out"; then
    ok "test_swift_gate_fails_below_threshold"
  else
    bad "test_swift_gate_fails_below_threshold" "exit=$exit out=$out"
  fi
}

test_swift_gate_passes_at_threshold() {
  # Given RaceStudioCore coverage exactly at threshold, Then the gate passes.
  local out exit
  out="$(printf '%s' '{"data":[{"totals":{"lines":{"count":20,"covered":19,"percent":95.0}}}]}' \
    | bash "$GATE" --swift-parse-json 95 2>&1)"
  exit=$?
  if [[ "$exit" -eq 0 ]] && grep -q 'RaceStudioCore' <<<"$out" && grep -qi 'PASS' <<<"$out"; then
    ok "test_swift_gate_passes_at_threshold"
  else
    bad "test_swift_gate_passes_at_threshold" "exit=$exit out=$out"
  fi
}

test_swift_gate_measures_core_only() {
  # Given a real coverage run, When scoped to Sources/RaceStudioCore, Then the
  # measured file set is exactly the Core library (no tests/runner/shell).
  ensure_swift_built
  if [[ "$SWIFT_BUILT" -ne 1 ]]; then
    bad "test_swift_gate_measures_core_only" "swift build/coverage failed"
    return
  fi
  local files
  files="$(bash "$GATE" --swift-export Sources/RaceStudioCore 2>/dev/null | export_filenames)"
  if grep -q 'Sources/RaceStudioCore/' <<<"$files" \
    && ! grep -qE 'Tests/|runner\.swift|Sources/RaceStudio/' <<<"$files"; then
    ok "test_swift_gate_measures_core_only"
  else
    bad "test_swift_gate_measures_core_only" "files: $(tr '\n' ' ' <<<"$files")"
  fi
}

test_shell_target_excluded_from_metric() {
  # Given the @main RaceStudio shell, Then its source never appears in the
  # coverage data (it is not linked into the test binary), so it cannot fail
  # the gate however uncovered it is.
  ensure_swift_built
  if [[ "$SWIFT_BUILT" -ne 1 ]]; then
    bad "test_shell_target_excluded_from_metric" "swift build/coverage failed"
    return
  fi
  local files
  files="$(bash "$GATE" --swift-export ALL 2>/dev/null | export_filenames)"
  if [[ -n "$files" ]] && ! grep -q 'Sources/RaceStudio/' <<<"$files"; then
    ok "test_shell_target_excluded_from_metric"
  else
    bad "test_shell_target_excluded_from_metric" "files: $(tr '\n' ' ' <<<"$files")"
  fi
}

# ---------------------------------------------------------------------------

echo "Running Swift gate tests against: $GATE"
test_swift_test_injects_clt_framework_paths
test_swiftlint_clean
test_swift_gate_fails_below_threshold
test_swift_gate_passes_at_threshold
test_swift_gate_measures_core_only
test_shell_target_excluded_from_metric

echo
echo "swift gate tests: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
