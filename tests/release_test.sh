#!/usr/bin/env bash
#
# Tests for the tag-driven release pipeline (issue #50).
#
# Scope note: this project ships **unsigned** builds on purpose — no Apple
# Developer ID certificate, no notarization. The pipeline must therefore need no
# signing secrets at all, and the artifact it publishes is a plain, ad-hoc-signed
# `.dmg` attached to a GitHub Release (Gatekeeper caveat documented in
# docs/RELEASE.md). `test_release_pipeline_needs_no_signing_secrets` pins that
# decision so a future edit cannot quietly reintroduce a secrets dependency that
# would make tag builds fail for anyone without the cert.
#
# Workflow assertions are static (parse .github/workflows/release.yml); the
# packaging assertions are dynamic — `scripts/release_smoke.sh --dry-run` runs
# the real bundle-assembly and DMG code over a stub executable, so the packaging
# logic is exercised without a full Swift build. Given-When-Then; no logic
# beyond string/file checks.
#
# Usage: bash tests/release_test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WF="$ROOT/.github/workflows/release.yml"
BUILD_APP="$ROOT/scripts/build_app.sh"
PACKAGE_DMG="$ROOT/scripts/package_dmg.sh"
SMOKE="$ROOT/scripts/release_smoke.sh"
RELEASE_DOC="$ROOT/docs/RELEASE.md"

PASS=0
FAIL=0
ok()  { printf '  ok   - %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL - %s: %s\n' "$1" "${2:-}"; FAIL=$((FAIL + 1)); }

# One job's block, so job-scoped assertions cannot be satisfied by a match
# somewhere else in the file.
job_block() {
  [ -f "$WF" ] || return 0
  awk -v job="  $1:" '
    $0 == job { inside = 1; next }
    inside && /^  [a-zA-Z0-9_-]+:/ { inside = 0 }
    inside { print }
  ' "$WF"
}

# ---------------------------------------------------------------------------
# The dry run is shared by every packaging assertion: run it once, then assert.

SMOKE_OUT=""
SMOKE_LOG=""
SMOKE_RC=1
SMOKE_VERSION="9.9.9"

run_smoke_once() {
  [ -n "$SMOKE_OUT" ] && return 0
  SMOKE_OUT="$(mktemp -d)"
  SMOKE_LOG="$SMOKE_OUT/smoke.log"
  if [ -f "$SMOKE" ]; then
    bash "$SMOKE" --dry-run --version "$SMOKE_VERSION" --out "$SMOKE_OUT" \
      >"$SMOKE_LOG" 2>&1
    SMOKE_RC=$?
  else
    echo "scripts/release_smoke.sh missing" >"$SMOKE_LOG"
    SMOKE_RC=127
  fi
}

cleanup() {
  [ -n "$SMOKE_OUT" ] && rm -rf "$SMOKE_OUT"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------

test_release_yml_triggers_on_version_tag() {
  # Given the release workflow, Then pushing a `v*` tag triggers it.
  local triggers
  triggers="$([ -f "$WF" ] && awk '/^on:/,/^jobs:/' "$WF")"
  if grep -q "'v\*'" <<<"$triggers"; then
    ok "test_release_yml_triggers_on_version_tag"
  else
    bad "test_release_yml_triggers_on_version_tag" "no tags: ['v*'] trigger"
  fi
}

test_release_yml_supports_manual_dispatch() {
  # Given the release workflow, Then it can also be run by hand with a version.
  if [ -f "$WF" ] && grep -q 'workflow_dispatch:' "$WF"; then
    ok "test_release_yml_supports_manual_dispatch"
  else
    bad "test_release_yml_supports_manual_dispatch" "no workflow_dispatch trigger"
  fi
}

test_build_needs_verify_job() {
  # Given the release workflow, Then `build` runs only after `verify` passes.
  local b
  b="$(job_block build)"
  if grep -qE '^[[:space:]]*needs:[[:space:]]*verify[[:space:]]*$' <<<"$b"; then
    ok "test_build_needs_verify_job"
  else
    bad "test_build_needs_verify_job" "build job has no 'needs: verify'"
  fi
}

test_verify_job_runs_the_ci_gate() {
  # Given the release workflow, Then `verify` re-runs the same lint + 95%
  # coverage + e2e gate CI runs, so a tag can never ship an unverified build.
  local v
  v="$(job_block verify)"
  if grep -qE '(^|[^a-z-])make ci([^a-z-]|$)' <<<"$v"; then
    ok "test_verify_job_runs_the_ci_gate"
  else
    bad "test_verify_job_runs_the_ci_gate" "verify job does not run 'make ci'"
  fi
}

test_version_derived_from_tag() {
  # Given a tag `v1.2.0`, Then VERSION is derived from it as `1.2.0`.
  if [ -f "$WF" ] && grep -q 'GITHUB_REF_NAME#v' "$WF"; then
    ok "test_version_derived_from_tag"
  else
    bad "test_version_derived_from_tag" "VERSION is not stripped from the tag name"
  fi
}

test_release_pipeline_needs_no_signing_secrets() {
  # Given this project ships unsigned builds, Then the workflow references no
  # secret other than the automatic GITHUB_TOKEN, and never invokes the Apple
  # Developer ID / notarization toolchain.
  local secrets tools
  if [ ! -f "$WF" ]; then
    bad "test_release_pipeline_needs_no_signing_secrets" "workflow missing"
    return
  fi
  secrets="$(grep -oE 'secrets\.[A-Za-z_][A-Za-z0-9_]*' "$WF" | sort -u \
    | grep -v '^secrets.GITHUB_TOKEN$')"
  tools="$(grep -oE 'notarytool|stapler|security import|create-keychain|Developer ID' "$WF" | sort -u)"
  if [ -z "$secrets" ] && [ -z "$tools" ]; then
    ok "test_release_pipeline_needs_no_signing_secrets"
  else
    bad "test_release_pipeline_needs_no_signing_secrets" \
      "secrets=[${secrets//$'\n'/ }] tools=[${tools//$'\n'/ }]"
  fi
}

test_release_publishes_dmg_asset() {
  # Given a tag push, Then the build job publishes a GitHub Release with the
  # .dmg and its checksums attached.
  local b
  b="$(job_block build)"
  if grep -q 'softprops/action-gh-release' <<<"$b" \
    && grep -q '\.dmg' <<<"$b" && grep -q 'SHA256SUMS.txt' <<<"$b"; then
    ok "test_release_publishes_dmg_asset"
  else
    bad "test_release_publishes_dmg_asset" "no release step attaching the .dmg"
  fi
}

test_build_app_builds_a_universal_binary() {
  # Given scripts/build_app.sh, Then the shipped binary is built for both
  # Apple Silicon and Intel.
  if [ -f "$BUILD_APP" ] && grep -q -- '--arch arm64' "$BUILD_APP" \
    && grep -q -- '--arch x86_64' "$BUILD_APP" \
    && grep -q -- 'lipo -create' "$BUILD_APP"; then
    ok "test_build_app_builds_a_universal_binary"
  else
    bad "test_build_app_builds_a_universal_binary" "no universal swift build"
  fi
}

test_dry_run_packages_dmg_and_checksums() {
  # Given `release_smoke.sh --dry-run`, Then it exits 0 having produced the
  # versioned .dmg and a SHA256SUMS.txt beside it.
  run_smoke_once
  if [ "$SMOKE_RC" -eq 0 ] \
    && [ -f "$SMOKE_OUT/RaceStudio-$SMOKE_VERSION.dmg" ] \
    && [ -f "$SMOKE_OUT/SHA256SUMS.txt" ]; then
    ok "test_dry_run_packages_dmg_and_checksums"
  else
    bad "test_dry_run_packages_dmg_and_checksums" \
      "rc=$SMOKE_RC $(tail -3 "$SMOKE_LOG" 2>/dev/null | tr '\n' ' ')"
  fi
}

test_dry_run_checksums_match_the_dmg() {
  # Given the published SHA256SUMS.txt, Then it verifies against the artifacts.
  run_smoke_once
  if [ -f "$SMOKE_OUT/SHA256SUMS.txt" ] \
    && ( cd "$SMOKE_OUT" && shasum -a 256 -c SHA256SUMS.txt >/dev/null 2>&1 ); then
    ok "test_dry_run_checksums_match_the_dmg"
  else
    bad "test_dry_run_checksums_match_the_dmg" "checksum file absent or stale"
  fi
}

test_dry_run_dmg_offers_drag_to_applications() {
  # Given the packaged .dmg, When it is mounted, Then it holds RaceStudio.app
  # next to an /Applications symlink so install is a drag.
  run_smoke_once
  local dmg mnt out
  dmg="$SMOKE_OUT/RaceStudio-$SMOKE_VERSION.dmg"
  if [ ! -f "$dmg" ]; then
    bad "test_dry_run_dmg_offers_drag_to_applications" "no .dmg to mount"
    return
  fi
  mnt="$(mktemp -d)"
  if ! hdiutil attach "$dmg" -nobrowse -readonly -mountpoint "$mnt" >/dev/null 2>&1; then
    bad "test_dry_run_dmg_offers_drag_to_applications" "hdiutil attach failed"
    rmdir "$mnt" 2>/dev/null
    return
  fi
  out=""
  [ -d "$mnt/RaceStudio.app" ] || out="$out no-app"
  [ -L "$mnt/Applications" ] || out="$out no-applications-link"
  [ -x "$mnt/RaceStudio.app/Contents/MacOS/RaceStudio" ] || out="$out no-executable"
  hdiutil detach "$mnt" -quiet >/dev/null 2>&1 \
    || hdiutil detach "$mnt" -force -quiet >/dev/null 2>&1
  rmdir "$mnt" 2>/dev/null
  if [ -z "$out" ]; then
    ok "test_dry_run_dmg_offers_drag_to_applications"
  else
    bad "test_dry_run_dmg_offers_drag_to_applications" "$out"
  fi
}

test_dry_run_bundle_is_universal_and_adhoc_signed() {
  # Given the assembled bundle, Then it carries both architectures and an
  # ad-hoc signature (the strongest signature available without a Developer ID),
  # so it at least launches once the user clears quarantine.
  run_smoke_once
  local app archs sig out=""
  app="$SMOKE_OUT/RaceStudio.app"
  if [ ! -d "$app" ]; then
    bad "test_dry_run_bundle_is_universal_and_adhoc_signed" "no .app assembled"
    return
  fi
  archs="$(lipo -archs "$app/Contents/MacOS/RaceStudio" 2>/dev/null)"
  grep -q 'arm64' <<<"$archs" || out="$out missing-arm64"
  grep -q 'x86_64' <<<"$archs" || out="$out missing-x86_64"
  sig="$(codesign -dv "$app" 2>&1 || true)"
  grep -q 'Signature=adhoc' <<<"$sig" || out="$out not-adhoc-signed"
  if [ -z "$out" ]; then
    ok "test_dry_run_bundle_is_universal_and_adhoc_signed"
  else
    bad "test_dry_run_bundle_is_universal_and_adhoc_signed" "$out (archs=$archs)"
  fi
}

test_dry_run_bundle_carries_the_requested_version_and_utis() {
  # Given `--version 9.9.9`, Then the bundle's Info.plist states it — and still
  # carries the app's document-type/UTI declarations, so packaging derives the
  # plist from the source of truth rather than duplicating a stripped copy.
  run_smoke_once
  local plist short out=""
  plist="$SMOKE_OUT/RaceStudio.app/Contents/Info.plist"
  if [ ! -f "$plist" ]; then
    bad "test_dry_run_bundle_carries_the_requested_version_and_utis" "no Info.plist"
    return
  fi
  short="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist" 2>/dev/null)"
  [ "$short" = "$SMOKE_VERSION" ] || out="$out version=$short"
  grep -q 'com.aim-sportline.xrk' "$plist" || out="$out missing-xrk-uti"
  [ -f "$SMOKE_OUT/RaceStudio.app/Contents/Resources/AppIcon.icns" ] || out="$out missing-icon"
  if [ -z "$out" ]; then
    ok "test_dry_run_bundle_carries_the_requested_version_and_utis"
  else
    bad "test_dry_run_bundle_carries_the_requested_version_and_utis" "$out"
  fi
}

test_make_dmg_builds_and_packages() {
  # Given `make dmg`, Then it builds the .app and packages the .dmg.
  local out
  out="$(make -C "$ROOT" -n dmg 2>&1)"
  if grep -q 'scripts/build_app.sh' <<<"$out" \
    && grep -q 'scripts/package_dmg.sh' <<<"$out"; then
    ok "test_make_dmg_builds_and_packages"
  else
    bad "test_make_dmg_builds_and_packages" "$(head -2 <<<"$out" | tr '\n' ' ')"
  fi
}

test_release_doc_warns_about_gatekeeper() {
  # Given unsigned artifacts, Then the release doc tells users how to open them
  # (Gatekeeper blocks a quarantined, non-notarized app by default).
  if [ -f "$RELEASE_DOC" ] && grep -qi 'gatekeeper' "$RELEASE_DOC" \
    && grep -q 'com.apple.quarantine' "$RELEASE_DOC"; then
    ok "test_release_doc_warns_about_gatekeeper"
  else
    bad "test_release_doc_warns_about_gatekeeper" "docs/RELEASE.md missing the caveat"
  fi
}

test_packaging_scripts_are_executable_and_strict() {
  # Given the packaging scripts, Then each is executable and fails fast.
  local f out=""
  for f in "$BUILD_APP" "$PACKAGE_DMG" "$SMOKE"; do
    [ -x "$f" ] || { out="$out $(basename "$f"):not-executable"; continue; }
    grep -q 'set -euo pipefail' "$f" || out="$out $(basename "$f"):not-strict"
  done
  if [ -z "$out" ]; then
    ok "test_packaging_scripts_are_executable_and_strict"
  else
    bad "test_packaging_scripts_are_executable_and_strict" "$out"
  fi
}

# ---------------------------------------------------------------------------

echo "Running release-pipeline tests"
test_release_yml_triggers_on_version_tag
test_release_yml_supports_manual_dispatch
test_build_needs_verify_job
test_verify_job_runs_the_ci_gate
test_version_derived_from_tag
test_release_pipeline_needs_no_signing_secrets
test_release_publishes_dmg_asset
test_build_app_builds_a_universal_binary
test_packaging_scripts_are_executable_and_strict
test_dry_run_packages_dmg_and_checksums
test_dry_run_checksums_match_the_dmg
test_dry_run_dmg_offers_drag_to_applications
test_dry_run_bundle_is_universal_and_adhoc_signed
test_dry_run_bundle_carries_the_requested_version_and_utis
test_make_dmg_builds_and_packages
test_release_doc_warns_about_gatekeeper

echo
echo "release tests: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
