# ADR 0008 — Overlay MP4 export: a custom compositor behind an asset reader and writer

- **Status:** Accepted
- **Date:** 2026-10-06
- **Milestone:** M7 (issue 9.13, #190; epic #145). Builds on the sync (`VideoSyncModel`,
  #185/#192), the telemetry sampler (`TelemetryTimeline`, #186), the overlay layout (#187) and the
  overlay renderer (`OverlayRenderer`, #188). Consumed by the export UI (#191).

## Context

The epic's second feature exports the session's footage as an MP4 with the telemetry overlay
burned in. The real input is an action camera's file:

- 3840×2160 H.264 at 29.97 fps, about 56 Mb/s;
- 600 s per file, about 4.2 GB;
- AAC sound.

The engine has to:

- export a range (whole footage, the session, laps, a custom span) frame-exactly, with the
  overlay of **each frame's own session time**;
- offer Source/2160p/1080p/720p, H.264 or HEVC, and keep or drop the sound;
- report progress, cancel within about a second, and never leave a partial file;
- stream with bounded memory and use the hardware encoder;
- give an estimate the export sheet can show (#191 wants it within ±15% of the real size) and
  check the free disk space against before writing.

Two AVFoundation designs can host a per-frame overlay. Both use the same
`AVMutableVideoComposition` with a **custom `AVVideoCompositing`** (`OverlayCompositor`); they
differ in what drives it and encodes its frames:

1. **`AVAssetExportSession`**, configured with a preset (`AVAssetExportPreset1920x1080`,
   `AVAssetExportPresetHEVC1920x1080`, …), the video composition and `outputFileType = .mp4`.
2. **`AVAssetReader` → `AVAssetWriter`**: an `AVAssetReaderVideoCompositionOutput` pulls each
   frame through the compositor, and an `AVAssetWriterInput` encodes it with explicit settings.

The issue made (1) the primary approach and (2) the fallback, "only if bitrate/codec control
proves insufficient". So we measured both before building either.

## Measurements

The spike ran on Apple silicon (the development Mac, macOS 26). The source was synthetic 4K
29.97 fps H.264 at 56 Mb/s. Its content was moving noise, so the encoder has to work, as it does
on real onboard footage. Each path exported it to 1080p, with the same compositor: a Lanczos
downscale plus an overlay bar blended with Core Image.

| Path | Clip | Wall time | × real time | Video bit rate | Peak footprint |
| --- | --- | --- | --- | --- | --- |
| Export Session, `1920x1080` preset (H.264) | 60 s | 7.6 s | 0.13× | **10.61 Mb/s** (preset's choice) | 320 MB (both presets, one process) |
| Export Session, `HEVC1920x1080` preset | 60 s | 7.4 s | 0.12× | **8.81 Mb/s** (preset's choice) | |
| Reader/Writer, H.264 at 12 Mb/s | 60 s | 7.6 s | 0.13× | **12.09 Mb/s** (asked 12) | 384 MB (both codecs, one process) |
| Reader/Writer, HEVC at 7 Mb/s | 60 s | 7.3 s | 0.12× | **7.07 Mb/s** (asked 7) | |

On a 20 s clip the results were the same: 10.76 and 8.94 Mb/s from the presets, 12.16 and
7.20 Mb/s for the 12 and 7 Mb/s asked of the writer.

The two paths are equally fast and both stream: the compositor and VideoToolbox are the work,
not the driver. They differ in control:

- **Bit rate:** an export session's preset picks the bit rate, and nothing sets it. It depends on
  the preset and the content, and is undocumented. The writer hit the requested average within
  1–3%.
- **The estimate:** without a known bit rate there is no honest size estimate. The ±15% target
  of #191 and the disk-space pre-check ("estimate + 10%") both depend on it.
- **Codec details:** the writer takes the profile (H.264 High, HEVC Main), the keyframe interval
  (2 s), the Rec. 709 colour tags and the encoder specification (hardware preferred, software
  fallback). A preset fixes all of these.
- **API direction:** the session's polling API (`exportAsynchronously`, `status`, `progress`,
  `error`) is deprecated as of macOS 15. Its replacement (`export(to:as:)` with
  `states(updateInterval:)`) is macOS 15+, and the app supports macOS 13. Neither warns at the
  macOS 13 deployment target, but the path ages badly.

## Decision

**Use the reader/writer path: the issue's fallback.** The bit-rate control the issue named as
the trigger proved insufficient in the export session, and nothing else favours the session. The
custom compositor stays exactly as planned.

`RaceStudioCore/VideoExport/`:

- **`ExportPlan.make`** (pure): maps the range through the sync onto the footage, clamps it, and
  snaps it to whole frames as an exact rational `CMTimeRange`.
  - It sizes the output by its short edge per preset: aspect kept, even dimensions, never upscaled.
  - It rejects unsupported codecs and sizes up front, using VideoToolbox's encoder list for HEVC.
  - It sets the bit rate as bits per pixel per frame: **0.2 for H.264**, about 12 Mb/s at 1080p30,
    and **0.12 for HEVC**, about 7.5 Mb/s.
- **`OverlayComposition`**: cuts the planned range into an `AVMutableComposition` that starts at
  zero. The sound is kept when planned.
  - It renders through `OverlayCompositor` at the output size.
  - It takes its frame timing from the footage track (`sourceTrackIDForFrameTiming`), so
    composition frame `j` is footage frame `first + j`.
  - It renders in **Rec. 709 SDR**. Camera footage, which is Rec. 709, passes through unconverted.
    AVFoundation converts anything else (BT.601, HDR) before the compositor sees it.
- **`OverlayCompositor`** (`AVVideoCompositing`) takes the export's `OverlayRenderContext` from
  its instruction. For each frame it:
  1. maps the frame's composition time through the sync to session time;
  2. samples the telemetry with a forward `SamplingCursor`;
  3. draws the overlay at the output size into one reused IOSurface buffer, through
     `OverlayRenderer`, prepared once per size;
  4. turns and scales the source frame, and blends the overlay over it, with a **Metal-backed
     `CIContext`** with colour management off.

  Frames are composed in order on a serial queue. The renderer serializes all overlay drawing
  process-wide anyway (#188), so nothing is lost.
- **`ExportPipeline`**: the reader pulls the composed frames and the decoded sound, and the writer
  encodes them.
  - The encoding is H.264 High or HEVC Main (`hvc1`) at the plan's average bit rate, a 2 s GOP,
    Rec. 709 tags, `EnableHardwareAcceleratedVideoEncoder` and AAC.
  - The pull loop runs on its own queue. It serves whichever writer input is ready, which lets the
    writer interleave the tracks, and naps 1 ms when neither is. Memory is therefore bounded by
    the writer's queues.
  - It sees a cancel within a frame.
- **`OverlayVideoExporter`** (an actor) checks the free space where it writes against the
  estimate + 10%, and reports progress as an `AsyncThrowingStream<ExportProgress, Error>` every
  250 ms.
  - It writes into the **item replacement directory** of the destination's volume. That is the
    sandbox's sanctioned safe-save location; the app's user-selected grant is now read-write.
  - It moves the finished file into place in one step with `replaceItemAt`, so an existing file
    is only ever replaced by a complete export. The scratch directory is removed however the
    export ends.
  - Every failure is a typed `OverlayExportError`.

## Benchmark: 10 minutes of 4K29.97 to 1080p H.264

`OverlayExportBenchmark` (opt-in with `RACESTUDIO_EXPORT_BENCH`, release build, two processes so
the peak is the export's own) exports 17,982 frames of synthetic 4K 29.97 fps noise at 56 Mb/s
(4.2 GB) to 1080p H.264. It uses the **Full telemetry** overlay (every widget) and the synthetic
telemetry fixture.

Results on the development Mac (Apple silicon, macOS 26, release build):

| Measure | Result | Budget |
| --- | --- | --- |
| Export wall time (17,982 frames, 600 s of footage) | **73.5 s — 0.12× real time** | ≤ 600 s (1×) |
| Peak memory footprint (export process) | **0.40 GB** | ≤ 1.5 GB |
| Output size vs the plan's estimate | **937 MB vs 946 MB (−0.9%)** | ±15% (#191) |
| Writing the synthetic source itself (not part of the export) | 187 s, 4.23 GB | — |

`ffprobe` on the output confirms what the engine wrote:

- H.264 High (`avc1`), 1920×1080, Rec. 709 colour tags;
- 30000/1001 fps, exactly 17,982 frames, 600.000 s;
- 12.44 Mb/s, the planned rate to within 1 kb/s;
- AAC LC sound of the same length;
- `moov` ahead of `mdat`, so the file starts playing before it has fully downloaded.

The budget is ≤ 1× real time (600 s) and ≤ 1.5 GB peak. CI runs a three-second export against a
generous ceiling instead (`OverlayExportThroughputTests`), and does not wait ten minutes.

## Consequences

- The plan's estimate is the encoder's own target, so the size shown before an export is what it
  writes, give or take the encoder's rate control. It falls below on easy content, where the
  encoder undershoots, and the estimate is then an upper bound.
- The engine owns the pull loop the export session would have hidden: back-pressure,
  interleaving, cancel and teardown on failure. All of it is covered by tests on synthetic media
  generated at test time (`TestMediaFactory`).
- HEVC needs an HEVC encoder. `EncoderAvailability.system` asks VideoToolbox, and the plan
  rejects HEVC up front where there is none. The HEVC test is skipped there with that reason.
- The output is always 8-bit Rec. 709 SDR. HDR footage is tone-mapped by AVFoundation. An HDR
  export would be a later issue.
- Several laps export as one continuous span. Stitching, 9:16 reframing and uploads are out of
  scope.

## References

- Issue 9.13 ([#190](https://github.com/Zenardi/racestudio-macos/issues/190)), the export UI
  ([#191](https://github.com/Zenardi/racestudio-macos/issues/191)), epic
  [#145](https://github.com/Zenardi/racestudio-macos/issues/145).
- `app/Sources/RaceStudioCore/VideoExport/`; tests `ExportPlanTests`, `FootageProbeTests`,
  `OverlayFrameComposerTests`, `OverlayCompositorTests`, `OverlayVideoExporterTests`,
  `OverlayVideoExporterFailureTests`, `OverlayExportErrorMappingTests`,
  `OverlayExportBenchmark`.
- Apple: *AVAssetReaderVideoCompositionOutput*, *AVVideoCompositing*,
  *FileManager.url(for:in:appropriateFor:create:)* (`.itemReplacementDirectory`).
