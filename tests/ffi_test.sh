#!/usr/bin/env bash
#
# Tests for the UniFFI xcframework pipeline (issue 0.4):
#   scripts/build_xcframework.sh — generates Swift bindings + a universal
#   RaceStudioFFI.xcframework from the racestudio-ffi crate's uniffi scaffolding.
#
# Named per the issue, Given-When-Then. The pipeline is built once (lazily) and
# both behaviours assert against the artifacts.
#
# Usage: bash tests/ffi_test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
GEN="$ROOT/app/Generated"
XCF="$ROOT/app/RaceStudioFFI.xcframework"

PASS=0
FAIL=0
ok()  { printf '  ok   - %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL - %s: %s\n' "$1" "${2:-}"; FAIL=$((FAIL + 1)); }

BUILT=0
ensure_built() {
  if [[ "$BUILT" -eq 0 ]]; then
    if [[ ! -f "$GEN/racestudio_ffi.swift" || ! -d "$XCF" ]]; then
      bash "$ROOT/scripts/build_xcframework.sh" >/dev/null 2>&1
    fi
    BUILT=1
  fi
}

# ---------------------------------------------------------------------------

test_uniffi_scaffolding_generates() {
  # Given the racestudio-ffi uniffi scaffolding, When bindings are generated,
  # Then the Swift binding + FFI header exist and expose coreVersion().
  ensure_built
  if [[ -f "$GEN/racestudio_ffi.swift" ]] \
    && grep -q 'func coreVersion' "$GEN/racestudio_ffi.swift" \
    && [[ -f "$GEN/racestudio_ffiFFI.h" ]]; then
    ok "test_uniffi_scaffolding_generates"
  else
    bad "test_uniffi_scaffolding_generates" "missing/empty generated bindings"
  fi
}

testXcframeworkHasArm64AndX86Slices() {
  # Given the built xcframework, Then its static library is universal
  # (arm64 + x86_64).
  ensure_built
  local lib="$XCF/macos-arm64_x86_64/libracestudio_ffi.a"
  local archs
  archs="$(lipo -archs "$lib" 2>/dev/null)"
  if grep -q 'arm64' <<<"$archs" && grep -q 'x86_64' <<<"$archs"; then
    ok "testXcframeworkHasArm64AndX86Slices"
  else
    bad "testXcframeworkHasArm64AndX86Slices" "archs: '$archs'"
  fi
}

# ---------------------------------------------------------------------------

echo "Running FFI pipeline tests"
test_uniffi_scaffolding_generates
testXcframeworkHasArm64AndX86Slices

echo
echo "ffi tests: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
