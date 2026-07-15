#!/usr/bin/env bash
#
# Tests for the developer front door (issue 0.6): the Makefile targets, the
# canonical Definition of Done, and the GitHub PR/issue templates.
#
# `make -n <target>` is used to assert a target expands to the right commands
# without running them. Doc/template tests assert the files carry the canonical
# content. Given-When-Then; no logic beyond string/expansion checks.
#
# Usage: bash tests/make_test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DOD="$ROOT/docs/DEFINITION_OF_DONE.md"
PR_TMPL="$ROOT/.github/PULL_REQUEST_TEMPLATE.md"
FEATURE_TMPL="$ROOT/.github/ISSUE_TEMPLATE/feature.md"

PASS=0
FAIL=0
ok()  { printf '  ok   - %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL - %s: %s\n' "$1" "${2:-}"; FAIL=$((FAIL + 1)); }

mk_n() { make -C "$ROOT" -n "$1" 2>&1; }

# The canonical 12-line DoD checklist — byte-identical to the block every issue
# pastes. `docs/DEFINITION_OF_DONE.md` and the PR template must both contain it.
canonical_dod() {
  cat <<'DOD'
- [ ] Red→Green→Refactor followed; tests written before implementation
- [ ] Every acceptance criterion in "Goal" met and demonstrable
- [ ] Rust: `cargo test` green · `cargo clippy -- -D warnings` clean · `cargo fmt --check` clean
- [ ] Swift: `swift test` green · `swiftlint` clean
- [ ] Line coverage ≥ 95% on the logic crate/target (CI gate passes)
- [ ] Overall coverage did not drop; every new public API is covered
- [ ] Tests isolated, repeatable, one-reason-to-fail (AAA / Given-When-Then), no logic in tests
- [ ] Golden/fixture data updated & reviewed if behaviour changed
- [ ] Public APIs documented; user-facing changes noted in docs/README
- [ ] CI green on PR (lint + coverage + e2e); branch-protection checks satisfied
- [ ] Reviewed & approved; no new warnings; no stray `unwrap()`/`TODO` in shipped paths
- [ ] Increment is potentially shippable (app runs / library usable)
DOD
}

# Every canonical DoD line appears (as a literal substring) in $1.
file_has_full_dod() {
  local file="$1" line
  [ -f "$file" ] || return 1
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    grep -Fq -- "$line" "$file" || return 1
  done < <(canonical_dod)
  return 0
}

# ---------------------------------------------------------------------------

test_make_coverage_invokes_gate_script() {
  # Given `make coverage`, Then it runs scripts/coverage.sh.
  if grep -q 'scripts/coverage.sh' <<<"$(mk_n coverage)"; then
    ok "test_make_coverage_invokes_gate_script"
  else
    bad "test_make_coverage_invokes_gate_script"
  fi
}

test_make_ci_runs_lint_coverage_e2e() {
  # Given `make ci`, Then it runs lint, then coverage, then e2e — invoking
  # the coverage + e2e gate scripts in that order.
  local out lint cov e2e
  out="$(mk_n ci)"
  lint="$(grep -n 'cargo clippy' <<<"$out" | head -1 | cut -d: -f1)"
  cov="$(grep -n 'scripts/coverage.sh' <<<"$out" | head -1 | cut -d: -f1)"
  e2e="$(grep -n 'scripts/e2e.sh' <<<"$out" | head -1 | cut -d: -f1)"
  if [ -n "$lint" ] && [ -n "$cov" ] && [ -n "$e2e" ] \
    && [ "$lint" -lt "$cov" ] && [ "$cov" -lt "$e2e" ]; then
    ok "test_make_ci_runs_lint_coverage_e2e"
  else
    bad "test_make_ci_runs_lint_coverage_e2e" "lint=$lint cov=$cov e2e=$e2e"
  fi
}

test_make_setup_fetches_fixtures() {
  # Given `make setup`, Then it fetches fixtures via scripts/fetch_fixtures.sh.
  if grep -q 'scripts/fetch_fixtures.sh' <<<"$(mk_n setup)"; then
    ok "test_make_setup_fetches_fixtures"
  else
    bad "test_make_setup_fetches_fixtures"
  fi
}

test_dod_doc_matches_issue_checklist() {
  # Given docs/DEFINITION_OF_DONE.md, Then it contains the canonical 12-line
  # checklist verbatim (the block every issue pastes).
  if file_has_full_dod "$DOD"; then
    ok "test_dod_doc_matches_issue_checklist"
  else
    bad "test_dod_doc_matches_issue_checklist" "DoD doc missing canonical checklist"
  fi
}

test_pr_template_embeds_dod() {
  # Given the PR template, Then it embeds the same canonical DoD checklist.
  if file_has_full_dod "$PR_TMPL"; then
    ok "test_pr_template_embeds_dod"
  else
    bad "test_pr_template_embeds_dod" "PR template missing DoD checklist"
  fi
}

test_feature_issue_template_has_six_sections() {
  # Given the feature issue template, Then it scaffolds the six required H3
  # sections.
  local f="$FEATURE_TMPL" missing=""
  if [ ! -f "$f" ]; then
    bad "test_feature_issue_template_has_six_sections" "template missing"
    return
  fi
  local section
  for section in "Description" "Goal" "Implementation plan" \
    "Definition of Done" "TDD checklist" "Recommended Claude Prompt"; do
    grep -Fq "### $section" "$f" || missing="$missing '$section'"
  done
  if [ -z "$missing" ]; then
    ok "test_feature_issue_template_has_six_sections"
  else
    bad "test_feature_issue_template_has_six_sections" "missing:$missing"
  fi
}

# ---------------------------------------------------------------------------

echo "Running make/DoD/template tests"
test_make_coverage_invokes_gate_script
test_make_ci_runs_lint_coverage_e2e
test_make_setup_fetches_fixtures
test_dod_doc_matches_issue_checklist
test_pr_template_embeds_dod
test_feature_issue_template_has_six_sections

echo
echo "make tests: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
