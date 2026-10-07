#!/usr/bin/env bash
#
# Run a command with a time limit (issue 200). GitHub's macOS VMs hand every
# VideoToolbox session to the host (VideoToolbox is paravirtualized there), and
# a Swift test run once blocked for ever in a call the host never answered:
# the job then sat until GitHub's six-hour limit with nothing in its log.
#
# The command's output and exit status pass through. If it is still running
# after SECONDS, the watchdog samples each of its processes whose command line
# matches WATCHDOG_SAMPLE (an extended regex; default, the Swift test helpers)
# into WATCHDOG_SAMPLE_DIR (default $TMPDIR), prints the frames that name our
# code or the media stack, stops the command and every descendant, and exits
# 124, as timeout(1) does. Stopping the watchdog stops the command too.
#
# Usage: scripts/watchdog.sh SECONDS COMMAND [ARG ...]
set -uo pipefail

usage() {
  echo "usage: watchdog.sh SECONDS COMMAND [ARG ...]" >&2
  exit 2
}
[ $# -ge 2 ] || usage
LIMIT="$1"
shift
case "$LIMIT" in '' | *[!0-9]*) usage ;; esac

SAMPLE_PATTERN="${WATCHDOG_SAMPLE:-swiftpm-testing-helper|xctest|PackageTests}"
SAMPLE_DIR="${WATCHDOG_SAMPLE_DIR:-${TMPDIR:-/tmp}}"
SAMPLER="${WATCHDOG_SAMPLER:-/usr/bin/sample}"
FRAMES='RaceStudio|VideoToolbox|VT[A-Z][A-Za-z]+|AVAsset|AVFoundation|Paravirt|CoreMedia'

# The pid of every descendant of $1 (bash 3.2: no mapfile).
descendants() {
  local child
  for child in $(pgrep -P "$1" 2>/dev/null); do
    echo "$child"
    descendants "$child"
  done
}

# Stop $1 and every descendant. The tree is listed before any is killed, so
# none is re-parented away first.
stop_tree() {
  local tree pid
  tree="$1 $(descendants "$1")"
  for pid in $tree; do kill -9 "$pid" 2>/dev/null; done
}

# Sample every process of the tree under $1 that matches SAMPLE_PATTERN, and
# print the frames of its call graph that name our code or the media stack.
sample_tree() {
  local pid command file
  mkdir -p "$SAMPLE_DIR"
  for pid in $1 $(descendants "$1"); do
    command="$(ps -o command= -p "$pid" 2>/dev/null)" || continue
    echo "watchdog:   $pid ${command:0:160}"
    grep -qE "$SAMPLE_PATTERN" <<<"$command" || continue
    file="$SAMPLE_DIR/hang-sample-$pid.txt"
    "$SAMPLER" "$pid" 3 -mayDie -file "$file" >/dev/null 2>&1 || true
    [ -s "$file" ] || continue
    echo "watchdog: sample of $pid in $file; its frames of our code and the media stack:"
    sed -n '/^Call graph:/,/^Total number in stack/p' "$file" | grep -E "$FRAMES" \
      | sed -E 's/  \[0x[0-9a-f]+\]//; s/^[ +!:|]*[0-9]+ /watchdog:       /' | awk '!seen[$0]++' | head -40
  done
}

"$@" &
CHILD=$!
trap 'stop_tree "$CHILD"; exit 143' TERM INT HUP

START=$SECONDS
while kill -0 "$CHILD" 2>/dev/null && [ $((SECONDS - START)) -lt "$LIMIT" ]; do
  sleep 1
done

if kill -0 "$CHILD" 2>/dev/null; then
  echo "watchdog: still running after ${LIMIT}s, stopping: $*"
  sample_tree "$CHILD"
  stop_tree "$CHILD"
  wait "$CHILD" 2>/dev/null
  exit 124
fi
wait "$CHILD"
