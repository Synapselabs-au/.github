#!/usr/bin/env bash
set -euo pipefail

# Consume NUL-delimited status/path pairs produced by:
# git diff --name-status --no-renames -z <base>...<head>

seen=0
apple=0
backend_functions=0
backend_database=0
blocked=0

while true; do
  status=''
  if ! IFS= read -r -d '' status; then
    if [[ -n "$status" ]]; then
      blocked=1
    fi
    break
  fi

  seen=1
  if ! IFS= read -r -d '' path; then
    blocked=1
    break
  fi

  case "$status" in
    A|C|D|M|T|U|X|B) ;;
    *)
      printf 'UNSUPPORTED_STATUS\t%s\n' "$status" >&2
      blocked=1
      continue
      ;;
  esac

  case "$path" in
    ''|/*|./*|../*|*/.|*/..|*/./*|*/../*|*//*|*/|*$'\t'*|*$'\n'*|*$'\r'*)
      printf 'UNSAFE_PATH_SHAPE\t%s\n' "$path" >&2
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
    docs/release/app-store-localizations/en-AU.json|docs/release/app-store-localizations/en-GB.json|docs/release/app-store-localizations/en-US.json)
      apple=1
      ;;
    services/apple-notifications/*|services/push-edge/*)
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
    scripts/load/entitlement-timing.ts|scripts/tests/entitlement-timing-tests.ts)
      backend_functions=1
      ;;
    docs/release/candidates/issue-691-delete-account/handler_test.ts|docs/release/candidates/issue-691-delete-account/observed.json|docs/release/candidates/issue-691-delete-account/source/deno.json|docs/release/candidates/issue-691-delete-account/source/delete-account/index.ts|docs/release/candidates/issue-691-delete-account/source/delete-account/handler.ts|docs/release/candidates/issue-691-delete-account/source/_shared/auth.ts|docs/release/candidates/issue-691-delete-account/source/_shared/http.ts|docs/release/candidates/issue-691-delete-account/source/_shared/database.ts|docs/release/candidates/issue-691-delete-account/source/_shared/runtime.ts)
      backend_functions=1
      ;;
    scripts/load/underbark-launch-load.ts|scripts/load/underbark-load-core.ts|scripts/load/underbark-provider-metrics.ts|scripts/tests/underbark-auth-provider-posture-tests.ts|scripts/tests/underbark-load-core-tests.ts|scripts/tests/underbark-provider-metrics-tests.ts|scripts/verify-supabase-auth-provider-posture.ts)
      backend_functions=1
      backend_database=1
      ;;
    scripts/archive-app.sh|scripts/release-testflight.sh|scripts/testflight-build-retention.sh|scripts/render-brand-assets.sh|scripts/verify-archive.sh|scripts/verify-brand.sh|scripts/verify-distribution-bundles.sh|scripts/verify-claims-register.sh|scripts/verify-continuity-protocol-parity.sh|scripts/verify-governance.sh|scripts/verify-ipa.sh|scripts/tests/continuity-protocol-parity-tests.sh|scripts/verify-pr-source-policy-tests.sh|scripts/verify-pr-source-policy.sh|scripts/verify-release-record.sh|scripts/verify-signing.sh|scripts/verify-storekit-catalogue.sh|scripts/verify-user-facing-copy.sh|scripts/verify-version-change-policy-tests.sh|scripts/verify-version-change-policy.sh|scripts/verify-version.sh|scripts/verify-xcode-cloud-config.sh|scripts/verify-xcode-cloud-prebuild-tests.sh|scripts/verify-xcode-cloud-source-policy-tests.sh|scripts/verify-xcode-cloud-source-policy.sh|scripts/version.sh|scripts/with-xcode-lane.sh|scripts/xcode-cloud-audit.sh|scripts/xcode-cloud-start-pr.sh|scripts/xcode-lane-status.sh)
      apple=1
      ;;
    scripts/sync-english-localizations.py|scripts/tests/test_localization_project_config.py|scripts/tests/test_sync_english_localizations.py|scripts/tests/test_task5_iphone_localization.py|scripts/tests/test_task6_watch_widget_localization.py|scripts/tests/test_verify_app_store_localizations.py|scripts/tests/test_verify_localizations.py|scripts/tests/verify-storekit-catalogue-tests.sh|scripts/verify-app-store-localizations.py|scripts/verify-localizations.py|scripts/xcstrings_schema.py)
      apple=1
      ;;
    scripts/with-build-host.sh|scripts/lib/build_host.py|scripts/tests/test_build_host.py|scripts/tests/test_build_host_review.py)
      apple=1
      ;;
    docs/data/EXPORT_COVERAGE.json|scripts/verify-export-coverage.py|scripts/tests/test_export_coverage.py|scripts/manual-import-process-drill.py|scripts/tests/test_manual_import_process_drill.py)
      apple=1
      ;;
    # The self-hosted Swift verification workflow. Apple-scoped because it
    # compiles the iOS app, the Watch app, and every test target on the Mac
    # mini, and because it calls scripts/with-xcode-lane.sh, which is already
    # classified apple. Unlike the retired ci.yml and pr-source-policy.yml
    # cases below, this file may be added and modified, not only deleted.
    .github/workflows/swift-verification.yml)
      apple=1
      ;;
    scripts/lib/app-store-connect.sh|scripts/lib/xcode-lane.sh|scripts/lib/xcode-storage.sh|scripts/tests/app-store-connect-tests.sh|scripts/tests/release-testflight-tests.sh|scripts/tests/testflight-build-retention-tests.sh|scripts/tests/xcode-lane-tests.sh|scripts/tests/xcode-lane-security-tests.sh|scripts/tests/xcode-storage-tests.sh|scripts/tests/xcode-wrapper-lane-tests.sh|scripts/tests/verify-distribution-bundles-tests.sh|scripts/tests/health-binary-scan-tests.sh|scripts/tests/verify-user-facing-copy-tests.sh|scripts/tests/xcode-cloud-audit-tests.sh|scripts/tests/xcode-cloud-smoke-plan-tests.sh|scripts/tests/xcode-cloud-start-pr-tests.sh|scripts/tests/fixtures/app-store-connect/beta-ready.json|scripts/tests/fixtures/app-store-connect/build-invalid.json|scripts/tests/fixtures/app-store-connect/build-valid.json|scripts/tests/fixtures/app-store-connect/builds-processing.json|scripts/tests/fixtures/app-store-connect/localization-different.json|scripts/tests/fixtures/app-store-connect/localization-empty.json|scripts/tests/fixtures/app-store-connect/localization-matching.json|scripts/tests/fixtures/app-store-connect/prerelease-versions.json|scripts/tests/fixtures/xcode-cloud/*)
      apple=1
      ;;
    .github/repo-integrity-policy.json|.github/workflows/repo-integrity-sentinel.yml|scripts/repo_integrity_audit.py|scripts/repo_integrity/__init__.py|scripts/repo_integrity/core.py|scripts/repo_integrity/deterministic.py|scripts/repo_integrity/github_checks.py|scripts/repo_integrity/issues.py|scripts/repo_integrity/reporting.py|scripts/repo_integrity/runner.py|scripts/repo_integrity/semantic.py|scripts/tests/test_repo_integrity_audit.py)
      ;;
    docs/brand/fonts/BricolageGrotesque-OFL.txt|docs/brand/fonts/HankenGrotesk-OFL.txt|docs/brand/fonts/SpaceMono-OFL.txt)
      ;;
    scripts/anonymise-export.py)
      ;;
    .gitattributes|.gitignore|*.md|.github/pull_request_template.md|.github/ISSUE_TEMPLATE/*)
      ;;
    .github/workflows/ci.yml|.github/workflows/pr-source-policy.yml|scripts/classify-ci-changes.sh|scripts/verify-ci-classifier.sh|scripts/verify-ci-workflow.sh)
      if [ "$status" != "D" ]; then
        printf 'RETIRED_PATH_NOT_DELETED\t%s\t%s\n' "$status" "$path" >&2
        blocked=1
      fi
      ;;
    *)
      # Name the path on stderr. The stdout contract is one tab-separated
      # record, so the reason cannot go there, and without it the caller sees
      # only "the diff contains an unclassified path" with no way to tell
      # which file or what to do about it.
      printf 'UNCLASSIFIED_PATH\t%s\n' "$path" >&2
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
