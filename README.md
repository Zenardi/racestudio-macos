# RaceStudio-macOS

[![CI](https://github.com/Zenardi/racestudio-macos/actions/workflows/ci.yml/badge.svg)](https://github.com/Zenardi/racestudio-macos/actions/workflows/ci.yml)

A native macOS re-implementation of AiM **RaceStudio 3** telemetry analysis —
successor and sibling to [XRKConverter](https://github.com/Zenardi/XRKConverter).

> **Status:** **M0–M5 complete**; **M6 — Device Connectivity (WiFi)** next. The
> logic core (the Rust crates + the Swift `RaceStudioCore` library) stays green,
> warning-free, and ≥95% line-covered, enforced in CI.

| Milestone | Scope | Issues | Status |
| --- | --- | --- | --- |
| **M0 — Foundations, Tooling & TDD Harness** | Scaffold, Rust + Swift **coverage gates**, the **UniFFI xcframework pipeline**, the **golden-fixtures harness** (libxrk oracle JSON + Rust/Swift loaders), the shared DoD/CI/Makefile, and enforceable branch protection. | 0.1–0.7 | ✅ Complete |
| **M1 — Rust Core: XRK Decode** | Clean-room `.xrk` decoder ([ADR 0002](docs/adr/0002-xrk-decode-strategy.md)) — `open_container`, `decode_channels`, `decode_gps`, and `decode_laps` unified behind `decode_session` into an immutable, panic-free `Session`, with a corpus-wide conformance harness gating CI to within [documented tolerances](docs/DECODE_TOLERANCES.md). | 1.1–1.8 | ✅ Complete |
| **M2 — App Shell & File Import** | Document-based SwiftUI shell (App Sandbox, AiM UTIs), the `SessionStore` `idle → loading → loaded / failed` load lifecycle, file import (Open panel / drag-and-drop / security-scoped **Recent Files**), the session summary screen, and async decode with progress + cancellation. | 2.1–2.5 | ✅ Complete |
| **M3 — Analysis Engine** | Lap segmentation & alignment, delta-t, resampling, Welford statistics, a math-channel **expression engine**, derived channels (heading / yaw-rate / accel / gear), and a windowed **FFT** — panic-free with typed errors, exposed to Swift over UniFFI (3.8). | 3.1–3.8 | ✅ Complete |
| **M4 — Analysis UI** | Time/distance line plot, lap overlay + delta-t strip, GPS track map, channel table & digital readouts, histogram / XY-scatter, a live-validated math editor, and a **linked workspace cursor** shared across tiles. | 4.1–4.7 | ✅ Complete |
| **M5 — Import/Export & Session Management** | RaceChrono **AiM-CSV export** (5.1) and **CSV import** (5.2) in Rust `racestudio-io`; the **session library index** — content-id-keyed summaries with search / filter and atomic, crash-safe on-disk persistence (5.3); and versioned, atomic **project / workspace files** (`.rsproj`) with forward migration and FFI-parsed math channels (5.4) — both in `RaceStudioCore`. | 5.1–5.4 ✅ | ✅ Complete |
| **M6 — Device Connectivity (WiFi)** | Direct session import from AiM loggers over WiFi. | 6.x | ⏳ Planned |
| **M7 — Parity, Performance & Release** | Feature parity with RaceStudio 3, performance tuning, and a packaged release. | 7.x | ⏳ Planned |

Per-feature detail lives in **[Architecture](#architecture)**, which documents
each sub-issue's contribution to its crate/target.

## Architecture

The app is a **Rust core** exposed to a **SwiftUI** frontend through **UniFFI**:

```
┌─────────────────────────────────────────────┐
│  SwiftUI frontend (app/)                      │
│                                               │
│   RaceStudio         thin @main shell         │  ← excluded from coverage
│      │  depends on                            │
│   RaceStudioCore     logic library            │  ← 95% Swift coverage target
│      ▲                                         │
│      │  UniFFI (.xcframework, added in 0.4)    │
├──────┴────────────────────────────────────────┤
│  Rust core (core/)                            │
│                                               │
│   racestudio-decode    clean-room .xrk decode │  ← 95% Rust coverage target
│   racestudio-analysis  channels / math        │  ← 95% Rust coverage target
│   racestudio-io        CSV export + import    │  ← 95% Rust coverage target
│   racestudio-ffi       UniFFI boundary        │
└───────────────────────────────────────────────┘
```

- **`racestudio-decode`** — clean-room Rust decoder for AiM `.xrk` files,
  validated against XRKConverter's `libxrk` output as the golden oracle (M1).
  `decode_session(path)` is the primary entry point: it bundles the layered
  decoders (container, channels, GPS, laps) into one immutable `Session`, with a
  single `#[non_exhaustive] DecodeError` and a panic-free decode path. The
  strategy — a clean-room port over wrapping the proprietary-linked `xdrk`
  crate — is recorded in
  [`docs/adr/0002-xrk-decode-strategy.md`](docs/adr/0002-xrk-decode-strategy.md).
- **`racestudio-analysis`** — telemetry analysis engine (M3), built on the
  decoded `Session`. Lap segmentation & alignment (3.1) is the first layer:
  `segment_laps` → per-lap `Lap` views, `distance_axis` (trapezoidal integration
  of GPS speed), and `align_by_time` / `align_by_distance` for two-lap overlay.
  Delta-t (3.2) adds `delta_t(reference, comparison)` — the time-variance-over-
  distance metric. Resampling (3.3) adds `resample_uniform` /
  `to_distance_grid` (linear interpolation onto a uniform-rate or distance grid,
  with a `max_gap` hole policy). Statistics (3.4) add `channel_stats` /
  `stats_over_range` / `stats_per_lap` — Welford-based min/max/mean/std/RMS/range
  over the whole channel, a `[t0, t1)` window, or each lap, ignoring `NaN` holes.
  The math-channel expression engine (3.5, module `expr`) adds `tokenize` →
  `parse` → `eval_scalar` / `eval_series` for user-defined channels, with a typed
  `ExprError` carrying `(line, col)` on any malformed input. Derived channels
  (3.6, module `derived`) add `heading` / `yaw_rate` / `longitudinal_accel_g` /
  `lateral_accel_g` / `gear_estimate`, matching libxrk's computed GPS channels.
  The windowed FFT (3.7, module `fft`) adds `spectrum` / `apply_window` / `Window`
  — a `rustfft`-backed single-sided amplitude spectrum with per-window coherent-
  gain correction. Panic-free, with typed errors throughout.
- **`racestudio-io`** — import/export (M5), built on the decoded `Session`. CSV
  export (5.1) is the first layer: `write_aim_csv(session, w, opts)` reproduces,
  in Rust, the RaceChrono-compatible "AiM CSV File" that XRKConverter's
  `xrk2csv.py` writes — every channel resampled onto a uniform 20 Hz grid
  (reusing `racestudio-analysis`'s resampler), GPS speed / velocity-accuracy
  converted m/s → km/h, latitude/longitude at 8 decimals, a synthesized
  `GPS Heading` (great-circle bearing) after `GPS Speed`, and `QUOTE_ALL`
  serialization with no trailing comma. Validated to within 0.5 km/h speed and
  1.0 m position of the RaceStudio reference, with a byte golden for regression.
  CSV import (5.2) is the inverse: `read_csv(reader)` parses a generic or AiM
  RS2Analysis CSV back into a `Session` — reconstructing channels (blank cells →
  `NaN`), metadata, and laps (from `Beacon Markers`), normalizing km/h speed back
  to m/s (`normalize_unit`), and tolerating quoting/line-ending/unit-row variants;
  a 5.1 ⇄ 5.2 round-trip and a structural session golden pin it. Panic-free, with
  typed `IoError` (export) and `ImportError` (import) enums.
- **`racestudio-ffi`** — the UniFFI boundary that bridges the Rust core to
  Swift, packaged as a universal (arm64 + x86_64) `RaceStudioFFI.xcframework`.
  As of 1.7 it exposes the decode interface — `open_session(path)`, an opaque
  `SessionHandle` (metadata / channel listing / lap + GPS summaries), and a
  windowed `samples(channel, start, count)` accessor — plus `core_version()`.
  3.8 adds the **analysis** interface, all **windowed** so the UI requests only
  the visible range: `list_laps`, `delta_t_series`, `channel_stats`,
  `eval_math_channel`, and `fft_spectrum` (each taking an `FfiWindow`), returning
  DTOs (`LapInfo` / `DeltaPoint` / `StatsDto` / `SpectrumDto`) and throwing a
  typed `AnalysisError` — never a trap.
  5.4 adds `validate_math_expression(expr)` — a **parse-only** entry (no session,
  no evaluation) that re-validates a stored math channel's source against the M2
  grammar when a project file is loaded, throwing `AnalysisError::InvalidExpression`
  on malformed input.
  8.2 adds the **distance-domain** accessors for distance-mode plots and the track
  map: `samples_with_distance(channel, start, count)` returns
  `(timecode, distance, value)` `DistanceSample`s — a channel window paired with
  the cumulative track distance (metres) at each sample — and
  `gps_track(start, count)` returns per-fix `GpsTrackPoint`s
  `(latitude, longitude, distance, timecode)`, an empty vec when the session has no
  GPS. Both derive distance by integrating `GPS Speed` (`cumulative_distance`) and
  interpolating that axis; neither traps.
  See [`docs/adr/0001-ffi-boundary.md`](docs/adr/0001-ffi-boundary.md).
- **`RaceStudioCore`** — the Swift logic library; all testable behaviour lives
  here. It is the 95% Swift coverage target. As of 2.2 it owns the load
  lifecycle: `SessionStore` (`@MainActor ObservableObject`, `LoadState` machine)
  loading a Core-owned `Session`/`SessionViewModel` through an injected
  `SessionLoading` (`FFISessionLoader` for production). 2.3 adds
  `ImportCoordinator` (drop/panel validation → store) and `RecentFilesStore`
  (security-scoped bookmarks behind injectable `BookmarkStoring`/`KeyValueStoring`).
  2.4 adds `SessionSummaryViewModel` + `LapTimeFormatter`/`ChannelFormatting` —
  pure presentation logic (rate/date/lap-time strings, em-dash fallbacks, best-lap
  detection) the summary views bind to. 2.5 adds `DecodeProgress` (clamped/monotonic
  progress), `ImportError(decodeError:)` (total `DecodeError` → title/message/recovery
  mapping), and `SessionStore` progress threading + `cancel()`.
  4.1 adds the `Plot/` geometry — `LinearScale` (value↔pixel), `TickGenerator`
  (nice 1/2/5 ticks), `PlotViewport` (anchor-preserving, non-finite-safe zoom/pan),
  `plotDomain` (finite-only axis range), and `PlotModel` (`XAxisMode`,
  `ChannelTrace`, `hitTest`, the min/max `envelope` and the visible-window
  `plotPolyline` both render paths draw) — all the testable math behind the
  time/distance line plot. 4.2 adds the `Overlay/` comparison model —
  `LapSelectionModel` (selected set + single reference with promotion),
  `LapOverlayViewModel` (distance-aligned `ChannelTrace` per lap, deterministic
  `PlotColor` palette, and the delta-t strip/cursor readout consuming the 3.2
  delta output) — the logic behind lap overlay comparison. 4.3 adds the `Map/`
  geometry — `GeoProjection` (auto-fit equirectangular projection),
  `TrackPath` (racing-line polyline + nearest-point lookup),
  `ChannelColorScale` (value→color gradient), and `SectorModel`
  (sector/mini-sector partitioning) — the testable math behind the GPS track map.
  4.4 adds the `Readout/` model — `ValueAtCursor` (interpolated value-at-cursor
  with extrapolation flagging), `ReadoutTableModel` (channels × laps grid with
  stable cell identity and no-data cells), and `ChannelFormatter` (unit/precision
  formatting, em dash for NaN/no-data) — the logic behind the channel table.
  4.5 adds the `Stats/` model — `Histogram` (equal-count and fixed-width binning,
  non-finite-safe, edges aligned to zero), `LinearRegression` (least-squares
  slope/intercept/R², `nil` for degenerate input), and `ScatterModel` (paired
  channel-vs-channel points with NaN-drop and window restriction) — the math
  behind the distribution and XY-scatter plots.
  8.9 adds the `Stats/` feed adapters that drive those two plots as analysis-window
  panels: `HistogramPanelModel` (a channel's whole-window distribution at a
  configurable bin count plus one per-lap distribution on a shared, zero-aligned
  value grid, coloured by selection order), `ScatterPanelModel` (two channels paired
  into the friction-circle **G-G** cloud with an optional least-squares trend line),
  and `StatsPanelsModel` — the `@MainActor` panel state (bin count, trend-line
  toggle, scatter axes) that assembles both from the analysis window's channel
  traces, so the reused `HistogramView`/`ScatterView` render live under the M8 rail.
  8.10 adds the `Report/` model — the RS3 **Channels Report**: `ChannelStatistics`
  (non-finite-safe min/max/average/median plus interpolated 25/75/90/95th
  percentiles, with a `ReportStatistic` selector), `ReportPreset` (the "magic wand"
  vehicle-health / racer / vehicle-performance presets — a default statistic plus a
  case-insensitive channel-name match), and `ChannelsReportModel` — the `@MainActor`
  state + assembly that slices each selected channel per lap (or per equal-time
  segment) into a min/max/avg/median table and maps the chosen statistic across the
  laps into a graph hot-tracked to the selected table row, all from the window's
  channel traces so it renders live under the M8 rail.
  8.11 adds the `Splits/` model — the RS3 **Split Times** report. A new analysis
  primitive `segment_times` (in `racestudio-analysis`, exported over UniFFI as
  `SessionHandle::segment_times`) cuts each lap into `N` equal-**distance**
  segments off its `GPS Speed` odometer — the same track pieces lap after lap —
  and returns the seconds spent in each (pinned to the lap's `[0, duration]` so
  they sum to the lap time exactly; GPS-less laps fall back to equal-time). On top
  of that base grid, `SplitLayout` groups the cells into editable splits (pure
  merge / divide / rename / type / lock), `SplitReport` derives the per-lap table,
  the **best theoretical** lap (sum of each split's fastest time across laps) and
  the **best rolling** lap (fastest one-lap-length window over the concatenated
  grid), and `SplitReportModel` is the `@MainActor` state driving it — so editing a
  split re-groups the base grid and recomputes without re-reading the session.
  8.12 adds the `Plot/PlotArrangementModel` — the RS3 **plot display modes**.
  `PlotArrangement.arrange(mode:channels:)` maps N channels onto graphs for each
  mode: **overlapped** (one shared-Y graph), **tiled** (one channel per graph),
  **mixed** (channels distributed across up to six graphs), **smart** (corner-bound
  families — dampers / wheel speeds / brakes / tyres, matched by name via
  `PlotChannelFamily` — auto-grouped, leftovers overlaid together), and
  **smart-tiled** (families grouped, each leftover tiled). `PlotLineStyle` clamps the
  line-width / dot-size knobs; `snapToLapBoundaries` constrains zoom/pan to whole
  laps (fed by `lapTimeBoundaries`); and `localTimeOffsets` / `ChannelTrace.timeShifted`
  / `LapOverlayViewModel.localTimeTraces` align overlaid laps to a common start so
  identical track sections line up. `TimeDistancePlotView` binds all of it (the
  layout picker, line/dot sliders, snap toggle, and the lap-overlay local-time
  toggle), stacking one band per arranged graph.
  8.13 wires the 5.4 `Project/` persistence into the analysis window — **profiles /
  workspace**. `AnalysisWindowModel` gains a `ProjectDocument` mapping
  (`Workspace/AnalysisWindowProject`): `projectDocument(mathChannels:)` captures the
  selected channels (as a pane), selected laps + reference (under the session's
  content id), the active layout, and the math channels; `restore(from:)` re-applies
  them (skipping channels/laps absent from the session). The `.rsproj` schema bumps
  to **v3** — `ProjectDocument.activeLayout` + `LapSelection.reference` persist and
  round-trip, and a pre-8.13 v2 project migrates forward defaulting to Time/Distance.
  A `Workspace/StoryBoardModel` derives the lap strip (shown laps in order, reference
  marked); `LapSelectionModel.move(from:to:)` reorders it and every panel follows via
  `AnalysisWindowModel.reorderSelectedLap`. The thin `WorkspaceBar` / `StoryBoardView`
  surface File-style Open/Save `.rsproj` commands and the reorderable strip; `make run`
  builds + launches the app.
  8.14 adds the `Library/LibraryBrowserModel` — the RaceStudio 3 **session library
  browser**, and makes it the app's landing window. Over the 5.3
  `SessionIndex`/`LibraryStore` it lists indexed sessions date-descending; imports add
  to the index (dedup by content id) and persist via `save(to:)`; a left filtering
  column (vehicle facet + free-text search) narrows the list; and a selected session
  previews its laps summary + a `MapPreviewModel` racing-line thumbnail
  (`SessionPreview`) — decoded through the injected `SessionLoading` + `AnalysisSession`,
  **without opening full analysis**. A missing/corrupt library loads empty (5.3
  semantics). The shell makes the browser the **primary `Window` scene**
  (`LibraryRootView` → `LibraryBrowserView`), so launching RaceStudio opens the browser
  rather than a file-open panel; `SessionStore.reset()` returns from analysis to the
  browser. `make run` now wraps the built binary in a minimal `.app` bundle (via
  `scripts/run_app.sh`) so it launches with a real window — a bare `swift run`
  executable gets non-GUI activation and never shows one — and `make help` lists every
  target.
  8.15 extends the browser with RS3 **collections** and **faceted search**. Core:
  `FilterSpec` grows the six facet predicates (vehicle, racer, track, championship,
  comment, logger — exact, case-insensitive) and becomes `Codable`; `SessionFacet`
  centralises how each facet reads a `SessionSummary` and applies to a `FilterSpec`;
  `SessionCollection` is a **smart** (rule-based, backed by a `FilterSpec`) or **manual**
  (curated, ordered content ids) collection. `SessionIndex` gains `recent(limit:)`
  (RS3 "Recent", ranked by import time), `facetValues(_:)`, and collection CRUD +
  `sessions(in:)` resolution — all persisted in `library.json` alongside the summaries
  (older libraries without a `collections` key, or summaries without the new facet
  fields, still load). `LibraryBrowserModel` adds a `LibraryScope` (all / recent /
  collection) narrowed by search + facets, plus `setFacet`, `showRecent`/`showCollection`,
  and drag-a-session-into-a-manual-collection persistence. The shell adds a collections
  sidebar and per-facet pickers, with session rows draggable onto manual collections.
  Championship comes from the session's series; comment/logger are modelled but not yet
  surfaced by the decoder. Out of scope: cloud collections.
  8.16 adds the RS3 **Frequency Analysis** spectrum panel over the existing
  `fft_spectrum` FFI export (damper / vibration analysis). Core: `AnalysisSession.spectrum`
  reads a channel's single-sided amplitude spectrum through a new `SessionDataSource` seam
  method (Core's `SpectrumWindowKind` / `ChannelSpectrum` mirror the FFI `SpectrumWindow` /
  `SpectrumDto`, seconds→ms window like `stats`), and `Stats/SpectrumModel` pairs the
  aligned `freqs`/`amps` into frequency-vs-amplitude `points` + the dominant-frequency
  `peak`, degrading to an empty panel on any engine error. The engine resamples a
  non-uniformly-sampled channel to a uniform rate before the FFT, so a non-uniform channel
  transforms with no caller work and no crash. The shell adds a `.spectrum` window layout →
  `SpectrumView` (a thin amplitude-vs-frequency area plot reusing the 4.1 plot primitives,
  peak marked) with a window-function picker that recomputes the spectrum when changed. Out
  of scope: waterfall / spectrogram.
  8.17 adds the RS3 **Suspension Analysis** composite and the **Log Sheet** ledger,
  composed from existing panels. Core: `Suspension/SuspensionComposition` is a pure,
  view-free description of the composite's ordered sub-panels (shock time/distance +
  travel histogram + damper FFT + settings), so the arrangement is unit-tested;
  `Suspension/ShockVelocity` derives shock (damper) velocity as a plottable math channel —
  the backward-difference time-derivative of a suspension-position channel, first sample 0
  and a non-positive `dt` guarded to 0 (mirroring the Rust `derived.rs` `guarded_dt`
  policy). `LogSheet/LogSheetModel` is the user-authored session/setup metadata (weather,
  engine, dimensions, weights, fuel, gearing, notes) added to `ProjectDocument` as a schema
  **v4** `logSheet` field — a pre-8.17 v3 project migrates forward with an empty sheet — and
  carried through the `AnalysisWindowModel` ↔ `ProjectDocument` mapping so an edited sheet
  persists with the `.rsproj`. The shell adds `.suspension` (a `SuspensionPanel` stacking
  the composed panels for the shared channel selection) and `.logSheet` (a `LogSheetPanel`
  form editing the sheet through `updateLogSheet`) window layouts. Out of scope:
  cross-session setup-database sharing.
  4.6 adds the `MathEditor/` model — `MathChannelEditorModel` (a debounced,
  last-write-wins live validator publishing an `EditorState` + preview
  `ChannelTrace`), `ExpressionDiagnostic`/`ExpressionEngineError` (engine-error →
  message + character-span mapping), and the `ExpressionEvaluating` seam whose
  `FFIExpressionEvaluator` runs the 3.5 engine over the session via UniFFI — the
  logic behind the math-channel editor.
  4.7 adds the `Workspace/` model — `WorkspaceCursor` (one canonical cursor whose
  `timePosition`/`distancePosition` interpolate through the 3.8 mapping so linked
  views agree on the same physical point), `CursorSelection` (normalized,
  emptiness-aware drag range), and `LinkedViewRegistry`/`CursorBroadcaster` (weak,
  identity-keyed broadcast that skips the originator) — the shared cursor &
  selection contract the M4 tiles consume. (4.4's placeholder `WorkspaceCursor`
  struct became a scalar `cells(atX:)` argument, freeing the name for it.)
  5.3 adds the `Library/` model — `SessionSummary` (a `Codable` per-session
  summary: venue / date / vehicle / driver / lap count / best lap / source), a
  `SessionIndex` that summarises each decoded/imported `Session` and keeps
  entries de-duplicated by a stable, content-derived SHA-256 id with
  case-insensitive `search` and a structured `filter` (both date-descending),
  and `LibraryStore` for **atomic, crash-safe** JSON persistence — a corrupt
  index loads as empty (typed `LibraryError`) and a moved/deleted source is
  flagged unavailable rather than dropped — the browsable, searchable session
  library.
  5.4 adds the `Project/` model — the versioned `.rsproj` workspace document:
  `ProjectDocument` (`schemaVersion`, session refs, `AnalysisLayout` panes +
  X-axis mode, `LapSelection`s, `MathChannelDef`s) and `ProjectStore` for atomic,
  crash-safe save/load with a v1→current `migrate`. On load it resolves session
  refs and clamps lap selections against the 5.3 library (a `LibraryContext`),
  and re-validates each math channel by **parsing** its source through the M2
  grammar over an injected `ExpressionValidating` seam (production
  `FFIExpressionValidator` → the new `validate_math_expression` FFI) — an invalid
  expression is recorded as a typed `ProjectError.invalidMathChannel` without
  aborting the load; a newer `schemaVersion` is refused, and a garbage file loads
  to `ProjectError.corruptDocument` rather than crashing.
- **`RaceStudio`** — a thin `@main` SwiftUI shell that holds no logic and is
  excluded from the coverage metric by target. As of 2.1 it is a
  **document-based** app (`DocumentGroup` over `XRKDocument`) that opens
  `.xrk`/`.xrz` files under the App Sandbox; its file-type logic
  (`SupportedFileType`, `UTType.xrk`/`.xrz`) and byte-loading (`DocumentContents`)
  live in `RaceStudioCore`. 4.1 adds `Views/TimeDistancePlotView` (the reusable
  multi-channel line plot) with a Metal-primary / Swift Charts fallback renderer
  (ADR 0003); it owns gestures and drawing only — all geometry is in the Core.
  4.2 adds `Views/LapOverlayView` (lap picker + overlaid plot) and
  `Views/DeltaStripView` (the gain/loss strip), reusing `TimeDistancePlotView`.
  4.3 adds `Views/TrackMapView` (the GPS track map: racing line colored by
  channel, sector marks, cursor marker), drawing the Core `Map/` geometry.
  4.4 adds `Views/ChannelTableView` (the channels × laps value-at-cursor grid +
  pinned digital readouts), rendering the Core `Readout/` model.
  4.5 adds `Views/HistogramView` (bin bars) and `Views/ScatterView` (points +
  fitted trend line), drawing the Core `Stats/` model with the 4.1
  `LinearScale`/`TickGenerator` axes.
  4.6 adds `Views/MathChannelEditorView` (expression field + inline diagnostic
  caret + embedded 4.1 preview plot), rendering the Core `MathChannelEditorModel`.
  4.7 adds `Views/WorkspaceView` (tiles the M4 views and binds them to one shared
  `WorkspaceCursor`, injected with the `LinkedViewRegistry` via the environment).

## Layout

```
Cargo.toml                     # Rust workspace (resolver "2")
rustfmt.toml · clippy.toml     # shared Rust format/lint config
core/
  racestudio-decode/           # .xrk decoder — container/channels/gps/laps/session
  racestudio-analysis/         # analysis engine — laps, alignment, delta-t, resample, stats
  racestudio-io/               # import/export — AiM CSV writer (5.1) + reader (5.2)
  racestudio-ffi/              # UniFFI boundary — open_session, windowed samples (+distance), gps_track, validate_math_expression
app/
  Package.swift                # RaceStudioCore/RaceStudio/tests + FFI targets
  Sources/RaceStudioCore/      # logic library — session store, analysis/plot models, session library, project files, FFI bindings
  Sources/RaceStudio/          # @main SwiftUI shell — DocumentGroup, open/drop/recents, summary views
  Tests/RaceStudioCoreTests/   # swift-testing smoke + FFI round-trip + file-type/document tests
  Generated/                   # checked-in uniffi-generated Swift bindings
  .swiftlint.yml               # SwiftLint config
  RaceStudioFFI.xcframework/   # built artifact (git-ignored, ~34 MB)
fixtures/                      # decode goldens (0.5): golden/*.json + sample.v1.rsproj committed,
                               #   .xrk/.csv samples git-ignored (make fixtures)
scripts/
  coverage.sh                  # Rust + Swift quality + coverage gate
  swift_test.sh                # `swift test` wrapper (CLT framework paths)
  build_xcframework.sh         # universal xcframework + Swift bindings
  fetch_fixtures.sh            # fetch .xrk samples + regenerate goldens
  gen_goldens.py               # libxrk -> deterministic golden JSON
  gen_csv_golden.sh            # regenerate the AiM CSV byte golden (5.1)
  gen_session_golden.sh        # regenerate the imported-session structural golden (5.2)
  e2e.sh                       # build pipeline + corpus golden conformance (1.8)
  spike_xdrk_linkage.sh        # reproducible xdrk-crate linkage probe (ADR 0002)
tests/
  gate_test.sh                 # Rust gate self-tests
  swift_gate_test.sh           # Swift gate self-tests
  ffi_test.sh                  # FFI pipeline tests
  fixtures_test.sh             # fetch-fixtures self-tests
.github/workflows/ci.yml       # macos-15 CI: Rust + Swift gates
docs/DEFINITION_OF_DONE.md     # shared DoD checklist
docs/DECODE_TOLERANCES.md      # decode conformance tolerance table (1.8)
docs/adr/                      # architecture decision records (0001 FFI, 0002 decode, 0003 plot render)
docs/spike/                    # spike evidence (xdrk linkage finding)
Makefile                       # `make coverage`, `make xcframework`, `make fixtures`
```

## Development

Requires the Rust toolchain (`rustup` + `cargo-llvm-cov` + the
`llvm-tools-preview` component), the Swift toolchain, `swiftlint`, and
[`trivy`](https://trivy.dev) (the security scanner). A full Xcode install is
**not** required — the tooling also works with just Apple's Command Line Tools.
`make setup` installs the toolchains.

```sh
# Rust core
cargo build --workspace          # compiles all three crates, warning-free
cargo test  --workspace          # runs the placeholder unit tests
cargo clippy -- -D warnings      # lint gate
cargo fmt --check                # format gate

# Rust→Swift FFI boundary
make xcframework                 # build RaceStudioFFI.xcframework + Swift bindings

# Decode test fixtures (libxrk golden oracle — see fixtures/README.md)
make fixtures                    # fetch .xrk samples + regenerate golden JSON

# Swift app
cd app
swift build                      # compiles RaceStudioCore + the @main shell
bash ../scripts/swift_test.sh    # runs the smoke + FFI round-trip tests
```

The Swift package links the `RaceStudioFFI` binary target, so `swift build`/
`swift test` need `RaceStudioFFI.xcframework` present. It is a git-ignored
artifact; the coverage gate builds it on demand, or run `make xcframework`. A
fresh checkout without it still builds — the FFI surface is gated behind
`#if canImport(RaceStudioFFIBindings)`.

### Coverage gate

`scripts/coverage.sh` is the single quality + coverage gate, run identically
locally and in CI. It enforces a **≥95% line-coverage floor** (configurable via
`COVERAGE_THRESHOLD`) on the logic core only — the Rust crates and the Swift
`RaceStudioCore` library; the `RaceStudio` `@main` shell is structurally
excluded (it is never linked into the tests).

```sh
make coverage                    # both gates (Rust then Swift)
bash scripts/coverage.sh --rust-only    # cargo fmt/clippy/test + llvm-cov ≥95%
bash scripts/coverage.sh --swift-only   # swiftlint + swift test + llvm-cov ≥95% on Core
```

### Testing framework

The Swift smoke tests use **[swift-testing](https://github.com/swiftlang/swift-testing)**
(`import Testing`), the framework bundled with the Swift toolchain. On a runner
with only the Command Line Tools installed (no full Xcode), `swift test` builds
the swift-testing bundle but cannot load it at runtime unless the framework
search paths are supplied. **`scripts/swift_test.sh`** injects those paths
(`-F`/`-rpath` into `$(xcode-select -p)/Library/Developer/Frameworks` and
`.../usr/lib`) when — and only when — the Command Line Tools are the active
developer dir, so `swift test` builds *and runs* on both CLT-only and full-Xcode
hosts. On full Xcode it is a transparent pass-through.

## Make targets

One command per intent — `make ci` is the exact sequence CI runs, so a green
`make ci` locally predicts a green pipeline.

| Target | Does |
| --- | --- |
| `make help` | list every target with its description (the default target) |
| `make setup` | install toolchains + fetch fixtures |
| `make run` | build + launch the app as a `.app` bundle so it shows a window |
| `make test` | Rust + Swift test suites (`test-rust`, `test-swift`) |
| `make coverage` | the ≥95% line-coverage gate (Rust + Swift) |
| `make lint` | `clippy -D warnings` + `cargo fmt --check` + `swiftlint` |
| `make security` | Trivy scan (vulns / secrets / IaC misconfig); fails on HIGH/CRITICAL |
| `make e2e` | build the pipeline + validate the decode oracle |
| `make ci` | `lint` → `coverage` → `e2e` (what CI runs) |
| `make fixtures` | fetch `.xrk` samples + regenerate goldens |
| `make xcframework` | build the universal `RaceStudioFFI.xcframework` |
| `make clean` | remove build artifacts |

## Contributing

Test-first (Red → Green → Refactor) with a **≥95% line-coverage floor** on the
logic core, enforced by `make ci` in CI (`.github/workflows/ci.yml`, `macos-15`).
The shared bar is [`docs/DEFINITION_OF_DONE.md`](docs/DEFINITION_OF_DONE.md) — the
single source of truth that [the PR template](.github/PULL_REQUEST_TEMPLATE.md)
embeds and every issue pastes. New issues use
[`.github/ISSUE_TEMPLATE/feature.md`](.github/ISSUE_TEMPLATE/feature.md).

CI also runs a **[Trivy](https://trivy.dev) security scan** (`make security`) —
known-vulnerable dependencies, committed secrets, and IaC misconfigurations —
which fails the build on HIGH/CRITICAL findings. Run it (with the rest of the
gates) before pushing.

`main` is protected: changes land via PR, and the `make ci (lint, coverage, e2e)`
check plus 1 review are required before merge (linear history, no direct pushes).
The exact, reproducible configuration is in
[`docs/BRANCH_PROTECTION.md`](docs/BRANCH_PROTECTION.md).

## License

[MIT](LICENSE) © 2026 Eduardo Zenardi
