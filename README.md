# RaceStudio-macOS

A native macOS re-implementation of AiM **RaceStudio 3** telemetry analysis —
successor and sibling to [XRKConverter](https://github.com/Zenardi/XRKConverter).

> **Status:** **M0 — Foundations, Tooling & TDD Harness** complete (0.1–0.7);
> **M1 — Rust Core: XRK Decode** complete (1.2–1.8). M0 shipped the scaffold, the Rust +
> Swift **coverage gates**, the **UniFFI xcframework pipeline**, the
> **golden-fixtures harness** (libxrk-derived oracle JSON + Rust/Swift loaders),
> the shared DoD/CI/Makefile, and enforceable branch protection — green,
> warning-free, ≥95% line coverage on the logic core, enforced in CI. M1 opens
> with the **decode-strategy decision**
> ([ADR 0002](docs/adr/0002-xrk-decode-strategy.md)): a clean-room Rust decoder
> validated against the `libxrk` oracle, after a spike rejected wrapping the
> proprietary-linked `xdrk` crate. The full M1 decode layer now ships:
> **`open_container`** parses the `.xrk` container header into session
> **metadata** (driver, vehicle, venue, session date/time) plus the structural
> counts (channels, GPS presence, lap markers) the later decoders consume;
> **`decode_channels`** turns the container's `CHS` table and `(S`/`(M` sample
> streams into typed, unit-tagged **channel series** (`name`, `unit`,
> `sample_rate_hz`, `(timecode, value)` samples); **`decode_gps`** decodes
> the u-blox **NAV-SOL** stream into `GpsData` — latitude/longitude (ECEF →
> geodetic, matching the golden to 1e-8), speed (m/s), altitude, accuracy, and
> satellite count, distinguishing raw from computed GPS channels; and
> **`decode_laps`** decodes the **LAP marker** table into `LapData` — per-lap
> cumulative times and the best (fastest) lap. All reproduce the libxrk golden
> to precision. These now unify (1.6) behind one call — **`decode_session`** —
> which opens the container and runs every decoder, returning a complete,
> immutable **`Session`** (metadata + channels + GPS + laps) through one typed,
> `#[non_exhaustive]` **`DecodeError`**; the whole decode path is panic-free,
> enforced by a clippy lint forbidding `unwrap`/`expect`/`panic!` on library
> code. That `Session` is now exposed to Swift over **UniFFI** (1.7):
> **`open_session(path)`** returns an opaque, `Arc`-backed **`SessionHandle`**,
> and Swift reads channel data through a **windowed** `samples(channel, start,
> count)` accessor — a bounded slice per call — so the UI never copies a whole
> channel across the boundary; a Swift round-trip test opens the real sample,
> lists channels, and stitches two adjacent windows. Closing M1, a **corpus-wide
> conformance harness** (1.8) decodes **every** `fixtures/*.xrk` with
> `decode_session` and asserts metadata/channels/GPS/laps match the committed
> libxrk goldens within [documented tolerances](docs/DECODE_TOLERANCES.md),
> emitting a precise diff on any mismatch and gating CI via `scripts/e2e.sh` —
> the milestone's regression net. **M2** now stands up the app itself:
> RaceStudio is a **document-based SwiftUI shell** (2.1) that opens
> `.xrk`/`.xrz` files — declaring the imported AiM UTIs, running under the
> **App Sandbox** with user-selected read-only access, and loading a picked
> file's bytes into memory (`XRKDocument`) with a typed error on empty/unreadable
> input, all **without decoding** yet. `SessionStore` (2.2) then drives the load
> lifecycle: a `@MainActor ObservableObject` that decodes a URL through an
> injected `SessionLoading` (production `FFISessionLoader` → Rust core) and
> publishes an `idle → loading → loaded / failed` state machine, so views render
> purely from state. File import (2.3) then brings files in three ways — Open
> panel, drag-and-drop, and a **Recent Files** list that survives relaunch via
> **security-scoped bookmarks**: `ImportCoordinator` validates/dedupes incoming
> URLs and drives the store, while `RecentFilesStore` persists a most-recent-first,
> path-deduped, max-10 list behind injectable bookmark/key-value protocols. The
> summary screen (2.4) is the milestone's payoff — open a real `.xrk` and see its
> contents: `SessionSummaryViewModel` turns a decoded `Session` into a metadata
> panel, a channel list (name/unit/`"100 Hz"` rate), and a lap list
> (`m:ss.mmm` times, best-lap marker) — all formatting, em-dash fallbacks, and
> best-lap detection are pure/tested in Core, so the SwiftUI views are trivial
> bindings. Closing M2, async decode (2.5) threads a clamped/monotonic
> `DecodeProgress` through the `.loading` state, maps every `DecodeError` to a
> user-facing `ImportError` (title/message/recovery), and supports **cancellation**
> (a new load cancels the prior) — so opening a large `.xrk` shows a progress bar,
> recovers from a bad file with a clear alert, and can be cancelled. **M2 is
> complete.** **M3** opens the **analysis engine**: lap segmentation & alignment
> (3.1) splits a decoded `Session` into per-lap views — each channel (CHS + GPS)
> sliced to the lap's half-open time window — then derives a trapezoidal distance
> axis from GPS speed and aligns any two laps in the **time** or **distance**
> domain for overlay comparison, all validated against the beacon-lap golden.
> Delta-t (3.2) is the overlay's core metric: `delta_t` returns the cumulative
> time a comparison lap has gained or lost versus a reference lap as a function
> of distance (positive ⇒ slower) — zero at the start line, the lap-time
> difference at the finish, with both laps aligned by track position. Resampling
> (3.3) puts heterogeneously-sampled channels on a common grid: `resample_uniform`
> (fixed-rate, endpoint-preserving, holes across gaps wider than `max_gap`) and
> `to_distance_grid` (onto a supplied distance axis), linearly interpolated and
> cross-checked against libxrk's `resample_to_timecodes`. Statistics (3.4) reduce
> any channel — whole-session, per-lap, or over a half-open `[t0, t1)` window — to
> `channel_stats` (min / max / mean / population & sample std / RMS / count /
> range) using Welford's numerically stable one-pass moments, ignoring `NaN`
> holes and cross-checked per channel against a numpy oracle. Math channels (3.5)
> add a small expression language — lexer, precedence-climbing parser, and
> evaluator — for user-defined channels like `sqrt(Ax*Ax + Ay*Ay)`: `+ - * /`
> with correct precedence, parentheses, unary minus, scientific-notation
> literals, a built-in function set (`abs min max sqrt sin cos tan log exp pow
> clamp`), and channel references resolved to a scalar or a per-sample series.
> Every malformed input returns a typed `ExprError` with a `(line, col)` — never
> a panic. Derived channels (3.6) compute what the logger doesn't record —
> GPS `heading` (ENU bearing, `atan2(V_east, V_north)`), `yaw_rate` (with ±180°
> wrap), longitudinal and lateral acceleration in g, and a nearest-centroid
> `gear_estimate` — matching XRKConverter/libxrk's computed channels on the
> golden so overlays agree with the reference tool. Finally the windowed FFT
> (3.7) gives a channel's frequency spectrum: `spectrum` applies a window
> (rectangular / Hann / Hamming / Blackman), transforms with a mixed-radix FFT,
> and returns a coherent-gain-corrected single-sided amplitude spectrum on a
> `k·fs/N` axis — peak amplitudes physical to ~1%, Parseval-conserving. **M3 is
> complete.**

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
│   racestudio-io        CSV export (AiM CSV)   │  ← 95% Rust coverage target
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
  Panic-free, with a single `IoError`.
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
  racestudio-io/               # import/export — RaceChrono AiM CSV writer (5.1)
  racestudio-ffi/              # UniFFI boundary — open_session + windowed samples
app/
  Package.swift                # RaceStudioCore/RaceStudio/tests + FFI targets
  Sources/RaceStudioCore/      # logic library — session store, file types, doc bytes, FFI bindings
  Sources/RaceStudio/          # @main SwiftUI shell — DocumentGroup, open/drop/recents, summary views
  Tests/RaceStudioCoreTests/   # swift-testing smoke + FFI round-trip + file-type/document tests
  Generated/                   # checked-in uniffi-generated Swift bindings
  .swiftlint.yml               # SwiftLint config
  RaceStudioFFI.xcframework/   # built artifact (git-ignored, ~34 MB)
fixtures/                      # decode goldens (0.5): golden/*.json committed,
                               #   .xrk/.csv samples git-ignored (make fixtures)
scripts/
  coverage.sh                  # Rust + Swift quality + coverage gate
  swift_test.sh                # `swift test` wrapper (CLT framework paths)
  build_xcframework.sh         # universal xcframework + Swift bindings
  fetch_fixtures.sh            # fetch .xrk samples + regenerate goldens
  gen_goldens.py               # libxrk -> deterministic golden JSON
  gen_csv_golden.sh            # regenerate the AiM CSV byte golden (5.1)
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
docs/adr/                      # architecture decision records (0001 FFI, 0002 decode)
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
| `make setup` | install toolchains + fetch fixtures |
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
