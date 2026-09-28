# PR Review: #173 — Stop a hand-pushed tag and an auto-release both publishing one commit

**Reviewed**: 2026-09-27
**Branch**: fix/release-tag-race → main
**Decision**: APPROVE with comments

## Summary
The pre-publish re-check closes the duplicate-release window from minutes to seconds, and fails loudly
instead of mislabelling a build. The debounce test fix removes a wall-clock dependency without touching
production code.

## Findings

### CRITICAL
None

### HIGH
None (found and fixed during review: the implicit GitHub shell is `bash -e` without pipefail, so
`next_version.sh | tee` swallowed a refusal. Verified: `bash -e -c 'false | tee /dev/null; echo x'`
prints x. Both version steps now use `shell: bash`.)

### MEDIUM
- A residual window of a few seconds remains between the re-check and `action-gh-release` creating the
  tag. It can't be closed without an atomic tag-create, and the old window was ~3.5 min.
- Concurrency drops all but one *pending* run per group, so a middle merge in a burst of three gets
  no tag of its own. Its content still ships in the next release. Noted in the PR, not fixed.

### LOW
- The 60 s debounce test leaves one sleeping unstructured Task at suite end. It is abandoned at process
  exit and does not hold the run open (suite finished in 0.055 s).

## Validation Results

| Check | Result |
|---|---|
| tests/release_test.sh | Pass (33/33, 4 new) |
| Edge probes (tag-push re-check, non-main branch, mismatch) | Pass |
| MathChannelEditorModelTests | Pass (13/13) |
| SwiftLint --strict | Pass |
| YAML parse | Pass (actionlint not installed) |

## Files Reviewed
- scripts/next_version.sh (Modified)
- .github/workflows/release.yml (Modified)
- tests/release_test.sh (Modified)
- docs/RELEASE.md (Modified)
- app/Tests/RaceStudioCoreTests/MathChannelEditorModelTests.swift (Modified)
