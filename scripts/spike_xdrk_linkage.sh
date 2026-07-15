#!/usr/bin/env bash
#
# spike_xdrk_linkage.sh — reproducible linkage probe for issue 1.1 (decode ADR).
#
# Question: is the third-party `xdrk` crate a *native* Rust `.xrk` reader, or does
# it link/vendor AiM's proprietary C library? If the latter, wrapping it would
# reintroduce the exact non-native, redistribution-encumbered dependency that the
# native rewrite (M1) exists to remove — so this probe's verdict decides the ADR.
#
# It touches NOTHING in the repo: it builds a throwaway crate in a temp dir, adds
# `xdrk`, fetches its source, and inspects the vendored binaries + `build.rs`
# link directives. Read-only w.r.t. the working tree.
#
# The committed finding it produced lives in docs/spike/xdrk-linkage.md and the
# decision it informed in docs/adr/0002-xrk-decode-strategy.md.
#
# Usage:
#   bash scripts/spike_xdrk_linkage.sh            # probe, print evidence + VERDICT
#   bash scripts/spike_xdrk_linkage.sh --crate X  # probe a different crate name
#
# Equivalent by hand (what this script automates):
#   cd "$(mktemp -d)" && cargo new --lib probe && cd probe
#   cargo add xdrk && cargo fetch
#   SRC=$(find ~/.cargo/registry/src -maxdepth 2 -type d -name 'xdrk-*' | sort | tail -1)
#   file "$SRC"/aim/* ; grep -n 'rustc-link-lib' "$SRC/build.rs"
#
# Requires: cargo (network access to crates.io) and coreutils `file`.
set -uo pipefail

CRATE="xdrk"
while [ $# -gt 0 ]; do
  case "$1" in
    --crate) CRATE="$2"; shift 2 ;;
    -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

# Make cargo available even in a non-login shell.
[ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"
command -v cargo >/dev/null 2>&1 || { echo "cargo not found on PATH" >&2; exit 127; }

WORK="$(mktemp -d)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

echo "==> probing crate '$CRATE' in throwaway project $WORK"
cargo new --lib --vcs none "$WORK/probe" >/dev/null 2>&1
(
  cd "$WORK/probe" || exit 1
  cargo add "$CRATE" >/dev/null 2>&1 || { echo "cargo add $CRATE failed" >&2; exit 1; }
  cargo fetch >/dev/null 2>&1 || true
) || exit 1

# Locate the fetched crate source in the registry cache (highest version dir).
SRC="$(find "$HOME/.cargo/registry/src" -maxdepth 2 -type d -name "${CRATE}-*" 2>/dev/null | sort | tail -1)"
[ -n "$SRC" ] && [ -d "$SRC" ] || { echo "could not locate $CRATE source in registry cache" >&2; exit 1; }
echo "==> source: $SRC"

echo
echo "---- vendored binaries (look for non-Rust, proprietary, platform-locked libs) ----"
VENDORED=""
if [ -d "$SRC/aim" ]; then
  VENDORED="$SRC/aim"
fi
# Fall back to scanning for shipped object/lib files anywhere in the crate.
BINS="$(find "$SRC" -type f \( -name '*.so' -o -name '*.so.*' -o -name '*.dll' \
        -o -name '*.dylib' -o -name '*.a' -o -name '*.lib' \) 2>/dev/null | sort)"
if [ -n "$BINS" ]; then
  # shellcheck disable=SC2086
  file $BINS
else
  echo "(none found)"
fi

echo
echo "---- build.rs link directives ----"
if [ -f "$SRC/build.rs" ]; then
  grep -n "rustc-link-lib\|rustc-link-search" "$SRC/build.rs" || echo "(no link directives in build.rs)"
else
  echo "(no build.rs — crate ships no native link step)"
fi

echo
echo "---- native-Rust check ----"
# Native == no shipped .so/.dll/.dylib/.a AND no rustc-link-lib against a vendored lib.
HAS_VENDORED_BIN="no"; [ -n "$BINS" ] && HAS_VENDORED_BIN="yes"
HAS_LINK_DIRECTIVE="no"
[ -f "$SRC/build.rs" ] && grep -q "rustc-link-lib" "$SRC/build.rs" && HAS_LINK_DIRECTIVE="yes"
# A macOS-native artifact would be a .dylib or an arm64/aarch64 object.
HAS_MACOS_ARTIFACT="no"
if [ -n "$BINS" ] && printf '%s\n' "$BINS" | grep -qi '\.dylib$'; then HAS_MACOS_ARTIFACT="yes"; fi
if [ -n "$BINS" ] && file $BINS 2>/dev/null | grep -qi 'arm64\|aarch64\|Mach-O'; then HAS_MACOS_ARTIFACT="yes"; fi

echo "  vendored native binaries present : $HAS_VENDORED_BIN"
echo "  build.rs links a vendored lib    : $HAS_LINK_DIRECTIVE"
echo "  native macOS/arm64 artifact       : $HAS_MACOS_ARTIFACT"

echo
if [ "$HAS_VENDORED_BIN" = "yes" ] || [ "$HAS_LINK_DIRECTIVE" = "yes" ]; then
  echo "VERDICT: '$CRATE' is NON-NATIVE — it links/vendors a proprietary C library."
  if [ "$HAS_MACOS_ARTIFACT" = "no" ]; then
    echo "         Worse: it ships NO native macOS/arm64 artifact, so it cannot even"
    echo "         link on Apple Silicon. Rejected for the native rewrite."
  fi
  exit 0
else
  echo "VERDICT: '$CRATE' appears NATIVE — no vendored libs or link directives found."
  echo "         Re-evaluate the ADR: a native crate may be viable."
  exit 0
fi
