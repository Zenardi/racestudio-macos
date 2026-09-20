#!/usr/bin/env bash
#
# Package an assembled RaceStudio.app into a downloadable .dmg (issue #50).
#
# The disk image holds the app beside an `/Applications` symlink, so installing
# is the familiar drag-across gesture. It is compressed + read-only (UDZO) and
# HFS+-formatted for the widest macOS compatibility, and `ditto` stages the
# bundle so the code signature and extended attributes survive the copy
# (`cp -R` does not reliably preserve them).
#
# A SHA256SUMS.txt is written beside the image so a download can be verified --
# the only integrity check available for an unsigned, non-notarized build.
#
# Usage:
#   scripts/package_dmg.sh [--version 1.2.0] [--app PATH] [--out DIR]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

VERSION=""
OUT="$ROOT/dist"
APP=""

while [ $# -gt 0 ]; do
  case "$1" in
    --version) VERSION="${2:?--version needs a value}"; shift 2 ;;
    --out) OUT="${2:?--out needs a value}"; shift 2 ;;
    --app) APP="${2:?--app needs a value}"; shift 2 ;;
    -h|--help) sed -n '2,16p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

[ -n "$APP" ] || APP="$OUT/RaceStudio.app"
[ -d "$APP" ] || { echo "no app bundle at $APP -- run scripts/build_app.sh first" >&2; exit 1; }

# Default to whatever the bundle itself says, so the image name can never
# disagree with the version inside it.
if [ -z "$VERSION" ]; then
  VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
fi

DMG="$OUT/RaceStudio-$VERSION.dmg"
mkdir -p "$OUT"

echo "==> [1/3] staging the disk-image contents"
STAGE_ROOT="$(mktemp -d)"
STAGE="$STAGE_ROOT/RaceStudio"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/RaceStudio.app"
ln -s /Applications "$STAGE/Applications"
# The signature must survive staging -- a broken one would ship a bundle macOS
# refuses to launch even after the user clears quarantine.
codesign --verify --strict "$STAGE/RaceStudio.app"

echo "==> [2/3] hdiutil create $(basename "$DMG")"
rm -f "$DMG"
hdiutil create \
  -volname "RaceStudio $VERSION" \
  -srcfolder "$STAGE" \
  -fs HFS+ \
  -format UDZO \
  -ov -quiet \
  "$DMG"
rm -rf "$STAGE_ROOT"

echo "==> [3/3] SHA256SUMS.txt"
( cd "$OUT" && shasum -a 256 "$(basename "$DMG")" > SHA256SUMS.txt )

echo "PASS: $DMG ($(du -h "$DMG" | cut -f1 | tr -d ' '))"
cat "$OUT/SHA256SUMS.txt"
