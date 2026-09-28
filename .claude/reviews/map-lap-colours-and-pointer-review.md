# Review: track map lap colours, per-lap markers, snapshot imagery, wheel/middle-drag input

**Reviewed**: 2026-09-28
**Branch**: feature/map-lap-colours-and-pointer → main
**Decision**: APPROVE (after fixes below)

## Summary
Colours each selected lap with its selection colour (legend + "By lap"/channel picker), draws one
marker per lap at the cursor's time into the lap, replaces the live MKMapView backdrop with
MapKit snapshots placed by two anchor coordinates (so imagery scales with the line at any zoom),
and adds mouse-wheel zoom about the pointer, middle-button pan and pointer-anchored pinch.

## Findings

### CRITICAL
None

### HIGH
None — the root cause of "zoom buttons not working" (the live map's learned zoom limit capping
and snapping back the viewport, and disabling zoom-in outright on a small circuit) is removed
with the live map itself.

### MEDIUM
- (fixed) `TrackMapImageryLoader`: one failed snapshot held back the other forever, leaving no
  imagery. It now publishes whatever arrived once every fetch has finished.

### LOW
- (fixed) `MapPointerInput`: back/forward mouse buttons are "other" buttons; they would have
  started a pan and been swallowed. Only button 2 (the wheel) pans now.
- (accepted) The fine snapshot is 2048 pt (about 64 MB decoded at 2x) while imagery is on; the
  coarse one is 1024 pt. Only held while a backdrop is selected.
- (accepted) The scroll monitor claims wheel events over the map's bounds in its window; nothing
  else in the window overlaps the map pane.

## Validation Results

| Check | Result |
|---|---|
| Build (RaceStudio product) | Pass |
| Lint (swiftlint, 285 files) | Pass, 0 violations |
| Tests (RaceStudioCoreTests) | Pass, 1323 tests |
| Coverage (changed Core files) | 100% lines; Core total 98.99% |
| Visual (real views, user's laps 13+14, satellite) | Pass: fit, 3x wheel zoom, 0.4x, middle-drag |

The visual harness drove queued synthetic events; synthetic scroll events carry no window, so the
harness copy of `MapPointerInput` accepted window 0. Real hardware events carry their window.

## Files Reviewed
Added: MapImagery.swift, MapPointerInput.swift, TrackMapImagery.swift, TrackMapPanel.swift (moved),
3 test suites. Modified: TrackMapModel, AnalysisWindowModel(+TrackMap), GeoProjection,
MapViewport, TrackMapView, TrackMapControls, AnalysisWindowView, MapViewportTests, handbook.
Deleted: TrackMapBackdropView.swift.
