# Review: issue #190 — overlay MP4 export engine (per-frame compositor, ranges, progress, cancel, typed errors)

**Reviewed**: 2026-10-06 to 2026-10-07
**Branch**: feature/190-overlay-export-engine → main (rebased onto 4567cd5, after #189 merged)
**Decision**: APPROVE — the third pass found nothing above LOW. Both remaining LOWs are justified below.

## Summary

This change adds `RaceStudioCore/VideoExport/`, the headless engine that writes footage as an MP4
with the telemetry overlay burned into every frame:

- **Planning.** `ExportPlan.make` is pure: it maps the range through the sync, snaps it to
  frames, sizes the output and estimates the file.
- **Compositing.** `OverlayCompositor` is an `AVVideoCompositing`; Core Image on Metal does the
  blend.
- **Encoding.** `ExportPipeline` uses `AVAssetReader` → `AVAssetWriter`. ADR 0008 records why
  this beat `AVAssetExportSession`.
- **Exporting.** `OverlayVideoExporter` is an actor with progress, cancel, typed errors and
  atomic placement.
- **Sandbox.** The entitlement moves to user-selected read-write.

All test media is synthetic and generated at test time. Real-footage and 4K benchmark checks are
local and env-gated.

## Found while building (before review)

- **Synthetic NTSC footage was mistimed by the writer's 600 timescale.** The test factory now
  writes 30000, as cameras do; the engine got the same fix in M2.
- **Untagged SD-sized test footage was read as BT.601.** It was colour-converted into the
  Rec. 709 composition, by up to ±12 levels. Cameras tag Rec. 709, so the factory now does too.
  The engine always outputs Rec. 709 SDR and lets AVFoundation convert other inputs, HDR
  included.
- **The test factory deadlocked AVAssetWriter.** It held video back for the encoder's
  look-ahead and never marked an exhausted input finished. Fixed in the factory.
- **Exporter hardening.**
  - A cancel issued right after `export()`, before its job had registered, was missed. Exports
    are now numbered, and `cancel()` covers every number issued so far.
  - The free space was read in the destination's folder, which a sandboxed app may not read.
    It is now read in the scratch directory, and an unreadable figure does not block.

## First pass (independent `swift-reviewer`, origin/main..57f3a16)

No CRITICAL or HIGH. Every fix below was test-first: each test was seen RED, then GREEN.

### MEDIUM

1. **The free-space rule ignored the fast-start copy.**
   - `shouldOptimizeForNetworkUse` rewrites the finished file into a second copy, so the disk
     peak is about twice the file.
   - **Fixed**: `requiredBytes = 2 × (estimate + 10%)`. Fast start stays: the issue asked for
     it, and it lets shared files play before they download.
   - ADR 0008, `docs/RELEASE.md` and the API docs explain the rule. #191's text does not cite
     the old rule; its message reads `required`.
2. **NTSC output was written in the default 600 timescale, so frame times jittered by up to
   1 ms.**
   - **Fixed**: the video track and the movie use the smallest multiple of the rate's numerator
     that is ≥ 600 (`ExportEncoding.timescale(for:)`).
   - The NTSC export test now asserts every frame at exactly `k·1001/30000`.
3. **Nothing stopped an export onto the footage itself.**
   - **Fixed**: a new `OverlayExportError.destinationIsSource`, checked before anything is
     written.
   - The check compares the path (symlinks resolved, `.`/`..` removed) and, when the
     destination exists, its file resource identifier.
   - Tests cover a respelled path, a symlink and a hard link.

### LOW

4. **Progress hit 1.0 before the file was finished, and a cancel during finishing was ignored.**
   - **Fixed**: `ExportProgress.phase` (encoding / finishing / complete). Finishing is the last
     step, so 1.0 means the file is in place.
   - A cancel while finishing now cancels the writer, and an existing destination is untouched.
     Both are tested through an internal `willFinish` seam.
5. **The file operations had not been checked in the sandbox.**
   - **Done**: `scripts/sandbox_export_probe.sh` runs a sandboxed, self-signed probe app (RaceStudio
     entitlements) on macOS 27.0.1. On the boot volume and on a mounted APFS image, with a
     file-only or a folder grant, the item-replacement directory, `moveItem` and `replaceItemAt`
     all work.
   - **The probe found a bug.** Off the startup disk, `volumeAvailableCapacityForImportantUsage`
     is 0, so every export to an external drive would have been refused.
   - **Fixed**: `VolumeDiskSpace` falls back to `volumeAvailableCapacity`. A test mounts a disk
     image and fails without the fix; an end-to-end export onto it succeeds.
   - A real save-panel grant is left to #191's manual check, as ADR 0008 states.
6. **Test gaps.**
   - All four rotations are tested in the composer, plus a rotated export end to end. Swapping
     one orientation fails both tests.
   - An existing destination survives a mid-encode cancel.
   - The production scratch-directory failure is covered.
7. **CI fragility.**
   - The encoded-bar tolerance is now 2 px; a one-frame error still moves the bar 3 px.
   - HEVC is offered only where a compression session actually opens (`canEncode` seam). A VM
     that lists an encoder it cannot use rejects HEVC up front, and the HEVC test is skipped.
   - The throughput ceiling's looseness is explained in the test.
8. **Small fixes.**
   - Disk-full now reports the free space as unknown (`available: nil`) rather than 0.
   - The dead `OverlayRenderContext.outputSize` is gone.
   - The exporter prefetches lap deltas before the first frame. A test proves no delta is
     fetched on the compositor's queue; it failed before. `TelemetryTimeline` and
     `ExportOverlay` document this.

## Second pass (same reviewer, origin/main..815c3d1)

The first-pass fixes were confirmed. New findings:

- **MEDIUM — a cancel could queue `cancelWriting` ahead of `finishWriting`, on another thread.**
  This could happen between `run()` marking the pipeline as finishing and its call to finish.
  - **Fixed**: finishing starts on the pipeline's queue, and the cancel's `cancelWriting` is
    queued there too, only while the writer is still writing.
- **LOW — the in-flight cancel test used a 2 ms timer.** It could pass without the writer ever
  being cancelled.
  - **Fixed**: a `didStartFinishing` seam cancels at that exact moment, on busier footage. The
    test asserts the writer ends `.cancelled`. It ran 20× with no hang and no flake.
- **LOW — `ExternalVolume` failed instead of skipping where `hdiutil` cannot mount.**
  - **Fixed**: `ExternalVolume.canMount` gates the tests with a reason, and a failed attach no
    longer leaks its directory.
- **Observation, deliberately not enforced — nothing checks that `plan.frameCount` frames were
  written.**
  - A variable-frame-rate phone clip legitimately writes a different count from nominal
    fps × duration, so a tolerance check would reject real footage.
  - A reader that stops on a failure already throws.

## Third pass

Same reviewer, on 6aaf316: **nothing above LOW.**

- **Queue ordering is sound.** A cancel either stops the finish before it starts or reaches a
  writer that was already told to finish.
- **`done` is resumed exactly once on every path.**
- **The `canMount` gate and the unenforced frame count are both accepted.**

Two optional LOWs, both **justified, not changed**:

- **No timeout on `finishWriting`'s completion handler.**
  - AVFoundation documents that the handler also runs after `cancelWriting`, with the status
    `.cancelled`, and the in-flight cancel test passed 20 times out of 20.
  - A timeout would turn a long but healthy fast-start pass into a false failure. That pass
    rewrites the whole file, so it takes seconds for a multi-GB 4K export.
- **A residual window in `test_a_cancel_while_finishing_cancels_the_writer`.**
  - If `finishWriting` completed before the queued cancel ran, the status would read
    `.completed`. The queued cancel runs microseconds after the finish starts, while the
    fast-start pass on 8 Mb/s noise footage takes milliseconds.
  - The strict `.cancelled` assertion stays, because it is what proves the in-flight path
    reaches the writer. The contract, that `run()` throws `cancelled`, holds either way.

## Validation

| Check | Result |
| --- | --- |
| swiftlint (`--strict`) | Pass: 0 violations |
| Swift tests (CLT route, full suite) | Pass: 2250 tests; the opt-in benchmark and real-footage suites are skipped |
| Shell compile (`swift build --product RaceStudio`) | Pass |
| `tests/release_test.sh` | Pass: 36/36 (locally with `SDKROOT` = 26.5; the macOS 27 SDK's `.tbd` breaks the local linker for the universal C stub, CI unaffected) |
| `scripts/e2e.sh` | Pass |
| Coverage (`RaceStudioCore`, llvm-cov) | 99.39% lines; VideoExport files 92.1–100% |
| 4K benchmark (local, release) | 600 s in 73.5 s (0.12× real time), 0.40 GB peak, estimate −0.9% |
| Real footage (local, env-gated) | 1080p29.97, 10,082 frames in 28.6 s (0.09× real time), estimate −1.1% |

## Files reviewed

`app/Sources/RaceStudioCore/VideoExport/*` (added), `Telemetry/TelemetryTimeline.swift` (doc),
`app/Sources/RaceStudio/RaceStudio.entitlements`, `app/Package.swift` (FFI test exclude),
`app/.swiftlint.yml` (one SDK-mandated identifier), the new tests and support files,
`tests/release_test.sh`, `scripts/sandbox_export_probe.sh`, `docs/adr/0008-overlay-video-export.md`,
`docs/RELEASE.md`, `README.md`.
