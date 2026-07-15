#!/usr/bin/env bash
#
# Tests for scripts/fetch_fixtures.sh — the golden-fixtures fetch harness
# (issue 0.5). Runs offline: pre-seeds the sample files so the cached `dl`
# short-circuits and no network is used.
#
# Usage: bash tests/fixtures_test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FETCH="$ROOT/scripts/fetch_fixtures.sh"
FIX="$ROOT/fixtures"

PASS=0
FAIL=0
ok()  { printf '  ok   - %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL - %s: %s\n' "$1" "${2:-}"; FAIL=$((FAIL + 1)); }

test_fetch_fixtures_is_idempotent() {
  # Given the samples already present, When fetch runs, Then every file reports
  # "cached" and nothing is downloaded (idempotent, cached).
  mkdir -p "$FIX"
  local f seeded=()
  for f in aim_official_test.xrk fuji_0033.xrk fuji_0033_reference.csv; do
    if [ ! -s "$FIX/$f" ]; then
      printf 'seed\n' > "$FIX/$f"
      seeded+=("$FIX/$f")
    fi
  done

  local out rc
  out="$(bash "$FETCH" --no-goldens 2>&1)"
  rc=$?

  # Remove any placeholders we created. Leaving a fake ~5-byte .xrk behind would
  # make a later "cached" fetch skip the real download and break the decode
  # oracle tests (which would open the placeholder and hit BadMagic).
  [ "${#seeded[@]}" -gt 0 ] && rm -f "${seeded[@]}"

  if [ "$rc" -eq 0 ] \
    && grep -qE '^  cached  aim_official_test\.xrk$' <<<"$out" \
    && ! grep -qE '^  fetch ' <<<"$out"; then
    ok "test_fetch_fixtures_is_idempotent"
  else
    bad "test_fetch_fixtures_is_idempotent" "rc=$rc out=$(tr '\n' '|' <<<"$out")"
  fi
}

# ---------------------------------------------------------------------------

echo "Running fetch-fixtures tests"
test_fetch_fixtures_is_idempotent

echo
echo "fixtures tests: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
