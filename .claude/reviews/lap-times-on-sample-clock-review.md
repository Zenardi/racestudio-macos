# Review: lap windows on the samples' clock

**Reviewed**: 2026-09-28
**Branch**: fix/lap-times-on-sample-clock → main
**Decision**: APPROVE

## Summary
Lap times are decoded counted from the first lap's start (as libxrk does), but channel and
GPS samples keep the raw logger timecode. The FFI lap listing and `segment_laps` paired the
two unshifted, so every lap windowed the data `first_lap_origin` early — 31.012 s in the
user's stint-1, which put lap time 0 at a hairpin ~140 m from the finish line on the track
map and cut the wrong data into per-lap overlays, readouts, stats and split times. The CSV
writer already applied the origin, which is why its export matched AiM byte-for-byte.

Fix: `Session::lap_timecode_origin_s()` (0 without lap markers, e.g. CSV imports), added to
lap start/end in `SessionHandle::laps` / `list_laps` (and their window filter) and in
`segment_laps`. The decoder's own lap times and every libxrk golden are unchanged.

## Findings
### CRITICAL / HIGH
None.
### MEDIUM
None.
### LOW
- The laps golden comparisons (Rust analysis + Swift FFI parity) now add the origin rather
  than comparing raw: the oracle stays the oracle; the tests state the clock shift.

## Evidence
- User's stint-1 through the real FFI: every lap start within 2.3 m of AiM's own GPS at its
  beacon markers (was ~140 m, 31 s early).
- stint-2: 20–21 m from stint-1's line — AiM's own export shows the same 20 m, so that is the
  logger's lap trigger, not the app.
- New regression tests fail with the shift disabled (verified) and pass with it.

## Validation Results
| Check | Result |
|---|---|
| cargo test --workspace | Pass (38 suites) |
| cargo clippy -D warnings / fmt | Pass |
| Swift RaceStudioCoreTests | Pass (1323) |
| SwiftLint | Pass (0 violations) |
| make xcframework (bindings) | Regenerated (doc comments only) |
