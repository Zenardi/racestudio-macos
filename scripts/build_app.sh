#!/usr/bin/env bash
#
# Assemble the shippable RaceStudio.app bundle (issue #50).
#
# `swift build` produces a bare Mach-O executable; macOS only gives an app
# regular foreground activation (Dock icon, windows, document types) when it is
# wrapped in a `.app` bundle. This script builds the executable **universal**
# (arm64 + x86_64, so one download runs on Apple Silicon and Intel) and lays out
# the bundle around it.
#
# The bundle's Info.plist is derived from app/Sources/RaceStudio/Info.plist --
# the same plist the executable embeds -- with only the version keys rewritten,
# so the shipped bundle can never drift from the source-of-truth document-type
# and UTI declarations.
#
# Signing: this project has no Apple Developer ID, so the bundle is **ad-hoc**
# signed (`codesign --sign -`). That is the strongest signature available
# without a paid certificate: it makes the bundle launchable and keeps the
# sandbox entitlements attached, but it is not notarized, so Gatekeeper will
# quarantine a downloaded copy -- see docs/RELEASE.md.
#
# Usage:
#   scripts/build_app.sh [--version 1.2.0] [--out DIR] [--executable PATH]
#
#   --version     version written into CFBundleShortVersionString/CFBundleVersion
#                 (default: the newest `v*` git tag, else the source plist value)
#   --out         directory to assemble into (default: dist/)
#   --executable  use this prebuilt binary instead of running `swift build`;
#                 used by scripts/release_smoke.sh to exercise the packaging
#                 path without a full Swift build
#   --resource-bundle
#                 the RaceStudio_RaceStudioCore.bundle to install (default: the
#                 one `swift build` emits); paired with --executable so the smoke
#                 test can exercise resource installation with a stub bundle
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_DIR="$ROOT/app"
SRC_PLIST="$APP_DIR/Sources/RaceStudio/Info.plist"
ENTITLEMENTS="$APP_DIR/Sources/RaceStudio/RaceStudio.entitlements"
ICNS="$APP_DIR/AppIcon/AppIcon.icns"

VERSION=""
OUT="$ROOT/dist"
EXECUTABLE=""
RESOURCE_BUNDLE=""
RESOURCE_BUNDLE_NAME="RaceStudio_RaceStudioCore.bundle"

while [ $# -gt 0 ]; do
  case "$1" in
    --version) VERSION="${2:?--version needs a value}"; shift 2 ;;
    --out) OUT="${2:?--out needs a value}"; shift 2 ;;
    --executable) EXECUTABLE="${2:?--executable needs a value}"; shift 2 ;;
    --resource-bundle) RESOURCE_BUNDLE="${2:?--resource-bundle needs a value}"; shift 2 ;;
    -h|--help) sed -n '2,30p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

# Version precedence: explicit flag > newest v* tag > the source plist value.
if [ -z "$VERSION" ]; then
  VERSION="$(git -C "$ROOT" describe --tags --abbrev=0 --match 'v*' 2>/dev/null || true)"
  VERSION="${VERSION#v}"
fi
if [ -z "$VERSION" ]; then
  VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$SRC_PLIST")"
fi

APP="$OUT/RaceStudio.app"
mkdir -p "$OUT"

# The committed app icon (issue #142) is regenerable; rebuild it if a fresh
# checkout is missing it.
[ -f "$ICNS" ] || bash "$SCRIPT_DIR/gen_app_icon.sh"

if [ -n "$EXECUTABLE" ]; then
  echo "==> [1/5] using prebuilt executable: $EXECUTABLE"
  [ -f "$EXECUTABLE" ] || { echo "no such executable: $EXECUTABLE" >&2; exit 1; }
  BIN="$EXECUTABLE"
else
  # One `swift build --arch arm64 --arch x86_64` would be the obvious way to get
  # a universal binary, but SwiftPM's multi-arch mode does not add the binary
  # target's static library to the link line -- the build gets as far as
  # importing the module and then dies with `library not found for
  # -lracestudio_ffi`. Building each slice on its own works (the xcframework's
  # macos-arm64_x86_64 slice resolves fine for a single arch), so build twice
  # and lipo the two executables together.
  echo "==> [1/5] building the release binary, one slice per architecture"
  [ -d "$APP_DIR/RaceStudioFFI.xcframework" ] || bash "$SCRIPT_DIR/build_xcframework.sh"

  ( cd "$APP_DIR" && swift build -c release --product RaceStudio --arch arm64 )
  ARM_BIN="$(cd "$APP_DIR" \
    && swift build -c release --product RaceStudio --arch arm64 --show-bin-path)/RaceStudio"

  ( cd "$APP_DIR" && swift build -c release --product RaceStudio --arch x86_64 )
  X86_BIN="$(cd "$APP_DIR" \
    && swift build -c release --product RaceStudio --arch x86_64 --show-bin-path)/RaceStudio"

  BIN="$(mktemp -d)/RaceStudio"
  lipo -create "$ARM_BIN" "$X86_BIN" -output "$BIN"

  # SwiftPM drops the target's resources in a .bundle next to the binary. Both
  # slices emit identical resources, so either copy will do.
  [ -n "$RESOURCE_BUNDLE" ] \
    || RESOURCE_BUNDLE="$(dirname "$ARM_BIN")/$RESOURCE_BUNDLE_NAME"
fi

echo "==> [2/5] assembling $(basename "$APP")"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/RaceStudio"
chmod +x "$APP/Contents/MacOS/RaceStudio"
printf 'APPL????' > "$APP/Contents/PkgInfo"
cp "$ICNS" "$APP/Contents/Resources/AppIcon.icns"

# The localization catalog lives in SwiftPM's resource bundle. Shipping without
# it is what crashed v0.1.0 (see ResourceBundle.swift), so this is a hard gate,
# not a best-effort copy.
if [ ! -d "$RESOURCE_BUNDLE" ]; then
  echo "FAIL: resource bundle not found: ${RESOURCE_BUNDLE:-<unset>}" >&2
  exit 1
fi
ditto "$RESOURCE_BUNDLE" "$APP/Contents/Resources/$RESOURCE_BUNDLE_NAME"

echo "==> [3/5] Info.plist (version $VERSION, from the source plist)"
cp "$SRC_PLIST" "$APP/Contents/Info.plist"
plist_set() {
  /usr/libexec/PlistBuddy -c "Set :$1 $2" "$APP/Contents/Info.plist" >/dev/null 2>&1 \
    || /usr/libexec/PlistBuddy -c "Add :$1 string $2" "$APP/Contents/Info.plist" >/dev/null
}
plist_set CFBundleShortVersionString "$VERSION"
plist_set CFBundleVersion "$VERSION"
# A bundled app needs its principal class to get regular (foreground)
# activation -- without it the scene never registers a Dock icon or a window.
plist_set NSPrincipalClass NSApplication

echo "==> [4/5] verifying both architectures are present"
ARCHS="$(lipo -archs "$APP/Contents/MacOS/RaceStudio")"
for arch in arm64 x86_64; do
  case " $ARCHS " in
    *" $arch "*) ;;
    *) echo "FAIL: binary is missing the $arch slice (got: $ARCHS)" >&2; exit 1 ;;
  esac
done

CATALOG="$APP/Contents/Resources/$RESOURCE_BUNDLE_NAME/Localizable.xcstrings"
[ -f "$CATALOG" ] || { echo "FAIL: $CATALOG missing from the bundle" >&2; exit 1; }

echo "==> [5/5] ad-hoc signing (no Developer ID -- see docs/RELEASE.md)"
codesign --force --sign - --entitlements "$ENTITLEMENTS" --timestamp=none "$APP"
codesign --verify --strict "$APP"

echo "PASS: $APP  (version $VERSION, archs: $ARCHS, signature: ad-hoc)"
