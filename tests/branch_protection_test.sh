#!/usr/bin/env bash
#
# Tests for the branch-protection runbook (issue 0.7). These validate the
# committed `gh api` payload (docs/branch_protection.json) and the runbook
# (docs/BRANCH_PROTECTION.md) WITHOUT touching GitHub — the protection is applied
# by a human running the documented commands. Given-When-Then; the critical case
# is that the required status-check contexts exactly match the CI job names, so
# the gate can never be silently non-blocking.
#
# Usage: bash tests/branch_protection_test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PAYLOAD="$ROOT/docs/branch_protection.json"
RUNBOOK="$ROOT/docs/BRANCH_PROTECTION.md"
CI="$ROOT/.github/workflows/ci.yml"

PASS=0
FAIL=0
ok()  { printf '  ok   - %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL - %s: %s\n' "$1" "${2:-}"; FAIL=$((FAIL + 1)); }

# Evaluate a Python expression over the loaded payload (bound as `d`).
# Prints True / False / ERR (ERR on missing/invalid payload).
pj() {
  python3 - "$PAYLOAD" "$1" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    print(eval(sys.argv[2]))
except Exception:
    print("ERR")
PY
}

payload_contexts() {
  python3 - "$PAYLOAD" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
print("\n".join(sorted(d["required_status_checks"]["contexts"])))
PY
}

ci_job_names() {
  ruby -ryaml -e "puts YAML.load_file('$CI')['jobs'].values.map { |j| j['name'] }.compact.sort" 2>/dev/null
}

# ---------------------------------------------------------------------------

test_protection_payload_requires_coverage_and_e2e_contexts() {
  # Given the payload, Then its required status-check contexts cover the 95%
  # coverage gate and the e2e check.
  local expr='(lambda c: ("coverage" in c) and ("e2e" in c))(" ".join(d["required_status_checks"]["contexts"]).lower())'
  if [ "$(pj "$expr")" == "True" ]; then
    ok "test_protection_payload_requires_coverage_and_e2e_contexts"
  else
    bad "test_protection_payload_requires_coverage_and_e2e_contexts"
  fi
}

test_protection_payload_requires_one_review() {
  # Given the payload, Then at least one approving review is required.
  if [ "$(pj 'd["required_pull_request_reviews"]["required_approving_review_count"] == 1')" == "True" ]; then
    ok "test_protection_payload_requires_one_review"
  else
    bad "test_protection_payload_requires_one_review"
  fi
}

test_protection_dismisses_stale_approvals() {
  # Given the payload, Then pushing new commits dismisses stale approvals.
  if [ "$(pj 'd["required_pull_request_reviews"]["dismiss_stale_reviews"] is True')" == "True" ]; then
    ok "test_protection_dismisses_stale_approvals"
  else
    bad "test_protection_dismisses_stale_approvals"
  fi
}

test_protection_requires_linear_history() {
  # Given the payload, Then linear history is required (no merge commits).
  if [ "$(pj 'd["required_linear_history"] is True')" == "True" ]; then
    ok "test_protection_requires_linear_history"
  else
    bad "test_protection_requires_linear_history"
  fi
}

test_required_contexts_match_ci_job_names() {
  # Given the payload, Then its required contexts EXACTLY match the CI job names
  # (a mismatch would make the required check silently non-blocking).
  local ctx names
  ctx="$(payload_contexts)"
  names="$(ci_job_names)"
  if [ -n "$ctx" ] && [ "$ctx" == "$names" ]; then
    ok "test_required_contexts_match_ci_job_names"
  else
    bad "test_required_contexts_match_ci_job_names" "contexts=[$ctx] jobs=[$names]"
  fi
}

test_readback_confirms_protection_enabled() {
  # Given the payload + runbook, Then admin enforcement is on, force-push and
  # deletion are off, and the runbook documents a read-back audit command.
  local locked doc_ok
  locked="$(pj 'd["enforce_admins"] is True and d["allow_force_pushes"] is False and d["allow_deletions"] is False')"
  doc_ok=1
  { [ -f "$RUNBOOK" ] \
    && grep -q 'branches/main/protection' "$RUNBOOK" \
    && grep -qiE 'read.?back|audit|verify' "$RUNBOOK"; } || doc_ok=0
  if [ "$locked" == "True" ] && [ "$doc_ok" -eq 1 ]; then
    ok "test_readback_confirms_protection_enabled"
  else
    bad "test_readback_confirms_protection_enabled" "locked=$locked doc_ok=$doc_ok"
  fi
}

# ---------------------------------------------------------------------------

echo "Running branch-protection payload tests"
test_protection_payload_requires_coverage_and_e2e_contexts
test_protection_payload_requires_one_review
test_protection_dismisses_stale_approvals
test_protection_requires_linear_history
test_required_contexts_match_ci_job_names
test_readback_confirms_protection_enabled

echo
echo "branch-protection tests: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
