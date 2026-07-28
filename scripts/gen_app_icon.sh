#!/usr/bin/env bash
#
# Regenerates the RaceStudio macOS app icon (issue 7.4) from source: renders each
# required size with scripts/gen_app_icon.swift, writes the AppIcon.appiconset
# (the committed asset catalog), and packs an AppIcon.icns for the .app bundle.
#
# Deterministic and dependency-free (Swift + sips/iconutil ship with macOS), so
# `make run` can rebuild the icon if it is ever missing. Run: bash scripts/gen_app_icon.sh
set -euo pipefail

cd "$(dirname "$0")/.."
GEN="scripts/gen_app_icon.swift"
APPICONSET="app/AppIcon/Assets.xcassets/AppIcon.appiconset"
ICNS="app/AppIcon/AppIcon.icns"

mkdir -p "$APPICONSET"
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"

# name<space>pixels — the macOS AppIcon slot set (16–512 pt @1x/@2x).
SLOTS="
icon_16x16 16
icon_16x16@2x 32
icon_32x32 32
icon_32x32@2x 64
icon_128x128 128
icon_128x128@2x 256
icon_256x256 256
icon_256x256@2x 512
icon_512x512 512
icon_512x512@2x 1024
"

while read -r name pixels; do
  [ -z "$name" ] && continue
  swift "$GEN" "$pixels" "$ICONSET/$name.png"
  cp "$ICONSET/$name.png" "$APPICONSET/$name.png"
done <<< "$SLOTS"

# The asset-catalog manifest (Xcode format) listing every slot.
cat > "$APPICONSET/Contents.json" <<'JSON'
{
  "images" : [
    { "idiom" : "mac", "size" : "16x16", "scale" : "1x", "filename" : "icon_16x16.png" },
    { "idiom" : "mac", "size" : "16x16", "scale" : "2x", "filename" : "icon_16x16@2x.png" },
    { "idiom" : "mac", "size" : "32x32", "scale" : "1x", "filename" : "icon_32x32.png" },
    { "idiom" : "mac", "size" : "32x32", "scale" : "2x", "filename" : "icon_32x32@2x.png" },
    { "idiom" : "mac", "size" : "128x128", "scale" : "1x", "filename" : "icon_128x128.png" },
    { "idiom" : "mac", "size" : "128x128", "scale" : "2x", "filename" : "icon_128x128@2x.png" },
    { "idiom" : "mac", "size" : "256x256", "scale" : "1x", "filename" : "icon_256x256.png" },
    { "idiom" : "mac", "size" : "256x256", "scale" : "2x", "filename" : "icon_256x256@2x.png" },
    { "idiom" : "mac", "size" : "512x512", "scale" : "1x", "filename" : "icon_512x512.png" },
    { "idiom" : "mac", "size" : "512x512", "scale" : "2x", "filename" : "icon_512x512@2x.png" }
  ],
  "info" : { "version" : 1, "author" : "racestudio" }
}
JSON

# Pack the .icns the bundle actually loads (all sizes → no missing-slot warnings).
iconutil --convert icns "$ICONSET" --output "$ICNS"

echo "app icon regenerated: $ICNS + $APPICONSET (10 slots)"
