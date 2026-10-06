# Code Review: issue 192 — Video sync hardening (9.7)

**Reviewed**: 2026-10-06
**Branch**: feature/192-video-sync-hardening → main
**Scope**: `app/Sources/RaceStudioCore/Video/*`, `Project/ProjectDocument.swift`,
`Project/ProjectStore.swift`, `Localization/*`, the Video Review shell
(`VideoReviewController`, `VideoReviewPanel`, `VideoSyncBar`), tests and docs.
**Decision**: APPROVE. Two review passes: the first found 1 HIGH, 6 MEDIUM and
several LOW findings, all fixed. The second found 4 LOW findings, also fixed.

## Summary

Adds a clock rate to `VideoSyncModel`, which is bit-identical at `rate == 1`, so
the 9.5/9.6 suites stay untouched. It also adds a plausibility gate on the
file-date offset, an exact frame grid for trimming, a two-point offset + rate
solver, a sync status with a lap-coverage summary, and `.rsproj` v6. The maths
was checked at the boundaries: the exact 1 s overlap, the inclusive ±0.5% rate
bounds, and the 10 s anchor spacing.

## Findings

### CRITICAL
None. There is no new I/O beyond the existing bookmark/AVAsset reads, and no
credentials or dependencies. Fixtures are synthetic.

### HIGH
1. **A corrupt `.rsproj` could trap the status line**: FIXED. A decoded lap
   index of `Int.max` overflowed `index + 1`. Lap indices outside
   `0...Int32.max-1` are now a decode error. Tests cover `-1` and `Int.max`.

### MEDIUM
2. **A malformed `status` made the whole project unopenable**: FIXED. The status
   is cosmetic, so it now decodes as `.notSynced`, keeping the offset and rate.
3. **Importing a different file inherited the old sync** ("Synced on lap 3"):
   FIXED. `attach` resets the sync unless it is re-linking a workspace video that
   failed to open.
4. **The first frame step after an anchor moved 0.5–1.5 frames**: FIXED.
   `FrameGrid.step` is now exactly `n × frameDuration`. Snapping would also have
   shifted the anchored lap. This deviates from the issue's "frame steps keep the
   offset on the frame grid", which still holds for an on-grid offset (recorded
   in the PR).
5. **The sync bar was too wide for the panel at the minimum window width**:
   FIXED. It now has two rows plus the status line.
6. **Keyboard shortcuts**: the bare `,`/`.` next to a text field, and whether
   `⇧,`/`⇧.` match. This cannot be verified from code. The tooltips now name the
   shortcuts, and it is listed for manual verification in the PR.
7. **Anchors could be set without footage**: FIXED. A `hasVideo` guard was
   added, a failed restore clears the player, and its message is now shown.

### LOW (all fixed)
- A stale two-point error is now cleared on the next sync action.
- A stale frame grid is reset when a clip has no readable track.
- `open()` race: added a generation token.
- Rates below 1 fps fall back to 30 fps.
- Doc fixes: "fifty times", plus the missing doc comments.
- `@ViewBuilder` replaces `AnyView`, and the duplicate a11y label is gone.
- The slider's a11y value is now the offset readout.
- Help strings are localized, and a refused two-point sync is announced to
  VoiceOver.
- The readout is now in Core and locale-aware, and never shows "−0.000 s".
- The double decode of the anchored lap is gone.
- The constant-only schema test became an on-disk v6 stamp test.

### Kept by design
- A single-section sync after a two-point sync keeps the solved rate. This is
  documented in the handbook and a doc comment.
- `applyAutoOffset` consults the raw `autoOffset` only to tell `.unavailable` from
  `.implausible`. It never applies it.
- A migrated v5 non-zero offset becomes `.anchored(lap: nil)`, as the issue asks.

## Validation Results

| Check | Result |
|---|---|
| RaceStudioCore tests (CLT toolchain) | Pass (1533, up from 1419) |
| SwiftLint `--strict` | Pass (0 violations) |
| Shell build (`swift build --product RaceStudio`) | Pass, no new warnings |
| Line coverage `RaceStudioCore` | 97.40%; every new/changed Core file at 100% |
| Handbook link-check | Pass |
| Rust | Untouched |
