# Code Review: issue #106 — [M8] 8.15 Library collections + search facets

**Reviewed**: 2026-07-19
**Branch**: feature/8.15-library-collections → main
**Mode**: `/ecc:code-review --fix` (independent Swift review of the committed change set)
**Decision**: APPROVE (all findings fixed)

## Summary
RS3 collections (recent/smart/manual) + faceted search added to the 8.14 library
browser. Logic lives in `RaceStudioCore`; the shell binds. One HIGH and two MEDIUM
findings were raised and all were fixed with regression tests.

## Findings & resolution

### HIGH — a single malformed collection wiped the entire library index on load
`SessionIndex.init(from:)` decoded `collections` with `decodeIfPresent`, which
tolerates a *missing* key but still throws if any element is malformed. Because
`LibraryStore.load` treats a decode throw as `.corruptIndex` and returns an empty
index, one bad hand-edited/schema-evolved collection discarded every session
summary too.
**Fixed**: collections now decode leniently via a `FailableDecodable<T>` wrapper —
a malformed collection is skipped, summaries and valid collections survive.
Regression test: `LibraryStoreTests.test_malformed_collection_is_skipped_not_fatal`.

### MEDIUM — `SessionIndex.facetValues` tie-break was non-deterministic
`Array(Set(values)).sorted { localizedCaseInsensitiveCompare }` left case-variant
duplicates (e.g. "BMW"/"bmw") in randomized `Set` order.
**Fixed**: added a raw-value secondary sort key.
Regression test: `SessionIndexTests.test_facet_values_break_case_insensitive_ties_deterministically`.

### MEDIUM — `LibraryBrowserModel.vehicles` duplicated `facetValues(.vehicle)` and could drift
**Fixed**: `vehicles` is now defined as `facetValues(.vehicle)` so the two cannot diverge.

### Not flagged
No CRITICAL issues: no force-unwraps/`try!`/`as!`, no secrets, no injection/path
traversal. `LibraryBrowserModel` is correctly `@MainActor`; `loadPreview()` guards
the stale-selection race; `SessionIndex` stays a non-`Sendable` class mutated only
through the `@MainActor` model (pre-existing, acceptable under the package's Swift 5.9).

## Validation

| Check | Result |
|---|---|
| swift test (full) | Pass — 745 tests, 81 suites |
| swiftlint --strict | Pass — 0 violations, 191 files |
| RaceStudioCore coverage | Pass — 99.64% (≥ 95%) |
| Rust coverage gate | Pass — ≥ 95% |
| cargo fmt / clippy / test | Pass (no Rust changes) |
| swift build (app) | Pass |
