#!/usr/bin/env bash
#
# Regenerate the RaceChrono AiM CSV byte golden (issue 5.1) from fuji_0033.xrk.
#
# The golden is the deterministic output of this repo's own writer
# (racestudio-io::write_aim_csv), committed as fixtures/golden/fuji_0033.csv and
# asserted byte-for-byte by test_fuji_export_matches_byte_golden. Independent
# correctness is checked separately against the RaceStudio reference CSV within
# the documented tolerances (0.5 km/h speed, 1.0 m position).
#
# Run this only when a deliberate writer-behaviour change should update the
# golden; review the diff before committing.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
XRK="$ROOT/fixtures/fuji_0033.xrk"
GOLDEN="$ROOT/fixtures/golden/fuji_0033.csv"

if [ ! -s "$XRK" ] || ! head -c 2 "$XRK" | grep -q '<h'; then
  echo "error: $XRK missing or not a genuine .xrk — run 'make fixtures' first" >&2
  exit 1
fi

echo "==> Generating $GOLDEN from $(basename "$XRK")"
cargo run --quiet --release -p racestudio-io --example aim_csv -- "$XRK" > "$GOLDEN"
echo "Wrote $(wc -c < "$GOLDEN" | tr -d ' ') bytes."
