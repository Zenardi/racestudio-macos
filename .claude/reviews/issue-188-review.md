# Review: issue #188 — video overlay renderer (CoreGraphics HUD shared by preview and export)

**Reviewed**: 2026-10-06
**Branch**: feature/188-overlay-renderer → main
**Decision**: APPROVE (third pass clean after two LOW test-hygiene fixes — see below)

## Summary

`RaceStudioCore/VideoOverlay/Render/` adds a deterministic CoreGraphics and
CoreText renderer: `(OverlayLayout, TelemetryFrame, size)` becomes premultiplied
BGRA sRGB pixels, transparent outside the widgets. The live HUD (#189) and the
MP4 export (#190) will both draw through it.

- **Renderer and cache.** `OverlayRenderer` draws `layout.drawable(for:session:)`
  back to front. A lock-protected `StaticLayerCache` renders plates, guides,
  labels and the track map's line once per output size.
- **Drawers.** One drawer per widget kind, behind `OverlayWidgetDrawer` (layout,
  static, readouts, dynamic).
- **Text.** `OverlayTextStyle` uses DIN Condensed (tabular digits), draws glyph
  outlines from whole-pixel origins, and adds a dark legibility outline.
- **Formatter.** `OverlayFormatter` takes an injected export locale (`.` / `,`)
  and writes `—` for every missing value.
- **Shared lap-time rule.** `LapTimeFormatter` now also owns the sector form, and
  the review grid uses it, so the shell keeps no copy.
- **Named channels.** `TelemetryFrame` and `TelemetryTimeline` sample extra
  session channels by name, additively.
- **Tests and CI.** Golden snapshots, structural pixel tests and performance
  tests are added, and CI uploads the renders.

## Found while building (before review)

- **CoreGraphics data race (macOS 26).** A wide *translucent* plate fill,
  rasterised while another thread drew translucent fills (G-trail dots), took
  the other fill's colour in its last 3 columns. The static layer was 231 px
  wide (231 mod 4 = 3). Reproduced in 2–9 of 72 concurrent renders. Ruled out:
  row alignment and global alpha. Gone with a `.copy` plate fill, which gives
  identical pixels on an empty layer, and with opaque plates.
  **Fixed**: the plates are copied. After the review the renderer also
  serialises drawing process-wide (see first pass, #4). A threaded regression
  test failed before these fixes.
- **Named-channel collisions were non-deterministic.** Two names matching
  alike resolved through `Dictionary(uniquingKeysWith:)`, so the winner followed
  the per-process dictionary order (a flaky RED proved it).
  **Fixed**: resolved in sorted-name order.
- **A running sector at exactly its start read `—`.** **Fixed**: it reads
  `0.000`.

## First pass — findings and resolution

Self-review plus an independent `swift-reviewer` agent over `git diff
origin/main...HEAD` (0ef523e). Each fix below was test-first. The tests
were confirmed RED against 0ef523e: assertion failures, or a process trap
for the huge-size case.

### HIGH

1. **Pedals assumed a 0–100 % scale for every unit.** A brake logged in bar was
   drawn as a percentage. **Fixed**: new `throttleFullScale` and
   `brakeFullScale` options. They default to 100, are validated to
   0.1…10000, decode leniently (older layouts read 100), and are documented in
   the handbook.

### MEDIUM

2. **`OverlayPixelSize` converted a huge finite size to `Int` and trapped.**
   **Fixed**: the range check is done in `Double` first. Tests cover ±1e30 and
   "draw leaves the context untouched".
3. **The golden tolerance (the issue's 2/255 and ≤0.5%) cannot catch one changed
   digit.** **Justified as is**: the tolerance is the spec. The overclaiming
   doc is corrected (harness and fixtures README), because every readout's text
   is asserted exactly by the widget suites.
4. **The `.copy` workaround was partial, and its threaded test was weak.**
   **Fixed**: a process-wide raster lock serialises every overlay draw (a
   frame costs about 1.5 ms). The threaded test now builds 48 fresh renderers
   at once with faded widgets.
5. **Self-review: widget opacity was applied per primitive**, although
   `OverlayWidget.opacity` documents "the whole widget's opacity". **Fixed**:
   a transparency layer is used when opacity < 1. A test checks that the
   digits keep the text colour at α 0.5.

### LOW

6. **Delta bar off by 1 px on odd widths.** **Fixed**: the bar is
   pixel-aligned, the centre sits on a pixel, and each side scales by its own
   span.
7. **Delta `0.004` drew a fill beside the text `0.00`.** **Fixed**: the bar
   fills only when the written delta is signed.
8. **A NaN position drew neither a dot nor `—`, and NaN racing-line points made
   the scale NaN.** **Fixed**: a shared finite check, and `OverlayTrackMap`
   filters the points.
9. **`draw` inherited a shadow or dash from the caller.** **Fixed**: both are
   reset. Documented: the context must be in its default space, and the pixels
   equal `makeImage`'s only on a premultiplied BGRA sRGB context.
10. **Docs.** Named channels are sampled linearly; glyph origins are whole
    pixels per line; a fallback face may differ by OS. **Fixed** (documented).
11. **Weak tests.** **Fixed**:
    - "paints its rect" now uses no plate;
    - the monospaced-digits test asserts that all ten digits share one advance
      (DIN Condensed has no number-spacing feature, so CoreText drops the
      request);
    - byte comparisons strip row padding;
    - buffers are zeroed, padding included.
12. **Performance budget asserted only loosely in debug.** **Justified as is**:
    the generous debug and CI ceilings follow #186. The release budget is
    asserted in optimised builds and reported in the PR.

## Second pass — on the fixes (a9cefd3)

The same reviewer re-read `0ef523e..a9cefd3` and verified each first-pass fix:
- the pixel-size range check;
- group opacity, confirmed with an empirical CoreGraphics probe;
- lock ordering (raster → cache → glyph, never reversed, no re-entrancy);
- delta edges (widths 0 and 1, −0, NaN);
- the track map's finite checks;
- the options' coding and validation;
- the padding-free test bytes.

### CRITICAL / HIGH
None.

### MEDIUM
1. **The pedal default stays 100, and no UI can change it yet**, while the
   handbook told users to set it. **Fixed** (docs): the handbook now says the
   scale is stored per layout but can't be set until the overlay editor
   offers it. **Follow-up** for #189 (the editor), listed in the PR. An
   automatic per-session scale needs the timeline and the session context, so
   it is out of scope here.
2. **The raster lock covers only overlay drawing.** The threaded test read its
   renders back by drawing them again, outside the lock, which is the same
   race pattern. **Fixed**: renders are read from the image's data provider
   (no redraw). The `draw` doc now says what the lock does not cover and that
   footage should be composited with Core Image or Metal, as #190 plans.

### LOW
3. **A NaN pedal full scale gave a NaN rect** (reachable only from
   hand-built options). **Fixed**: it falls back to the default, with a test.
4. **The first draw at a new size builds every static layer while holding
   the draw lock.** **Fixed**: the public `OverlayRenderer.prepare(for:)`
   builds them ahead of the first frame, with two tests.
5. **`allowsAntialiasing` is context state that `draw` cannot reset.**
   **Fixed** (docs): `draw` documents the anti-aliasing default it relies on.

## Third pass — on 83bbc09

No CRITICAL, HIGH or MEDIUM. Both LOW items, about test hygiene, are fixed:
1. The threaded tests compared redraw-based expected bytes with
   data-provider results. **Fixed**: both sides use
   `OverlayBitmap.pixelBytes(of:)`.
2. `CFDataGetBytePtr` was read without keeping the `CFData` alive.
   **Fixed**: `withExtendedLifetime(data)`.

The pass reported the rest of `a9cefd3..83bbc09` clean.

## Found during validation — a hang in the device-panel test fake (7a89ce9)

The full suite hung in about 1 of 12 runs once the overlay tests added CPU
load. `origin/main`, built from a clean export, never hung in 25 runs.

The cause: `FakeDeviceService` reset its `cancelled` flag when a download was
recorded. A test's cancel could land after the model reported `.downloading`
but before the fake recorded the download. That erased the cancel, and the
held download then waited forever. It is an existing test-harness race that
appears only under load.

**Fixed**:
- The fake consumes a cancel.
- `untilDownloading` waits until the fake actually holds the download, with a
  10 s deadline.
- The overlay bitmaps scan in one pass, so they starve other suites less.

25 of 25 full runs then completed.

**Review of the fix** (same reviewer):
- The continuation is resumed exactly once, the retry and close semantics are
  kept, and the scan's pointer arithmetic is correct.
- LOW: a second held download would overwrite the first waiter. **Fixed**:
  a precondition.
- LOW: a cancel that lands between a download's end and `.finished` would
  pre-cancel the next held download. **Justified as is**: no test reaches it,
  and it would time out and record an issue rather than hang.

## Validation

| Check | Result |
|---|---|
| Swift tests (CLT route, debug) | 1961 passed, ×3 consecutive |
| swiftlint --strict | 0 violations |
| Shell (`swift build --product RaceStudio`) | builds |
| Coverage, `RaceStudioCore` lines | 98.10% (new files at 100%, except `OverlayTextStyle` at 98.10%) |
| Release performance | 1080p ≈ 1.45 ms, 4K ≈ 2.65 ms per frame (budget 6 / 12 ms) |
| #186 sampler, release | 18,000 frames in ≈ 4.7 ms (budget 50 ms) |
