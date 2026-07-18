#!/usr/bin/env bash
#
# Regenerate the imported-session structural golden (issue 5.2) from the
# RaceStudio reference CSV.
#
# The golden is a deterministic JSON summary (channel names/units/sample counts,
# lap count, metadata) of `read_csv(fuji_0033_reference.csv)`. Blessing it with
# RS_WRITE_GOLDEN=1 runs the *same* function the assertion uses
# (test_import_reference_matches_session_golden), so the generator and the oracle
# can never drift.
#
# Run this only when a deliberate importer change should update the golden;
# review the diff before committing.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REF="$ROOT/fixtures/fuji_0033_reference.csv"

if [ ! -s "$REF" ] || [ "$(wc -c <"$REF")" -lt 1024 ]; then
  echo "error: $REF missing or a placeholder — run 'make fixtures' first" >&2
  exit 1
fi

echo "==> Blessing fixtures/golden/fuji_0033.session.json from $(basename "$REF")"
RS_WRITE_GOLDEN=1 cargo test --quiet -p racestudio-io --test csv_import_test \
  test_import_reference_matches_session_golden -- --exact
echo "Done."
