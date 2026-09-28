# Review: map imagery scale, framing, and zoom/pan controls

**Reviewed**: 2026-09-27
**Branch**: fix/map-scale-and-controls → main
**Decision**: APPROVE with comments

## Summary
The satellite imagery was drawn at a different scale from the racing line (reported in the user's
screenshot, ~2x). Root cause, measured: MapKit will not zoom past its limit (~0.54 m/pt on a Retina
display; ~1.1 m/pt at 1x, which matches the screenshot) and silently shows a wider region than it
was asked for, while the line was still drawn at the requested scale. The line is now drawn at the
scale the map reports. Also fixed: the framing trim clipped hairpins off clean laps (measured 8–10%
per axis on the user's laps). Adds zoom in / out / fit, a pan pad, pinch, and ⌥-drag.

## Evidence
- MapKit honours an exact region down to its limit, then widens: asked 0.24 m/pt → shown 2.25x
  wider (on-screen probe, backing scale 2).
- Ground truth (MapKit's own projection on a satellite snapshot) puts the user's lap 13 at the
  circuit's real size, so the GPS data is correct.
- One harness run of the real TrackMapView over imagery showed the line on the tarmac. Later harness
  captures drew no tiles at all, even with the change under suspicion disabled (an environment
  artefact), so **the clamped case was not verified visually end to end**. It rests on the probe plus
  the unit-tested scale math.

## Findings

### CRITICAL
None

### HIGH
None. Found and fixed during review: a transient whole-world region (an unsized map) or a stale
off-centre region could have been taken as the zoom limit and shrunk the line. `zoomLimit(forRequest:in:)`
now rejects both (tested).

### MEDIUM
- The learned limit is in pixels per degree for the current display. Moving the window between a
  Retina and a 1x display keeps the old limit until the backdrop style changes. The drawing still
  follows the next region MapKit reports, so this only affects how far "zoom in" goes.
- MapKit's own gestures stay disabled. Pan is ⌥-drag or the arrows, because a plain drag already
  moves the cursor.

### LOW
- The control strings are literals, matching the other track-map strings.

## Validation Results

| Check | Result |
|---|---|
| Swift tests (CLT route) | Pass — 1302/1302 (24 new) |
| Coverage | MapViewport.swift 100% lines; GeoProjection.swift 100% lines |
| SwiftLint --strict | Pass — 0 violations |
| App build (`RaceStudio` product) | Pass |

## Files Reviewed
- app/Sources/RaceStudioCore/Map/MapViewport.swift (Added)
- app/Sources/RaceStudioCore/Map/GeoProjection.swift (Modified)
- app/Sources/RaceStudio/Views/TrackMapView.swift (Modified)
- app/Sources/RaceStudio/Views/TrackMapBackdropView.swift (Modified)
- app/Sources/RaceStudio/Views/TrackMapControls.swift (Added)
- app/Tests/RaceStudioCoreTests/MapViewportTests.swift (Added)
- app/Tests/RaceStudioCoreTests/GeoRegionTests.swift (Modified)
