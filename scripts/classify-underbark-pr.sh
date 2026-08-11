#!/usr/bin/env bash
set -euo pipefail

# Consume NUL-delimited status/path pairs produced by:
# git diff --name-status --no-renames -z <base>...<head>

seen=0
apple=0
blocked=0

while IFS= read -r -d '' status; do
  seen=1
  if ! IFS= read -r -d '' path; then
    echo "Malformed changed-file input: status without path." >&2
    exit 2
  fi

  case "$status" in
    A|C|D|M|R|T|U|X|B) ;;
    *)
      echo "Malformed changed-file input: unsupported status ${status}." >&2
      exit 2
      ;;
  esac

  case "$path" in
    Recovr/*|RecovrKit/*|RecovrStoreKitTests/*|RecovrTests/*|RecovrUITests/*|RecovrWatch/*|RecovrWatchUITests/*|RecovrWatchWidgets/*|RecovrWidgets/*|Shared/*|Config/*|ci_scripts/*)
      apple=1
      ;;
    project.yml)
      apple=1
      ;;
    scripts/archive-app.sh|scripts/render-brand-assets.sh|scripts/verify-archive.sh|scripts/verify-brand.sh|scripts/verify-distribution-bundles.sh|scripts/verify-ipa.sh|scripts/verify-pr-source-policy-tests.sh|scripts/verify-pr-source-policy.sh|scripts/verify-release-record.sh|scripts/verify-signing.sh|scripts/verify-storekit-catalogue.sh|scripts/verify-version-change-policy-tests.sh|scripts/verify-version-change-policy.sh|scripts/verify-version.sh|scripts/verify-xcode-cloud-config.sh|scripts/verify-xcode-cloud-prebuild-tests.sh|scripts/version.sh)
      apple=1
      ;;
    *.md|.github/pull_request_template.md)
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
  echo blocked
elif [ "$apple" -eq 1 ]; then
  echo apple
else
  echo static
fi
