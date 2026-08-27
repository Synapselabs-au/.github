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

expect_classification $'static\t0\t0' "ordinary Markdown only" M README.md
expect_classification $'static\t0\t0' "nested Markdown" A docs/guides/setup.md
expect_classification $'static\t0\t0' "pull request template" M .github/pull_request_template.md
expect_classification $'static\t0\t0' "issue template lifecycle" \
  A .github/ISSUE_TEMPLATE/work-item.yml \
  D .github/ISSUE_TEMPLATE/retired.yml
expect_classification $'static\t0\t0' "repository attributes" A .gitattributes
expect_classification $'static\t0\t0' "repository ignore list" M .gitignore
expect_classification $'static\t0\t0' "Bricolage Grotesque license record" \
  M docs/brand/fonts/BricolageGrotesque-OFL.txt
expect_classification $'static\t0\t0' "Hanken Grotesk license record" \
  M docs/brand/fonts/HankenGrotesk-OFL.txt
expect_classification $'static\t0\t0' "Space Mono license record" \
  M docs/brand/fonts/SpaceMono-OFL.txt
expect_classification $'static\t0\t0' "legacy workflow deletion" \
  D .github/workflows/ci.yml \
  D .github/workflows/pr-source-policy.yml
expect_classification $'static\t0\t0' "legacy classifier deletion" \
  D scripts/classify-ci-changes.sh \
  D scripts/verify-ci-classifier.sh \
  D scripts/verify-ci-workflow.sh
expect_classification $'static\t0\t0' "repository integrity sentinel control surface" \
  A .github/repo-integrity-policy.json \
  A .github/workflows/repo-integrity-sentinel.yml \
  A docs/REPO_INTEGRITY.md \
  A scripts/repo_integrity_audit.py \
  A scripts/repo_integrity/__init__.py \
  A scripts/repo_integrity/core.py \
  A scripts/repo_integrity/deterministic.py \
  A scripts/repo_integrity/github_checks.py \
  A scripts/repo_integrity/issues.py \
  A scripts/repo_integrity/reporting.py \
  A scripts/repo_integrity/runner.py \
  A scripts/repo_integrity/semantic.py \
  A scripts/tests/test_repo_integrity_audit.py

expect_classification $'apple\t0\t0' "RecovrKit logic" M RecovrKit/Sources/RecovrKit/Scoring/Recovery.swift
expect_classification $'apple\t0\t0' "iPhone source" A Recovr/TodayView.swift
expect_classification $'apple\t0\t0' "AppModel source" M Recovr/AppModel.swift
expect_classification $'apple\t0\t0' "shared AlarmKit metadata" A AlarmShared/WakeAlarmMetadata.swift
expect_classification $'apple\t0\t0' "AlarmKit controller tests" A RecovrAlarmKitTests/WakeAlarmControllerTests.swift
expect_classification $'apple\t0\t0' "AlarmKit service tests" A RecovrAlarmKitTests/WakeAlarmServiceTests.swift
expect_classification $'apple\t0\t0' "Watch source" M RecovrWatch/RecoveryView.swift
expect_classification $'apple\t0\t0' "Markdown inside an iPhone target" M Recovr/RuntimeContent.md
expect_classification $'apple\t0\t0' "Markdown inside a Watch target" M RecovrWatch/RuntimeContent.md
expect_classification $'apple\t0\t0' "project configuration" M project.yml
expect_classification $'apple\t0\t0' "signing script" M scripts/verify-signing.sh
expect_classification $'apple\t0\t0' "user-facing copy verifier and fixtures" \
  A scripts/verify-user-facing-copy.sh \
  A scripts/tests/verify-user-facing-copy-tests.sh
expect_classification $'apple\t0\t0' "Xcode lane implementation" \
  A scripts/lib/xcode-lane.sh \
  A scripts/with-xcode-lane.sh \
  A scripts/xcode-lane-status.sh
expect_classification $'apple\t0\t0' "Xcode lane and governance fixtures" \
  A scripts/tests/xcode-lane-tests.sh \
  A scripts/tests/xcode-lane-security-tests.sh \
  A scripts/tests/xcode-wrapper-lane-tests.sh \
  A scripts/verify-governance.sh
expect_classification $'apple\t0\t0' "distribution verifier test suite" \
  M scripts/tests/verify-distribution-bundles-tests.sh
expect_classification $'apple\t0\t0' "Xcode Cloud policy audit tooling" \
  A scripts/xcode-cloud-audit.sh \
  A scripts/tests/xcode-cloud-audit-tests.sh \
  A scripts/tests/fixtures/xcode-cloud/live-readback-2026-08-19.json
expect_classification $'apple\t0\t0' "Xcode Cloud smoke and manual-start tooling" \
  A scripts/tests/xcode-cloud-smoke-plan-tests.sh \
  A scripts/xcode-cloud-start-pr.sh \
  A scripts/tests/xcode-cloud-start-pr-tests.sh
expect_classification $'apple\t0\t0' "TestFlight release automation" \
  A Config/TestFlightWhatToTest-en-AU.txt \
  A scripts/release-testflight.sh \
  A scripts/lib/app-store-connect.sh \
  A scripts/tests/release-testflight-tests.sh \
  A scripts/tests/app-store-connect-tests.sh \
  A scripts/tests/fixtures/app-store-connect/build-valid.json
expect_classification $'apple\t0\t0' "nested Xcode Cloud fixture" \
  A scripts/tests/fixtures/xcode-cloud/drift/enabled-flip.json
expect_classification $'apple\t0\t0' "mixed docs and Apple" M docs/README.md M Recovr/App.swift

expect_classification $'backend\t1\t0' "Supabase function source" M supabase/functions/delete-account/index.ts
expect_classification $'backend\t1\t0' "Supabase function handler" M supabase/functions/delete-account/handler.ts
expect_classification $'backend\t1\t0' "Supabase function documentation" M supabase/functions/README.md
expect_classification $'backend\t0\t1' "Supabase migration" M supabase/migrations/20260101000000_example.sql
expect_classification $'backend\t0\t1' "fixture Supabase migration" A supabase/migrations/20260812000000_fixture.sql
expect_classification $'backend\t0\t1' "Supabase database test" M supabase/tests/example.sql
expect_classification $'backend\t1\t1' "Supabase configuration" M supabase/config.toml
expect_classification $'backend\t1\t1' "approved launch load CLI" \
  A scripts/load/underbark-launch-load.ts
expect_classification $'backend\t1\t1' "approved launch load core" \
  A scripts/load/underbark-load-core.ts
expect_classification $'backend\t1\t1' "approved launch load core tests" \
  A scripts/tests/underbark-load-core-tests.ts
expect_classification $'backend\t0\t1' "Supabase seed" M supabase/seed.sql
expect_classification $'backend\t0\t1' "Supabase schema" M supabase/schemas/example.sql
expect_classification $'backend\t1\t1' "function plus migration" \
  M supabase/functions/delete-account/index.ts \
  M supabase/migrations/20260101000000_example.sql
expect_classification $'apple-backend\t1\t0' "function plus Apple source" \
  M supabase/functions/delete-account/index.ts \
  M Recovr/App.swift
expect_classification $'apple-backend\t1\t0' "AppModel plus function handler" \
  M Recovr/AppModel.swift \
  M supabase/functions/delete-account/handler.ts
expect_classification $'apple-backend\t0\t1' "migration plus project configuration" \
  M supabase/migrations/20260101000000_example.sql \
  M project.yml

expect_classification $'blocked\t0\t0' "unknown root file" M Package.resolved
expect_classification $'blocked\t0\t0' "unlisted fixtures root stays denied" \
  A scripts/tests/fixtures/other-tool/data.json
expect_classification $'blocked\t0\t0' "unlisted new script stays denied" \
  A scripts/xcode-cloud-nuke.sh
expect_classification $'blocked\t0\t0' "unlisted load script stays denied" \
  A scripts/load/arbitrary.ts
expect_classification $'blocked\t0\t0' "unknown workflow" A .github/workflows/new-workflow.yml
expect_classification $'blocked\t0\t0' "repository integrity workflow lookalike" \
  A .github/workflows/repo-integrity-sentinel-copy.yml
expect_classification $'blocked\t0\t0' "repository integrity policy lookalike" \
  A .github/repo-integrity-policy.json.bak
expect_classification $'blocked\t0\t0' "unlisted repository integrity module" \
  A scripts/repo_integrity/auto_fix.py
expect_classification $'blocked\t0\t0' "attributes lookalike" A .gitattributes.bak
expect_classification $'blocked\t0\t0' "ignore lookalike" A .gitignore.bak
expect_classification $'blocked\t0\t0' "nested ignore is not the root one" A tools/.gitignore
expect_classification $'blocked\t0\t0' "unknown brand license record" \
  A docs/brand/fonts/Other-OFL.txt
expect_classification $'blocked\t0\t0' "brand license suffix lookalike" \
  A docs/brand/fonts/BricolageGrotesque-OFL.txt.bak
expect_classification $'blocked\t0\t0' "nested brand license record" \
  A docs/brand/fonts/archive/BricolageGrotesque-OFL.txt
expect_classification $'blocked\t0\t0' "legacy workflow modification" M .github/workflows/ci.yml
expect_classification $'blocked\t0\t0' "mixed static and unknown" M README.md A tools/new-tool.sh
expect_classification $'blocked\t0\t0' "mixed Apple and unknown" M Recovr/App.swift A tools/new-tool.sh
expect_classification $'blocked\t0\t0' "AlarmShared traversal" A AlarmShared/../Secrets.swift
expect_classification $'blocked\t0\t0' "AlarmKit test duplicate separator" A RecovrAlarmKitTests//WakeAlarmServiceTests.swift
expect_classification $'blocked\t0\t0' "AlarmShared newline" A $'AlarmShared/WakeAlarm\nMetadata.swift'
expect_classification $'blocked\t0\t0' "AlarmKit test carriage return" A $'RecovrAlarmKitTests/WakeAlarm\rServiceTests.swift'
# The supabase-analytics/ tree was classified as backend for one day, for
# Underbark #384's second Supabase project. #384 folded that project into the
# main one before merging, so the directory never existed on a merged branch
# and these paths went back to being unknown. Pinned as fixtures because the
# classifier's default-deny is what now covers them: if the tree is ever
# reintroduced, the gate must stop and somebody must decide, rather than the
# paths quietly resolving to backend from a rule nothing exercises.
expect_classification $'blocked\t0\t0' "retired analytics project config" \
  A supabase-analytics/config.toml
expect_classification $'blocked\t0\t0' "retired analytics project function" \
  A supabase-analytics/functions/analytics-contribute/index.ts
expect_classification $'blocked\t0\t0' "retired analytics project migration" \
  A supabase-analytics/migrations/20260826120000_create_analytics.sql

expect_classification $'blocked\t0\t0' "empty diff"
expect_classification $'blocked\t0\t0' "malformed status pair" M
expect_classification $'blocked\t0\t0' "rename ambiguity" R100 Recovr/Old.swift Recovr/New.swift

if [ "$failures" -ne 0 ]; then
  echo "${failures} classifier fixture(s) failed." >&2
  exit 1
fi

echo "All Underbark classifier fixtures passed."
