# Definition of Done

This is the **canonical Definition of Done** for RaceStudio-macOS — the single
source of truth every issue and pull request is measured against. Every issue
body pastes the checklist below **verbatim**, and
[`.github/PULL_REQUEST_TEMPLATE.md`](../.github/PULL_REQUEST_TEMPLATE.md) embeds
it so each PR is reviewed against the same bar.

## How to use it

- **Authoring an issue:** paste the *Checklist* block below into the issue's
  "Definition of Done" section, unchanged.
- **Opening a PR:** the template pre-fills this checklist; tick each item and
  paste your local `make coverage` result under *Testing & coverage*.
- **Reviewing:** approve only when every box is genuinely satisfied — see the
  coverage split below for how the 95% floor is measured.

Every change follows **test-first development** (Red → Green → Refactor) and
holds a **≥95% line-coverage floor on the logic core** (the Rust crates and the
Swift `RaceStudioCore` target), enforced by an automatic gate. Run the whole bar
locally with `make ci` (the exact sequence CI runs).

## Checklist

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

## Coverage split

Coverage is measured on the **logic core only**:

| Layer | Target | In coverage metric? |
| ----- | ------ | ------------------- |
| Rust decode/analysis/ffi | `racestudio-*` crates | ✅ yes |
| Swift logic | `RaceStudioCore` library target | ✅ yes |
| Swift UI shell | `RaceStudio` `@main` executable target | ❌ excluded |

The thin `@main` SwiftUI shell holds no logic and is excluded by target so the
95% floor is meaningful rather than diluted by declarative view bodies.
