#!/usr/bin/env bash
#
# Collect the crash reports a failed CI job left behind (issue 200). A Swift
# test process that crashes leaves only "Exited with unexpected signal code 11"
# in the log: Swift Testing buffers its output, so no test is named. The crash
# report (`.ips`) names the faulting thread, its queue and its frames.
#
# ReportCrash writes a report a few seconds after the crash, so this waits up
# to CRASH_REPORT_WAIT seconds (default 20) for one to appear. It then copies
# every `.ips` from the report folders into DEST, which the workflow uploads
# as an artifact, and prints each report's faulting thread to the log.
#
# Usage: scripts/collect_crash_reports.sh DEST [REPORT_DIR ...]
#   REPORT_DIR defaults to ~/Library/Logs/DiagnosticReports and
#   /Library/Logs/DiagnosticReports.
set -euo pipefail

DEST="${1:?usage: collect_crash_reports.sh DEST [REPORT_DIR ...]}"
shift
if [ $# -gt 0 ]; then
  DIRS=("$@")
else
  DIRS=("$HOME/Library/Logs/DiagnosticReports" "/Library/Logs/DiagnosticReports")
fi
WAIT="${CRASH_REPORT_WAIT:-20}"

mkdir -p "$DEST"

# Every crash report in the report folders (bash 3.2: no mapfile).
reports() {
  local dir
  for dir in "${DIRS[@]}"; do
    [ -d "$dir" ] && find "$dir" -maxdepth 1 -type f -name '*.ips' -print
  done
  return 0
}

waited=0
while [ -z "$(reports)" ] && [ "$waited" -lt "$WAIT" ]; do
  sleep 1
  waited=$((waited + 1))
done
# A report that has just appeared may still be being written.
[ "$WAIT" -gt 0 ] && [ -n "$(reports)" ] && sleep 2

found=0
while IFS= read -r report; do
  [ -n "$report" ] || continue
  found=$((found + 1))
  cp "$report" "$DEST/"
  echo "=== $(basename "$report")"
  # The faulting thread: its queue, the signal, and its frames, symbolicated
  # where the report is. `-I` keeps the interpreter off this script's folder.
  python3 -I - "$report" <<'PY' || echo "  (could not be read; see the uploaded file)"
import json
import sys

with open(sys.argv[1], encoding="utf-8", errors="replace") as handle:
    header = handle.readline()
    body = json.loads(handle.read())
exception = body.get("exception", {})
print("  process:", body.get("procName") or json.loads(header).get("app_name", "?"))
print("  exception:", exception.get("type", "?"), exception.get("signal", ""), exception.get("subtype", ""))
images = body.get("usedImages", [])
faulting = body.get("faultingThread")
threads = body.get("threads", [])
if faulting is None or faulting >= len(threads):
    print("  (no faulting thread)")
    sys.exit(0)
thread = threads[faulting]
print("  thread %d queue=%s name=%s" % (faulting, thread.get("queue", "-"), thread.get("name", "-")))
for frame in thread.get("frames", [])[:40]:
    index = frame.get("imageIndex", -1)
    image = images[index].get("name", "?") if 0 <= index < len(images) else "?"
    where = ""
    if frame.get("sourceFile"):
        where = " %s:%s" % (frame["sourceFile"], frame.get("sourceLine", "?"))
    print("    %-28s %s%s" % (image, frame.get("symbol", "0x%x" % frame.get("imageOffset", 0)), where))
PY
done <<<"$(reports)"

if [ "$found" -eq 0 ]; then
  echo "no crash reports in: ${DIRS[*]}"
fi
