# RaceStudio-macOS

A native macOS re-implementation of AiM **RaceStudio 3** telemetry analysis —
successor and sibling to [XRKConverter](https://github.com/Zenardi/XRKConverter).

> **Status:** **M0 — Foundations, Tooling & TDD Harness** complete (0.1–0.7);
> **M1 — Rust Core: XRK Decode** has begun. M0 shipped the scaffold, the Rust +
> Swift **coverage gates**, the **UniFFI xcframework pipeline**, the
> **golden-fixtures harness** (libxrk-derived oracle JSON + Rust/Swift loaders),
> the shared DoD/CI/Makefile, and enforceable branch protection — green,
> warning-free, ≥95% line coverage on the logic core, enforced in CI. M1 opens
> with the **decode-strategy decision**
> ([ADR 0002](docs/adr/0002-xrk-decode-strategy.md)): a clean-room Rust decoder
> validated against the `libxrk` oracle, after a spike rejected wrapping the
> proprietary-linked `xdrk` crate. No decode or analysis logic ships yet.

## Architecture

The app is a **Rust core** exposed to a **SwiftUI** frontend through **UniFFI**:

```
┌─────────────────────────────────────────────┐
│  SwiftUI frontend (app/)                      │
│                                               │
│   RaceStudio         thin @main shell         │  ← excluded from coverage
│      │  depends on                            │
│   RaceStudioCore     logic library            │  ← 95% Swift coverage target
│      ▲                                         │
│      │  UniFFI (.xcframework, added in 0.4)    │
├──────┴────────────────────────────────────────┤
│  Rust core (core/)                            │
│                                               │
│   racestudio-decode    clean-room .xrk decode │  ← 95% Rust coverage target
│   racestudio-analysis  channels / math        │  ← 95% Rust coverage target
│   racestudio-ffi       UniFFI boundary        │
└───────────────────────────────────────────────┘
```

- **`racestudio-decode`** — clean-room Rust decoder for AiM `.xrk` files,
  validated against XRKConverter's `libxrk` output as the golden oracle (M1).
  The strategy — a clean-room port over wrapping the proprietary-linked `xdrk`
  crate — is recorded in
  [`docs/adr/0002-xrk-decode-strategy.md`](docs/adr/0002-xrk-decode-strategy.md).
- **`racestudio-analysis`** — telemetry analysis engine: channels, math,
  resampling (M3).
- **`racestudio-ffi`** — the UniFFI boundary that bridges the Rust core to
  Swift, packaged as a universal (arm64 + x86_64) `RaceStudioFFI.xcframework`.
  As of 0.4 it exports `core_version()`, round-tripped by a Swift test. See
  [`docs/adr/0001-ffi-boundary.md`](docs/adr/0001-ffi-boundary.md).
- **`RaceStudioCore`** — the Swift logic library; all testable behaviour lives
  here. It is the 95% Swift coverage target.
- **`RaceStudio`** — a thin `@main` SwiftUI shell that holds no logic and is
  excluded from the coverage metric by target.

## Layout

```
Cargo.toml                     # Rust workspace (resolver "2")
rustfmt.toml · clippy.toml     # shared Rust format/lint config
core/
  racestudio-decode/           # stub crate + placeholder test
  racestudio-analysis/         # stub crate + placeholder test
  racestudio-ffi/              # UniFFI boundary — exports core_version()
app/
  Package.swift                # RaceStudioCore/RaceStudio/tests + FFI targets
  Sources/RaceStudioCore/      # logic library (wraps the FFI bindings)
  Sources/RaceStudio/          # @main SwiftUI shell
  Tests/RaceStudioCoreTests/   # swift-testing smoke + FFI round-trip tests
  Generated/                   # checked-in uniffi-generated Swift bindings
  .swiftlint.yml               # SwiftLint config
  RaceStudioFFI.xcframework/   # built artifact (git-ignored, ~34 MB)
fixtures/                      # decode goldens (0.5): golden/*.json committed,
                               #   .xrk/.csv samples git-ignored (make fixtures)
scripts/
  coverage.sh                  # Rust + Swift quality + coverage gate
  swift_test.sh                # `swift test` wrapper (CLT framework paths)
  build_xcframework.sh         # universal xcframework + Swift bindings
  fetch_fixtures.sh            # fetch .xrk samples + regenerate goldens
  gen_goldens.py               # libxrk -> deterministic golden JSON
  spike_xdrk_linkage.sh        # reproducible xdrk-crate linkage probe (ADR 0002)
tests/
  gate_test.sh                 # Rust gate self-tests
  swift_gate_test.sh           # Swift gate self-tests
  ffi_test.sh                  # FFI pipeline tests
  fixtures_test.sh             # fetch-fixtures self-tests
.github/workflows/ci.yml       # macos-15 CI: Rust + Swift gates
docs/DEFINITION_OF_DONE.md     # shared DoD checklist
docs/adr/                      # architecture decision records (0001 FFI, 0002 decode)
docs/spike/                    # spike evidence (xdrk linkage finding)
Makefile                       # `make coverage`, `make xcframework`, `make fixtures`
```

## Development

Requires the Rust toolchain (`rustup` + `cargo-llvm-cov` + the
`llvm-tools-preview` component), the Swift toolchain, `swiftlint`, and
[`trivy`](https://trivy.dev) (the security scanner). A full Xcode install is
**not** required — the tooling also works with just Apple's Command Line Tools.
`make setup` installs the toolchains.

```sh
# Rust core
cargo build --workspace          # compiles all three crates, warning-free
cargo test  --workspace          # runs the placeholder unit tests
cargo clippy -- -D warnings      # lint gate
cargo fmt --check                # format gate

# Rust→Swift FFI boundary
make xcframework                 # build RaceStudioFFI.xcframework + Swift bindings

# Decode test fixtures (libxrk golden oracle — see fixtures/README.md)
make fixtures                    # fetch .xrk samples + regenerate golden JSON

# Swift app
cd app
swift build                      # compiles RaceStudioCore + the @main shell
bash ../scripts/swift_test.sh    # runs the smoke + FFI round-trip tests
```

The Swift package links the `RaceStudioFFI` binary target, so `swift build`/
`swift test` need `RaceStudioFFI.xcframework` present. It is a git-ignored
artifact; the coverage gate builds it on demand, or run `make xcframework`. A
fresh checkout without it still builds — the FFI surface is gated behind
`#if canImport(RaceStudioFFIBindings)`.

### Coverage gate

`scripts/coverage.sh` is the single quality + coverage gate, run identically
locally and in CI. It enforces a **≥95% line-coverage floor** (configurable via
`COVERAGE_THRESHOLD`) on the logic core only — the Rust crates and the Swift
`RaceStudioCore` library; the `RaceStudio` `@main` shell is structurally
excluded (it is never linked into the tests).

```sh
make coverage                    # both gates (Rust then Swift)
bash scripts/coverage.sh --rust-only    # cargo fmt/clippy/test + llvm-cov ≥95%
bash scripts/coverage.sh --swift-only   # swiftlint + swift test + llvm-cov ≥95% on Core
```

### Testing framework

The Swift smoke tests use **[swift-testing](https://github.com/swiftlang/swift-testing)**
(`import Testing`), the framework bundled with the Swift toolchain. On a runner
with only the Command Line Tools installed (no full Xcode), `swift test` builds
the swift-testing bundle but cannot load it at runtime unless the framework
search paths are supplied. **`scripts/swift_test.sh`** injects those paths
(`-F`/`-rpath` into `$(xcode-select -p)/Library/Developer/Frameworks` and
`.../usr/lib`) when — and only when — the Command Line Tools are the active
developer dir, so `swift test` builds *and runs* on both CLT-only and full-Xcode
hosts. On full Xcode it is a transparent pass-through.

## Make targets

One command per intent — `make ci` is the exact sequence CI runs, so a green
`make ci` locally predicts a green pipeline.

| Target | Does |
| --- | --- |
| `make setup` | install toolchains + fetch fixtures |
| `make test` | Rust + Swift test suites (`test-rust`, `test-swift`) |
| `make coverage` | the ≥95% line-coverage gate (Rust + Swift) |
| `make lint` | `clippy -D warnings` + `cargo fmt --check` + `swiftlint` |
| `make security` | Trivy scan (vulns / secrets / IaC misconfig); fails on HIGH/CRITICAL |
| `make e2e` | build the pipeline + validate the decode oracle |
| `make ci` | `lint` → `coverage` → `e2e` (what CI runs) |
| `make fixtures` | fetch `.xrk` samples + regenerate goldens |
| `make xcframework` | build the universal `RaceStudioFFI.xcframework` |
| `make clean` | remove build artifacts |

## Contributing

Test-first (Red → Green → Refactor) with a **≥95% line-coverage floor** on the
logic core, enforced by `make ci` in CI (`.github/workflows/ci.yml`, `macos-15`).
The shared bar is [`docs/DEFINITION_OF_DONE.md`](docs/DEFINITION_OF_DONE.md) — the
single source of truth that [the PR template](.github/PULL_REQUEST_TEMPLATE.md)
embeds and every issue pastes. New issues use
[`.github/ISSUE_TEMPLATE/feature.md`](.github/ISSUE_TEMPLATE/feature.md).

CI also runs a **[Trivy](https://trivy.dev) security scan** (`make security`) —
known-vulnerable dependencies, committed secrets, and IaC misconfigurations —
which fails the build on HIGH/CRITICAL findings. Run it (with the rest of the
gates) before pushing.

`main` is protected: changes land via PR, and the `make ci (lint, coverage, e2e)`
check plus 1 review are required before merge (linear history, no direct pushes).
The exact, reproducible configuration is in
[`docs/BRANCH_PROTECTION.md`](docs/BRANCH_PROTECTION.md).

## License

[MIT](LICENSE) © 2026 Eduardo Zenardi
