---
name: Feature / task
about: A milestone feature or tooling task (mirrors the M0–M7 issue format)
title: "[Mx] x.y — <short title>"
labels: type:feature
---

### Description

<!-- What and why. Link the milestone and any dependencies (builds on issue N). -->

### Goal

<!-- Acceptance criteria as Given / When / Then bullets — each independently
     demonstrable. -->

### Implementation plan

<!-- The concrete steps: files to add/change, scripts, wiring. -->

### Definition of Done

<!-- Pasted verbatim from docs/DEFINITION_OF_DONE.md — the single source of truth. -->

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

### TDD checklist

- [ ] Write the acceptance behaviours as test names FIRST
- [ ] RED: failing test per behaviour; confirm it fails for the right reason
- [ ] GREEN: minimum code to pass
- [ ] REFACTOR: tidy with tests green
- [ ] Edge/negative cases: empty, malformed .xrk, boundaries, error paths
- [ ] Property/parameterised tests where input space is large (resample, expr eval)
- [ ] Golden-file assertions vs XRKConverter reference where applicable
- [ ] `make coverage` ≥95% verified locally before PR

### Recommended Claude Prompt

<!-- A precise, test-first prompt: read docs/DEFINITION_OF_DONE.md, start RED with
     named tests, then GREEN with the minimum, then REFACTOR. State what is out of
     scope. -->
