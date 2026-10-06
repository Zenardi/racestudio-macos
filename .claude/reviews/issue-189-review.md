# Review: issue #189 — Video + Data view (HUD over the player, synced plot/map, overlay editor)

**Reviewed**: 2026-10-06
**Branch**: feature/189-video-data-view → main
**Decision**: APPROVE — the fourth pass was clean (see below)

## Summary

The Video Review panel becomes the **Video + Data** workspace. The footage
gets a live telemetry HUD drawn on the visible picture. A lap strip plot (speed
and RPM) sits under it, and the track map sits over the lap × sector grid. All
of them run on one clock. The same panel hosts an overlay editor.

- **Core (`RaceStudioCore`, test-first).**
  - `VideoDataViewModel` and its `+Laps` extension;
  - `LapStripPlot`;
  - `OverlayEditorModel` and its `+Geometry` extension;
  - `OverlayWidgetOption`;
  - `OverlayAccessibilitySummary`;
  - `VideoDataPaneLayout`;
  - `ProjectDocument` v8, which adds `videoData` and migrates v7, v6 and v5 files;
  - `ProjectLoadNotice`;
  - `TelemetryFrame.hasSameReadings(as:)`.
- **Shell.**
  - `VideoDataPanel`, which replaces `VideoReviewPanel` on the `videoReview` rail entry;
  - `OverlayHUDView`: an `AVPlayerView` plus a layer-backed HUD on the visible
    video rect, rendered on a private serial queue at the displayed pixel size;
  - the editor canvas and inspector;
  - the **Video** menu;
  - the workspace-bar load notice.

## Process

`/ecc:code-review` in local mode over `git diff origin/main...HEAD`. It ran as a
self-review, plus an independent `swift-reviewer` agent working read-only on the
same diff. Every Core fix was test-first. The new tests failed first, either on a
missing symbol or on the assertion, and the RED was confirmed by running them.

## Found while building (before review)

- **`make run` showed `⚠️MISSING:` for every localized string.** The dev bundle
  never installed the string catalog's resource bundle. This was pre-existing.
  `build_app.sh` already does it for releases. **Fixed**: `run_app.sh` copies it.
- **The overlay layout's per-kind options lived in the shell.** **Fixed**: moved
  to Core as `OverlayWidgetOption` and `OverlayWidgetKind.editableOptions`, with
  tests. That keeps the shell free of logic.

## First pass — findings and resolution

Self-review plus `swift-reviewer` over `origin/main...d6eec22`.

### HIGH

1. **The whole window redrew on every video frame and every drag update.**
   `AnalysisWindowView` held the data model and the editor as `@StateObject`,
   which observes them. (Self-review caught it; the reviewer confirmed it.)
   **Fixed**: the four video models live in one `VideoWorkspace` holder. It is
   made lazily and never publishes. Only the views that draw a model observe it.

### MEDIUM

2. **Telemetry was not reloaded for an overlay or split change made while the
   panel was off screen.** **Fixed**:
   `VideoDataViewModel.needsTelemetryReload(channels:)` records the sectors and
   channels each load was made for (test-first). The panel asks it on appear and
   on each change.
3. **The splitter dragged in local coordinates, and its cursor push/pop could
   unbalance.** **Fixed**:
   - drags use the global coordinate space;
   - a drag is previewed locally and written on release;
   - the cursor is pushed and popped in pairs, and popped on disappear.
4. **The HUD could freeze during a fast widget drag.** Every renderer change
   dropped the render in flight. **Fixed**: only clearing the HUD drops a
   render. A finished render is shown, and a newer one is queued.
5. **The `videoBounds` KVO was unverified.** **Fixed**: the visible rect is
   `AVMakeRect(presentationSize, bounds)`, with documented KVO on
   `currentItem.presentationSize`. `videoBounds` is the fallback.
6. **The arrow-key monitor was too greedy.** **Fixed**:
   - modified arrows are ignored;
   - so are arrows while a text field or control owns the keyboard;
   - a click on the video takes the keyboard back.
7. **The UndoManager and the editor history could desync.** **Fixed**:
   - `undo()` and `redo()` are internal, so the shell undoes only through the
     manager;
   - the history resets (in both stacks) when the panel goes off screen, so ⌘Z
     elsewhere never edits a hidden HUD;
   - the manager is re-attached when the environment changes it.

   **Justified as is**: after more than 100 edits, the window's unbounded
   `UndoManager` keeps entries for steps the editor dropped, and those do
   nothing. Bounding them would mean changing `levelsOfUndo` on a manager the
   whole window shares.

### LOW

8. **Gesture bookkeeping.** **Fixed**, test-first in `OverlayEditorGestureTests`:
   - an edit, an undo or a nudge made during an open drag first records the drag;
   - a click without movement changes nothing;
   - the gesture's widget is found by id;
   - resize begins explicitly;
   - a drag cut short ends on disappear.
9. **The VoiceOver sentence was built every frame.** **Fixed**: it is built only
   while VoiceOver runs.
10. **The renderer cache keyed on the kart id.** **Fixed**: it keys on the whole
    `Kart`, so a rename refreshes the badge.
11. **Toggling a pane rebuilt the player.** **Fixed** by the single-stack splitter.
12. **Transport details.** **Fixed**:
    - a scrub also pauses a player that is about to play;
    - the frame observer is capped at 60 Hz;
    - the `start(driving:)` doc now matches what it does;
    - Play Lap is disabled through Core `canPlayLap` (tested), and the menu beeps
      when no lap is on film.
13. **Docs and localization.** **Fixed**:
    - the `plotLap` doc;
    - lap labels, Lap −/+, tooltips, Dismiss, the save-failure alert, and
      non-math load diagnostics are now localized;
    - the editor shows "Unsaved overlay changes".

    The store's own warning lines were still English at this point; the
    second pass's typed warnings fix that.
14. **Test gaps.** **Fixed**: the UndoManager walk over a drag and a nudge, undo
    and commands during an open drag, zero-move clicks, and history reset.

## Second pass — on 434e3a8

The same reviewer re-read `d6eec22..434e3a8`. Of the 13 first-pass findings, 12
were fixed and #3 was partly fixed. The pass agreed with the justification
for the 100-step bound. Each item below was fixed in 1f6c147, test-first where
it is in Core.

- **N1 (MEDIUM). Play Lap could stay wrongly disabled.** The button observed
  only the data model, which doesn't publish on attach, remove or re-sync.
  **Fixed**: it observes the review too.
- **N2 (LOW). `resetHistory()` dropped an open drag.** The window was never
  told, so a save would lose it. **Fixed**: the open drag is recorded first
  (with a test). The handbook now says that leaving the view clears the
  history.
- **N3 (LOW). An arrow key during a drag made the widget jump.** **Fixed**:
  `nudge` returns `false` and is ignored, with the key not claimed, while a
  drag is open (with a test).
- **N4 (LOW). Splitter details.** **Fixed**:
  - the preview uses `@GestureState`, which resets on a cancel;
  - each pane has its own slot in one stack, and a hidden pane is not built.
- **N5 (LOW). VoiceOver turned on while paused got no value.** **Fixed**: the
  value follows `isVoiceOverEnabled`.
- **Store warnings in English, conditionally agreed.** Since this PR is the
  first to show them, they are **fixed**, not deferred.
  - `ProjectLoadWarning` (test-first) keeps the old English text for the log.
  - It localizes the notice in en and pt-BR.
  - `ProjectDocument.warnings` is now computed over the typed values.

## Third pass — on 1f6c147

Every second-pass item was confirmed fixed, with no MEDIUM or HIGH
regressions. Two LOW items were found:

- **L1. A lost mouse-up left a gesture open.** Nudges stayed disabled until the
  next click. **Fixed**: the canvas abandons any open gesture on disappear and
  when the app resigns active.
- **L2. The VoiceOver publisher could deliver off the main thread.** **Fixed**:
  `.receive(on: DispatchQueue.main)`. The value also reads
  `isVoiceOverEnabled` directly, so it doesn't depend on KVO alone.

## Fourth pass

FOURTH_PASS_PENDING

## Validation

| Check | Result |
|---|---|
| Swift tests (CLT route, debug) | 2163 passed |
| swiftlint --strict | 0 violations |
| Shell (`swift build --product RaceStudio`) | builds, no new warnings |
| Handbook lint (`handbook_links_test`) | 6 passed |
| Coverage, `RaceStudioCore` lines | 98.11%; new files 97.3–100% |
