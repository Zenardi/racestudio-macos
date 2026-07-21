#!/usr/bin/env bash
#
# Tests for the M6 device-WiFi legal gate (issue 6.1). The units under test are
# three deliverables that gate every later device issue (6.2–6.7):
#
#   * docs/adr/0006-device-wifi-reverse-engineering.md — the clean-room,
#     interoperability-only reverse-engineering decision + legal basis.
#   * docs/device/LEGAL_GATE.md — the AiM first-contact record, the clean-room
#     role split, and the "MUST NOT redistribute" list.
#   * scripts/check_legal_gate.sh — the CI guard that fails a device-area PR whose
#     body lacks a recorded `needs-legal-review` sign-off / ADR link, and that
#     rejects any committed forbidden AiM artifact (firmware/DLL/app binary).
#
# The guard is driven by committed fixture PR-body + changed-file lists (see
# tests/fixtures/legal_gate/) so the whole gate is testable in CI with no GitHub
# API calls. Given-When-Then; the assertions carry no logic beyond string/exit
# checks. Written for macOS system bash (3.2).
#
# Usage: bash tests/legal_gate_test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ADR="$ROOT/docs/adr/0006-device-wifi-reverse-engineering.md"
GATE_DOC="$ROOT/docs/device/LEGAL_GATE.md"
GUARD="$ROOT/scripts/check_legal_gate.sh"
FIX="$ROOT/tests/fixtures/legal_gate"

PASS=0
FAIL=0
ok()  { printf '  ok   - %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL - %s: %s\n' "$1" "${2:-}"; FAIL=$((FAIL + 1)); }

# run_guard <args...> -> sets GUARD_EXIT, GUARD_OUT. Runs with an empty ambient
# PR_BODY/PR_LABELS so only the explicit --body-file/--files-file drive it.
run_guard() {
  GUARD_OUT="$(PR_BODY='' PR_LABELS='' bash "$GUARD" "$@" 2>&1)"
  GUARD_EXIT=$?
}

# ---------------------------------------------------------------------------

test_adr_0006_exists_and_records_clean_room_decision() {
  # Given the three-way choice (official docs / partnership / clean-room RE),
  # Then ADR 0006 exists with the standard sections and records the decision to
  # pursue clean-room interoperability reverse-engineering.
  if [ -f "$ADR" ] \
    && grep -qiE '^-?[[:space:]]*\*?\*?status' "$ADR" \
    && grep -qi '## Context' "$ADR" \
    && grep -qi '## Decision' "$ADR" \
    && grep -qi '## Consequences' "$ADR" \
    && grep -qiE 'clean.?room' "$ADR" \
    && grep -qiE 'interoperab' "$ADR" \
    && grep -qi 'partnership' "$ADR"; then
    ok "test_adr_0006_exists_and_records_clean_room_decision"
  else
    bad "test_adr_0006_exists_and_records_clean_room_decision" "missing/incomplete ADR at $ADR"
  fi
}

test_adr_cites_dmca_1201f_and_eu_art6() {
  # Given the interoperability purpose, When ADR 0006 is read, Then it cites the
  # legal basis in writing (DMCA §1201(f) + EU Software Directive 2009/24/EC
  # Art.6) and states the observation-vs-implementation clean-room separation.
  if [ -f "$ADR" ] \
    && grep -qF '1201(f)' "$ADR" \
    && grep -qF '2009/24/EC' "$ADR" \
    && grep -qiE 'art(icle)?\.? ?6' "$ADR" \
    && grep -qiE 'observ' "$ADR" \
    && grep -qiE 'implement' "$ADR"; then
    ok "test_adr_cites_dmca_1201f_and_eu_art6"
  else
    bad "test_adr_cites_dmca_1201f_and_eu_art6" "missing legal-basis citations in $ADR"
  fi
}

test_legal_gate_lists_do_not_redistribute_artifacts() {
  # Given the legal-gate doc, Then it carries an explicit "MUST NOT redistribute"
  # list naming AiM firmware, RaceStudio DLLs, and the iOS app binary.
  if [ -f "$GATE_DOC" ] \
    && grep -qi 'MUST NOT' "$GATE_DOC" \
    && grep -qi 'firmware' "$GATE_DOC" \
    && grep -qi 'DLL' "$GATE_DOC" \
    && grep -qiE 'app binary|iOS app|app binaries' "$GATE_DOC"; then
    ok "test_legal_gate_lists_do_not_redistribute_artifacts"
  else
    bad "test_legal_gate_lists_do_not_redistribute_artifacts" "do-not-redistribute list missing in $GATE_DOC"
  fi
}

test_aim_first_contact_record_present() {
  # Given the legal-gate doc, Then it records the AiM first-contact attempt: the
  # request text, the date it was sent, and the outcome (or "no response by").
  if [ -f "$GATE_DOC" ] \
    && grep -qiE 'first.?contact' "$GATE_DOC" \
    && grep -qi 'AiM' "$GATE_DOC" \
    && grep -qiE 'date sent|sent:' "$GATE_DOC" \
    && grep -qiE 'response|no response by' "$GATE_DOC"; then
    ok "test_aim_first_contact_record_present"
  else
    bad "test_aim_first_contact_record_present" "AiM first-contact record missing in $GATE_DOC"
  fi
}

test_ci_guard_blocks_device_pr_without_signoff() {
  # Given a device-area PR whose body lacks the recorded needs-legal-review
  # sign-off, When the guard runs, Then it fails (non-zero) and says why.
  run_guard --files-file "$FIX/changed_files_device.txt" \
    --body-file "$FIX/pr_body_missing_signoff.md"
  if [ "$GUARD_EXIT" -ne 0 ] \
    && grep -qiE 'needs-legal-review|sign-?off' <<<"$GUARD_OUT"; then
    ok "test_ci_guard_blocks_device_pr_without_signoff"
  else
    bad "test_ci_guard_blocks_device_pr_without_signoff" "exit=$GUARD_EXIT out=$GUARD_OUT"
  fi
}

test_ci_guard_passes_pr_with_recorded_signoff() {
  # Given a device-area PR whose body carries the ADR link and the recorded
  # needs-legal-review sign-off, When the guard runs, Then it passes (exit 0).
  run_guard --files-file "$FIX/changed_files_device.txt" \
    --body-file "$FIX/pr_body_with_signoff.md"
  if [ "$GUARD_EXIT" -eq 0 ]; then
    ok "test_ci_guard_passes_pr_with_recorded_signoff"
  else
    bad "test_ci_guard_passes_pr_with_recorded_signoff" "exit=$GUARD_EXIT out=$GUARD_OUT"
  fi
}

test_forbidden_artifact_patterns_rejected() {
  # Given a changed-file set that stages a forbidden AiM artifact (firmware .fw /
  # RaceStudio .dll / app .ipa), When the guard runs, Then it fails regardless of
  # the (otherwise valid) sign-off and names the offending file.
  run_guard --files-file "$FIX/changed_files_forbidden.txt" \
    --body-file "$FIX/pr_body_with_signoff.md"
  if [ "$GUARD_EXIT" -ne 0 ] \
    && grep -qiE '\.fw|\.dll|\.ipa|forbidden' <<<"$GUARD_OUT"; then
    ok "test_forbidden_artifact_patterns_rejected"
  else
    bad "test_forbidden_artifact_patterns_rejected" "exit=$GUARD_EXIT out=$GUARD_OUT"
  fi
}

# ---------------------------------------------------------------------------

echo "Running device-WiFi legal-gate tests"
test_adr_0006_exists_and_records_clean_room_decision
test_adr_cites_dmca_1201f_and_eu_art6
test_legal_gate_lists_do_not_redistribute_artifacts
test_aim_first_contact_record_present
test_ci_guard_blocks_device_pr_without_signoff
test_ci_guard_passes_pr_with_recorded_signoff
test_forbidden_artifact_patterns_rejected

echo
echo "legal-gate tests: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
