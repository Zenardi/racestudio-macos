# Review: issue #191 — Export Video with Overlay: export sheet, progress, docs and end-to-end acceptance

**Reviewed**: 2026-10-07
**Branch**: feature/191-export-video-ui → main (cut from d5d1b4e, v0.4.18)
**Decision**: APPROVE — three passes; the third found nothing above LOW, and both LOWs are fixed.

## Summary

This change puts the #190 export engine in the operator's hands and closes epic #145:

- **Core (`RaceStudioCore/VideoExport/`).**
  - `ExportSheetModel`: range, overlay and output choices, lap coverage with reasons,
    validation, a debounced live estimate, the sync warning and the suggested file name.
  - `ExportSettingsStore`: last-used choices, read leniently.
  - `ExportProgressModel`: the export's states, a smoothed ETA, and a message with a fix for
    every failure.
  - `ExportFlowModel`: which sheet is up and what a window owns.
  - `ExportCommandAvailability`, `ExportFileName`, `DelayScheduling`.
  - `VideoDataViewModel.exportSheetInput` / `exportOverlay`: the sheet's input, and the overlay
    drawn by the HUD's own renderer.
- **Shell.** ⌥⌘E and the panel button, the settings and progress sheets, `NSSavePanel`, Reveal
  in Finder / Open, and quit/close/Home guards.
- **E2E.** `OverlayExportEndToEndTests` (public sample + synthetic footage → synced → one lap at
  320×180), run by `scripts/e2e.sh` with the sample required.
- **Docs.** Handbook chapter 6, PARITY_MATRIX, README.

## First pass

Two reviews of `d5d1b4e..760388a`:

- `/ecc:code-review`, run locally;
- an independent, read-only `ecc:swift-reviewer` agent.

No CRITICAL. Every fix was test-first where it touches `RaceStudioCore`. Shell-only fixes are
noted as such: the shell is excluded from coverage and is checked by build, lint and the manual
list in the PR.

### HIGH

1. **After Cancel, the progress sheet stayed up, dead** (swift-reviewer H1; also found in the
   local pass).
   - The model went back to `.idle`. The sheet mapped `.idle` to an indeterminate "running"
     view, with Cancel disabled.
   - **Fixed**: `ExportFlowModel.exportChanged(to: .idle)` closes the progress sheet once a
     cancel has cleaned up. A failure that is on screen stays.
   - Tested: `test_a_cleaned_up_cancel_closes_the_sheet` and
     `test_a_shown_failure_stays_when_the_export_is_idle`.

### MEDIUM

1. **`startedHere` was never reset** (M1).
   - A window that had exported once still acted as the owner of a later export started from
     another window.
   - **Fixed**: ownership is the export's destination (`ExportFlowModel.owns`). It is cleared
     when the export ends, is cancelled, is put away, or fails before starting.
   - Tested: `test_a_window_owns_only_the_export_it_started`,
     `test_an_ended_export_shows_its_result_in_its_window`,
     `test_a_failure_while_preparing_owns_nothing`.
2. **The preparation phase was outside every guard** (M2). This is the overlay's telemetry
   loading, between the save panel and the first frame.
   - **Fixed**: the flow model tracks `isPreparing`.
     - The command counts it as busy (`isBusy`), as it does a probe in flight.
     - The close guard covers it (`guardsClose`).
     - Cancel works during it (`cancelPreparation`, which also cancels the preparation task).
     - A cancelled preparation never starts the export (`endPreparation()` → `false`).
   - Quitting during preparation needs no guard: nothing has been written yet.
   - Tested: `test_a_cancelled_preparation_starts_nothing`, `test_opening_or_preparing_is_busy`,
     `test_closing_is_guarded_while_this_windows_export_runs`.
3. **An ignored `start` left an unobserved export running** (M3). An exporter's stream starts its
   export as soon as it is made.
   - **Fixed**: `ExportProgressModel.start` returns whether it followed the stream. The
     coordinator makes the stream only after checking that the app's export is free.
   - Tested: `test_a_second_start_while_running_is_ignored` asserts the `false`.
4. **The footage's security scope was not held while probing** (M4).
   - A workspace video reopened from its bookmark could fail the probe.
   - **Fixed** (shell): the probe runs inside `startAccessingSecurityScopedResource`.
5. **Settings → progress swapped one sheet for another in place** (M5).
   - **Fixed**: `ExportFlowModel` never swaps. A new sheet waits until the one on screen is
     dismissed (`sheetDismissed`, wired to `.sheet(onDismiss:)`).
   - Tested: `test_an_export_replaces_the_settings_sheet_once_it_has_gone` and
     `test_dismiss_forgets_a_waiting_sheet`.
6. **The menu's focused value was republished on every progress tick** (M6).
   - **Fixed** (shell): `ExportHost` and the panel button follow only `progress.$state`. They
     get the export from a non-observing environment value. Only the tiny status badge observes
     every tick.
7. **Esc cancelled a running export without asking** (M7).
   - **Fixed** (shell): Esc is on **Hide**. Cancel is an ordinary button. The handbook says so.
8. **The completion announcement was lost when the sheet was hidden** (local pass).
   - **Fixed** (shell): the announcement moved into `ExportHost`, which is always mounted.

### LOW

1. **The window-delegate proxy's limits** (L1). **Documented** on `CloseGuardDelegate`:
   - it relies on an Objective-C delegate;
   - it stops asking if SwiftUI replaces the delegate;
   - it is only in place while this window's export runs.
2. **A menu item's `.help` may not show as a tooltip** (L2). **Justified**:
   - it is set, and AppKit decides whether a menu shows it;
   - the panel button shows the same reason;
   - the handbook says to hover for the reason;
   - the PR's manual list checks it.
3. **The fire-and-forget cancel task** (L3). **Commented**. The wait ends on the stream's
   report, and a cancel covers every export asked for before it.
4. **Impossible log dates, two-digit years, `%d` with `Int`** (L4). **Fixed** test-first:
   - dates are validated through the Gregorian calendar;
   - the year must have four digits;
   - the format is `%ld`.
   - Tested: `test_impossible_log_dates_are_ignored`.
5. **Unlocalized "4K (2160p)", "1080p", "720p", "H.264", "HEVC"** (L5). **Justified**: these are
   technical names, the same in both languages. "Source" is localized.
6. **The dead `export.progress.failed` key** (L6). **Removed**.
7. **A stale estimate during the debounce** (L7). **Fixed** test-first: a change that leaves
   nothing to export clears the estimate at once.
   - Tested: `test_an_invalid_choice_clears_the_estimate_at_once`.
8. **`open()` was not re-entrant-safe** (L8). **Fixed**: `ExportFlowModel.beginOpening()`
   ignores a second open while one is probing or a sheet is up.
   - Tested: `test_opening_is_not_re_entrant`.
9. **Test quality** (L9).
   - The shell's state transitions moved into the tested `ExportFlowModel`, and the shell now
     only applies them.
   - `TaskDelayScheduler`'s cancel test keeps its 120 ms negative wait, **justified**:
     - the production scheduler exposes no task handle to inspect;
     - the wait is 6× the scheduled delay;
     - its debounce logic is tested deterministically through `ManualScheduler`.
10. **The sound toggle was offered on silent footage** (local pass). **Fixed** test-first:
    `ExportSheetModel.footageHasAudio` disables it.
    - Tested: `test_the_sound_choice_follows_the_footage`.
11. **`.combine` on the sync warning swallowed the Sync First button** (local pass). **Fixed**
    (shell): `.contain`.

## Second pass (independent `swift-reviewer`, 760388a..918cecc)

No CRITICAL or HIGH. Every first-pass finding is resolved except M2, which was only partly fixed.
Core fixes were test-first: each test was seen RED, then GREEN.

### MEDIUM

1. **The VoiceOver announcement of a failure was always empty.**
   - `@Published` fires on willSet, so inside `.onReceive(progress.$state)` the model still held
     the old state, and `failureMessage()` returned `nil`.
   - **Fixed** (shell): the announcement reads the error from the delivered state.
2. **A stale preparation could start or fail the next export.** This was the rest of first-pass
   M2.
   - A preparation cancelled, then replaced by a new Export…, saw `isPreparing` true again
     whenever its telemetry load returned late.
   - **Fixed** (test-first): each preparation is a token (`ExportFlowModel.Preparation`).
     `endPreparation(_:)` and `failPreparation(_:_:)` act only for the current token, and the
     coordinator uses it on both paths.
   - Tested: `test_a_stale_preparation_cannot_start_or_fail_the_next_export` and
     `test_the_current_preparation_can_fail`.
   - Closing the window or the session mid-preparation now cancels it on disappear, so no orphan
     export starts.
   - Quitting mid-preparation stays unguarded, **justified**:
     - the preparation task dies with the process;
     - nothing has been written yet, because the exporter makes its scratch directory only once
       the export starts.

### LOW

1. **`show` could still swap a sheet in place while one was going away.** **Fixed**: it replaces
   the queued sheet instead.
   - Tested: `test_a_sheet_asked_for_while_one_goes_away_waits_its_turn`.
2. **A window's open result showed another window's export.** **Fixed**: another window's export
   starting closes an old result. A failure or a preparation on screen stays.
   - Tested: `test_another_windows_export_closes_a_shown_result` and
     `test_another_windows_export_leaves_a_failure_or_a_preparation`.
3. **A five-digit year was accepted, and the guard expression was redundant.**
   - **Fixed**: the year is bounded to 1000…9999 (tested).
   - The close guard reads `guardsClose` alone.
4. **`.writerFailed` was used as a text carrier.** **Fixed**: `exportRunningMessage` has its own
   fix string in en and pt-BR (tested).
5. **A re-subscription could replay a state.** **Fixed**: `exportChanged` acts once per state,
   so a result the operator put away never comes back.
   - Tested: `test_a_repeated_state_is_not_acted_on_twice`.

Also found locally in this pass:

- **A failure while the progress sheet was up took the sheet down and put it up again.**
  **Fixed** (test-first): the sheet stays up and shows the failure.
  - Tested: `test_a_failure_shows_in_the_progress_sheet_already_up`.

## Third pass (independent `swift-reviewer`, 918cecc..56cd128)

No CRITICAL, HIGH or MEDIUM findings. Every second-pass finding is confirmed resolved.

The reviewer confirmed three behaviours as safe:

- **`lastState` dedup.** Every start emits `.running`, so no legitimate transition repeats back
  to back.
- **The non-owner dismissal.** `start` sets `destination` before `state`, so the owner's own
  `.running` takes the owner branch.
- **`.onDisappear`.** Presenting a sheet does not trigger it, and `cancelPreparation` is
  idempotent.

### LOW (both fixed)

1. **A non-owning window kept a stale destination after dismissing an old result.** A later
   export to the same file would have been taken for its own.
   - **Fixed** (test-first): once another window's export starts, a window that is not preparing
     drops its destination.
   - Tested: `test_another_windows_export_ends_this_windows_ownership`.
2. **The sheet hand-off relied on `onDismiss` alone.**
   - **Hardened** (shell): a one-shot fallback calls `sheetDismissed()` 0.6 s after the route
     goes to `nil`. It does nothing when nothing is waiting, so the usual path is unchanged.

## Decision

**APPROVE.** All three passes are resolved:

- the first had 1 HIGH, 7 MEDIUM and 9 LOW from the reviewer, plus 5 found locally;
- the second had 2 MEDIUM and 5 LOW, plus 1 found locally;
- the third had 2 LOW.

Every finding was fixed, or is justified above (L2, L5, the quit-during-preparation case, and
the DelaySchedulingTests negative wait).

Validation at a57a191 (after a last commit pinning four rules that the tests had not stated):

- `make lint` is clean.
- The Swift suite passes: 2385 tests (CLT route).
- `RaceStudioCore` line coverage is **99.41%**.
- `OverlayExportEndToEndTests` passes with `RS_REQUIRE_CORPUS=1`.
- The golden and CSV corpus gates pass, as do the handbook and parity doc-lints and `make docs`.
- The shell builds with no new warnings.

## Found while building (before review)

- **The `type_body_length` lint on `L10n.Key`.** The key enum is a list that grows with every
  string. The lint is lifted for that enum alone (`swiftlint:disable:this`), with the reason in
  its doc comment.
- **A full local test run hung once.** It hung in #190's engine tests (`OverlayVideoExporterTests`
  and others) while another agent's worktree ran the same export tests and an ASAN build on this
  Mac. The re-run passed: 2348 tests in 14 s. This matches the CI flake under #200, so it is not
  chased here.

## Review of 1e78684, after the rebase onto #201 (issue 200)

Scope: `OverlayExportEndToEndTests` skipped in a VM's full run; `scripts/e2e.sh` runs it alone
with `RACESTUDIO_VIDEO_TESTS=1` under `scripts/watchdog.sh`; a make test pins it.

- The smoke still runs in CI, as this issue asks, and is still required (`RS_REQUIRE_CORPUS=1`).
  It now runs alone, so the VM's paravirtualized VideoToolbox serves one export, and a hang fails
  the gate at `SWIFT_TEST_TIMEOUT` instead of holding the job.
- **LOW — a hung export's samples went to `$TMPDIR`, which CI does not upload.** **Fixed**:
  `WATCHDOG_SAMPLE_DIR` defaults to the uploaded crash-reports folder on CI, as in `coverage.sh`.
- **LOW, kept — e2e's other Swift runs (the corpus goldens) are not under the watchdog.** They
  decode no video, and the job's `timeout-minutes` bounds them.

| Check | Result |
|---|---|
| Full suite on a Mac, rebased | 2390 passed in 10.4 s |
| Full suite with `RACESTUDIO_VIDEO_TESTS=0` (as on CI) | 2390 passed; video suites skipped |
| RaceStudioCore coverage, as a VM measures it | 98.73% |
| The e2e smoke, run as `e2e.sh` runs it | 1 passed in 3.2 s |
| `tests/make_test.sh` | 8 passed |
| swiftlint | 0 violations |
