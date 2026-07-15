<!-- Thanks for contributing to RaceStudio-macOS! Fill in the sections below. -->

## Summary

<!-- What does this PR do, and why? -->

Closes #<!-- issue number -->

## Testing & coverage

<!-- Paste your local `make coverage` result (the ≥95% gate) and note how you
     verified the change end-to-end. A green `make ci` locally predicts a green
     pipeline. -->

```
$ make coverage
<!-- paste output: PASS: coverage gate green (threshold 95%) -->
```

## Definition of Done

<!-- The canonical checklist from docs/DEFINITION_OF_DONE.md — the single source
     of truth. Tick each item; do not remove any. -->

- [ ] Red→Green→Refactor followed; tests written before implementation
- [ ] Every acceptance criterion in "Goal" met and demonstrable
- [ ] Rust: `cargo test` green · `cargo clippy -- -D warnings` clean · `cargo fmt --check` clean
- [ ] Swift: `swift test` green · `swiftlint` clean
- [ ] Line coverage ≥ 95% on the logic crate/target (CI gate passes)
- [ ] Overall coverage did not drop; every new public API is covered
- [ ] Tests isolated, repeatable, one-reason-to-fail (AAA / Given-When-Then), no logic in tests
- [ ] Golden/fixture data updated & reviewed if behaviour changed
- [ ] Public APIs documented; user-facing changes noted in docs/README
- [ ] CI green on PR (lint + coverage + e2e); branch-protection checks satisfied
- [ ] Reviewed & approved; no new warnings; no stray `unwrap()`/`TODO` in shipped paths
- [ ] Increment is potentially shippable (app runs / library usable)
