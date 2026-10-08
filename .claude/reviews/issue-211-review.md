# Review: issue 211, F1-style sector splits

## Review of 3b5b358

Scope:
- `LapClockReading.sectorBestsSoFar` and how `LapClock` builds it.
- `SectorSplit` and `SectorPace`: done, running or upcoming, and the gap.
- `OverlayTheme.sectorBest` and `sectorSlower`, and the palette's new colours.
- The `SectorTimesWidget` rewrite: the bar, name, time and gap in each row, and a plate that fits the
  session's sectors.
- `drawPlate(in:over:)`, the presets, the goldens, the handbook and the diagram.

What holds:
- **Best so far never looks ahead.**
  - Each lap entry takes the per-split bests as they stood before that lap. The bests are built in
    session order, the same way as `bestSoFar`, so a sector finished on the current lap only counts from
    the next lap on (tested at 157.9 s).
  - The out-lap, the in-lap, laps without a valid duration and empty sectors never set a best (tested).
  - The bests are computed once in `LapClock.init`. A read only copies the dictionary's reference.
- **The colour always agrees with the text.**
  - The gap is taken on whole milliseconds, so a gap that reads `0.000` is purple and `+0.001` is yellow
    (tested at 15.5004 against 15.4996).
  - The worst gap is under 600 s (a sector up to 9:59.999 minus a best above 0), so it fits the
    `+888.888` template.
- **Neutral when there's nothing to compare against.**
  - The first flying lap, the out-lap and the in-lap show the time with no gap and no colour. The bar
    is grey.
  - This is the choice the issue asked to record. Colour is never the only signal.
- **The clock and the widget use the same splits.**
  - The live HUD caches its renderer on `telemetryRevision`. A split re-cut reloads the telemetry, and
    the clock's bests and the renderer's `sectors` then change together.
  - The export uses `telemetry(sampling:)`, which requires `loaded.sectors == review.timeline`. So split
    ids are never compared across two layouts.
- **Layout.**
  - Rows keep one size, so the eight-sector box doesn't blow three sectors up to three times the size
    (tested).
  - The plate covers the rows in use and nothing below them (tested).
  - With eight sectors, the rows stay inside the plate without overlapping. The text is at least 16 px
    tall at 1080p, and every template fits its slot (tested).
- **Presets.**
  - In Kart coaching the splits sit right under the kart badge, and in Full telemetry under session
    info. Both are in the badge's column and the same size (tested). The temperatures moved up under lap
    info.
  - The aspect tests keep every preset inside the safe area with no overlaps in 16:9, 4:3, 1:1 and 9:16.
- **Contrast.** Purple `#B388FF` measures 7.1:1 on the solid plate and 5.1:1 on the translucent plate
  over white. Yellow `#FFD60A` measures 13.4:1 and 9.7:1. Both new roles are in the WCAG AA proof through
  `TextRole.allCases`.
- **Goldens.** The six goldens were re-recorded (synthetic data) and checked by eye:
  - mid-lap, S1 purple at −0.268 and S2 running in the accent colour;
  - at lap start, S1 running from 0.400;
  - in the channel gap, a single dash on the plate.

Findings:
- **MEDIUM, fixed: the bar's corner radius could exceed half its height.**
  - The radius was `bar.width / 2`, with a minimum width of 2 px. At the smallest widget size, a 720p
    export gives rows 2 px tall, and the small HUD preview gives rows 0 px tall.
  - The SDK header states no precondition, and this Mac's CoreGraphics (macOS 26) didn't trap: the new
    `test_a_tiny_widget_draws` passed before the fix as well. Older CoreGraphics asserted on such radii,
    and CI runs macOS 15.
  - The bar now rounds by half its shorter side and skips an empty rect. The test stays as the guard,
    at five heights in a 720p output.
- **LOW, fixed:** the type's doc comment said a row is "an eighth of the widget's height". It is
  1/8.8, with the padding taken off.
- **LOW, kept: a renamed split wider than `S88` can run into the time column.** The name template is
  the one the widget had before, and default names are S1–S8.
- **LOW, kept: older saved layouts get smaller rows.**
  - A layout saved with the old top-right sector box (0.18 × 0.16) now draws rows sized for eight
    sectors in that box: about 19 px at 1080p, against about 46 px before.
  - Saved layouts keep their widgets by design, as the handbook says. Choosing the preset again gives
    the new box.
- **Note: the session-wide "no sectors" case behaves as today.**
  - The widget is left out with *No sectors in this session*.
  - A lap the splits don't divide shows a single `—`.
  - The handbook explains how to add splits in the Split Times report.

| Check | Result |
|---|---|
| Tests before the change (RED) | Compile failure on the missing API (`sectorBestsSoFar`, `SectorSplit`, the theme tokens, `Layout.rows`, `plate` and `styles`) |
| Full suite in parallel / `--no-parallel` | 2474 / 2474 passed |
| RaceStudioCore coverage | 99.37%; `SectorSplit`, `LapClock`, `SectorTimesWidget`, `OverlayTheme` and `OverlayPresets` at 100% |
| SwiftLint | 0 violations |
| Tooling self-tests (CLT selected) | All pass except `swift_gate_test` (2), which fails the same way on clean `origin/main` |
| Legal gate | No device-area changes |
