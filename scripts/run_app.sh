#!/usr/bin/env bash
#
# Build the RaceStudio SwiftUI app and launch it as a real macOS `.app` bundle.
#
# `swift run RaceStudio` builds and starts a bare Mach-O executable. macOS gives
# an un-bundled executable non-GUI (accessory) activation, so the app's scene
# never registers a Dock icon or shows a window — the process just exits back to
# the shell. Wrapping the built binary in a minimal `.app` bundle (an `Info.plist`
# with `NSPrincipalClass = NSApplication`) and `open`-ing it gives regular
# foreground activation: the app appears in the Dock and shows its window.
#
# The FFI is a static library (`libracestudio_ffi.a`) linked into the binary, so
# the bundle needs no embedded frameworks. Run via `make run`.
set -euo pipefail

cd "$(dirname "$0")/../app"

# The static FFI xcframework is linked into the binary; build it if missing.
[ -d RaceStudioFFI.xcframework ] || bash ../scripts/build_xcframework.sh

# The app icon (issue 7.4) is committed under app/AppIcon; regenerate if missing.
[ -f AppIcon/AppIcon.icns ] || bash ../scripts/gen_app_icon.sh

swift build --product RaceStudio

BIN="$(swift build --product RaceStudio --show-bin-path)/RaceStudio"
APP=".build/RaceStudio.app"

# Reassemble the bundle from scratch each run so the binary is always current.
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/RaceStudio"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>RaceStudio</string>
    <key>CFBundleDisplayName</key><string>RaceStudio</string>
    <key>CFBundleIdentifier</key><string>com.racestudio.app</string>
    <key>CFBundleExecutable</key><string>RaceStudio</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>CFBundleIconFile</key><string>AppIcon</string>
</dict>
</plist>
PLIST
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Install the app icon (issue 7.4) so it shows in the Dock, Finder, and Launchpad.
mkdir -p "$APP/Contents/Resources"
cp AppIcon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

open "$APP"
echo "Launched $(cd "$(dirname "$APP")" && pwd)/$(basename "$APP")"
