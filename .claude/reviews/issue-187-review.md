# Review: issue #187 — video overlay layout model

**Reviewed**: 2026-10-06
**Branch**: feature/187-overlay-layout-model → main
**Decision**: APPROVE (third pass clean — see below)

## Summary

A new pure `RaceStudioCore/VideoOverlay/` module (no AppKit, SwiftUI or
AVFoundation) defines the video overlay that the live HUD (#189), the renderer
(#188) and the MP4 export (#190) share:

- the widgets and their options;
- normalized geometry with an anchor-preserving remap to any output aspect;
- validation and lenient persistence;
- availability against what a session can feed;
- a WCAG-proven theme built from the brand tokens;
- three built-in presets;
- a user preset store in Application Support;
- unit conversions defined once.

`ProjectDocument` goes to schema v7 with `overlay`, and v6/v5 projects open with
the overlay off.

## First pass — findings and resolution

The first pass combined a self-review with an independent Swift-reviewer agent
pass over `git diff origin/main...HEAD`, backed by probe suites: 200k random
rects, 100k doubles, and lossy-JSON fuzzing.

### CRITICAL / HIGH

None.

### MEDIUM

1. **Presets collided in 4:3, 1:1 and 9:16.** Short-side sizing grew widgets in
   narrow frames (for example kart badge × delta and rpm × track map at 4:3).
   **Fixed**: a narrower output keeps each widget's share of the width (a wider
   one, of the height) and its pixel shape, so a widget only shrinks inside its
   authored rect toward its anchor. Pinned by a preset × aspect no-overlap test
   and a per-anchor × aspect "subset toward the anchor" test.
2. **A malformed `overlay` value made the whole `.rsproj` unopenable**, because
   `ProjectDocument` used synthesized Codable. **Fixed**: a custom `init(from:)`
   mirrors the synthesized decode field for field, except that `overlay` is
   read in a `do/catch`. A non-layout value opens the project with the overlay
   off and a load warning. Found independently by self-review and the agent.
   **Justified as is**: `{"widgets": 3}` reads as an empty widget list. A
   non-array value holds nothing recoverable.
3. **A lossy preset library was rewritten without a backup.** Skipped presets or
   widgets were lost on the next save, with no log. **Fixed**: `LossyList`
   reports skips to a counter carried in the decoder's `userInfo`, so it counts
   at any depth. The store logs `.skippedEntries(n)` and keeps a lossy or
   unreadable file aside under the first free `OverlayPresets.backup(-n).json`,
   so it never overwrites an earlier backup.

### LOW

4. **A decoded layout kept a newer `schema`** and wrote it back. **Fixed**
   (self-review, confirmed by the agent): `schema` is computed and is always
   `currentSchema`, read into and written as this build's format.
5. **The reference aspect was not bit-exact.** **Fixed**: exact placement
   (`start + (length − newLength)·{0, ½, 1}`), and the identity test is `==`.
6. **Session-info availability counted fields the widget doesn't show.**
   **Fixed**: it now counts only track, date and session name.
7. **A user preset could take a built-in's name.** **Fixed**: `.reservedName`
   covers every shipped language.
8. **The shell's `@State` was the overlay's only owner.** **Fixed**:
   `AnalysisWindowModel.overlay` owns it, `projectDocument()` captures it and
   `restore(from:)` restores it.
9. **API gaps for the consumers.** **Fixed**:
   - `drawable(for:session:)` is the draw list without unavailable widgets;
   - `NormalizedRect.reference(from:in:anchor:)` is the inverse map the editor
     needs;
   - the docs state that `resolved`/`availability` validate, so callers cache
     per output size.
10. **The documented preset path ignored the sandbox container.** **Fixed** in
    the docs and the handbook.
11. **Test gaps**: a vacuous preset sweep, a positional widget lookup, and
    untested store paths. **Fixed**: count assertion, lookup by id, and tests
    for copy failure, delete over an unreadable file, and a newer format.
12. **Track-map rotation could round up to 360.** **Fixed**: it maps to 0.

Also noted (no defect): `OverlayPresetStore` does an unserialized
read-modify-write, like `LibraryStore`. Its docs say to use one store from one
actor.

## Second pass

Ten findings were confirmed resolved, with a probe suite: 0 overlaps for all
three presets at 16:9, 4:3, 1:1, 9:16, 21:9 and extreme ratios, plus a 100k-rect
fuzz of subset, shape, inverse and finiteness. Two were partial, and there were
five new LOW findings. All are handled:

- **3, partial: the preset library could still be rewritten silently**, in four
  cases. **Fixed**:
  - a newer `schema` is logged (`.newerFormat(n)`) and counts as not read in
    full;
  - a `presets` value that isn't a list makes the file unreadable
    (`.corruptFile`), not empty;
  - `lenient` counts a setting that is present but unreadable, and so does an
    unknown theme id.

  Any of these keeps the file aside before a rewrite. A v7 project load counts
  the overlay entries it skipped and adds a warning
  (`video overlay: N unreadable entries skipped`).
- **11, partial: test gaps.** **Fixed** with N3.
- **N1: `AnalysisWindowModel.overlay` sat beside the lap-overlay members.**
  **Fixed**: renamed to `videoOverlay`. The `.rsproj` key stays `overlay`.
- **N2: the inverse map is lossy past the reach of the forward map.**
  **Documented**: the doc says where `reference(from:)` is exact, and tells an
  editor working in another aspect to re-anchor or to edit in the 16:9
  reference.
- **N3: the test helper silently skipped its edits if the id changed.**
  **Fixed**: it uses `try #require`.
- **N4: the shell never shows `ProjectDocument.warnings`.** **Justified, not
  changed**: `warnings` is the existing transient load channel, and the shell
  doesn't surface any warning today (unresolved session refs and clamped laps
  included). Surfacing them is shell UX belonging to the Video + Data view
  (#189), not this model issue.
- **N5: a read-only directory surfaces only as `ioFailure`.** Informational;
  no change.

## Third pass

Clean: every second-pass item is confirmed resolved or justified, with no
regressions. The probes covered skip counts on clean, null and broken input,
the absence of false positives on libraries this build wrote, and v6/v7 project
loads. Two optional LOW notes were raised, and both are fixed anyway:

- **One unreadable widget could count twice.** A malformed `id` was counted
  before an unknown `kind` failed the widget. **Fixed**: a widget reads its
  required `kind` and `frame` first.
- **Retried saves that kept failing each added a backup.** **Fixed**: the copy
  is skipped when a backup with the same bytes already exists.

## Validation Results

| Check | Result |
|---|---|
| Swift tests (CLT route) | Pass — 1763/1763 |
| SwiftLint --strict | Pass |
| App build (`RaceStudio` product) | Pass |
| Handbook link-check + `handbook_links_test` | Pass |
| Coverage (local CLT route) | New `VideoOverlay/` files 100% lines, except `OverlayPresetStore` at 99.1% (unreachable temp-dir fallback). `RaceStudioCore` 97.87% (gate parser) |
| Rust | Not touched (doc-lint test run for the handbook change) |
