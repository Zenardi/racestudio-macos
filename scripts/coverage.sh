#!/usr/bin/env bash
#
# Rust quality + coverage gate for racestudio-macos (issue 0.2).
#
# One threshold-driven script, run identically locally and in CI (macos-15),
# mirroring XRKConverter's scripts/coverage.sh convention. It runs, in order:
#
#   1. cargo fmt   --all --check                     (format gate)
#   2. cargo clippy --workspace --all-targets -- -D warnings   (lint gate)
#   3. cargo test  --workspace                       (tests)
#   4. cargo llvm-cov --workspace --fail-under-lines $THRESHOLD (coverage gate)
#
# Any failing step fails the build; the coverage step prints the measured
# line-coverage percentage and exits non-zero when it is below the threshold.
#
# Configuration (env):
#   COVERAGE_THRESHOLD   minimum line-coverage %% (default: 95)
#   RUST_WORKSPACE       dir holding the workspace Cargo.toml (default: repo root)
#   EMIT_LCOV=1          additionally write target/lcov.info for local inspection
#
# The Swift half of this gate lands in issue 0.3; branch-protection wiring is 0.7.
#
# `--print-config` prints the resolved configuration and exits 0 without running
# the gate (used by the test harness).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

THRESHOLD="${COVERAGE_THRESHOLD:-95}"
# The workspace Cargo.toml lives at the repo root in this project (unlike
# XRKConverter's core/ layout), so default there; overridable for testing.
RUST_WORKSPACE="${RUST_WORKSPACE:-$ROOT}"

if [[ "${1:-}" == "--print-config" ]]; then
  echo "THRESHOLD=${THRESHOLD}"
  echo "RUST_WORKSPACE=${RUST_WORKSPACE}"
  exit 0
fi

on_error() { echo "FAIL: Rust gate failed (see output above)" >&2; }
trap on_error ERR

echo "==> Rust gate: line-coverage threshold ${THRESHOLD}% (workspace: ${RUST_WORKSPACE})"
cd "$RUST_WORKSPACE"

echo "==> [1/4] cargo fmt --all --check"
cargo fmt --all --check

echo "==> [2/4] cargo clippy --workspace --all-targets -- -D warnings"
cargo clippy --workspace --all-targets -- -D warnings

echo "==> [3/4] cargo test --workspace"
cargo test --workspace

echo "==> [4/4] cargo llvm-cov --workspace --fail-under-lines ${THRESHOLD}"
# Collect coverage once, then report: the report enforces the threshold and
# prints the measured percentage; optionally also emit lcov (non-gating).
cargo llvm-cov --workspace --no-report
cargo llvm-cov report --fail-under-lines "${THRESHOLD}"
if [[ "${EMIT_LCOV:-0}" == "1" ]]; then
  echo "==> emitting lcov -> ${RUST_WORKSPACE}/target/lcov.info"
  cargo llvm-cov report --lcov --output-path target/lcov.info
fi

echo "PASS: Rust gate green — workspace line coverage >= ${THRESHOLD}%"
