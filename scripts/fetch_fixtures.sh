#!/usr/bin/env bash
#
# Fetch test fixtures (real .xrk samples + a RaceStudio reference CSV) from the
# libxrk repo, then regenerate the libxrk-derived golden JSON oracle. Idempotent
# and cached — mirrors XRKConverter's scripts/fetch_samples.sh (issue 0.5).
#
# Large `.xrk`/`.csv` samples stay local (git-ignored); the small deterministic
# goldens under fixtures/golden/ are committed and consumed by every decode test.
#
# Flags:
#   --no-goldens   download the samples only; skip the libxrk golden step
#                  (used by the offline idempotency test).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FIX="$ROOT/fixtures"
GOLDEN="$FIX/golden"
VENV="$ROOT/.venv-fixtures"
BASE="https://raw.githubusercontent.com/m3rlin45/libxrk/master"

NO_GOLDENS=0
[[ "${1:-}" == "--no-goldens" ]] && NO_GOLDENS=1

mkdir -p "$FIX" "$GOLDEN"

dl() {  # remote-path  local-name
  if [ -s "$FIX/$2" ]; then
    echo "  cached  $2"
    return
  fi
  echo "  fetch   $2"
  curl -sfL "$BASE/$1" -o "$FIX/$2"
}

echo "==> Fetching .xrk samples + reference CSV into $FIX"
dl "tests/test_data/aim_official/test.xrk" "aim_official_test.xrk"
dl "tests/test_data/SFJ/CMD_SFJ_Fuji%20GP%20Sh_Generic%20testing_a_0033.xrk" "fuji_0033.xrk"
dl "tests/test_data/SFJ/CMD_SFJ_Fuji%20GP%20Sh_Generic%20testing_a_0033.csv" "fuji_0033_reference.csv"

if [ "$NO_GOLDENS" -eq 1 ]; then
  echo "==> Skipping golden generation (--no-goldens)"
  echo "Done."
  exit 0
fi

echo "==> Generating goldens via libxrk (venv: $VENV)"
if [ ! -x "$VENV/bin/python3" ]; then
  python3 -m venv "$VENV"
fi
"$VENV/bin/python3" -m pip install --quiet --upgrade pip
"$VENV/bin/python3" -m pip install --quiet libxrk
"$VENV/bin/python3" "$SCRIPT_DIR/gen_goldens.py" "$GOLDEN" \
  "$FIX/aim_official_test.xrk" "$FIX/fuji_0033.xrk"
echo "Done."
