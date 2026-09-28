# Review: the bottom scrubber spans only the selected laps

**Reviewed**: 2026-09-27
**Branch**: feature/scrub-selected-laps → main
**Decision**: APPROVE with comments

## Summary
Session-mode scrubbing now covers only the selected laps, joined end to end in time order, with a
mark at each join. With none selected it still sweeps the whole session. After a lap-selection change
the cursor is moved into the selected laps when it sits outside them, which also closes #174's
"marker hidden until you drag into the lap" gap. All logic is in Core (`LapScrub`) and tested.

## Findings

### CRITICAL
None

### HIGH
None

### MEDIUM
- The segmented control still reads **Session | Lap**. With laps selected, "Session" now means "the
  selected laps". The slider help and the picker tooltip say so (the tooltip was stale and is fixed
  here), but the label itself was kept to avoid churn in a persisted `@AppStorage` value. A rename
  to "Laps" is a cheap follow-up if it reads wrong in use.
- Deselecting the lap the cursor is in (with others still selected) moves the cursor to the earliest
  remaining lap. That is consistent with "the cursor lives in the selected laps", but it is a jump the
  user did not directly ask for.

### LOW
- `segments` is recomputed per access (filter + sort over the session's laps, tens of items). It is
  not worth caching.
- The slider value is now a position along the joined laps, not absolute seconds. Only `MeasuresBar`
  consumes it, through `time(for:)`, so nothing else observes the change.

## Validation Results

| Check | Result |
|---|---|
| Swift tests (CLT route) | Pass — 1278/1278 (15 new) |
| Coverage | LapScrub.swift 100% lines; AnalysisWindowModel.swift 100% lines |
| SwiftLint --strict | Pass — 0 violations |
| App build (`RaceStudio` product) | Pass |

## Files Reviewed
- app/Sources/RaceStudioCore/Workspace/LapScrub.swift (Modified)
- app/Sources/RaceStudioCore/Workspace/AnalysisWindowModel.swift (Modified)
- app/Sources/RaceStudioCore/Workspace/AnalysisWindowProject.swift (Modified)
- app/Sources/RaceStudio/Views/MeasuresBar.swift (Modified — doc + tooltip only)
- app/Tests/RaceStudioCoreTests/LapScrubTests.swift (Modified)
