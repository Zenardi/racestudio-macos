# ADR 0003 — Plot rendering: Metal-primary line strips with a Swift Charts fallback

- **Status:** Accepted
- **Date:** 2026-07-17
- **Milestone:** M4 (issue 4.1). Consumed by 4.2 (lap overlay), 4.3 (GPS map),
  and 4.7 (shared workspace cursor), which build on the same component.

## Context

The core analysis surface is a multi-channel line plot that overlays several
channel traces on a shared x-axis (switchable between **time** and
**distance**) with interactive zoom/pan. A single lap can hold **tens of
thousands of samples per channel**, and several channels overlay at once, so the
renderer must redraw a large vertex count smoothly during a continuous pinch or
drag gesture.

Two rendering technologies are available under the macOS 13+ deployment target,
both present in the Command-Line-Tools SDK this project builds against
(`MetalKit.framework`, `Charts.framework`):

- **Swift Charts** — declarative, correct, accessible, trivial to write; but it
  rebuilds its view tree per frame and is not designed for 50k+ `LineMark`s at
  gesture frame rates.
- **Metal (`MTKView`)** — a GPU line-strip pass. Each frame it re-decimates only
  the **visible** window to at most one min/max pair per pixel column
  (`plotPolyline`/`envelope`, bounded by the view width, not the sample count),
  uploads a small vertex buffer, and the GPU draws the strips; more code, but the
  only option that keeps a dense plot interactive.

## Decision

Render the plot with **Metal as the primary path** (an `MTKView` drawing one
line strip per trace) and **Swift Charts as a correctness / low-density
fallback**. Crucially, **the numeric model is identical for both** and lives in
`RaceStudioCore`, not in either view:

- `LinearScale` — value↔pixel affine map (both paths place points with it; the
  view's tick/gridline overlay uses it too).
- `TickGenerator` — "nice" 1/2/5 × 10ⁿ axis ticks, drawn as the shared
  gridline/label overlay above both renderers.
- `PlotViewport` — zoom/pan window math (anchor-preserving, min-span guarded,
  non-finite-input safe).
- `PlotModel` — `XAxisMode`, `ChannelTrace`, `hitTest`, `plotDomain`, and the
  **min/max `envelope` decimation** behind `plotPolyline`, which both renderers
  consume over the same visible window so a dense channel draws the *same visible
  min/max envelope* regardless of path (the 4.1 parity requirement).

The SwiftUI views in the `RaceStudio` shell
(`TimeDistancePlotView`, `MetalPlotRenderer`, `SwiftChartsPlotFallback`) are
**thin**: they own gestures, layout, and drawing only, and carry no numeric
logic. All testable geometry is therefore in the 95%-coverage core, and the
views are structurally excluded from the coverage metric (per
[the Definition of Done](../DEFINITION_OF_DONE.md) coverage split).

## Consequences

- The plot stays interactive on dense laps because the Metal path's per-frame
  CPU work is the visible-window `envelope` decimation — bounded by the pixel
  width, so zooming in *reduces* work while *revealing* detail — followed by a
  GPU line-strip draw, rather than Swift Charts rebuilding an O(samples) view
  tree every frame.
- Because both paths share `RaceStudioCore`'s scales and `envelope`, switching
  between them (or using Charts for sparse channels / screenshots / debugging)
  produces the same picture — asserted by `test_dense_envelope_parity_min_max`.
- Metal shader/runtime correctness is not exercised by the unit-test gate (no GPU
  in CI); the risk is contained by keeping every decision the renderer makes
  (scale, ticks, decimation, hit-testing) in the tested core, leaving the view a
  thin conduit that `swift build` in the e2e phase compiles.
- Later issues (4.2 overlay, 4.3 map, 4.7 cursor) extend the same component and
  reuse the same core geometry rather than re-deriving it.

## References

- Issue 4.1 (this component); consumers 4.2, 4.3, 4.7.
- Core geometry: `app/Sources/RaceStudioCore/Plot/`.
- Views: `app/Sources/RaceStudio/Views/`.
- FFI boundary / analysis source: [ADR 0001](0001-ffi-boundary.md), issue 3.8.
