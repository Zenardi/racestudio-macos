# Code Review: issue 164 — GPS timecode wrap detection

**Reviewed**: 2026-09-27
**Scope**: `core/racestudio-decode/src/gps.rs`, `core/racestudio-ffi/src/lib.rs`
**Decision**: APPROVE (one MEDIUM finding fixed during review)

## Summary

A wrap-detection fix in the GPS timecode reconstruction, plus the tail-shift repair
that keeps the series monotonic, plus an index-alignment fix in `gps_track` that the
repair exposed. Logic is sound and the libxrk oracle goldens are untouched. One
performance finding was fixed before opening the PR.

## Findings

### CRITICAL
None. The change is pure numeric decoding — no I/O, no credentials, no user input
beyond bytes already being parsed, no new dependencies.

### HIGH
None.

### MEDIUM
1. **`derived_channels` looked up repaired indices with a linear scan** — FIXED.
   `repaired.contains(&i)` ran inside the per-sample loop, making it O(n·r).
   Negligible at r=1 (the fixtures) but quadratic on a pathological file with many
   out-of-order records. `repaired` is ascending by construction, so it is now
   `binary_search`, and that ordering guarantee is documented on
   `restore_monotonicity` where it is produced.

### LOW
2. **Duplicate-timecode asymmetry.** The `monotonic` fast path tests `w[1] >= w[0]`,
   so a series whose only anomaly is *equal* consecutive timecodes returns unrepaired,
   while a series that also contains a real inversion has its duplicates repaired too
   (the repair triggers on `<=`). Not a defect: every downstream consumer requires
   only a **non-decreasing** axis (`validated_distance` in `delta.rs`), and a zero
   `dt` is already guarded in `derived_channels`. Left as is; noted because a test
   asserting *strict* increase would be fragile for a duplicates-only file.
3. **File length.** `gps.rs` is 1028 lines and `ffi/lib.rs` 2511, over the 800-line
   heuristic. Both were already over before this change (the repo lints file length
   for Swift only), and splitting them is not the business of a bug-fix PR.

## Checklist

| Category | Result |
|---|---|
| Correctness | Edge cases covered: empty, single sample, consecutive inversions, wrap after an inversion, exact half-range boundary. No i64 overflow risk (millisecond magnitudes). |
| Type safety | No casts that can lose data; `i64` throughout the unwrap, `f64` only at the boundary. |
| Pattern compliance | Matches the crate's style: total functions, no panics, doc comments explaining *why*. |
| Security | Nothing applicable. |
| Performance | One finding, fixed (above). No per-sample allocation. |
| Completeness | 4 new decode tests + 1 strengthened FFI test; the fix is proven against 4 real sessions. |
| Maintainability | New functions 12–34 lines; the non-obvious decisions (why shift, not clamp or drop) are documented at the code, with the measured numbers. |

## Validation

| Check | Result |
|---|---|
| `cargo clippy -- -D warnings` | Pass (0) |
| `cargo fmt --check` | Pass |
| `cargo test --workspace` | Pass |
| Rust coverage gate (≥95%) | Pass — 99.30% lines |
| Swift tests (1204) | Pass |
| `swiftlint --strict` | Pass (0 violations) |
| `make e2e` goldens | Pass |
| libxrk oracle goldens unchanged | Pass — all 8 |

## Files Reviewed

- `core/racestudio-decode/src/gps.rs` — Modified
- `core/racestudio-ffi/src/lib.rs` — Modified
- `fixtures/golden/aim_official_test.delta_t.json` — Modified (our own snapshot, regenerated)
