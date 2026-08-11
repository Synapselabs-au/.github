#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
workflow="${script_dir}/../.github/workflows/underbark-risk-tiered-pr-gate.yml"
failures=0

bash "${script_dir}/test-classify-underbark-pr.sh"

expect_contains() {
  pattern="$1"
  description="$2"
  if ! grep -Fq -- "$pattern" "$workflow"; then
    echo "FAIL: workflow ${description}" >&2
    failures=$((failures + 1))
  fi
}

expect_excludes() {
  pattern="$1"
  description="$2"
  if grep -Fq -- "$pattern" "$workflow"; then
    echo "FAIL: workflow ${description}" >&2
    failures=$((failures + 1))
  fi
}

expect_step_token() {
  step_name="$1"
  description="$2"
  if ! awk -v step_name="$step_name" '
    $0 == "      - name: " step_name { in_step = 1; next }
    in_step && /^      - name: / { exit }
    in_step && /^[[:space:]]*GH_TOKEN:/ { found = 1 }
    END { exit !found }
  ' "$workflow"; then
    echo "FAIL: workflow ${description}" >&2
    failures=$((failures + 1))
  fi
}

expect_contains "uses: denoland/setup-deno@22d081ff2d3a40755e97629de92e3bcbfa7cf2ed" "must pin denoland/setup-deno"
expect_contains "deno-version: v2.9.5" "must pin Deno 2.9.5"
expect_excludes "cache:" "must not enable a Deno or Actions cache"
expect_excludes "actions/cache" "must not use an Actions cache"

expect_contains "uses: supabase/setup-cli@ab058987d8d6c725971f6cf9d0b5c98467e30bd1" "must pin supabase/setup-cli"
expect_contains "version: 2.113.0" "must pin Supabase CLI 2.113.0"

expect_contains "if: \${{ steps.classify.outputs.backend_functions == '1' }}" "must condition Deno work on function scope"
expect_contains "if: \${{ steps.classify.outputs.backend_database == '1' }}" "must condition database work on database scope"
expect_contains "timeout 10m deno fmt --check supabase/functions" "must use the fixed Deno format command"
expect_contains "timeout 10m deno check --config supabase/functions/deno.json supabase/functions/*/index.ts" "must use the fixed Deno check command"
expect_contains "timeout 10m deno test --config supabase/functions/deno.json supabase/functions" "must use the fixed Deno test command"

expect_contains "timeout 15m supabase start --workdir . --exclude gotrue,realtime,storage-api,imgproxy,kong,mailpit,postgrest,postgres-meta,studio,edge-runtime,logflare,vector,supavisor" "must use the fixed Supabase start exclusions"
expect_contains "for suite in supabase/tests/*.sql; do psql \"postgresql://postgres:postgres@127.0.0.1:54322/postgres\" -v ON_ERROR_STOP=1 -f \"\$suite\"; done" "must run every SQL suite with ON_ERROR_STOP"
expect_contains "supabase stop --workdir . --no-backup" "must stop Supabase without a backup"
expect_contains "if: \${{ always() && steps.classify.outputs.backend_database == '1' }}" "must always clean up selected database work"

expect_contains "if: \${{ steps.classify.outputs.classification == 'apple' || steps.classify.outputs.classification == 'apple-backend' }}" "must poll Apple only for Apple and mixed scope"

expect_step_token "Classify trusted verification" "must scope GH_TOKEN to trusted classification"
expect_step_token "Poll exact-head Apple verification" "must scope GH_TOKEN to Apple polling"
expect_step_token "Validate final live tuple" "must scope GH_TOKEN to final tuple validation"
token_count="$(grep -c '^[[:space:]]*GH_TOKEN:' "$workflow" || true)"
if [ "$token_count" -ne 3 ]; then
  echo "FAIL: workflow must scope GH_TOKEN only to classification, Apple polling, and final tuple validation" >&2
  failures=$((failures + 1))
fi

expect_excludes "secrets." "must not expose secrets"
expect_excludes "upload-artifact" "must not upload artifacts"
expect_excludes "download-artifact" "must not download artifacts"
expect_excludes "matrix:" "must not use a matrix"
expect_excludes "deployment" "must not deploy"
expect_excludes ".candidate/scripts/" "must not execute candidate scripts"
expect_excludes "macos-" "must not allocate a macOS runner"

if [ "$failures" -ne 0 ]; then
  echo "${failures} trusted workflow structure assertion(s) failed." >&2
  exit 1
fi

echo "All trusted workflow structure assertions passed."
