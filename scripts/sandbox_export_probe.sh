#!/usr/bin/env bash
#
# sandbox_export_probe.sh -- do the overlay export's file operations work
# inside the App Sandbox? (issue 9.13, ADR 0008)
#
# OverlayVideoExporter writes its MP4 into FileManager's item-replacement
# directory for the destination, checks the free space there, and moves the
# finished file into place (moveItem, or replaceItemAt over an existing file).
# Unit tests run unsandboxed, so this probe builds a tiny app that performs
# exactly those calls, signs it with RaceStudio's sandbox entitlements and a
# self-signed certificate (scripts/self_sign.sh -- as release builds are), and
# launches it with `open` so the sandbox applies.
#
# A save panel grants the one file the user chose, which a script cannot
# click. The probe stands in for it with temporary-exception grants -- to the
# destination file alone (the save panel's shape) and to its whole folder --
# on the boot volume and on a freshly mounted disk image (an external volume).
#
# It touches nothing in the repo: everything lives in a temp directory and the
# disk image is detached at the end. macOS keeps the probe's (empty) sandbox
# container, ~/Library/Containers/com.racestudio.export-probe, and protects it
# from Terminal; a fixed bundle id makes every run reuse that one.
#
# Usage: bash scripts/sandbox_export_probe.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENTITLEMENTS="$ROOT/app/Sources/RaceStudio/RaceStudio.entitlements"
WORK="$(cd "$(mktemp -d)" && pwd -P)"
ID="com.racestudio.export-probe"
VOLUME="/Volumes/RSExportProbe-$$"
APP="$WORK/ExportProbe.app"

cleanup() {
  hdiutil detach "$VOLUME" -quiet >/dev/null 2>&1 || hdiutil detach "$VOLUME" -force -quiet >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

echo "==> external volume: a 32 MB APFS disk image at $VOLUME"
hdiutil create -quiet -size 32m -fs APFS -volname RSExportProbe "$WORK/probe.dmg"
hdiutil attach -quiet -nobrowse -mountpoint "$VOLUME" "$WORK/probe.dmg"

# One destination per case: <volume>/<case>/export.mp4. "folder" cases grant
# the folder; "file" cases grant only the file (the save panel's shape).
BOOT="$WORK/boot"
mkdir -p "$BOOT/folder" "$BOOT/file" "$VOLUME/folder" "$VOLUME/file"
# Written by the probe into its granted folder: Terminal may not read the
# probe's own container.
RESULTS="$BOOT/folder/probe-results.txt"
GRANTS=("$BOOT/folder/" "$BOOT/file/export.mp4" "$VOLUME/folder/" "$VOLUME/file/export.mp4")

echo "==> probe app ($ID)"
mkdir -p "$APP/Contents/MacOS"
cat > "$WORK/main.swift" <<'SWIFT'
import Foundation

// The exporter's file operations, as OverlayVideoExporter performs them.
var report: [String] = []
func note(_ line: String) { report.append(line) }

func probe(_ label: String, destination: URL) {
    let fm = FileManager.default
    for (form, anchor) in [("folder", destination.deletingLastPathComponent()), ("file", destination)] {
        let step = "\(label) appropriateFor=\(form)"
        let scratch: URL
        do {
            scratch = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: anchor,
                                 create: true)
        } catch {
            note("\(step): replacementDirectory FAIL \((error as NSError).code) \(error.localizedDescription)")
            continue
        }
        note("\(step): replacementDirectory ok \(scratch.path)")
        defer { try? fm.removeItem(at: scratch) }
        let values = try? scratch.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey,
                                                            .volumeAvailableCapacityKey])
        let important = values?.volumeAvailableCapacityForImportantUsage.map(String.init) ?? "unreadable"
        let plain = values?.volumeAvailableCapacity.map(String.init) ?? "unreadable"
        note("\(step): free space in scratch: for important usage \(important), available \(plain)")
        do {
            try? fm.removeItem(at: destination)
            let first = scratch.appendingPathComponent("first.mp4")
            try Data(repeating: 1, count: 1_000_000).write(to: first)
            try fm.moveItem(at: first, to: destination)
            note("\(step): moveItem to new destination ok")
            let second = scratch.appendingPathComponent("second.mp4")
            try Data(repeating: 2, count: 1_000_000).write(to: second)
            _ = try fm.replaceItemAt(destination, withItemAt: second)
            let replaced = (try? Data(contentsOf: destination))?.first == 2
            note("\(step): replaceItemAt existing destination \(replaced ? "ok" : "WRONG CONTENT")")
        } catch {
            note("\(step): place FAIL \((error as NSError).code) \(error.localizedDescription)")
        }
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
for path in arguments.dropFirst() {
    probe(path, destination: URL(fileURLWithPath: path))
}
let sandboxed = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
note("sandboxed: \(sandboxed) (home \(NSHomeDirectory()))")
if let results = arguments.first {
    try? report.joined(separator: "\n").write(toFile: results, atomically: false, encoding: .utf8)
}
SWIFT
swiftc -O -o "$APP/Contents/MacOS/ExportProbe" "$WORK/main.swift"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$ID</string>
  <key>CFBundleExecutable</key><string>ExportProbe</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST

# RaceStudio's entitlements plus the stand-in grants.
cp "$ENTITLEMENTS" "$WORK/probe.entitlements"
/usr/libexec/PlistBuddy -c "Add :com.apple.security.temporary-exception.files.absolute-path.read-write array" \
  "$WORK/probe.entitlements"
for grant in "${GRANTS[@]}"; do
  /usr/libexec/PlistBuddy -c "Add :com.apple.security.temporary-exception.files.absolute-path.read-write: string $grant" \
    "$WORK/probe.entitlements"
done
bash "$ROOT/scripts/self_sign.sh" "$APP" "$WORK/probe.entitlements" "RaceStudio Export Probe" >/dev/null

echo "==> running sandboxed"
open -W "$APP" --args "$RESULTS" "$BOOT/folder/export.mp4" "$BOOT/file/export.mp4" \
  "$VOLUME/folder/export.mp4" "$VOLUME/file/export.mp4"
if [ -f "$RESULTS" ]; then
  sed -e "s|$WORK|<tmp>|g" -e "s|$VOLUME|<external>|g" "$RESULTS"
else
  echo "FAIL: the probe wrote no results ($RESULTS)"
  exit 1
fi
