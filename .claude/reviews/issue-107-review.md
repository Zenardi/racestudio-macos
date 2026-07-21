# Code Review: issue #107 — [M8] 8.16 Frequency analysis: spectrum panel over `fft_spectrum`

**Reviewed**: 2026-07-20
**Branch**: feature/8.16-frequency-analysis → main
**Mode**: `/ecc:code-review --fix` (independent `ecc:swift-reviewer` pass over the committed change set)
**Decision**: APPROVE (all findings fixed)

## Summary
An RS3 **Frequency Analysis** spectrum panel over the existing `fft_spectrum` FFI
export (damper / vibration analysis). Logic lives in `RaceStudioCore`
(`AnalysisSession.spectrum` through a new `SessionDataSource` seam method +
`Stats/SpectrumModel`); the shell binds (`SpectrumView` + `SpectrumPanel`, a new
`.spectrum` window layout). No Rust changes — `fft_spectrum` already existed. One
HIGH, two MEDIUM, and five LOW findings were raised; all were fixed with tests.

## Findings & resolution

### HIGH — uncached synchronous FFI/FFT recompute on `@MainActor`, driven by unrelated publishes
`SpectrumPanel` computed `SpectrumModel.compute(...)` directly in `body`, so any
`AnalysisWindowModel` publish (a channel-search keystroke, a lap toggle) re-ran the
full `fft_spectrum` (resample + FFT) synchronously across the FFI over the whole
channel — contradicting `AnalysisSession`'s own "pass a bounded window on the hot
path" contract and diverging from `SplitTimesPanel`'s established cache discipline.
**Fixed**: the computation is now cached in `@State` keyed on
`(channel, windowFunction)` and recomputed only in `.onAppear` / `.onChange`, exactly
like `SplitTimesPanel.loadSegments()`.

### MEDIUM — window-function selection lost on every layout switch
The taper was a panel-local `@State`, destroyed when `PanelHost` swapped the active
layout (every sibling knob — `StatsPanelsModel`, `SplitReportModel` — is hoisted to a
window-level `@StateObject` precisely to survive switches).
**Fixed**: added `SpectrumPanelModel` (`@MainActor ObservableObject`, Core) holding the
`windowFunction`, owned by `AnalysisWindowView` and passed into `SpectrumPanel` like
the other panel knobs. Covered by `SpectrumPanelModelTests`.

### MEDIUM — `window` parameter overloaded (taper vs. time range) across the seam
The seam method named the taper `window: SpectrumWindowKind`, colliding with the
`window: TimeWindow` / `window: FfiWindow` (time range) in the very same call
expressions — a real readability trap in a file family that scrupulously names
`SampleWindow`/`TimeWindow`/`FfiWindow` apart.
**Fixed**: renamed the seam parameter (and the `FakeSessionDataSource` fields) to
`windowFunction:`, matching `AnalysisSession.spectrum`'s own naming.

### LOW (all fixed)
- **`isEmpty` vs. the view's 2-point minimum** disagreed on a degenerate 1-point
  spectrum (blank canvas + a peak readout). `SpectrumView` now always draws the grid +
  peak marker and only the area/line needs ≥ 2 points.
- **NaN-unsafe peak** — `max(by:)` seeded on a NaN never updates. `peak` now filters to
  finite amplitudes; covered by `test_peak_ignores_nan_amplitudes` /
  `test_peak_is_nil_when_every_amplitude_is_non_finite`.
- **Misfiled test** — the `ChannelSpectrum.empty` assertion moved from
  `SpectrumWindowKindTests` into its own `ChannelSpectrumTests` suite.
- **Conflated empty-state message** — the panel now distinguishes "needs a decoded
  session" (`analysis == nil`) from "select a channel".
- **Test-coverage gaps** — added the reverse axis-mismatch case and a
  tie-break-determinism test for `peak`.

### Not flagged
No CRITICAL: no force-unwraps / `try!` / `as!`, no secrets, no injection. The
seconds→ms window scaling and the Core↔FFI taper mapping are verified against the live
Rust engine in `FFISessionDataSourceTests` (real `aim_official_test.xrk`). Domain
anchoring (`0...max(x, 1)`) is always a valid `ClosedRange`. `SpectrumModel` is a pure
`Sendable` value type; `SpectrumPanelModel` / `AnalysisSession` are correctly `@MainActor`.

## Validation

| Check | Result |
|---|---|
| swift test (full) | Pass — 773 tests, 85 suites |
| swiftlint --strict (app scope) | Pass — 0 violations |
| RaceStudioCore coverage | Pass — 99.65% (≥ 95%) |
| Rust fmt / clippy / test | Pass (no Rust changes) |
| swift build (app) | Pass |
