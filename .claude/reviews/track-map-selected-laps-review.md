# Review: Track Map shows only the selected laps

**Reviewed**: 2026-09-27
**Branch**: feature/track-map-selected-laps → main
**Decision**: APPROVE with comments

## Summary
The map is scoped to the selected laps' time windows. Each lap is its own run, so no line joins two
laps. Sector marks measure one lap, the colour scale spans only the selected laps, and an empty
selection shows a prompt instead of the whole session. All decisions are in Core and 100% covered.

## Findings

### CRITICAL
None

### HIGH
None. Two were found and fixed during review:
- `sectorDistances` was a computed property allocating an O(lap fixes) array, read twice per render,
  and the panel re-renders on every cursor move. It is now stored in `init`.
- A selected lap outside GPS coverage showed "No GPS data for this session", which is false. It now
  reads "No GPS data in the selected laps" (`hasGPSTrack`, tested).

### MEDIUM
- The window opens with no lap selected, so the Track Map opens on the prompt. That is what was asked
  for, but it is a visible behaviour change from showing the whole session.
- The shared cursor still starts at session time 0. With a later lap selected, the marker is hidden
  until the cursor enters that lap. The follow-up (the bottom cursor spans only the selected laps)
  resolves this.

### LOW
- The new hint strings are literals, not catalog entries, matching the sibling hints in the same file.
- Lap windows and GPS times share the logger clock (the #164 fix aligned them to ~0.4 s), so a fix
  near a lap boundary may land in the neighbouring lap. That is not visible at map scale.

## Validation Results

| Check | Result |
|---|---|
| Swift tests (CLT route) | Pass — 1263/1263 (27 new) |
| Coverage | TrackMapModel 100%, AnalysisWindowModel+TrackMap 100%, AnalysisWindowModel 100% lines |
| SwiftLint --strict | Pass — 0 violations |
| App build (`RaceStudio` product) | Pass |

## Files Reviewed
- app/Sources/RaceStudioCore/Map/TrackMapModel.swift (Modified)
- app/Sources/RaceStudioCore/Workspace/AnalysisWindowModel.swift (Modified)
- app/Sources/RaceStudioCore/Workspace/AnalysisWindowModel+TrackMap.swift (Added)
- app/Sources/RaceStudio/Views/TrackMapView.swift (Modified)
- app/Sources/RaceStudio/Views/AnalysisWindowView.swift (Modified)
- app/Tests/RaceStudioCoreTests/TrackMapLapScopeTests.swift (Added)
- app/Tests/RaceStudioCoreTests/AnalysisWindowTrackMapLapTests.swift (Added)
- app/Tests/RaceStudioCoreTests/AnalysisWindowTrackMapTests.swift (Modified)
