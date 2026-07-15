#!/usr/bin/env bash
#
# Wrapper around `swift test "$@"` that injects the swift-testing framework
# search paths + rpaths when only Apple's Command Line Tools are installed
# (no full Xcode). Without them SwiftPM builds the test bundle but cannot load
# swift-testing at runtime, so `swift test` runs zero tests; with them it builds
# AND runs. Ported from XRKConverter's scripts/swift_test.sh.
#
# On a full-Xcode runner these paths are unnecessary and are not injected, so the
# wrapper is a transparent pass-through. Set SWIFT_TEST_FORCE_CLT=1 to force the
# CLT branch (used by the tests). `--print-flags` prints the computed flags and
# exits without invoking swift.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="${SWIFT_APP:-$(cd "$SCRIPT_DIR/../app" && pwd)}"

# Resolve the developer dir. When forcing CLT (or when xcode-select points at
# the Command Line Tools) use the CLT layout, which ships swift-testing.
if [[ "${SWIFT_TEST_FORCE_CLT:-0}" == "1" ]]; then
  DEV="/Library/Developer/CommandLineTools"
else
  DEV="$(xcode-select -p 2>/dev/null || true)"
fi

EXTRA=()
if [[ "$DEV" == *CommandLineTools* ]]; then
  FW="$DEV/Library/Developer/Frameworks"
  LIB="$DEV/Library/Developer/usr/lib"
  if [[ -d "$FW/Testing.framework" ]]; then
    EXTRA=(
      -Xswiftc -F -Xswiftc "$FW"
      -Xlinker -F -Xlinker "$FW"
      -Xlinker -rpath -Xlinker "$FW"
      -Xlinker -rpath -Xlinker "$LIB"
    )
  fi
fi

if [[ "${1:-}" == "--print-flags" ]]; then
  # bash 3.2-safe: only expand the array when it is non-empty.
  if [[ ${#EXTRA[@]} -gt 0 ]]; then
    printf '%s\n' "${EXTRA[@]}"
  fi
  exit 0
fi

cd "$APP_DIR"
# bash 3.2-safe empty-array expansion guard (avoids "unbound variable" on set -u).
if [[ ${#EXTRA[@]} -gt 0 ]]; then
  exec swift test "${EXTRA[@]}" "$@"
else
  exec swift test "$@"
fi
