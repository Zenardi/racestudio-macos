# Review: issue 213, turning overlay widgets on or off at export

## Review of 6d5fb05

Scope:
- `ExportSheetInput.workspaceOverlay` and `overlaySession`.
- `ExportWidgetItem`.
- `ExportSheetModel`'s widget list and switches, and `layout(locale:)`.
- `ExportPreferences.widgetSwitches` and the store's `widgets` field.
- In the shell: the sheet's list, plus the coordinator, the host and the analysis window's kart wiring.
- The en and pt-BR strings, and the handbook.

What holds:
- **For this export only.**
  - `layout(locale:)` changes `isVisible` on a copy of the chosen overlay. `OverlayLayout` is a value type,
    so the workspace's overlay, the presets and the HUD's layout never change (tested).
  - The draw list (`resolved(for:)`) already skips hidden widgets, so a widget switched off is drawn on
    no frame. Every other widget keeps its frame, anchor, plate and options (`layout == expected`).
- **The widget's own state is the default.**
  - A switch is stored only while it differs from the overlay's own state. Switching back forgets it
    (tested), so the widget follows its overlay again.
  - A switch for an id the overlay doesn't have is never applied (tested).
- **Widgets the session can't feed.**
  - Availability comes from the same `OverlayWidgetKind.availability(for:)` the editor and the renderer
    use, with the session's garage kart.
  - Such a widget lists as off, with its reason. Its switch is disabled and `setWidget(…, isOn: true)`
    is refused (tested).
  - A degraded widget, for example pedals with only a brake channel, can still be switched, and shows
    why it is degraded.
- **Every widget off.** The plan doesn't depend on the overlay, so the export still runs and draws an
  empty overlay. The sheet says *No overlay will be drawn* (tested).
- **Remembered.**
  - The switches are saved with the other last-used choices when *Export…* is pressed, keyed by
    overlay choice.
  - Reading is lenient:
    - settings saved before this change read with no switches;
    - an unknown overlay or a non-object is dropped;
    - only JSON booleans count, so `1` and `"off"` are dropped (CFBoolean check) (tested).
- **The workspace overlay is read when the sheet opens.** It is the editor's layout, exactly as the
  export read it before. The sheet is modal, so the editor can't change while it is open.
  `hasWorkspaceOverlay` is now derived from it, so the two can't disagree.
- **Strings.** All four keys are in en and pt-BR, typed in `L10n.Key`, and covered by the catalog
  tests. The catalog diff only adds lines.

Findings:
- **MEDIUM, fixed: Show All and Hide All published once per widget.**
  - Each called `setWidget` in a loop. Every call rebuilt the chosen layout and reassigned the
    `@Published` switches, so one tap sent n change notifications and did O(n²) work.
  - A single `switchWidgets` pass now builds the new switches and assigns them once, and not at all
    when nothing changes.
  - `test_show_all_and_hide_all_change_the_switches_at_once` failed first, with one change per widget,
    and now sees one change per tap.
- **LOW, fixed:** the sheet passed the `@MainActor` methods `showAllWidgets` and `hideAllWidgets` as
  button actions by reference. They are now closures, like the sheet's other buttons, so no actor
  isolation is dropped in the conversion.
- **LOW, kept: the *Current overlay* switches carry over between workspaces.**
  - They are keyed by widget id (`speed`, `gForce`…) under one `workspace` choice. A switch saved in one
    workspace applies to a same-id widget in another.
  - This is what "per overlay choice, like its other last choices" asks for. It only applies while it
    differs from that overlay's own state.
- **LOW, kept: switches for widgets that are gone stay in the stored settings.** They are ignored when
  used, and they cost a few bytes in `UserDefaults`.
- **Note: keyboard and VoiceOver are not unit-testable here.**
  - Each row is a SwiftUI `Toggle` with a text label (the widget's name, plus the reason when there is
    one) in the sheet's `Form`. A `Toggle` is reachable from the keyboard and reads its label and state.
  - It goes on the manual checklist, along with the shell's compile, which only CI's e2e step does
    (this Mac's Xcode licence is unaccepted).

| Check | Result |
|---|---|
| Tests before the change (RED) | Compile failure on the missing API (`overlaySession`, `workspaceOverlay`, `widgetItems`, …); then the one-change test (one publish per widget) |
| Full suite in parallel / `--no-parallel` (rebased on main with #211) | 2489 / 2489 passed |
| RaceStudioCore coverage | 99.38%; the store, `VideoDataViewModel+Export` and the new model code at 100% (the 2 lines `ExportSheetModel` misses are `init`'s older closures) |
| SwiftLint | 0 violations |
| Tooling self-tests (CLT selected) | All pass except `swift_gate_test` (2), which fails the same way on clean `origin/main` |
| Legal gate | No device-area changes |
