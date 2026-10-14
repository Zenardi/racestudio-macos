# Review: issue 229, a reopened session's video standing on its first frame

## Review of 8eb1257

Scope:
- `VideoDataViewModel.footageOpened`: seeds the footage's length and frame grid, applies a file-date guess, and
  returns where a paused player must stand — the cursor's frame under the sync in force.
- `VideoReviewController.open` reads the asset in one step (`AVURLAsset.openedFootage`) and seeks there.
- `VideoSyncReopenTests`: an engine-sound sync survives closing and reopening through the workspace autosave, with
  the real `VideoReviewModel`.

Method: my own read plus an independent Swift reviewer.

What holds:
- **The cause.** The app's log of the reported run shows the reopened footage resolved from its bookmark and the
  player at 0 s with no seek until auto-sync was run again, which then sought to the same lap start as before. The
  saved sync was in force; the player was never moved to the cursor, because the panel's follow-the-cursor ran
  before the footage's length was known.
- **No regression in `open`.** Collapsing the per-await generation checks into one is safe: nothing is written
  between the awaits. The file-date guess still never overrides a saved sync (re-linking keeps it), its outcome is
  still reported only when a date was offered, and an unread length still leaves the footage unplayable.
- **Every path is covered.** A failed restore clears the player and re-linking goes through `open`; a hidden panel
  follows the cursor itself when it appears, and its seek and the new one agree.

Findings:
- **MEDIUM, fixed: a Play pressed while the footage loaded could be overridden.** The new seek was gated on
  `isPlaying`, which is false while the player waits to play, so it could land after *Play lap*'s seek and start
  playback from the cursor instead of the lap. It is now gated on playing *or about to*
  (`isPlayingOrAboutTo`), the rule `pauseForScrub` already used. Shell only; the core's no-seek-while-playing rule
  is tested.
- **LOW, fixed: tests with more than one reason to fail.** Split into one claim each, with values exact in binary
  (offset 12.5, rate 1.0625) so no expected value is computed in a test; the saved sync is checked whole with
  `review.stamped(saved) == saved`.
- **LOW, fixed: `OpenedFootage.duration`'s documentation** now says an unread length leaves the length as it was,
  and that a length that is no number reads as none. A test covers `nil` and NaN.
- **LOW, fixed: the reopen test's scope** now says why it is there: the first window's autosave must be released,
  as a closed window's is, or the reopened window is a second window that doesn't save. (Without it the test fails
  on the *open in another window* notice.)
- **LOW, fixed: the handbook** says the footage reopens on the frame at the cursor.
- **No change: no seek without a cursor.** Footage that opens before the panel has bound the cursor is not moved;
  the panel follows the cursor when it appears.

| Check | Result |
|---|---|
| Tests before the change (RED) | Compile failure on the missing API (`VideoFootageOpeningTests`); `VideoSyncReopenTests` is a regression guard that passed before the fix |
| Full suite in parallel / `--no-parallel` | 2654 / 2654 passed |
| RaceStudioCore coverage | 99.39%; `VideoDataViewModel+Opening.swift` at 100% |
| SwiftLint | 0 violations |
| App shell build (CLT + Xcode's SwiftUI macro plugin) | Builds |
| Tooling self-tests (CLT selected) | All pass |
| Legal gate | No device-area changes |
