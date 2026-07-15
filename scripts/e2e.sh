#!/usr/bin/env bash
#
# End-to-end check (issue 0.6) — the `e2e` gate referenced by 0.7.
#
# Builds the shipping pipeline (RaceStudioFFI.xcframework + the Swift app) and
# validates the decode oracle. At M0 there is no `.xrk` decoder yet (that lands
# in M1), so this validates that every committed golden is well-formed. As decode
# lands this script will decode each fixtures/*.xrk and assert its output matches
# the golden. Thin by design — mirrors XRKConverter's scripts/e2e.sh shape.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "==> [e2e 1/3] building RaceStudioFFI.xcframework"
if [ ! -d "$ROOT/app/RaceStudioFFI.xcframework" ]; then
  bash "$SCRIPT_DIR/build_xcframework.sh"
else
  echo "  cached  RaceStudioFFI.xcframework"
fi

echo "==> [e2e 2/3] swift build (RaceStudioCore + @main app)"
( cd "$ROOT/app" && swift build )

echo "==> [e2e 3/3] validating decode goldens"
shopt -s nullglob
goldens=("$ROOT"/fixtures/golden/*.channels.json)
if [ "${#goldens[@]}" -eq 0 ]; then
  echo "  no goldens found — run 'make fixtures'" >&2
  exit 1
fi

for golden in "${goldens[@]}"; do
  python3 - "$golden" <<'PY'
import json, os, sys
path = sys.argv[1]
with open(path) as fh:
    data = json.load(fh)
count = data["channel_count"]
assert count == len(data["channels"]) > 0, f"malformed channels golden: {path}"
for channel in data["channels"]:
    assert channel["name"], "channel with empty name"
    assert "samples" in channel, "channel missing sample count"
print(f"  ok  {os.path.basename(path)}  ({count} channels)")
PY
done

echo "E2E OK — xcframework + app built; ${#goldens[@]} golden(s) validated."
