# ADR 0001 — Rust↔Swift FFI boundary: UniFFI, and the bulk-data strategy

- **Status:** Accepted
- **Date:** 2026-07-15
- **Milestone:** M0 (issue 0.4); referenced by all M1+ decode/analysis issues.

## Context

RaceStudio-macOS is a Rust core (`racestudio-decode`, `racestudio-analysis`,
`racestudio-ffi`) driven by a SwiftUI frontend. Two decisions taken now shape
every later milestone:

1. **How the Rust↔Swift boundary is generated** — the mechanism that turns Rust
   functions/types into a callable Swift API.
2. **How bulk telemetry crosses that boundary** — a single `.xrk` session is
   many channels × up to millions of samples. Naively copying whole sessions
   across FFI would dominate memory and latency.

This ADR is validated by the smallest possible surface: a
`#[uniffi::export] fn core_version() -> String` that a Swift test round-trips
(issue 0.4).

## Decision 1 — UniFFI over swift-bridge (and hand-rolled C)

We use **[UniFFI](https://mozilla.github.io/uniffi-rs/)** (library/proc-macro
mode, `uniffi::setup_scaffolding!()`), packaged as a universal
`RaceStudioFFI.xcframework` with generated Swift bindings.

### Options considered

| Option | Pros | Cons |
| --- | --- | --- |
| **UniFFI** | Mature (Mozilla/Firefox); generates idiomatic Swift; handles records/enums/errors/async; arm64+x86_64 xcframework; one `#[uniffi::export]` surface | Generated glue is verbose; opinionated type mapping; extra build step (bindgen) |
| swift-bridge | Very ergonomic Swift↔Rust; good perf; supports `some`/opaque types | Smaller community; less coverage of complex enums/errors; more manual bridging for our record-heavy telemetry types |
| Hand-rolled C ABI + Swift shims | Zero deps; full control | Every type bridged by hand; error-prone; no tooling; slowest to evolve |

### Rationale

Our domain is **record-heavy** (channels, samples, laps, math-channel
definitions, errors). UniFFI's first-class support for structs/enums/`Result`
and its proven xcframework packaging outweigh swift-bridge's ergonomics for a
telemetry app that will grow many typed values. The generated bindings are kept
**out of the coverage metric** (they are generated glue, not hand-written
logic); only the thin `RaceStudioCore` wrappers are measured.

## Decision 2 — Session handle + windowed accessors (not whole-session copy)

Bulk telemetry stays **owned in Rust**. Swift receives an **opaque session
handle** (a UniFFI `Arc<Object>`), and pulls data through **windowed accessors**
— e.g. `session.channel(id, range:)`, `session.downsampled(id, width:)` —
returning only the samples a view needs.

### Options considered

- **Whole-session copy across FFI** — decode in Rust, return the entire session
  (all channels, all samples) as UniFFI records. Simple, but copies tens–hundreds
  of MB across the boundary per open, duplicates it in Swift memory, and stalls
  the UI. Rejected.
- **Session handle + windowed accessors (chosen)** — Rust owns the decoded
  session behind an `Arc`; Swift holds the handle and requests bounded windows
  (visible time range, target pixel width) on demand. Bounded memory, cheap
  crossings, and downsampling happens in Rust where the data lives. This matches
  how the UI actually consumes data (a viewport at a time).

### Consequences

- `racestudio-ffi` will expose an **opaque `Session` object** plus value-typed
  accessors returning bounded slices; M1 decode issues build against this shape.
- Downsampling/resampling for display is a **Rust-side** concern (M3), invoked
  through windowed accessors — never by shipping raw samples to Swift.
- Coverage: the generated bindings live in `app/Generated/` (excluded from the
  `RaceStudioCore` metric); Swift-side logic stays thin and testable.
- Build: the xcframework is a git-ignored artifact built by
  `scripts/build_xcframework.sh` (universal arm64 + x86_64) and rebuilt on demand
  by the coverage gate; only the generated `.swift` is checked in.

## References

- Issue 0.4 (this pipeline), M1 decode issues (consume the session handle).
- [[racestudio-macos-project]] architecture (Rust core + UniFFI + SwiftUI).
