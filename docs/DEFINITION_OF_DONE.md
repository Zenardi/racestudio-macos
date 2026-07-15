# Definition of Done

> **Status: stub.** This file is authored as a stub in issue 0.1 and fully
> fleshed out in issue 0.6 (Makefile / DoD wiring). It captures the shared
> checklist every issue in this repository must satisfy before it is considered
> complete.

Every change follows **test-first development** (Red → Green → Refactor) and
holds a **≥95% line-coverage floor on the logic core** (the Rust crates and the
Swift `RaceStudioCore` target), enforced by an automatic gate.

## Checklist

- [ ] Red → Green → Refactor followed; tests written before implementation.
- [ ] Every acceptance criterion in the issue's *Goal* met and demonstrable.
- [ ] Rust: `cargo test` green · `cargo clippy -- -D warnings` clean ·
      `cargo fmt --check` clean.
- [ ] Swift: `swift test` green · `swiftlint` clean.
- [ ] Line coverage ≥ 95% on the logic crate/target (CI gate passes).
- [ ] Overall coverage did not drop; every new public API is covered.
- [ ] Tests isolated, repeatable, one-reason-to-fail (AAA / Given-When-Then);
      no logic in tests.
- [ ] Golden/fixture data updated & reviewed if behaviour changed.
- [ ] Public APIs documented; user-facing changes noted in docs/README.
- [ ] CI green on PR (lint + coverage + e2e); branch-protection checks satisfied.
- [ ] Reviewed & approved; no new warnings; no stray `unwrap()`/`TODO` in
      shipped paths.
- [ ] Increment is potentially shippable (app runs / library usable).

## Coverage split

Coverage is measured on the **logic core only**:

| Layer | Target | In coverage metric? |
| ----- | ------ | ------------------- |
| Rust decode/analysis/ffi | `racestudio-*` crates | ✅ yes |
| Swift logic | `RaceStudioCore` library target | ✅ yes |
| Swift UI shell | `RaceStudio` `@main` executable target | ❌ excluded |

The thin `@main` SwiftUI shell holds no logic and is excluded by target so the
95% floor is meaningful rather than diluted by declarative view bodies.
