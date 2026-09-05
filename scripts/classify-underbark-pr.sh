#!/usr/bin/env bash
set -euo pipefail

# Consume NUL-delimited status/path pairs produced by:
# git diff --name-status --no-renames -z <base>...<head>

seen=0
apple=0
backend_functions=0
backend_database=0
blocked=0

while IFS= read -r -d '' status; do
  seen=1
  if ! IFS= read -r -d '' path; then
    blocked=1
    break
  fi

  case "$status" in
    A|C|D|M|T|U|X|B) ;;
    *)
      blocked=1
      continue
      ;;
  esac

  case "$path" in
    ''|/*|./*|../*|*/./*|*/../*|*//*|*/|*$'\t'*|*$'\n'*|*$'\r'*)
      blocked=1
      continue
      ;;
  esac

  case "$path" in
    AlarmShared/*|Recovr/*|RecovrAlarmKitTests/*|RecovrKit/*|RecovrStoreKitTests/*|RecovrTests/*|RecovrUITests/*|RecovrWatch/*|RecovrWatchUITests/*|RecovrWatchWidgets/*|RecovrWidgets/*|Shared/*|Config/*|ci_scripts/*)
      apple=1
      ;;
    project.yml)
      apple=1
      ;;
    services/apple-notifications/*)
      backend_functions=1
      ;;
    supabase/functions/*)
      backend_functions=1
      ;;
    supabase/config.toml)
      backend_functions=1
      backend_database=1
      ;;
    supabase/migrations/*|supabase/tests/*|supabase/seed.sql|supabase/schemas/*)
      backend_database=1
      ;;
    scripts/load/underbark-launch-load.ts|scripts/load/underbark-load-core.ts|scripts/load/underbark-provider-metrics.ts|scripts/tests/underbark-auth-provider-posture-tests.ts|scripts/tests/underbark-load-core-tests.ts|scripts/tests/underbark-provider-metrics-tests.ts|scripts/verify-supabase-auth-provider-posture.ts)
      backend_functions=1
      backend_database=1
      ;;
    scripts/archive-app.sh|scripts/release-testflight.sh|scripts/testflight-build-retention.sh|scripts/render-brand-assets.sh|scripts/verify-archive.sh|scripts/verify-brand.sh|scripts/verify-distribution-bundles.sh|scripts/verify-governance.sh|scripts/verify-ipa.sh|scripts/verify-pr-source-policy-tests.sh|scripts/verify-pr-source-policy.sh|scripts/verify-release-record.sh|scripts/verify-signing.sh|scripts/verify-storekit-catalogue.sh|scripts/verify-user-facing-copy.sh|scripts/verify-version-change-policy-tests.sh|scripts/verify-version-change-policy.sh|scripts/verify-version.sh|scripts/verify-xcode-cloud-config.sh|scripts/verify-xcode-cloud-prebuild-tests.sh|scripts/verify-xcode-cloud-source-policy-tests.sh|scripts/verify-xcode-cloud-source-policy.sh|scripts/version.sh|scripts/with-xcode-lane.sh|scripts/xcode-cloud-audit.sh|scripts/xcode-cloud-start-pr.sh|scripts/xcode-lane-status.sh)
      apple=1
      ;;
    scripts/lib/app-store-connect.sh|scripts/lib/xcode-lane.sh|scripts/lib/xcode-storage.sh|scripts/tests/app-store-connect-tests.sh|scripts/tests/release-testflight-tests.sh|scripts/tests/testflight-build-retention-tests.sh|scripts/tests/xcode-lane-tests.sh|scripts/tests/xcode-lane-security-tests.sh|scripts/tests/xcode-storage-tests.sh|scripts/tests/xcode-wrapper-lane-tests.sh|scripts/tests/verify-distribution-bundles-tests.sh|scripts/tests/verify-user-facing-copy-tests.sh|scripts/tests/xcode-cloud-audit-tests.sh|scripts/tests/xcode-cloud-smoke-plan-tests.sh|scripts/tests/xcode-cloud-start-pr-tests.sh|scripts/tests/fixtures/app-store-connect/beta-ready.json|scripts/tests/fixtures/app-store-connect/build-invalid.json|scripts/tests/fixtures/app-store-connect/build-valid.json|scripts/tests/fixtures/app-store-connect/builds-processing.json|scripts/tests/fixtures/app-store-connect/localization-different.json|scripts/tests/fixtures/app-store-connect/localization-empty.json|scripts/tests/fixtures/app-store-connect/localization-matching.json|scripts/tests/fixtures/app-store-connect/prerelease-versions.json|scripts/tests/fixtures/xcode-cloud/*)
      apple=1
      ;;
    .github/repo-integrity-policy.json|.github/workflows/repo-integrity-sentinel.yml|scripts/repo_integrity_audit.py|scripts/repo_integrity/__init__.py|scripts/repo_integrity/core.py|scripts/repo_integrity/deterministic.py|scripts/repo_integrity/github_checks.py|scripts/repo_integrity/issues.py|scripts/repo_integrity/reporting.py|scripts/repo_integrity/runner.py|scripts/repo_integrity/semantic.py|scripts/tests/test_repo_integrity_audit.py)
      ;;
    docs/brand/fonts/BricolageGrotesque-OFL.txt|docs/brand/fonts/HankenGrotesk-OFL.txt|docs/brand/fonts/SpaceMono-OFL.txt)
      ;;
    .gitattributes|.gitignore|*.md|.github/pull_request_template.md|.github/ISSUE_TEMPLATE/*)
      ;;
    .github/workflows/ci.yml|.github/workflows/pr-source-policy.yml|scripts/classify-ci-changes.sh|scripts/verify-ci-classifier.sh|scripts/verify-ci-workflow.sh)
      if [ "$status" != "D" ]; then
        blocked=1
      fi
      ;;
    *)
      blocked=1
      ;;
  esac
done

if [ "$seen" -eq 0 ] || [ "$blocked" -eq 1 ]; then
  printf 'blocked\t0\t0\n'
elif [ "$apple" -eq 1 ] && { [ "$backend_functions" -eq 1 ] || [ "$backend_database" -eq 1 ]; }; then
  printf 'apple-backend\t%s\t%s\n' "$backend_functions" "$backend_database"
elif [ "$backend_functions" -eq 1 ] || [ "$backend_database" -eq 1 ]; then
  printf 'backend\t%s\t%s\n' "$backend_functions" "$backend_database"
elif [ "$apple" -eq 1 ]; then
  printf 'apple\t0\t0\n'
else
  printf 'static\t0\t0\n'
fi
