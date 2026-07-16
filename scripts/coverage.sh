#!/usr/bin/env bash
#
# Quality + coverage gate for racestudio-macos, run identically locally and in
# CI (macos-15). Mirrors XRKConverter's scripts/coverage.sh convention.
#
# Rust gate (issue 0.2):  fmt --check -> clippy -D warnings -> test ->
#   cargo llvm-cov --fail-under-lines $THRESHOLD.
# Swift gate (issue 0.3): swiftlint -> swift test --enable-code-coverage (via
#   scripts/swift_test.sh) -> xcrun llvm-cov export -summary-only scoped to
#   Sources/RaceStudioCore -> line coverage >= $THRESHOLD. The RaceStudio @main
#   shell is a separate executable target, never linked into the tests, so it is
#   structurally excluded from the metric.
#
# Usage:
#   scripts/coverage.sh                 both gates (Rust then Swift)
#   scripts/coverage.sh --rust-only     Rust gate only
#   scripts/coverage.sh --swift-only    Swift gate only
#   scripts/coverage.sh --print-config  print resolved config and exit
#
# Config (env): COVERAGE_THRESHOLD (default 95), RUST_WORKSPACE (default repo
#   root), SWIFT_APP (default repo-root/app), EMIT_LCOV=1 (Rust lcov artifact).
#
# Internal sub-modes (used by tests/swift_gate_test.sh):
#   --swift-parse-json <threshold>   parse llvm-cov JSON on stdin, gate on %
#   --swift-build                    run swift test --enable-code-coverage
#   --swift-export [scope|ALL]       xcrun llvm-cov export (default scope: Core)
#   --swift-lint                     run swiftlint on app
#
# Branch-protection wiring that makes these checks *required* is issue 0.7.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

THRESHOLD="${COVERAGE_THRESHOLD:-95}"
# The Rust workspace Cargo.toml lives at the repo root in this project (unlike
# XRKConverter's core/ layout); both dirs are overridable for testing.
RUST_WORKSPACE="${RUST_WORKSPACE:-$ROOT}"
SWIFT_APP="${SWIFT_APP:-$ROOT/app}"
CORE_SCOPE="Sources/RaceStudioCore"

# --------------------------------------------------------------------------- #
# Swift helpers
# --------------------------------------------------------------------------- #

swift_locate_bin() {
  find "$SWIFT_APP/.build" -name 'RaceStudioPackageTests' -type f \
    -path '*/Contents/MacOS/*' ! -path '*.dSYM*' 2>/dev/null | head -1 || true
}

swift_locate_prof() {
  find "$SWIFT_APP/.build" -name 'default.profdata' 2>/dev/null | head -1 || true
}

# The UniFFI xcframework is a git-ignored build artifact; build it on demand so
# the Swift package can link the RaceStudioFFI binary target (issue 0.4).
ensure_xcframework() {
  if [[ ! -d "$SWIFT_APP/RaceStudioFFI.xcframework" ]]; then
    echo "==> [swift 0/2] building RaceStudioFFI.xcframework (missing)"
    bash "$SCRIPT_DIR/build_xcframework.sh"
  fi
}

swift_build_coverage() {
  ensure_xcframework
  echo "==> [swift 1/2] swift test --enable-code-coverage (via scripts/swift_test.sh)"
  bash "$SCRIPT_DIR/swift_test.sh" --enable-code-coverage
}

# $1 = scope path relative to app/, or "ALL" for the full (unscoped) export.
swift_export() {
  local scope="${1:-$CORE_SCOPE}" bin prof
  bin="$(swift_locate_bin)"
  prof="$(swift_locate_prof)"
  if [[ -z "$bin" || -z "$prof" ]]; then
    echo "error: no Swift coverage data found — run --swift-build first" >&2
    return 3
  fi
  (
    cd "$SWIFT_APP"
    if [[ "$scope" == "ALL" ]]; then
      xcrun llvm-cov export -summary-only "$bin" -instr-profile "$prof"
    else
      xcrun llvm-cov export -summary-only "$bin" -instr-profile "$prof" "$scope"
    fi
  )
}

# $1 = threshold. Reads llvm-cov export JSON on stdin, gates on totals.lines.percent.
swift_parse_json() {
  local th="$1" tmp rc=0
  tmp="$(mktemp)"
  cat > "$tmp"
  python3 - "$th" "$tmp" <<'PY' || rc=$?
import sys, json
threshold = float(sys.argv[1])
with open(sys.argv[2]) as fh:
    data = json.load(fh)
pct = float(data["data"][0]["totals"]["lines"]["percent"])
print(f"SWIFT RaceStudioCore line coverage: {pct:.2f}%")
if pct + 1e-9 < threshold:
    print(f"FAIL: RaceStudioCore {pct:.2f}% < {threshold:.0f}% threshold")
    sys.exit(1)
print(f"PASS: RaceStudioCore {pct:.2f}% >= {threshold:.0f}% threshold")
PY
  rm -f "$tmp"
  return "$rc"
}

run_swiftlint() {
  echo "==> [swift lint] swiftlint lint --strict (app)"
  local dyld=""
  if [[ "$(xcode-select -p 2>/dev/null || true)" == *CommandLineTools* ]]; then
    # SwiftLint's SourceKit lives in the CLT when no full Xcode is installed.
    dyld="/Library/Developer/CommandLineTools/usr/lib"
  fi
  (
    cd "$SWIFT_APP"
    if [[ -n "$dyld" ]]; then
      DYLD_FRAMEWORK_PATH="$dyld" swiftlint lint --strict
    else
      swiftlint lint --strict
    fi
  )
}

swift_gate() {
  echo "==> Swift gate: RaceStudioCore line-coverage threshold ${THRESHOLD}%"
  run_swiftlint
  swift_build_coverage
  echo "==> [swift 2/2] xcrun llvm-cov export -summary-only … ${CORE_SCOPE}"
  swift_export "$CORE_SCOPE" | swift_parse_json "$THRESHOLD"
}

# --------------------------------------------------------------------------- #
# Rust gate (issue 0.2)
# --------------------------------------------------------------------------- #

rust_gate() {
  echo "==> Rust gate: line-coverage threshold ${THRESHOLD}% (workspace: ${RUST_WORKSPACE})"
  (
    cd "$RUST_WORKSPACE"
    echo "==> [rust 1/4] cargo fmt --all --check"
    cargo fmt --all --check
    echo "==> [rust 2/4] cargo clippy --workspace --all-targets -- -D warnings"
    cargo clippy --workspace --all-targets -- -D warnings
    echo "==> [rust 3/4] cargo test --workspace"
    cargo test --workspace
    echo "==> [rust 4/4] cargo llvm-cov --workspace --fail-under-lines ${THRESHOLD}"
    cargo llvm-cov --workspace --no-report
    echo "==> [diag] show-missing-lines"
    cargo llvm-cov report --show-missing-lines || true
    cargo llvm-cov report --fail-under-lines "${THRESHOLD}"
    if [[ "${EMIT_LCOV:-0}" == "1" ]]; then
      cargo llvm-cov report --lcov --output-path target/lcov.info
    fi
  )
  echo "PASS: Rust gate green — workspace line coverage >= ${THRESHOLD}%"
}

# --------------------------------------------------------------------------- #
# Dispatch — internal sub-modes exit before the ERR trap is installed.
# --------------------------------------------------------------------------- #

case "${1:-}" in
  --print-config)
    echo "THRESHOLD=${THRESHOLD}"
    echo "RUST_WORKSPACE=${RUST_WORKSPACE}"
    echo "SWIFT_APP=${SWIFT_APP}"
    exit 0
    ;;
  --swift-parse-json)
    swift_parse_json "${2:-$THRESHOLD}"
    exit $?
    ;;
  --swift-build)
    swift_build_coverage
    exit $?
    ;;
  --swift-export)
    swift_export "${2:-$CORE_SCOPE}"
    exit $?
    ;;
  --swift-lint)
    run_swiftlint
    exit $?
    ;;
esac

on_error() { echo "FAIL: coverage gate failed (see output above)" >&2; }
trap on_error ERR

case "${1:-}" in
  --rust-only)  rust_gate ;;
  --swift-only) swift_gate ;;
  "")           rust_gate; swift_gate ;;
  *)
    echo "usage: coverage.sh [--rust-only|--swift-only|--print-config]" >&2
    exit 2
    ;;
esac

echo "PASS: coverage gate green (threshold ${THRESHOLD}%)"
