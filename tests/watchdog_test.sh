#!/usr/bin/env bash
#
# Tests for scripts/watchdog.sh (issue 200): a Swift test run on GitHub's macOS
# VMs can block for ever in a VideoToolbox call the host never answers, and the
# job then sat until GitHub's six-hour limit. The watchdog runs a command,
# passes its output and status through, and, when it runs past its limit,
# samples its stuck processes, prints their frames, stops the whole process tree
# and exits 124. Offline: the hung commands are sleeps and the sampler is a fake.
#
# Usage: bash tests/watchdog_test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WATCHDOG="$ROOT/scripts/watchdog.sh"

PASS=0
FAIL=0
ok()  { printf '  ok   - %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL - %s: %s\n' "$1" "${2:-}"; FAIL=$((FAIL + 1)); }

WORK="$(mktemp -d)"
trap 'pkill -f "sleep 432[0-9]" 2>/dev/null; rm -rf "$WORK"' EXIT

# A sampler standing in for `sample PID SECONDS -mayDie -file FILE`: it writes
# a call graph with one media-stack frame, one of ours and one of neither.
FAKE_SAMPLER="$WORK/fake-sample"
cat > "$FAKE_SAMPLER" <<'SH'
#!/usr/bin/env bash
pid="$1"; file="$5"
cat > "$file" <<EOF
Sampling process $pid
Call graph:
    + 2868 VTCompressionSessionCreate + 32
    + 2868 static EncoderAvailability.openCompressionSession(_:) + 116 RaceStudioCore
    + 2868 __workq_kernreturn  (in libsystem_kernel.dylib)
EOF
SH
chmod +x "$FAKE_SAMPLER"

# Whether any process still runs `sleep <marker>`.
still_running() {
  pgrep -f "sleep $1" >/dev/null 2>&1
}

test_a_finished_command_keeps_its_output_and_status() {
  # Given a command that prints and exits 3 well within its limit, When the
  # watchdog runs it, Then the output and the status pass through untouched.
  local out rc
  out="$(bash "$WATCHDOG" 10 bash -c 'echo from-the-command; exit 3' 2>&1)"
  rc=$?
  if [ "$rc" -eq 3 ] && grep -q 'from-the-command' <<<"$out" && ! grep -q 'watchdog:' <<<"$out"; then
    ok "test_a_finished_command_keeps_its_output_and_status"
  else
    bad "test_a_finished_command_keeps_its_output_and_status" "rc=$rc out=$out"
  fi
}

test_a_hung_command_is_stopped_with_124() {
  # Given a command that never finishes, When it runs past a 2 s limit, Then
  # the watchdog says so, stops it and exits 124 — in seconds, not hours.
  local out rc start elapsed
  start=$SECONDS
  out="$(WATCHDOG_SAMPLER="$FAKE_SAMPLER" WATCHDOG_SAMPLE_DIR="$WORK/s1" \
    bash "$WATCHDOG" 2 bash -c 'sleep 4321' 2>&1)"
  rc=$?
  elapsed=$((SECONDS - start))
  if [ "$rc" -eq 124 ] && [ "$elapsed" -lt 15 ] \
    && grep -q 'watchdog: still running after 2s' <<<"$out" && ! still_running 4321; then
    ok "test_a_hung_command_is_stopped_with_124"
  else
    bad "test_a_hung_command_is_stopped_with_124" "rc=$rc elapsed=${elapsed}s out=$out"
  fi
}

test_every_descendant_is_stopped() {
  # Given a command whose child and grandchild hang, When the limit passes,
  # Then none of them outlives the watchdog.
  local rc
  WATCHDOG_SAMPLER="$FAKE_SAMPLER" WATCHDOG_SAMPLE_DIR="$WORK/s2" \
    bash "$WATCHDOG" 2 bash -c 'bash -c "sleep 4322 & sleep 4323; wait" & wait' >/dev/null 2>&1
  rc=$?
  sleep 1
  if [ "$rc" -eq 124 ] && ! still_running 4322 && ! still_running 4323; then
    ok "test_every_descendant_is_stopped"
  else
    bad "test_every_descendant_is_stopped" "rc=$rc; left: $(pgrep -fl 'sleep 432[23]' | tr '\n' ' ')"
  fi
}

test_the_stuck_processes_are_sampled_and_their_frames_printed() {
  # Given a hung command whose processes match WATCHDOG_SAMPLE, When the limit
  # passes, Then each is sampled into WATCHDOG_SAMPLE_DIR, and the log names the
  # sample file and the frames of our code and the media stack — and no others.
  local out rc dir="$WORK/s3"
  out="$(WATCHDOG_SAMPLER="$FAKE_SAMPLER" WATCHDOG_SAMPLE_DIR="$dir" WATCHDOG_SAMPLE='sleep 4324' \
    bash "$WATCHDOG" 2 bash -c 'sleep 4324' 2>&1)"
  rc=$?
  local samples
  samples="$(ls "$dir"/hang-sample-*.txt 2>/dev/null | wc -l | tr -d ' ')"
  if [ "$rc" -eq 124 ] && [ "$samples" -ge 1 ] \
    && grep -q "$dir/hang-sample-" <<<"$out" \
    && grep -q 'VTCompressionSessionCreate' <<<"$out" \
    && grep -q 'EncoderAvailability.openCompressionSession' <<<"$out" \
    && ! grep -q '__workq_kernreturn' <<<"$out"; then
    ok "test_the_stuck_processes_are_sampled_and_their_frames_printed"
  else
    bad "test_the_stuck_processes_are_sampled_and_their_frames_printed" "rc=$rc samples=$samples out=$out"
  fi
}

test_a_stopped_watchdog_stops_its_command() {
  # Given a watchdog with a long limit, When it is itself stopped (a cancelled
  # job, a Ctrl-C), Then its command goes with it rather than running on — a
  # background command of a script ignores the terminal's interrupt.
  local wd
  WATCHDOG_SAMPLER="$FAKE_SAMPLER" bash "$WATCHDOG" 600 bash -c 'sleep 4325' >/dev/null 2>&1 &
  wd=$!
  sleep 2
  kill -TERM "$wd"
  wait "$wd" 2>/dev/null
  sleep 1
  if ! still_running 4325; then
    ok "test_a_stopped_watchdog_stops_its_command"
  else
    bad "test_a_stopped_watchdog_stops_its_command" "left: $(pgrep -fl 'sleep 4325' | tr '\n' ' ')"
  fi
}

test_a_missing_limit_is_a_usage_error() {
  # Given no limit or no command, When the watchdog runs, Then it exits 2.
  local rc1 rc2
  bash "$WATCHDOG" >/dev/null 2>&1; rc1=$?
  bash "$WATCHDOG" 5 >/dev/null 2>&1; rc2=$?
  if [ "$rc1" -eq 2 ] && [ "$rc2" -eq 2 ]; then
    ok "test_a_missing_limit_is_a_usage_error"
  else
    bad "test_a_missing_limit_is_a_usage_error" "rc1=$rc1 rc2=$rc2"
  fi
}

echo "watchdog tests:"
test_a_finished_command_keeps_its_output_and_status
test_a_hung_command_is_stopped_with_124
test_every_descendant_is_stopped
test_the_stuck_processes_are_sampled_and_their_frames_printed
test_a_stopped_watchdog_stops_its_command
test_a_missing_limit_is_a_usage_error
echo "watchdog tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
