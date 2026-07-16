#!/usr/bin/env bash
#
# End-to-end check (issue 0.6, extended in 1.8) — the `e2e` gate referenced by 0.7.
#
# Builds the shipping pipeline (RaceStudioFFI.xcframework + the Swift app) and
# runs the corpus-wide golden conformance harness
# (core/racestudio-decode/tests/golden_e2e_test.rs): it decodes every
# fixtures/*.xrk with `decode_session` and asserts metadata/channels/gps/laps
# match fixtures/golden/*.json within the documented tolerances
# (docs/DECODE_TOLERANCES.md), exiting non-zero on any mismatch.
#
# Usage:
#   scripts/e2e.sh                 full gate: build pipeline + run harness
#   scripts/e2e.sh --goldens-only  run only the harness (used by the harness's
#                                  own script self-test against a poisoned corpus;
#                                  honours RS_FIXTURES_DIR)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

GOLDENS_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --goldens-only) GOLDENS_ONLY=1 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

FIXTURES_DIR="${RS_FIXTURES_DIR:-$ROOT/fixtures}"

if [ "$GOLDENS_ONLY" -eq 0 ]; then
  echo "==> [e2e 1/4] building RaceStudioFFI.xcframework"
  if [ ! -d "$ROOT/app/RaceStudioFFI.xcframework" ]; then
    bash "$SCRIPT_DIR/build_xcframework.sh"
  else
    echo "  cached  RaceStudioFFI.xcframework"
  fi

  echo "==> [e2e 2/4] swift build (RaceStudioCore + @main app)"
  ( cd "$ROOT/app" && swift build )

  # The goldens are committed; the .xrk samples are git-ignored. Ensure the
  # samples are present so the harness has real data to decode (it skips
  # gracefully when the corpus is empty, which would make this gate vacuous).
  echo "==> [e2e 3/4] ensuring .xrk samples are present"
  if ls "$FIXTURES_DIR"/*.xrk >/dev/null 2>&1; then
    echo "  present  $(ls "$FIXTURES_DIR"/*.xrk | wc -l | tr -d ' ') sample(s)"
  else
    echo "  no .xrk samples — fetching (goldens stay committed)"
    bash "$SCRIPT_DIR/fetch_fixtures.sh" --no-goldens
  fi
fi

STEP=$([ "$GOLDENS_ONLY" -eq 1 ] && echo "1/1" || echo "4/4")
echo "==> [e2e $STEP] corpus golden conformance (decode_session vs libxrk oracle)"
# RS_REQUIRE_CORPUS makes the harness FAIL (not skip) on an empty corpus, so this
# gate can never pass vacuously when the samples are absent or non-genuine.
if [ "$GOLDENS_ONLY" -eq 1 ]; then
  # Poisoned-corpus self-test context: run the harness against RS_FIXTURES_DIR,
  # skipping the script self-test itself so it cannot recurse.
  RS_REQUIRE_CORPUS=1 RS_FIXTURES_DIR="$FIXTURES_DIR" \
    cargo test -p racestudio-decode --test golden_e2e_test -- \
    --skip test_e2e_script_exits_nonzero_on_mismatch
else
  # Full gate: run the whole harness, enabling the script self-test.
  RS_REQUIRE_CORPUS=1 RS_RUN_E2E_SCRIPT_TEST=1 \
    cargo test -p racestudio-decode --test golden_e2e_test
fi

if [ "$GOLDENS_ONLY" -eq 1 ]; then
  echo "E2E (goldens-only) OK — corpus matches the libxrk goldens."
else
  echo "E2E OK — xcframework + app built; corpus matches the libxrk goldens."
fi
