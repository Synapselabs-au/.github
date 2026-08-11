#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
classifier="${script_dir}/classify-underbark-pr.sh"
workflow="${script_dir}/../.github/workflows/underbark-risk-tiered-pr-gate.yml"
failures=0

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

expect_failure() {
  description="$1"
  shift

  set +e
  printf '%s\0' "$@" | "$classifier" >/dev/null 2>&1
  status=$?
  set -e

  if [ "$status" -eq 0 ]; then
    echo "FAIL: ${description}: expected non-zero status" >&2
    failures=$((failures + 1))
  fi
}

expect_classification static "root Markdown" M README.md
expect_classification static "nested Markdown" A docs/guides/setup.md
expect_classification static "pull request template" M .github/pull_request_template.md
expect_classification static "legacy workflow deletion" \
  D .github/workflows/ci.yml \
  D .github/workflows/pr-source-policy.yml
expect_classification static "legacy classifier deletion" \
  D scripts/classify-ci-changes.sh \
  D scripts/verify-ci-classifier.sh \
  D scripts/verify-ci-workflow.sh

expect_classification apple "RecovrKit logic" M RecovrKit/Sources/RecovrKit/Scoring/Recovery.swift
expect_classification apple "iPhone source" A Recovr/TodayView.swift
expect_classification apple "Watch source" M RecovrWatch/RecoveryView.swift
expect_classification apple "project configuration" M project.yml
expect_classification apple "signing script" M scripts/verify-signing.sh
expect_classification apple "mixed docs and Apple" M docs/README.md M Recovr/App.swift

expect_classification blocked "unknown root file" M Package.resolved
expect_classification blocked "unknown workflow" A .github/workflows/new-workflow.yml
expect_classification blocked "legacy workflow modification" M .github/workflows/ci.yml
expect_classification blocked "mixed static and unknown" M README.md A tools/new-tool.sh
expect_classification blocked "mixed Apple and unknown" M Recovr/App.swift A tools/new-tool.sh
expect_classification blocked "empty diff"

expect_failure "missing path in status pair" M

job_count="$(grep -c '^    runs-on:' "$workflow")"
if [ "$job_count" -ne 1 ]; then
  echo "FAIL: workflow expected one job, found ${job_count}" >&2
  failures=$((failures + 1))
fi

expect_workflow_contains "name: Underbark PR Gate result" "must keep the stable required-check name"
expect_workflow_contains "runs-on: ubuntu-latest" "must use the cheap Linux runner"
expect_workflow_contains 'ref: ${{ github.workflow_sha }}' "must bind trusted code to the workflow source SHA"
expect_workflow_contains "git -C .candidate diff --name-status --no-renames -z" "must classify the exact diff"
expect_workflow_contains 'APPLE_APP_ID: "117084"' "must pin the Apple GitHub App"
expect_workflow_contains "APPLE_CHECK_NAME: Recovr | Underbark PR Verification | Test - iOS" "must pin the Apple check name"
expect_workflow_contains "require_current_tuple" "must reject stale pull request state"
expect_workflow_contains "cancel-in-progress:" "must cancel superseded attempts"
expect_workflow_excludes "macos-" "must not allocate a GitHub-hosted macOS runner"
expect_workflow_excludes "xcodebuild" "must not run Xcode"
expect_workflow_excludes ".candidate/scripts/" "must not execute candidate scripts"
expect_workflow_excludes "upload-artifact" "must not upload artifacts"

if [ "$failures" -ne 0 ]; then
  echo "${failures} classifier fixture(s) failed." >&2
  exit 1
fi

echo "All Underbark classifier fixtures passed."
