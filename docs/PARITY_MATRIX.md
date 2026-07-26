# RaceStudio 3 parity matrix

The systematic audit of AiM RaceStudio 3's analysis feature set against what
RaceStudio-macOS ships today (issue 7.1). Every `Done`/`Partial` row cites the
milestone issue(s) that provide the behaviour — and, where one backs it, the
`racestudio-analysis` primitive — so the mapping is auditable. Every non-`Done`
row links a follow-up gap issue; the prioritized backlog at the bottom is ready
to be opened verbatim. Each follow-up must meet the bar in
[docs/DEFINITION_OF_DONE.md](DEFINITION_OF_DONE.md).

- **RS3 version examined:** 3.83.26 (released 2026-06-11, the current stable
  release at audit time)
- **Evidence source:** AiM's published RaceStudio3 documentation and release
  notes (`aim-sportline.com/docs/racestudio3`) cross-checked against the RS3
  Analysis feature dissection recorded in epic #109 (M8), which screened the
  running RS3 Analysis UI; app-side status verified directly in this
  repository's code and closed issues.
- **Audit date:** 2026-07-26 (time-box ≤ 2 days respected)

**Status legend** — `Done`: shipped and reachable in the app · `Partial`:
core of the feature shipped, named sub-behaviours missing · `Missing`: no
implementation · `Won't-do`: deliberately excluded (the *Gap issue* column
links the issue recording that decision) · `Unknown`: could not be verified in
the time-box (unused — every audited feature was verifiable from the sources
above). This file is structurally validated by
`core/racestudio-analysis/tests/parity_matrix_test.rs`, which enforces the
status set, the gap-issue links, and the backlog ordering.

## Parity matrix

| Feature | RS3 behaviour | This app status | Implementing issue | Gap issue | Priority |
| --- | --- | --- | --- | --- | --- |
| Time/distance line plots | Multi-channel plot vs time or distance, zoom/pan, linked cursor | Done | 4.1, 8.3, 8.12 (resample 3.3, distance axis 3.1, FFI 8.2) | — | — |
| Plot display modes | Overlapped / mixed / tiled / smart layouts, line width, snap-to-sample | Done | 8.12 | — | — |
| Multi-lap overlay | Overlay selected laps of a session on a shared axis | Done | 4.2, 8.7 (lap alignment 3.1) | — | — |
| Delta-t / predictive lap | Time-variance strip vs reference lap, predictive gain/loss readout | Done | 4.2, 8.7 (delta_t 3.2) | — | — |
| GPS track map | Racing line, colour-by-channel, sector markers, cursor sync | Done | 4.3, 8.6 (GPS decode 1.4, GPS FFI 8.2) | — | — |
| Track detection & track database | Auto-recognizes the circuit from GPS against a bundled track DB; sets start/finish and sectors | Missing | — | 9.2 (proposed) | P2 |
| Math channels & expression editor | User-defined channels from a live-validated expression editor | Done | 4.6, 8.8 (expression engine 3.5, FFI 3.8) | — | — |
| Derived channels | Computed heading, lateral/longitudinal g, yaw rate, gear estimate | Done | 3.6, 8.8 (FFI 3.8) | — | — |
| Histogram | Channel distribution with configurable bins, per-lap filter | Done | 4.5, 8.9 (stats 3.4) | — | — |
| XY scatter (G-G diagram) | Channel-vs-channel plot, lateral-vs-longitudinal g | Done | 4.5, 8.9 | — | — |
| FFT / frequency analysis | Windowed single-sided spectrum of a channel | Done | 3.7, 8.16 (spectrum + windows in fft) | — | — |
| Min/max/avg statistics | Whole-channel, windowed and per-lap min/max/mean/std readouts | Done | 3.4, 8.5, 8.10 (channel_stats, stats_per_lap) | — | — |
| Channels report | Per-lap/segment stats table plus stat-vs-lap graph, presets | Done | 8.10 (stats 3.4) | — | — |
| Split / segment times | Per-segment times, best theoretical & best rolling lap, split editing | Done | 8.11 (segment_times in splits, laps 3.1) | — | — |
| Multi-session compare | Load several sessions together and overlay their laps across every panel | Missing | — | 9.1 (proposed) | P1 |
| Gauges & digital displays | Measures bar with digital readouts plus analog-style gauge widgets | Partial | 4.4, 8.5 (readouts shipped; no gauge widgets) | 9.4 (proposed) | P3 |
| Report / export | CSV export/import, printable report (PDF/print), plot image export | Partial | 5.1, 5.2 (CSV both ways), 5.4 (project files; no PDF/print/image export) | 9.3 (proposed) | P2 |
| Video sync | Synchronized video playback tied to the analysis cursor | Missing | — | 9.5 (proposed) | P3 |
| Suspension analysis | Suspension composite views and log sheets | Done | 8.17 | — | — |
| Session library / database | Browsable session database with search, filters, collections, preview | Done | 5.3, 8.14, 8.15 | — | — |
| Workspaces & profiles | Saved layouts/profiles, project files, storyboard switching | Done | 5.4, 8.13 | — | — |
| Device download | Discover the logger, list on-device sessions, download/delete | Done | 6.3, 6.4, 6.5, 6.6, 6.7 | — | — |
| AiM Cloud sync & profile sharing | Cloud account, uploaded sessions, shared profiles | Won't-do | — | #109 | — |
| Weather API integration | 12-month weather history attached to sessions | Won't-do | — | #109 | — |
| DLL / C++ math plugins | Native plugin math channels beyond the expression language | Won't-do | — | #109 | — |
| RS2 .drk import/export | Legacy RaceStudio 2 data format round-trip | Won't-do | — | #109 | — |
| Predictive-lap transmit-to-device | Push predictive reference laps back to the logger | Won't-do | — | #109 | — |

## Analysis-primitive cross-reference

Every `Done` row above ultimately consumes the decode core (M1) through these
`racestudio-analysis` primitives (M3), all exposed to Swift over the FFI (3.8,
8.2):

- `laps` — lap segmentation, distance axis, time/distance alignment (3.1)
- `delta` — delta-t time variance over distance (3.2)
- `resample` — uniform-rate and distance-grid interpolation (3.3)
- `stats` — Welford min/max/mean/std/RMS, windowed and per-lap (3.4)
- `expr` — math-channel lexer/parser/evaluator (3.5)
- `derived` — heading, yaw rate, accelerations, gear estimate (3.6)
- `fft` — windowed single-sided amplitude spectrum (3.7)
- `splits` — per-segment times behind the Split Times report (8.11)

## Gap backlog (prioritized)

Scored user-impact × effort (1 = lowest, 5 = highest); priority buckets rank
high-impact/affordable-effort work first (P1 before P2 before P3). Each row is
a ready-to-open follow-up issue for milestone M9 and must meet
[docs/DEFINITION_OF_DONE.md](DEFINITION_OF_DONE.md).

| Priority | Proposed issue | Area label | Impact | Effort | Scope |
| --- | --- | --- | --- | --- | --- |
| P1 | 9.1 | area:analysis | 5 | 3 | Multi-session compare: open ≥2 sessions in one analysis window and overlay their laps across plot, delta strip, track map and reports |
| P2 | 9.2 | area:analysis | 4 | 3 | Track detection & track database: auto-recognize the circuit from GPS, bundled start/finish + sector definitions per track |
| P2 | 9.3 | area:import-export | 3 | 2 | Report export: printable PDF report of plots and stats tables plus PNG plot-image export |
| P3 | 9.4 | area:ui | 2 | 2 | Gauge widgets: analog-style gauge displays alongside the digital measures bar |
| P3 | 9.5 | area:ui | 3 | 5 | Video sync: import external video, align it to the session cursor, side-by-side playback |
