#!/usr/bin/env bash
#
# Tests for the Trivy security-scan wiring: the `make security` target and the
# CI step that runs it. Config-only (no network, no actual scan) so it runs fast
# in the "Tooling self-tests" step. Given-When-Then; no logic beyond
# string/expansion checks.
#
# Usage: bash tests/security_test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CI="$ROOT/.github/workflows/ci.yml"

PASS=0
FAIL=0
ok()  { printf '  ok   - %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL - %s: %s\n' "$1" "${2:-}"; FAIL=$((FAIL + 1)); }

mk_n() { make -C "$ROOT" -n "$1" 2>&1; }

test_make_security_runs_trivy_fs_scan() {
  # Given `make security`, Then it runs a Trivy filesystem scan that fails
  # (non-zero exit) on HIGH/CRITICAL findings.
  local out; out="$(mk_n security)"
  if grep -q 'trivy fs' <<<"$out" \
    && grep -qi 'HIGH,CRITICAL' <<<"$out" \
    && grep -q -- '--exit-code 1' <<<"$out"; then
    ok "test_make_security_runs_trivy_fs_scan"
  else
    bad "test_make_security_runs_trivy_fs_scan" "$out"
  fi
}

test_ci_workflow_runs_make_security() {
  # Given the CI workflow, Then it has a Trivy step that runs the same
  # `make security` scan (local == CI).
  if grep -q 'make security' "$CI" && grep -qi 'trivy' "$CI"; then
    ok "test_ci_workflow_runs_make_security"
  else
    bad "test_ci_workflow_runs_make_security"
  fi
}

test_make_setup_installs_trivy() {
  # Given `make setup`, Then it ensures Trivy is installed alongside the other
  # toolchains, so `make security` is runnable locally before pushing.
  if grep -q 'trivy' <<<"$(mk_n setup)"; then
    ok "test_make_setup_installs_trivy"
  else
    bad "test_make_setup_installs_trivy"
  fi
}

echo "Running security-scan wiring tests"
test_make_security_runs_trivy_fs_scan
test_ci_workflow_runs_make_security
test_make_setup_installs_trivy

echo
echo "security tests: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
