# Review: issue 223, the HUD's background opacity

## Review of 89215da

Scope:
- `OverlayLayout.plateOpacity`: 0–1 in whole percent, 88 % to start, read leniently, saved with the layout.
- `OverlayTheme.withPlateOpacity` and `plateFill` (no plate at 0); the renderer draws with the layout's opacity.
- `OverlayEditorModel.setPlateOpacity`, the inspector's slider, the strings, the handbook.
- The legibility proof: the plate from 88 % up, the outline below.

Method: my own read plus an independent Swift reviewer.

What holds:
- **One path to the plate.** Every plate is drawn from the widget's palette, built from the renderer's theme; the
  renderer is the only production place a theme meets a layout, and both the live HUD and the export build it from
  the layout. Nothing reads the theme's default opacity any more.
- **The renderer cache** is keyed by the whole layout, so each change rebuilds it.
- **At 0 % nothing is drawn**: `drawPlate` returns early without a plate.
- **Back-compat**: older layouts, presets, last HUDs and workspaces read 88 %; an older build ignores the key; the
  theme still saves only its id.
- **Goldens** are unchanged at 88 %.
- **Quit or close mid-drag**: the autosave's flush and `resetHistory` close an open drag first.

Findings:
- **MEDIUM, fixed: the export's built-in presets ignored the opacity.** Choosing *Kart coaching* in the export sheet
  burned 88 % plates whatever the HUD was set to. A preset chosen there is now drawn with the HUD's opacity (the
  default without a HUD). `test_the_export_presets_keep_the_huds_opacity` failed first.
- **LOW, fixed (documented): applying a saved preset keeps the HUD's opacity**, as it keeps the units and theme —
  it is the HUD's setting, not the preset's. Said in `apply`'s documentation and the handbook, and tested.
- **LOW, fixed: an undo mid-drag split the rest of the drag into a step per tick.** The slider now has its own
  adjust mode (`beginPlateAdjustment` / `endPlateAdjustment`): after an undo the rest of the drag is still one step.
  `test_an_undo_mid_drag_keeps_the_rest_of_the_drag_one_step` failed first.
- **LOW, fixed: the slider and a widget drag shared one open gesture.** `beginGesture` now records a gesture still
  open first, and the slider ends its drag when it goes away. `test_a_widget_drag_after_an_open_slider_drag_records_both`
  failed first; `test_closing_mid_drag_keeps_the_opacity` covers the workspace and the last HUD.
- **LOW, fixed: the legibility claim below 88 % rested on a one-pixel outline.** The outline now thickens as a
  translucent plate fades (twice at 0 %), and the handbook says what it guarantees — every glyph's dark edge meets
  4.5:1 — and that a faint background over busy, mid-grey video is still harder to read.
  `test_as_the_plate_fades_the_outline_thickens` and the rasterised no-plate check over white.
- **LOW, fixed: unlit bars and guides went faint without a plate.** Their alpha rises as the plate fades (0.35 to
  0.7). `test_as_the_plate_fades_the_guides_strengthen`.
- **LOW, fixed: the renderer silently overrode a passed theme's opacity.** Documented (the layout's opacity wins,
  and the theme's own opacity is only a starting point) and tested.
- **LOW, fixed: a theme took any opacity.** `withPlateOpacity` holds it to 0–1 in whole percent, as the layout does.

| Check | Result |
|---|---|
| Tests before the change (RED) | Compile failure on the missing API; then the review's tests above on 89215da |
| Full suite in parallel / `--no-parallel` (rebased on #222) | 2637 / 2637 passed |
| RaceStudioCore coverage | 99.39%; `OverlayLayout`, `OverlayTheme`, `OverlayWidgetDrawer`, `OverlayEditorModel` at 100% |
| SwiftLint | 0 violations |
| App shell build (CLT + Xcode's SwiftUI macro plugin) | Builds |
| Goldens | Unchanged at 88 % |
| Tooling self-tests (CLT selected) | All pass except `swift_gate_test` (2), which fails the same way on clean `origin/main` |
| Legal gate | No device-area changes |
