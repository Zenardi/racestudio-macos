#!/usr/bin/env bash
#
# Decide which version the release pipeline builds, and whether it publishes.
#
# Policy: **every commit that lands on `main` ships.** A merge to `main` is a
# change users should be able to download, so the pipeline mints the next patch
# version itself rather than waiting for someone to remember a tag -- which is
# how v0.1.0 stayed the only release while `main` moved on past a crash fix.
#
# The rules, in precedence order:
#
#   1. an explicit `--input-version` (a manual `workflow_dispatch`) builds that
#      version but does **not** publish: a dry run must never mint a tag;
#   2. a `v*` tag push builds and publishes exactly that tag;
#   3. a push to `main` builds and publishes the newest `v*` tag with its patch
#      segment incremented -- unless the commit is already tagged, in which case
#      that tag's own push is publishing it and this run must not duplicate it.
#
# This lives in a script, not inline in the workflow, so `tests/release_test.sh`
# can exercise every branch with injected inputs instead of trusting YAML.
#
# Usage:
#   scripts/next_version.sh [--input-version V] [--ref-type tag|branch]
#                           [--ref-name N] [--latest-tag v1.2.3] [--head-tags "v1.2.3 ..."]
#
# Defaults come from the environment GitHub Actions provides and from `git`;
# every one is overridable so the decision logic is testable without tags.
#
# Prints `GITHUB_OUTPUT`-shaped lines:
#   version=1.2.4
#   publish=true
set -euo pipefail

INPUT_VERSION="${INPUT_VERSION:-}"
REF_TYPE="${GITHUB_REF_TYPE:-branch}"
REF_NAME="${GITHUB_REF_NAME:-}"
LATEST_TAG=""
HEAD_TAGS=""
LATEST_TAG_SET=0
HEAD_TAGS_SET=0

while [ $# -gt 0 ]; do
  case "$1" in
    --input-version) INPUT_VERSION="${2-}"; shift 2 ;;
    --ref-type) REF_TYPE="${2:?--ref-type needs a value}"; shift 2 ;;
    --ref-name) REF_NAME="${2-}"; shift 2 ;;
    --latest-tag) LATEST_TAG="${2-}"; LATEST_TAG_SET=1; shift 2 ;;
    --head-tags) HEAD_TAGS="${2-}"; HEAD_TAGS_SET=1; shift 2 ;;
    -h|--help) sed -n '2,30p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

[ "$LATEST_TAG_SET" -eq 1 ] \
  || LATEST_TAG="$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null || true)"
[ "$HEAD_TAGS_SET" -eq 1 ] \
  || HEAD_TAGS="$(git tag --points-at HEAD 2>/dev/null | tr '\n' ' ')"

emit() {
  echo "version=$1"
  echo "publish=$2"
}

# 1. Manual run with an explicit version: build only.
if [ -n "$INPUT_VERSION" ]; then
  emit "${INPUT_VERSION#v}" false
  exit 0
fi

# 2. Tag push: that tag is the release.
if [ "$REF_TYPE" = "tag" ]; then
  if [ -z "$REF_NAME" ]; then
    echo "next_version: a tag build needs --ref-name" >&2
    exit 1
  fi
  emit "${REF_NAME#v}" true
  exit 0
fi

# 3. Branch push. Only `main` ships; any other branch just builds.
if [ "$REF_NAME" != "main" ]; then
  FALLBACK="${LATEST_TAG#v}"
  emit "${FALLBACK:-0.0.0}" false
  exit 0
fi

# A commit that already carries a v* tag is being published by that tag's own
# push; publishing here too would race it and create a duplicate release.
for tag in $HEAD_TAGS; do
  case "$tag" in
    v*) emit "${tag#v}" false; exit 0 ;;
  esac
done

# No tags yet: start at 0.1.0. Bumping the patch of an implied 0.0.0 would
# publish 0.0.1, which reads like a broken counter rather than a first release.
if [ -z "$LATEST_TAG" ]; then
  emit "0.1.0" true
  exit 0
fi

BASE="${LATEST_TAG#v}"
if ! [[ "$BASE" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
  echo "next_version: newest tag '$LATEST_TAG' is not vX.Y.Z; cannot derive the next version" >&2
  exit 1
fi

emit "${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.$((BASH_REMATCH[3] + 1))" true
