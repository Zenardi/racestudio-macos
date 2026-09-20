#!/usr/bin/env bash
#
# Fast self-test of the release packaging path (issue #50).
#
# The real tag build spends nearly all its wall-clock in `swift build`, which
# says nothing about whether the *packaging* is correct. This runs the genuine
# scripts/build_app.sh + scripts/package_dmg.sh code over a throwaway universal
# stub executable, so bundle layout, plist rewriting, ad-hoc signing, the DMG,
# and the checksums are all exercised in seconds -- in CI, on every PR, with no
# secrets and no full build.
#
# Usage: scripts/release_smoke.sh --dry-run [--version 9.9.9] [--out DIR]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DRY_RUN=0
VERSION="0.0.0-smoke"
OUT=""

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --version) VERSION="${2:?--version needs a value}"; shift 2 ;;
    --out) OUT="${2:?--out needs a value}"; shift 2 ;;
    -h|--help) sed -n '2,13p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [ "$DRY_RUN" -ne 1 ]; then
  echo "scripts/release_smoke.sh only supports --dry-run" >&2
  exit 2
fi

OWN_OUT=0
if [ -z "$OUT" ]; then
  OUT="$(mktemp -d)"
  OWN_OUT=1
fi
mkdir -p "$OUT"

WORK="$(mktemp -d)"
cleanup() {
  rm -rf "$WORK"
  if [ "$OWN_OUT" -eq 1 ]; then rm -rf "$OUT"; fi
  return 0
}
trap cleanup EXIT

echo "==> [smoke 1/3] compiling a universal stub executable"
cat > "$WORK/stub.c" <<'C'
int main(void) { return 0; }
C
cc -arch arm64 -arch x86_64 -o "$WORK/RaceStudio" "$WORK/stub.c"

echo "==> [smoke 2/3] scripts/build_app.sh"
bash "$SCRIPT_DIR/build_app.sh" --version "$VERSION" --out "$OUT" --executable "$WORK/RaceStudio"

echo "==> [smoke 3/3] scripts/package_dmg.sh"
bash "$SCRIPT_DIR/package_dmg.sh" --version "$VERSION" --out "$OUT"

DMG="$OUT/RaceStudio-$VERSION.dmg"
[ -f "$DMG" ] || { echo "FAIL: no $DMG" >&2; exit 1; }
[ -f "$OUT/SHA256SUMS.txt" ] || { echo "FAIL: no SHA256SUMS.txt" >&2; exit 1; }
( cd "$OUT" && shasum -a 256 -c SHA256SUMS.txt >/dev/null )

echo "RELEASE SMOKE OK -- $(basename "$DMG") + SHA256SUMS.txt packaged and verified."
