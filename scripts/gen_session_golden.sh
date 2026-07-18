#!/usr/bin/env bash
#
# Regenerate the imported-session structural golden (issue 5.2) from the
# RaceStudio reference CSV.
#
# The golden is a deterministic JSON summary (channel names/units/sample counts,
# lap count, metadata) of `read_csv(fuji_0033_reference.csv)`, committed as
# fixtures/golden/fuji_0033.session.json and asserted by
# test_import_reference_matches_session_golden.
#
# Run this only when a deliberate importer change should update the golden;
# review the diff before committing.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REF="$ROOT/fixtures/fuji_0033_reference.csv"
GOLDEN="$ROOT/fixtures/golden/fuji_0033.session.json"

if [ ! -s "$REF" ] || [ "$(wc -c <"$REF")" -lt 1024 ]; then
  echo "error: $REF missing or a placeholder — run 'make fixtures' first" >&2
  exit 1
fi

echo "==> Generating $GOLDEN from $(basename "$REF")"
cargo run --quiet --release -p racestudio-io --example session_summary -- "$REF" >"$GOLDEN"
echo "Wrote $(wc -c <"$GOLDEN" | tr -d ' ') bytes."
