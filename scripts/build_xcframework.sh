#!/usr/bin/env bash
#
# Builds the universal RaceStudioFFI.xcframework and regenerates the Swift
# bindings for the Rust→Swift UniFFI boundary (issue 0.4).
#
# Steps:
#   1. build a host cdylib and run the pinned uniffi-bindgen to write the Swift
#      bindings (racestudio_ffi.swift + FFI header + modulemap) into app/Generated/
#   2. build the release static library for arm64 + x86_64
#   3. lipo the two slices into one universal static library
#   4. assemble app/RaceStudioFFI.xcframework — via `xcodebuild -create-xcframework`
#      when a full Xcode is present, otherwise by hand (Command Line Tools only)
#
# The .xcframework is a build artifact (git-ignored); the generated .swift is
# checked in. Run via `make xcframework`.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
APP="$ROOT/app"
GEN="$APP/Generated"
XCF="$APP/RaceStudioFFI.xcframework"

LIB_BASENAME="libracestudio_ffi"      # crate racestudio-ffi -> libracestudio_ffi
FFI_MODULE="racestudio_ffiFFI"        # uniffi namespace = crate name
ARM_TARGET="aarch64-apple-darwin"
X86_TARGET="x86_64-apple-darwin"

cd "$ROOT"

echo "==> [1/4] generating Swift bindings -> app/Generated/"
mkdir -p "$GEN"
# Host cdylib supplies the metadata uniffi-bindgen reads.
cargo build --release -p racestudio-ffi
cargo run --release --features bindgen --bin uniffi-bindgen -- \
  generate --library "target/release/${LIB_BASENAME}.dylib" \
  --language swift --out-dir "$GEN"
# The xcframework wants the module map named module.modulemap in its Headers dir.
cp "$GEN/${FFI_MODULE}.modulemap" "$GEN/module.modulemap"

echo "==> [2/4] building release static libs (arm64 + x86_64)"
rustup target add "$ARM_TARGET" "$X86_TARGET" >/dev/null 2>&1 || true
cargo build --release -p racestudio-ffi --target "$ARM_TARGET"
cargo build --release -p racestudio-ffi --target "$X86_TARGET"

echo "==> [3/4] lipo -> universal static library"
UNIVERSAL="$(mktemp -d)/${LIB_BASENAME}.a"
lipo -create \
  "target/${ARM_TARGET}/release/${LIB_BASENAME}.a" \
  "target/${X86_TARGET}/release/${LIB_BASENAME}.a" \
  -output "$UNIVERSAL"
echo "    universal slices: $(lipo -archs "$UNIVERSAL")"

echo "==> [4/4] assembling RaceStudioFFI.xcframework"
rm -rf "$XCF"
HEADERS_SRC="$(mktemp -d)/Headers"
mkdir -p "$HEADERS_SRC"
cp "$GEN/${FFI_MODULE}.h" "$HEADERS_SRC/"
cp "$GEN/module.modulemap" "$HEADERS_SRC/"

if xcrun --find xcodebuild >/dev/null 2>&1 && xcodebuild -version >/dev/null 2>&1; then
  echo "    using xcodebuild -create-xcframework"
  xcodebuild -create-xcframework \
    -library "$UNIVERSAL" -headers "$HEADERS_SRC" \
    -output "$XCF"
else
  echo "    xcodebuild unavailable (Command Line Tools) — assembling by hand"
  SLICE="$XCF/macos-arm64_x86_64"
  mkdir -p "$SLICE/Headers"
  cp "$UNIVERSAL" "$SLICE/${LIB_BASENAME}.a"
  cp "$HEADERS_SRC/${FFI_MODULE}.h" "$SLICE/Headers/"
  cp "$HEADERS_SRC/module.modulemap" "$SLICE/Headers/"
  cat > "$XCF/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>AvailableLibraries</key><array><dict>
    <key>LibraryIdentifier</key><string>macos-arm64_x86_64</string>
    <key>LibraryPath</key><string>${LIB_BASENAME}.a</string>
    <key>HeadersPath</key><string>Headers</string>
    <key>SupportedArchitectures</key><array><string>arm64</string><string>x86_64</string></array>
    <key>SupportedPlatform</key><string>macos</string>
  </dict></array>
  <key>CFBundlePackageType</key><string>XFWK</string>
  <key>XCFrameworkFormatVersion</key><string>1.0</string>
</dict></plist>
PLIST
fi

echo "PASS: $(basename "$XCF") built — slices: $(lipo -archs "$UNIVERSAL")"
