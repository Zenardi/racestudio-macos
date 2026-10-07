#!/usr/bin/env bash
#
# Tests for scripts/collect_crash_reports.sh (issue 200): after a failed CI
# run it copies every crash report (`.ips`) into the artifact folder and prints
# each one's faulting thread, so a test process that dies with "Exited with
# unexpected signal code 11" names the code it crashed in. Offline: the
# reports are fakes written into a temporary folder.
#
# Usage: bash tests/crash_reports_test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
COLLECT="$ROOT/scripts/collect_crash_reports.sh"

PASS=0
FAIL=0
ok()  { printf '  ok   - %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL - %s: %s\n' "$1" "${2:-}"; FAIL=$((FAIL + 1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# A crash report as ReportCrash writes one: a JSON header line, then the body.
# Thread 0 is idle; thread 1 faulted in `OverlayCompositor.compose`.
write_report() {
  cat > "$1" <<'IPS'
{"app_name":"swiftpm-testing-helper","bug_type":"309","name":"swiftpm-testing-helper"}
{
  "procName" : "swiftpm-testing-helper",
  "exception" : {"type" : "EXC_BAD_ACCESS", "signal" : "SIGSEGV", "subtype" : "KERN_INVALID_ADDRESS at 0x10"},
  "faultingThread" : 1,
  "usedImages" : [{"name" : "libsystem_kernel.dylib"}, {"name" : "RaceStudioCoreTests"}],
  "threads" : [
    {"frames" : [{"imageIndex" : 0, "symbol" : "mach_msg2_trap"}]},
    {"queue" : "com.racestudio.overlay-compositor",
     "frames" : [{"imageIndex" : 1, "symbol" : "OverlayCompositor.compose(_:)",
                  "sourceFile" : "OverlayCompositor.swift", "sourceLine" : 73}]}
  ]
}
IPS
}

test_reports_are_copied_and_their_faulting_thread_printed() {
  # Given a crash report in a reports folder, When the collector runs, Then it
  # copies the report into the destination and prints the faulting thread's
  # queue, signal and frames.
  local reports="$WORK/reports1" dest="$WORK/dest1" out rc
  mkdir -p "$reports"
  write_report "$reports/swiftpm-testing-helper-2026-10-07-150000.ips"

  out="$(CRASH_REPORT_WAIT=0 bash "$COLLECT" "$dest" "$reports" 2>&1)"
  rc=$?

  if [ "$rc" -eq 0 ] \
    && [ -f "$dest/swiftpm-testing-helper-2026-10-07-150000.ips" ] \
    && grep -q 'SIGSEGV' <<<"$out" \
    && grep -q 'com.racestudio.overlay-compositor' <<<"$out" \
    && grep -q 'OverlayCompositor.compose(_:) OverlayCompositor.swift:73' <<<"$out" \
    && ! grep -q 'mach_msg2_trap' <<<"$out"; then
    ok "test_reports_are_copied_and_their_faulting_thread_printed"
  else
    bad "test_reports_are_copied_and_their_faulting_thread_printed" "rc=$rc out=$(tr '\n' '|' <<<"$out")"
  fi
}

test_no_report_is_not_an_error() {
  # Given no crash report anywhere (a plain test failure), When the collector
  # runs, Then it says so and succeeds, leaving the destination empty.
  local reports="$WORK/reports2" dest="$WORK/dest2" out rc
  mkdir -p "$reports"

  out="$(CRASH_REPORT_WAIT=0 bash "$COLLECT" "$dest" "$reports" "$WORK/missing" 2>&1)"
  rc=$?

  if [ "$rc" -eq 0 ] && grep -q 'no crash reports' <<<"$out" && [ -z "$(ls -A "$dest")" ]; then
    ok "test_no_report_is_not_an_error"
  else
    bad "test_no_report_is_not_an_error" "rc=$rc out=$(tr '\n' '|' <<<"$out")"
  fi
}

test_reports_older_than_the_job_are_left_out() {
  # Given a report from before the job (the runner image ships some) and a
  # fresh one, When the collector runs, Then only the fresh one is copied and
  # printed.
  local reports="$WORK/reports4" dest="$WORK/dest4" out rc
  mkdir -p "$reports"
  write_report "$reports/coreaudiod-2026-08-30-210857.ips"
  touch -t 202608302108 "$reports/coreaudiod-2026-08-30-210857.ips"
  write_report "$reports/swiftpm-testing-helper-fresh.ips"

  out="$(CRASH_REPORT_WAIT=0 bash "$COLLECT" "$dest" "$reports" 2>&1)"
  rc=$?

  if [ "$rc" -eq 0 ] && [ "$(ls "$dest")" = "swiftpm-testing-helper-fresh.ips" ] \
    && ! grep -q 'coreaudiod' <<<"$out"; then
    ok "test_reports_older_than_the_job_are_left_out"
  else
    bad "test_reports_older_than_the_job_are_left_out" "rc=$rc dest=$(ls "$dest" | tr '\n' ' ') out=$(tr '\n' '|' <<<"$out")"
  fi
}

test_an_unreadable_report_is_still_copied() {
  # Given a report that is not valid JSON (cut short), When the collector runs,
  # Then the file is still copied and the run still succeeds.
  local reports="$WORK/reports3" dest="$WORK/dest3" out rc
  mkdir -p "$reports"
  printf '{"app_name":"xctest"}\n{ "threads" : [' > "$reports/xctest-cut.ips"

  out="$(CRASH_REPORT_WAIT=0 bash "$COLLECT" "$dest" "$reports" 2>&1)"
  rc=$?

  if [ "$rc" -eq 0 ] && [ -f "$dest/xctest-cut.ips" ] && grep -q 'xctest-cut.ips' <<<"$out"; then
    ok "test_an_unreadable_report_is_still_copied"
  else
    bad "test_an_unreadable_report_is_still_copied" "rc=$rc out=$(tr '\n' '|' <<<"$out")"
  fi
}

test_ci_and_release_upload_crash_reports_on_failure() {
  # Given the two workflows that run `make ci`, Then each collects and uploads
  # the crash reports when the job fails.
  local wf missing=""
  for wf in ci.yml release.yml; do
    grep -q 'scripts/collect_crash_reports.sh' "$ROOT/.github/workflows/$wf" \
      && grep -q 'name: crash-reports' "$ROOT/.github/workflows/$wf" \
      || missing="$missing $wf"
  done
  if [ -z "$missing" ]; then
    ok "test_ci_and_release_upload_crash_reports_on_failure"
  else
    bad "test_ci_and_release_upload_crash_reports_on_failure" "missing in:$missing"
  fi
}

# ---------------------------------------------------------------------------

echo "Running crash-report collector tests"
test_reports_are_copied_and_their_faulting_thread_printed
test_no_report_is_not_an_error
test_reports_older_than_the_job_are_left_out
test_an_unreadable_report_is_still_copied
test_ci_and_release_upload_crash_reports_on_failure

echo
echo "crash-report tests: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
