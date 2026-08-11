#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
classifier="${script_dir}/classify-underbark-pr.sh"
workflow="${script_dir}/../.github/workflows/underbark-risk-tiered-pr-gate.yml"
failures=0

bash "${script_dir}/test-verify-underbark-ancestry-sync.sh"

expect_workflow_contains() {
  pattern="$1"
  description="$2"
  if ! grep -Fq -- "$pattern" "$workflow"; then
    echo "FAIL: workflow ${description}" >&2
    failures=$((failures + 1))
  fi
}

expect_workflow_excludes() {
  pattern="$1"
  description="$2"
  if grep -Fq -- "$pattern" "$workflow"; then
    echo "FAIL: workflow ${description}" >&2
    failures=$((failures + 1))
  fi
}

expect_classification() {
  expected="$1"
  description="$2"
  shift 2

  set +e
  if [ "$#" -eq 0 ]; then
    actual="$("$classifier" </dev/null 2>/dev/null)"
  else
    actual="$(printf '%s\0' "$@" | "$classifier" 2>/dev/null)"
  fi
  status=$?
  set -e

  if [ "$status" -ne 0 ] || [ "$actual" != "$expected" ]; then
    echo "FAIL: ${description}: expected ${expected}, got ${actual:-<empty>} (status ${status})" >&2
    failures=$((failures + 1))
  fi
}

expect_classification $'static\t0\t0' "ordinary Markdown only" M README.md
expect_classification $'static\t0\t0' "nested Markdown" A docs/guides/setup.md
expect_classification $'static\t0\t0' "pull request template" M .github/pull_request_template.md
expect_classification $'static\t0\t0' "legacy workflow deletion" \
  D .github/workflows/ci.yml \
  D .github/workflows/pr-source-policy.yml
expect_classification $'static\t0\t0' "legacy classifier deletion" \
  D scripts/classify-ci-changes.sh \
  D scripts/verify-ci-classifier.sh \
  D scripts/verify-ci-workflow.sh

expect_classification $'apple\t0\t0' "RecovrKit logic" M RecovrKit/Sources/RecovrKit/Scoring/Recovery.swift
expect_classification $'apple\t0\t0' "iPhone source" A Recovr/TodayView.swift
expect_classification $'apple\t0\t0' "Watch source" M RecovrWatch/RecoveryView.swift
expect_classification $'apple\t0\t0' "Markdown inside an iPhone target" M Recovr/RuntimeContent.md
expect_classification $'apple\t0\t0' "Markdown inside a Watch target" M RecovrWatch/RuntimeContent.md
expect_classification $'apple\t0\t0' "project configuration" M project.yml
expect_classification $'apple\t0\t0' "signing script" M scripts/verify-signing.sh
expect_classification $'apple\t0\t0' "mixed docs and Apple" M docs/README.md M Recovr/App.swift

expect_classification $'backend\t1\t0' "Supabase function source" M supabase/functions/delete-account/index.ts
expect_classification $'backend\t1\t0' "Supabase function documentation" M supabase/functions/README.md
expect_classification $'backend\t0\t1' "Supabase migration" M supabase/migrations/20260101000000_example.sql
expect_classification $'backend\t0\t1' "Supabase database test" M supabase/tests/example.sql
expect_classification $'backend\t1\t1' "Supabase configuration" M supabase/config.toml
expect_classification $'backend\t0\t1' "Supabase seed" M supabase/seed.sql
expect_classification $'backend\t0\t1' "Supabase schema" M supabase/schemas/example.sql
expect_classification $'backend\t1\t1' "function plus migration" \
  M supabase/functions/delete-account/index.ts \
  M supabase/migrations/20260101000000_example.sql
expect_classification $'apple-backend\t1\t0' "function plus Apple source" \
  M supabase/functions/delete-account/index.ts \
  M Recovr/App.swift
expect_classification $'apple-backend\t0\t1' "migration plus project configuration" \
  M supabase/migrations/20260101000000_example.sql \
  M project.yml

expect_classification $'blocked\t0\t0' "unknown root file" M Package.resolved
expect_classification $'blocked\t0\t0' "unknown workflow" A .github/workflows/new-workflow.yml
expect_classification $'blocked\t0\t0' "legacy workflow modification" M .github/workflows/ci.yml
expect_classification $'blocked\t0\t0' "mixed static and unknown" M README.md A tools/new-tool.sh
expect_classification $'blocked\t0\t0' "mixed Apple and unknown" M Recovr/App.swift A tools/new-tool.sh
expect_classification $'blocked\t0\t0' "empty diff"
expect_classification $'blocked\t0\t0' "malformed status pair" M
expect_classification $'blocked\t0\t0' "rename ambiguity" R100 Recovr/Old.swift Recovr/New.swift

job_count="$(grep -c '^    runs-on:' "$workflow")"
if [ "$job_count" -ne 5 ]; then
  echo "FAIL: workflow expected five isolated jobs, found ${job_count}" >&2
  failures=$((failures + 1))
fi

expect_workflow_contains "name: Underbark PR Gate result" "must keep the stable required-check name"
stable_name_count="$(grep -c '^    name: Underbark PR Gate result$' "$workflow")"
if [ "$stable_name_count" -ne 1 ]; then
  echo "FAIL: workflow must expose exactly one stable required-check job" >&2
  failures=$((failures + 1))
fi
expect_workflow_contains "github.repository == 'Synapselabs-au/Underbark'" "must not execute as a normal workflow in the trust repository"
expect_workflow_contains "runs-on: ubuntu-latest" "must use the cheap Linux runner"
expect_workflow_contains 'ref: ${{ github.workflow_sha }}' "must bind trusted code to the workflow source SHA"
expect_workflow_contains "git -C .candidate diff --name-status --no-renames -z" "must classify the exact diff"
expect_workflow_contains 'git -C .candidate diff --quiet "${LIVE_BASE_SHA}...${LIVE_HEAD}"' "must isolate the empty-diff ancestry path"
expect_workflow_contains 'verify-underbark-ancestry-sync.sh' "must verify exact ancestry-sync parents and tree"
expect_workflow_contains 'git/ref/heads/main' "must bind the ancestry sync to current main"
expect_workflow_contains 'EVENT_AUTHOR_LOGIN: ${{ github.event.pull_request.user.login }}' "must bind ancestry syncs to the dedicated App login"
expect_workflow_contains 'EVENT_AUTHOR_ID: ${{ github.event.pull_request.user.id }}' "must bind ancestry syncs to the dedicated App user ID"
expect_workflow_contains 'EVENT_AUTHOR_TYPE: ${{ github.event.pull_request.user.type }}' "must inspect ancestry-sync authorship"
expect_workflow_contains 'EVENT_HEAD_REPO: ${{ github.event.pull_request.head.repo.full_name }}' "must bind ancestry syncs to the protected repository"
expect_workflow_contains 'verify-underbark-release-context.sh' "must use executable release-context predicates"
expect_workflow_contains 'release-in-flight' "must require the active release reservation"
expect_workflow_contains '.total_count' "must count every active release reservation"
expect_workflow_contains '.merged_at // empty' "must require a merged release marker"
expect_workflow_contains 'require_current_main "$LIVE_MAIN_SHA"' "must revalidate main before ancestry success"
expect_workflow_contains 'merge-base --is-ancestor' "must bind the release marker to the live base ancestry"
release_context_check_count="$(grep -c '^[[:space:]]*require_release_context$' "$workflow")"
if [ "$release_context_check_count" -lt 2 ]; then
  echo "FAIL: workflow must verify release context before and after ancestry inspection" >&2
  failures=$((failures + 1))
fi
expect_workflow_contains 'APPLE_APP_ID: "117084"' "must pin the Apple GitHub App"
expect_workflow_contains "APPLE_CHECK_NAME: Recovr | Underbark PR Verification | Test - iOS" "must pin the Apple check name"
expect_workflow_contains "require_current_tuple" "must reject stale pull request state"
tuple_check_count="$(grep -c '^[[:space:]]*require_current_tuple$' "$workflow")"
if [ "$tuple_check_count" -lt 3 ]; then
  echo "FAIL: workflow must revalidate the live tuple before every success path and Apple poll" >&2
  failures=$((failures + 1))
fi
expect_workflow_contains 'any(.pull_requests[]?; .number == $pr_number)' "must bind Apple evidence to this pull request"
expect_workflow_contains "sort_by(.id)" "must select the newest Apple check deterministically"
expect_workflow_contains "gh api --paginate --slurp" "must inspect every page of exact-head check runs"
expect_workflow_contains 'group: underbark-pr-gate-${{ github.repository }}-${{ github.event.pull_request.number }}' "must share concurrency across superseded heads of one pull request"
expect_workflow_excludes 'group: underbark-pr-gate-${{ github.event.pull_request.number }}-${{ github.event.pull_request.head.sha }}' "must not isolate superseded heads from cancellation"
expect_workflow_contains "cancel-in-progress: true" "must cancel superseded attempts for one pull request"
expect_workflow_excludes "types: [" "must not claim unsupported ruleset-workflow event filters"
expect_workflow_excludes "macos-" "must not allocate a GitHub-hosted macOS runner"
expect_workflow_excludes "xcodebuild" "must not run Xcode"
expect_workflow_excludes ".candidate/scripts/" "must not execute candidate scripts"
expect_workflow_excludes "upload-artifact" "must not upload artifacts"

if [ "$failures" -ne 0 ]; then
  echo "${failures} classifier fixture(s) failed." >&2
  exit 1
fi

echo "All Underbark classifier fixtures passed."
