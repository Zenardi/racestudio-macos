# Review: issue 209, speed and RPM as needle dials

## Review of 40f1a21

Scope:
- `OverlayGaugeStyle` and the new `gaugeStyle` and `maxSpeed` options.
- The editor: the `maxSpeed` option, `offersGaugeStyle`, the style-aware `OverlayWidget.editableOptions`
  and `setGaugeStyle`, plus the "Needle gauge" toggle in the shell.
- The shared `Dial`, `DialScale` and `DialLayout`, and the `TachometerWidget` and `SpeedometerWidget`
  drawers.
- The renderer's `drawer(for:)`, the presets' bottom row, the goldens, the handbook and the diagram.

What holds:
- **Saved layouts keep their look.**
  - A widget's options without `gaugeStyle` read as `classic`, and an unknown value reads as classic
    too (tested).
  - `maxSpeed` falls back to 160 km/h and is clamped to 20–400.
  - Only the built-in Kart coaching and Full telemetry ask for needles; Minimal keeps the speed
    digits (tested).
- **Choosing the drawer.**
  - `OverlayWidgetKind.drawer(for:)` returns a dial only for `.rpm` and `.speed` with the needle
    style. Every other kind ignores the style (tested).
  - The style is part of the options' `Equatable` and `Hashable`, so switching it in the editor
    changes the layout and the HUD rebuilds its renderer.
- **The scale.**
  - Steps of 1, 2 or 5 × 10ⁿ with at most ten parts hold across the whole option range:
    1,000–30,000 rpm gives 100–5,000 rpm steps, and 20–400 km/h gives 2–50 in either unit.
  - The 5-digit and 3-digit value templates cover those ranges.
  - A scale with no usable full scale is just zero (tested).
- **The needle.**
  - The fraction is clamped both ways, so it stops at full scale and never goes below zero.
  - Without a value there is no needle and the digits read `—`.
  - Past full scale the digits read the real value (tested for both dials).
- **The red zone.** It runs from the shift light to full scale. It is empty when the shift light
  is at or above full scale, and probed between ticks in the tests.
- **The labels.** Tick labels at 0.68 R in 0.24 × 0.13 R slots clear each other even at eleven
  labels, and clear the digits and the caption (tested for 9,000, 16,000 and 30,000 rpm).
- **Layers.** The face, ticks, labels, caption and red zone are drawn once. Only the needle, the
  hub, the lit shift light and the digits are drawn per frame (tested). The renderer performance
  test passes with both dials in Full telemetry.
- **Presets.**
  - Each dial is 0.18 × 0.32, square at 16:9 and so round. They are level, 0.01 apart, centred
    and anchored to the bottom edge (tested).
  - The aspect tests keep every preset inside the safe area without overlaps in 16:9, 4:3, 1:1
    and 9:16.
  - The G-ball moved into the bottom-left corner the speed box had shared.
- **Goldens.** The six goldens were re-recorded (synthetic data) and looked at. The needles point
  right; at 14,210 rpm the shift light is lit and the needle is in the red zone.

Findings:
- **LOW, kept: at mid-scale the needle passes over the (unlit) shift light.** The light sits under
  the top of the scale; it is lit only near the red zone, where the needle points right.
- **LOW, kept: tick labels and captions are small at 720p.** They are legible from 1080p up and
  scale with the widget's size class.
- **LOW, kept: `DialGauge` has two unreachable fallbacks** (`?? ""` and `?? .zero`, because a scale
  always has a zero label).
- **Note: the shell's toggle was compiled only by CI.** The view change is small: a `Toggle` bound
  through the tested `setGaugeStyle`, and the list now uses `widget.editableOptions`. This Mac's
  Xcode licence is unaccepted, which blocks the Xcode toolchain, and the Command Line Tools have no
  SwiftUI macros. CI's e2e step runs a full `swift build`, app included.

| Check | Result |
|---|---|
| Tests before the change (RED) | Compile failure on the missing API; then the preset cluster tests (not needle, not round, not a cluster) |
| Full suite in parallel / `--no-parallel` | 2448 / 2448 passed |
| RaceStudioCore coverage | 99.37%: drawers, options and presets 100%, `DialGauge` 97.6% |
| SwiftLint | 0 violations (after wrapping one test line) |
| Tooling self-tests (CLT selected) | All pass except `swift_gate_test` (2), which fails the same way on clean `origin/main` |
