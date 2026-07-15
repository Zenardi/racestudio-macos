# RaceStudio-macOS

A native macOS re-implementation of AiM **RaceStudio 3** telemetry analysis —
successor and sibling to [XRKConverter](https://github.com/Zenardi/XRKConverter).

> **Status:** milestone **M0 — Foundations, Tooling & TDD Harness**.
> This is the project scaffold (issue 0.1): a green, warning-free build that
> encodes the coverage split the rest of the project hangs on. No decode or
> analysis logic ships yet.

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
- **`racestudio-analysis`** — telemetry analysis engine: channels, math,
  resampling (M3).
- **`racestudio-ffi`** — the UniFFI boundary that bridges the Rust core to
  Swift, packaged as a universal `.xcframework` (0.4).
- **`RaceStudioCore`** — the Swift logic library; all testable behaviour lives
  here. It is the 95% Swift coverage target.
- **`RaceStudio`** — a thin `@main` SwiftUI shell that holds no logic and is
  excluded from the coverage metric by target.

## Layout

```
Cargo.toml                     # Rust workspace (resolver "2")
core/
  racestudio-decode/           # stub crate + placeholder test
  racestudio-analysis/         # stub crate + placeholder test
  racestudio-ffi/              # stub crate + placeholder test
app/
  Package.swift                # three-target split
  Sources/RaceStudioCore/      # logic library
  Sources/RaceStudio/          # @main SwiftUI shell
  Tests/RaceStudioCoreTests/   # swift-testing smoke tests
docs/DEFINITION_OF_DONE.md     # shared DoD checklist
Makefile                       # placeholder task runner (wired in 0.6)
```

## Development

Requires the Rust toolchain (`rustup`) and the Swift toolchain. Building and
running the Swift **app** needs only the Command Line Tools; running `swift test`
requires **Xcode** (it provides the `xctest` bundle launcher — see the note
below).

```sh
# Rust core
cargo build --workspace          # compiles all three crates, warning-free
cargo test  --workspace          # runs the placeholder unit tests
cargo clippy -- -D warnings      # lint gate
cargo fmt --check                # format gate

# Swift app (run from app/)
cd app
swift build                      # compiles RaceStudioCore + the @main shell
swift test                       # runs the RaceStudioCore smoke tests (needs Xcode)
```

### Testing framework

The Swift smoke tests use **[swift-testing](https://github.com/swiftlang/swift-testing)**
(`import Testing`), the framework bundled with the Swift toolchain. `swift test`
launches test bundles through Xcode's `xctest` tool, so executing the suite
requires a full Xcode install (as CI provides). With only the Command Line
Tools installed, `swift build` and the test *build* still succeed; the runtime
run step is a no-op. `Package.swift` self-detects the Command-Line-Tools
swift-testing framework path and wires it in only when present, so the manifest
stays portable across CLT-only and full-Xcode setups.

## Testing philosophy

Test-first (Red → Green → Refactor) with a **≥95% line-coverage floor** on the
logic core, enforced by an automatic gate. See
[`docs/DEFINITION_OF_DONE.md`](docs/DEFINITION_OF_DONE.md).

## License

[MIT](LICENSE) © 2026 Eduardo Zenardi
