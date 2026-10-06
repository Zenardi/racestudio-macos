# Review: issue #186 — telemetry timeline (per-frame TelemetryFrame sampler)

**Reviewed**: 2026-10-06
**Branch**: feature/186-telemetry-timeline → main
**Decision**: APPROVE (second pass clean — see below)

## Summary
A new pure `RaceStudioCore/Telemetry/` module answers "what was the kart doing at
session time `t`?": role resolution (`TelemetryChannelMap`), contiguous
hint-searchable series, the lap clock, the live delta from `delta_t_series`, the
track position in the library preview's frame, and an immutable `Sendable`
`TelemetryTimeline` sampled sequentially (allocation-free) or at random with
identical frames. Golden frames come from an independent libxrk/numpy oracle.

## First pass — findings and resolution

### CRITICAL / HIGH
None.

### MEDIUM
1. `LiveDelta.Hints` identified its owner by address; a freed instance's address
   could be reused → stale curve. **Fixed**: the hint holds the owner; test carries a
   cursor across re-referenced timelines.
2. A cold delta cache fetches synchronously on the reader (main actor, workers);
   prefetch not cancellable. **Fixed**: cancellable `prefetch()`, async
   `prefetchDeltas()` / `prefetchingDeltaReference(_:)` off the main actor; the lazy
   path and idempotent duplicate fetches on a cold race are documented (justified
   instead of an in-flight guard).
3. No public `TelemetryFrame` initialiser for the renderer. **Fixed**.
4. `TelemetryRole.slot` could drift from declaration order. **Fixed**: pinned by a test.
5. `LapClock` assumed disjoint windows. **Fixed**: windows normalised (cut at the
   next beacon, reversed/empty dropped); property test incl. `Int.max` hints.
6. Greedy time sanitising dropped everything after a forward spike. **Fixed**: a lone
   forward spike is dropped alone; one shared filter for series and the track.

### LOW
7. `hint + 1` overflow. **Fixed**. 8. Hinted search claim at high rates. **Fixed**
   (galloping, O(log k)). 9. Heading jitter on a parked kart. **Fixed** (1 m of travel
   within 2 s). 10. GPS gap not rate-scaled. **Fixed** (median spacing). 11. G-trail
   indices / lag. **Fixed** (zero-based collection; lag documented). 12. Cursor
   allocation. **Fixed** (inline storage); no allocation-counting test (parallel test
   runner makes process-wide malloc stats flaky) — by construction. 13. Channel
   names / duplicate override. **Fixed** (WAT/H2O/EGT1; override by index). 14.
   O(n²) lap clock init. **Fixed** (one pass, same shared rule). 15. Frame unit docs.
   **Fixed**.

### Tests / oracle notes
Release budget verified (`-c release`); debug ceilings tightened; cold-cache
concurrency and negative-cache tests added; oracle uses the last valid lap, asserts
in-range/in-lap instants, adds track position and the sequential path at 12
instants, records the libxrk version; the shared issue-164 repair rule is stated in
`docs/DECODE_TOLERANCES.md`.

## Second pass

Every first-pass finding confirmed resolved or justified. Two LOW doc nits remained,
both fixed:
- The performance suite's header now gives the exact release command
  (`-Xswiftc -enable-testing`) and says the 50 ms assertion is manual-only (neither
  `make` nor CI builds the release configuration).
- `LapClock`'s doc no longer claims it can never disagree with the review grid: for
  malformed overlapping laps it takes the later lap, the grid the first listed.

## Validation Results

| Check | Result |
|---|---|
| Swift tests (CLT route) | Pass — 1634/1634 on the rebased tree |
| Telemetry under ThreadSanitizer | Pass — no reports |
| Coverage | Telemetry module 100% lines; RaceStudioCore 99.48% lines |
| SwiftLint --strict | Pass |
| App build (`RaceStudio` product) | Pass |
| Release performance | 18,000 sequential frames in ~2.7 ms (budget 50 ms) |
| Rust | Not touched |
