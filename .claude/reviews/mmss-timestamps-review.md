# Code Review: mm:ss timestamps

**Reviewed**: 2026-09-27
**Scope**: `TimecodeFormatter.swift` (new), `ChannelFormatter.swift`,
`LapTimeFormatter.swift`, `LapScrub.swift`, `MeasuresBar.swift`
**Decision**: APPROVE (one HIGH finding found and fixed during review)

## Summary

Renders time values as `mm:ss.mmm` instead of raw milliseconds or bare seconds.
Applied to the five `ms`-unit timing channels, the scrubber readout, and the per-lap
cursor chips. Review surfaced a latent crash — in the new code *and* in the existing
`LapTimeFormatter` — which is fixed and pinned by tests.

## Findings

### CRITICAL
None.

### HIGH
1. **`Int(Double)` traps on a finite-but-huge value** — FIXED, in both formatters.
   `guard seconds.isFinite` does not bound magnitude: `1e300` is finite, and
   `Int((1e300 * 1000).rounded())` raises
   *"Double value cannot be converted to Int because the result would be greater
   than Int.max"*. Reachable, because a channel value is whatever the decoder
   produced and `ChannelFormatter` forwards any finite value — so a corrupt sample
   would crash the app while drawing a readout. Now `Int(exactly:)` with the
   placeholder as the fallback. `LapTimeFormatter` carried the identical bug against
   lap durations and is fixed the same way; it was not introduced here but sits one
   line from the new code and is the same class of defect.

### MEDIUM
None.

### LOW
2. **A sentinel now looks like data.** `Best Today Diff`, `Prev Lap Diff` and
   `Ref Lap Diff` hold a constant `-12290` for the whole of the user's session —
   AiM's "no value" marker. It used to read `-12290.00 ms` (obvious nonsense) and now
   reads `-00:12.290` (a plausible gap). Deliberately **not** special-cased: a
   -12.290 s gap is a perfectly legitimate value, so filtering it would risk hiding
   real data to tidy one file. Flagged to the user instead.
3. **Two formatters now exist** — `LapTimeFormatter` (`m:ss.mmm`, unpadded,
   non-negative) and `TimecodeFormatter` (`mm:ss.mmm`, padded, signed). Deliberate:
   lap tables are asserted against the unpadded form in existing tests, and only the
   new one needs signed output. Documented on the type so the distinction is not
   mistaken for an accident.

## Checklist

| Category | Result |
|---|---|
| Correctness | Rounding carries into seconds/minutes; hour promotion; signed values; negative-zero suppressed; overflow guarded. All pinned. |
| Type safety | No force-unwraps; `Int(exactly:)` rather than a trapping conversion. |
| Pattern compliance | Reuses `ChannelFormatting.emDash`, matching the app's existing absent-value placeholder. |
| Security | Nothing applicable — pure formatting. |
| Performance | No allocation beyond the returned string; called per rendered cell. |
| Completeness | 27 new tests, including the overflow path and the untouched non-time units. Verified against real session data. |
| Maintainability | One `enum`, 5 members; why `ms` is special-cased is documented at the call site. |

## Validation

| Check | Result |
|---|---|
| Swift tests | Pass — 1231 / 134 suites |
| `swiftlint --strict` | Pass (0 violations) |
| Core coverage | `TimecodeFormatter` 100%, `ChannelFormatter` 100%; total 98.9% |
| Shell build | Pass |
| `cargo test --workspace` | Pass |
| `make e2e` | Pass |
