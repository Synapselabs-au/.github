#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
classifier="${script_dir}/classify-underbark-pr.sh"
failures=0

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

if [ "$failures" -ne 0 ]; then
  echo "${failures} classifier fixture(s) failed." >&2
  exit 1
fi

echo "All Underbark classifier fixtures passed."
