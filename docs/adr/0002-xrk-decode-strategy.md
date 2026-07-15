# ADR 0002 — `.xrk` decode strategy: clean-room Rust port, validated against the libxrk oracle

- **Status:** Accepted
- **Date:** 2026-07-15
- **Milestone:** M1 (issue 1.1). Consumed by 1.2 (container), 1.3 (channels),
  1.4 (GPS), 1.5 (laps), and 1.8 (golden validation).

> **ADR numbering note.** Issue 1.1 refers to this file as
> `0001-xrk-decode-strategy.md`, but `0001` was already taken by
> [`0001-ffi-boundary.md`](0001-ffi-boundary.md) (M0, issue 0.4). ADR numbers are
> monotonic and never reused, so this decision is **0002**. Content and scope are
> exactly as the issue specifies.

## Context

Before writing any decoder we must decide **how** AiM `.xrk` telemetry is
decoded in a *fully native* Rust backend — the whole reason RaceStudio-macOS
exists as a rewrite rather than a repackaging of the Python sibling
[XRKConverter](https://github.com/Zenardi/XRKConverter). "Native" here means: a
self-contained Rust core, no Python runtime, and **no proprietary precompiled
blobs** — so the app can ship as a universal (arm64 + x86_64) macOS binary.

`.xrk` is AiM's undocumented binary session format. Three strategies were on the
table; this ADR is a time-boxed (≤2 days) spike that ends here.

## Options considered

| Option | Summary | Native? | Verdict |
| --- | --- | --- | --- |
| **(a) Clean-room Rust port** | Decode `.xrk` in pure Rust, validated byte-for-value against `libxrk`'s output | ✅ yes | **Chosen** |
| (b) Wrap the `xdrk` crate | Depend on the crates.io `xdrk` crate | ❌ no — see spike | Rejected |
| (c) FFI to Python `libxrk` | Call XRKConverter's Python parser over FFI | ❌ no | Rejected up front |

### (b) `xdrk` — rejected on evidence

The one third-party Rust option was inspected with a reproducible probe
([`scripts/spike_xdrk_linkage.sh`](../../scripts/spike_xdrk_linkage.sh); full
evidence in [`docs/spike/xdrk-linkage.md`](../spike/xdrk-linkage.md)). Findings:

- `xdrk` v1.0.0 is a thin `extern "C"` wrapper (`src/bindings.rs`) around AiM's
  **proprietary** `libxdrk` / `libmatlabxrk` shared libraries, which it vendors
  as prebuilt binaries under `aim/`.
- Its `build.rs` links them: `cargo:rustc-link-lib=xdrk-x86_64` (unix) /
  `cargo:rustc-link-lib=dylib=libxdrk-x86_64` (windows).
- It ships **only** x86_64 **Linux** (`.so`) and **Windows** (`.dll`) objects —
  **no `.dylib`, no arm64/aarch64**. It cannot even link on Apple-Silicon macOS.

Wrapping it would reintroduce a non-native, redistribution-encumbered dependency
*and* fail to build on the target platform. Rejected.

### (c) Python `libxrk` over FFI — rejected up front

Embedding or shelling to XRKConverter's Python `libxrk` keeps a Python runtime
in the shipped app, defeating the native goal (that path is what XRKConverter
already is). Rejected without a spike. `libxrk` still has a role — as the decode
**oracle** (below), used offline at test time, never in the shipped app.

## Decision

Implement a **clean-room Rust port** of the `.xrk` decoder (option **a**) in the
`racestudio-decode` crate, developed **test-first against `libxrk` output as the
golden oracle**. No proprietary blobs, no Python runtime — a self-contained Rust
core behind the UniFFI boundary from
[ADR 0001](0001-ffi-boundary.md).

### The decode oracle & golden-fixture plan

Correctness is *defined* as "matches `libxrk`" — XRKConverter's pure-Python
`.xrk` parser — for the fields we expose:

- **Oracle generator:** [`scripts/gen_goldens.py`](../../scripts/gen_goldens.py)
  loads each `.xrk` with `libxrk`'s `aim_xrk(path)` and emits small, sorted,
  deterministic summaries — **not** raw samples — so goldens are committable and
  diffable:
  - `fixtures/golden/<name>.channels.json` — channel inventory + per-channel
    summary (units, decimals, sample count, first/last timecode, min/max/first/last).
  - `fixtures/golden/<name>.gps.json` — GPS lat/long/altitude summary.
  - `fixtures/golden/<name>.laps.json` — lap beacons (num / start / end / duration).
- **Sample inputs:** `.xrk`/`.csv` are large and stay git-ignored; fetched by
  [`scripts/fetch_fixtures.sh`](../../scripts/fetch_fixtures.sh) (via
  `make fixtures`). The `golden/*.json` are committed (see
  [`fixtures/README.md`](../../fixtures/README.md)).
- **Consumers:** 1.2–1.6 each assert their decoder output against the matching
  golden aspect; 1.8 is the end-to-end golden-validation gate. Loaders already
  exist: Rust `support::fixtures::load_golden`
  (`core/racestudio-decode/tests/support/fixtures.rs`) and Swift `FixtureLoader`.

### Float-comparison tolerance strategy

`libxrk` rounds each channel to its own declared decimal precision
(`ChannelMetadata.dec_pts`), and the goldens are stored at that precision. Decode
tests therefore compare:

- **Integers** (sample counts, timecodes in ms, lap boundaries) — **exact** equality.
- **Floats** (channel min/max/first/last, GPS) — within an **absolute tolerance**
  of half a unit in the channel's last recorded decimal place, i.e.
  `epsilon = 0.5 × 10^(−decimals)` (a strict per-channel epsilon, not a blanket
  ULP compare). GPS lat/long use the goldens' fixed 8-decimal precision.

This keeps assertions strict where the format is exact and tolerant only to the
rounding `libxrk` itself applies.

### Crate skeleton for 1.2

Issue 1.2 builds the container reader in the existing **`racestudio-decode`**
crate (`core/racestudio-decode`, stubbed in 0.1). The decoder grows there behind
a small public API; the FFI boundary (ADR 0001) surfaces it to Swift as an
opaque `Session` with windowed accessors.

## Consequences

- **1.2 starts the real decoder** in `racestudio-decode`, test-first against
  `fixtures/golden/*.json`, using the per-channel epsilon above.
- **`xdrk` is never a dependency** of this workspace (it would pull a proprietary,
  non-macOS blob into the build graph). The probe that proves this stays as a
  reproducible script + an `#[ignore]`d test, not a build dependency.
- **`libxrk` stays test-only** — the oracle for generating goldens offline, never
  shipped in the app.
- **Observed `.xrk` shape (high level), from the goldens:** a session is a set of
  named channels, each a time series of `(timecode_ms, value)` at a per-channel
  rate, plus GPS channels and a lap-beacon table — matching the
  channels/gps/laps golden aspects the decoders will reproduce.
- **Fallback (time-box respected):** the evidence was conclusive within the box,
  so no fallback was needed. Had `xdrk` proven native *and* macOS/arm64-capable,
  this ADR would have re-evaluated option (b); it is not, so option (a) stands.

## References

- Spike evidence: [`docs/spike/xdrk-linkage.md`](../spike/xdrk-linkage.md);
  probe: [`scripts/spike_xdrk_linkage.sh`](../../scripts/spike_xdrk_linkage.sh).
- Tests: `core/racestudio-decode/tests/spike_xdrk_linkage.rs`.
- FFI boundary: [ADR 0001](0001-ffi-boundary.md). Oracle harness: issue 0.5,
  [`fixtures/README.md`](../../fixtures/README.md).
- Sibling issues: 1.2 (container), 1.4 (GPS), 1.5 (laps), 1.8 (golden validation).
