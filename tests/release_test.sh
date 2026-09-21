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
NEXT_VERSION="$ROOT/scripts/next_version.sh"
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
  # Given a tag `v1.2.0`, Then the version is derived from it as `1.2.0`.
  # The derivation moved out of the workflow into next_version.sh, so this
  # asserts the behaviour rather than the YAML text (see also
  # test_tag_push_uses_the_tag_and_publishes for the publish decision).
  local out
  out="$(nv v0.9.0 "v1.2.0" tag v1.2.0)"
  if grep -q '^version=1\.2\.0$' <<<"$out"; then
    ok "test_version_derived_from_tag"
  else
    bad "test_version_derived_from_tag" "$(tr '\n' ' ' <<<"$out")"
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

test_dry_run_bundle_ships_the_localization_catalog() {
  # Given a packaged bundle, Then Localizable.xcstrings is inside
  # Contents/Resources/RaceStudio_RaceStudioCore.bundle.
  #
  # Regression: v0.1.0 shipped without this bundle, so SwiftPM's Bundle.module
  # accessor fatalError'd on the first localized string and the app died the
  # moment a session was opened for analysis.
  run_smoke_once
  local catalog
  catalog="$SMOKE_OUT/RaceStudio.app/Contents/Resources/RaceStudio_RaceStudioCore.bundle/Localizable.xcstrings"
  if [ -f "$catalog" ] && grep -q 'sourceLanguage' "$catalog"; then
    ok "test_dry_run_bundle_ships_the_localization_catalog"
  else
    bad "test_dry_run_bundle_ships_the_localization_catalog" "missing or invalid $catalog"
  fi
}

test_build_app_requires_the_resource_bundle() {
  # Given a build whose resource bundle is absent, Then build_app.sh fails loudly
  # rather than emitting an .app that traps at runtime.
  local work out rc=0
  work="$(mktemp -d)"
  printf 'int main(void) { return 0; }\n' > "$work/stub.c"
  cc -arch arm64 -arch x86_64 -o "$work/RaceStudio" "$work/stub.c" 2>/dev/null
  out="$(bash "$BUILD_APP" --version 0.0.0-nores --out "$work/out" \
    --executable "$work/RaceStudio" --resource-bundle "$work/absent.bundle" 2>&1)" || rc=$?
  rm -rf "$work"
  if [ "$rc" -ne 0 ] && grep -qi 'resource bundle not found' <<<"$out"; then
    ok "test_build_app_requires_the_resource_bundle"
  else
    bad "test_build_app_requires_the_resource_bundle" "rc=$rc out=$(head -3 <<<"$out" | tr '\n' ' ')"
  fi
}

test_app_does_not_depend_on_swiftpm_bundle_module() {
  # Given the shipped sources, Then no runtime code touches `Bundle.module`: its
  # release accessor fatalErrors on a miss and bakes in the *build machine's*
  # absolute path, neither of which survives packaging. ResourceBundle resolves
  # the bundle totally instead. Tests may still use Bundle.module.
  local hits
  hits="$(grep -rn 'Bundle\.module\|from: \.module' "$ROOT/app/Sources" \
    --include='*.swift' | grep -v '^\s*//' | grep -v '///' || true)"
  if [ -z "$hits" ]; then
    ok "test_app_does_not_depend_on_swiftpm_bundle_module"
  else
    bad "test_app_does_not_depend_on_swiftpm_bundle_module" "$(head -2 <<<"$hits" | tr '\n' ' ')"
  fi
}

# --- automatic tagging (every commit to main ships) -------------------------

# Run next_version.sh with git lookups stubbed out, so the decision logic is
# tested directly instead of through whatever tags this checkout happens to have.
nv() {
  bash "$NEXT_VERSION" --latest-tag "$1" --head-tags "$2" \
    --ref-type "$3" --ref-name "$4" --input-version "${5:-}" 2>&1
}

test_main_push_bumps_the_patch_version() {
  # Given a push to main on top of v0.2.0, Then the next release is v0.2.1.
  local out
  out="$(nv v0.2.0 "" branch main)"
  if grep -q '^version=0\.2\.1$' <<<"$out" && grep -q '^publish=true$' <<<"$out"; then
    ok "test_main_push_bumps_the_patch_version"
  else
    bad "test_main_push_bumps_the_patch_version" "$(tr '\n' ' ' <<<"$out")"
  fi
}

test_main_push_with_no_tags_yet_starts_at_0_1_0() {
  # Given a repo with no v* tag, Then the first automatic release is 0.1.0 --
  # never 0.0.1, which reads like a broken bump.
  local out
  out="$(nv "" "" branch main)"
  if grep -q '^version=0\.1\.0$' <<<"$out" && grep -q '^publish=true$' <<<"$out"; then
    ok "test_main_push_with_no_tags_yet_starts_at_0_1_0"
  else
    bad "test_main_push_with_no_tags_yet_starts_at_0_1_0" "$(tr '\n' ' ' <<<"$out")"
  fi
}

test_already_tagged_head_does_not_publish_twice() {
  # Given a main push whose commit is already tagged (someone pushed the tag by
  # hand, and that tag push is publishing it), Then this run must not publish a
  # second release for the same commit.
  local out
  out="$(nv v0.2.0 "v0.2.0" branch main)"
  if grep -q '^publish=false$' <<<"$out"; then
    ok "test_already_tagged_head_does_not_publish_twice"
  else
    bad "test_already_tagged_head_does_not_publish_twice" "$(tr '\n' ' ' <<<"$out")"
  fi
}

test_tag_push_uses_the_tag_and_publishes() {
  # Given a v* tag push, Then the version comes from the tag (unchanged
  # behaviour) and it publishes.
  local out
  out="$(nv v0.2.0 "v1.5.2" tag v1.5.2)"
  if grep -q '^version=1\.5\.2$' <<<"$out" && grep -q '^publish=true$' <<<"$out"; then
    ok "test_tag_push_uses_the_tag_and_publishes"
  else
    bad "test_tag_push_uses_the_tag_and_publishes" "$(tr '\n' ' ' <<<"$out")"
  fi
}

test_manual_dispatch_builds_without_publishing() {
  # Given an explicit version on a manual run, Then it builds that version but
  # does not cut a release -- a dry run must never mint a tag.
  local out
  out="$(nv v0.2.0 "" branch main 9.9.9)"
  if grep -q '^version=9\.9\.9$' <<<"$out" && grep -q '^publish=false$' <<<"$out"; then
    ok "test_manual_dispatch_builds_without_publishing"
  else
    bad "test_manual_dispatch_builds_without_publishing" "$(tr '\n' ' ' <<<"$out")"
  fi
}

test_other_branches_build_a_bare_version_without_publishing() {
  # Given a push on some other branch, Then it builds but never releases -- and
  # the version is bare (`0.2.0`, not `v0.2.0`), since it names the .dmg.
  local out
  out="$(nv v0.2.0 "" branch feature/x)"
  if grep -q '^version=0\.2\.0$' <<<"$out" && grep -q '^publish=false$' <<<"$out"; then
    ok "test_other_branches_build_a_bare_version_without_publishing"
  else
    bad "test_other_branches_build_a_bare_version_without_publishing" "$(tr '\n' ' ' <<<"$out")"
  fi
}

test_next_version_rejects_an_unparseable_tag() {
  # Given a latest tag that is not x.y.z, Then fail loudly rather than emitting
  # a bogus version that would be published under a wrong number.
  local rc=0
  bash "$NEXT_VERSION" --latest-tag "vBANANA" --head-tags "" \
    --ref-type branch --ref-name main >/dev/null 2>&1 || rc=$?
  if [ "$rc" -ne 0 ]; then
    ok "test_next_version_rejects_an_unparseable_tag"
  else
    bad "test_next_version_rejects_an_unparseable_tag" "accepted a non-semver tag"
  fi
}

test_release_yml_triggers_on_a_main_push() {
  # Given the policy "every commit to main ships", Then release.yml runs on a
  # push to main, not only on a tag.
  local triggers
  triggers="$([ -f "$WF" ] && awk '/^on:/,/^jobs:/' "$WF")"
  if grep -q 'branches:' <<<"$triggers" && grep -q 'main' <<<"$triggers"; then
    ok "test_release_yml_triggers_on_a_main_push"
  else
    bad "test_release_yml_triggers_on_a_main_push" "release.yml does not trigger on main"
  fi
}

test_release_yml_delegates_version_choice_to_the_script() {
  # The decision logic must live in the tested script, not inline in YAML where
  # nothing can exercise it.
  if grep -q 'scripts/next_version.sh' "$WF"; then
    ok "test_release_yml_delegates_version_choice_to_the_script"
  else
    bad "test_release_yml_delegates_version_choice_to_the_script" "version logic is not in next_version.sh"
  fi
}

test_publish_is_gated_on_the_publish_output() {
  # Publishing must follow the script's decision, and name the tag explicitly --
  # on a main push there is no tag ref for the action to infer one from.
  local b
  b="$(job_block build)"
  if grep -q "steps.version.outputs.publish == 'true'" <<<"$b" && grep -q 'tag_name:' <<<"$b"; then
    ok "test_publish_is_gated_on_the_publish_output"
  else
    bad "test_publish_is_gated_on_the_publish_output" "publish step is not gated on the publish output"
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
test_dry_run_bundle_ships_the_localization_catalog
test_build_app_requires_the_resource_bundle
test_app_does_not_depend_on_swiftpm_bundle_module
test_main_push_bumps_the_patch_version
test_main_push_with_no_tags_yet_starts_at_0_1_0
test_already_tagged_head_does_not_publish_twice
test_tag_push_uses_the_tag_and_publishes
test_manual_dispatch_builds_without_publishing
test_other_branches_build_a_bare_version_without_publishing
test_next_version_rejects_an_unparseable_tag
test_release_yml_triggers_on_a_main_push
test_release_yml_delegates_version_choice_to_the_script
test_publish_is_gated_on_the_publish_output
test_make_dmg_builds_and_packages
test_release_doc_warns_about_gatekeeper

echo
echo "release tests: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
