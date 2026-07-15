# Branch protection runbook — `main`

The gates from 0.2–0.6 only protect the project if `main` cannot be merged into
without them. This runbook is the **reproducible, reviewable** source for the
branch-protection configuration on `main` (no click-ops). The exact API payload
lives alongside this file in [`branch_protection.json`](branch_protection.json)
and is validated by `tests/branch_protection_test.sh`.

> **Applying protection is a manual admin step.** These commands are documented,
> not run automatically. Run them yourself once the `make ci (lint, coverage,
> e2e)` check is green on `main` (a required context that never passes would
> block every merge).

## What it enforces

- **Required status check:** `make ci (lint, coverage, e2e)` — the single CI job
  ([`.github/workflows/ci.yml`](../.github/workflows/ci.yml)) that runs
  `make ci` = lint → **coverage (≥95%)** → **e2e**. Requiring it makes all three
  mandatory. `strict: true` ⇒ the PR branch must be up to date with `main`.
- **1 approving review**, with **stale approvals dismissed** on new commits.
- **Linear history** (no merge commits — squash or rebase only).
- **Admins included** (`enforce_admins`), **force-pushes and deletions disabled**,
  conversations must be resolved before merge.

The required-check context **must exactly match** the CI job's `name:`. If that
job is renamed, update `branch_protection.json` — `test_required_contexts_match_ci_job_names`
fails the build on any mismatch, so the gate can never be silently non-blocking.

## Prerequisites

- Repo **admin** and `gh auth login` with the `repo` scope.
- The `make ci (lint, coverage, e2e)` check has run and is **green** on `main`
  at least once (so the context exists and is known to pass).

## Apply

```sh
# 1) Branch protection (required checks, reviews, linear history, lock-down).
gh api -X PUT repos/Zenardi/racestudio-macos/branches/main/protection \
  --input docs/branch_protection.json

# 2) Repo merge settings: no merge commits — squash + rebase only (linear history).
gh api -X PATCH repos/Zenardi/racestudio-macos \
  -F allow_merge_commit=false \
  -F allow_squash_merge=true \
  -F allow_rebase_merge=true
```

## Read back / audit

Confirm protection is enabled (fields are nested under `.enabled` in the GET
response):

```sh
gh api repos/Zenardi/racestudio-macos/branches/main/protection --jq '{
  contexts:      .required_status_checks.contexts,
  strict:        .required_status_checks.strict,
  reviews:       .required_pull_request_reviews.required_approving_review_count,
  dismiss_stale: .required_pull_request_reviews.dismiss_stale_reviews,
  linear:        .required_linear_history.enabled,
  admins:        .enforce_admins.enabled,
  force_pushes:  .allow_force_pushes.enabled,
  deletions:     .allow_deletions.enabled
}'
```

Expected: `contexts == ["make ci (lint, coverage, e2e)"]`, `strict == true`,
`reviews == 1`, `dismiss_stale == true`, `linear == true`, `admins == true`,
`force_pushes == false`, `deletions == false`.

## Verify it blocks

1. Branch, push a commit that breaks the gate (e.g. drop a `#[test]` so coverage
   falls below 95%, or introduce a clippy warning), and open a PR.
2. Confirm the `make ci (lint, coverage, e2e)` check goes red and the **Merge**
   button is disabled ("Required statuses must pass").
3. Confirm a direct `git push origin main` is rejected ("protected branch").
4. Close the throwaway PR; no merge should have been possible.

## Note for a solo maintainer

`enforce_admins: true` + `required_approving_review_count: 1` means even the repo
owner needs a **separate** approving review to merge — with a single maintainer
there is no one to approve. If you are working solo, either:

- set `enforce_admins` to `false` in `branch_protection.json` (admins may merge
  once checks pass, without a second reviewer), or
- keep the review requirement and add a second collaborator/bot reviewer.

The payload above follows the issue's team-oriented spec; relax `enforce_admins`
if you need to self-merge. Re-run `tests/branch_protection_test.sh` after editing
so the validators stay green.
