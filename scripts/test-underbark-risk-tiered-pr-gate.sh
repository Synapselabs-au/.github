#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
workflow="${script_dir}/../.github/workflows/underbark-risk-tiered-pr-gate.yml"
failures=0

bash "${script_dir}/test-classify-underbark-pr.sh"

expect_excludes() {
  pattern="$1"
  description="$2"
  if grep -Fq -- "$pattern" "$workflow"; then
    echo "FAIL: workflow ${description}" >&2
    failures=$((failures + 1))
  fi
}

expect_excludes_regex() {
  pattern="$1"
  description="$2"
  if grep -Eq -- "$pattern" "$workflow"; then
    echo "FAIL: workflow ${description}" >&2
    failures=$((failures + 1))
  fi
}

expect_step_contains() {
  step_name="$1"
  pattern="$2"
  description="$3"
  if ! awk -v step_name="$step_name" -v pattern="$pattern" '
    $0 == "      - name: " step_name { in_step = 1; seen_step = 1; next }
    in_step && /^      - name: / { in_step = 0 }
    in_step && index($0, pattern) { found = 1 }
    END { exit !(seen_step && found) }
  ' "$workflow"; then
    echo "FAIL: workflow ${description}" >&2
    failures=$((failures + 1))
  fi
}

expect_step_excludes() {
  step_name="$1"
  pattern="$2"
  description="$3"
  if ! awk -v step_name="$step_name" -v pattern="$pattern" '
    $0 == "      - name: " step_name { in_step = 1; next }
    in_step && /^      - name: / { exit }
    in_step && index($0, pattern) { found = 1 }
    END { exit !found }
  ' "$workflow"; then
    return
  fi
  echo "FAIL: workflow ${description}" >&2
  failures=$((failures + 1))
}

expect_step_token() {
  step_name="$1"
  description="$2"
  if ! awk -v step_name="$step_name" '
    $0 == "      - name: " step_name { in_step = 1; seen_step = 1; next }
    in_step && /^      - name: / { in_step = 0 }
    in_step && /^[[:space:]]*GH_TOKEN:/ { has_gh_token = 1 }
    in_step && index($0, "${{ github.token }}") { has_github_token = 1 }
    END { exit !(seen_step && has_gh_token && has_github_token) }
  ' "$workflow"; then
    echo "FAIL: workflow ${description}" >&2
    failures=$((failures + 1))
  fi
}

expect_no_default_candidate_directory() {
  if awk '
    function indentation(line) {
      match(line, /[^ ]/)
      return RSTART - 1
    }
    /^[[:space:]]*defaults:[[:space:]]*($|#)/ {
      defaults_indent = indentation($0)
      in_defaults = 1
      next
    }
    in_defaults && $0 !~ /^[[:space:]]*($|#)/ && indentation($0) <= defaults_indent {
      in_defaults = 0
    }
    in_defaults {
      normalized = $0
      gsub(/[[:space:]\"\047]/, "", normalized)
      if (normalized ~ /^working-directory:(\.\/)?\.candidate(\/\.)*\/?(#.*)?$/) {
        bad = 1
      }
    }
    END { exit !bad }
  ' "$workflow"; then
    echo "FAIL: workflow must not set a defaults.run candidate working directory" >&2
    failures=$((failures + 1))
  fi
}

expect_excludes "cache:" "must not enable a Deno or Actions cache"
expect_excludes "actions/cache" "must not use an Actions cache"

function_condition="if: \${{ steps.classify.outputs.backend_functions == '1' }}"
database_condition="if: \${{ steps.classify.outputs.backend_database == '1' }}"
apple_condition="if: \${{ steps.classify.outputs.classification == 'apple' || steps.classify.outputs.classification == 'apple-backend' }}"
cleanup_condition="if: \${{ always() && steps.classify.outputs.backend_database == '1' }}"

expect_step_contains "Set up Deno" "$function_condition" "must condition Deno setup on function scope"
expect_step_contains "Set up Deno" "uses: denoland/setup-deno@22d081ff2d3a40755e97629de92e3bcbfa7cf2ed" "must pin Deno setup in its conditional step"
expect_step_contains "Set up Deno" "deno-version: v2.9.5" "must pin Deno 2.9.5 in its conditional step"
expect_step_contains "Verify Supabase functions" "$function_condition" "must condition Deno verification on function scope"
expect_step_contains "Verify Supabase functions" "timeout 10m deno fmt --check supabase/functions" "must use the fixed Deno format command"
expect_step_contains "Verify Supabase functions" "timeout 10m deno check --config supabase/functions/deno.json supabase/functions/*/index.ts" "must use the fixed Deno check command"
expect_step_contains "Verify Supabase functions" "timeout 10m deno test --config supabase/functions/deno.json supabase/functions" "must use the fixed Deno test command"

expect_step_contains "Set up Supabase CLI" "$database_condition" "must condition Supabase setup on database scope"
expect_step_contains "Set up Supabase CLI" "uses: supabase/setup-cli@ab058987d8d6c725971f6cf9d0b5c98467e30bd1" "must pin Supabase setup in its conditional step"
expect_step_contains "Set up Supabase CLI" "version: 2.113.0" "must pin Supabase CLI 2.113.0 in its conditional step"
expect_step_contains "Start disposable Supabase database" "$database_condition" "must condition Supabase start on database scope"
expect_step_contains "Start disposable Supabase database" "timeout 15m supabase start --workdir . --exclude gotrue,realtime,storage-api,imgproxy,kong,mailpit,postgrest,postgres-meta,studio,edge-runtime,logflare,vector,supavisor" "must use the fixed Supabase start exclusions"
expect_step_contains "Run Supabase SQL suites" "$database_condition" "must condition SQL suites on database scope"
expect_step_contains "Run Supabase SQL suites" "for suite in supabase/tests/*.sql; do psql \"postgresql://postgres:postgres@127.0.0.1:54322/postgres\" -v ON_ERROR_STOP=1 -f \"\$suite\"; done" "must run every SQL suite with ON_ERROR_STOP"
expect_step_contains "Stop disposable Supabase database" "$cleanup_condition" "must always clean up selected database work"
expect_step_contains "Stop disposable Supabase database" "supabase stop --workdir . --no-backup" "must stop Supabase without a backup"

expect_step_contains "Poll exact-head Apple verification" "$apple_condition" "must poll Apple only for Apple and mixed scope"

expect_step_token "Classify trusted verification" "must scope GH_TOKEN to trusted classification"
expect_step_token "Poll exact-head Apple verification" "must scope GH_TOKEN to Apple polling"
expect_step_token "Validate final live tuple" "must scope GH_TOKEN to final tuple validation"
token_count="$(grep -c '^[[:space:]]*GH_TOKEN:' "$workflow" || true)"
github_token_count="$(grep -cF '${{ github.token }}' "$workflow" || true)"
github_token_env_count="$(grep -cF 'GITHUB_TOKEN' "$workflow" || true)"
if [ "$token_count" -ne 3 ] || [ "$github_token_count" -ne 3 ] || [ "$github_token_env_count" -ne 0 ]; then
  echo "FAIL: workflow must scope all GitHub tokens only to classification, Apple polling, and final tuple validation" >&2
  failures=$((failures + 1))
fi

expect_excludes "secrets." "must not expose secrets"
expect_excludes_regex 'secrets[[:space:]]*\[' "must not expose bracket-form secrets"
expect_excludes_regex 'github[[:space:]]*\[' "must not use bracket-form GitHub tokens"
expect_excludes "upload-artifact" "must not upload artifacts"
expect_excludes "download-artifact" "must not download artifacts"
expect_excludes "matrix:" "must not use a matrix"
expect_excludes "deployment" "must not deploy"
expect_excludes ".candidate/scripts/" "must not execute candidate scripts"
expect_excludes ".candidate/scripts" "must not execute candidate scripts through an alternate path"
expect_excludes_regex '(^|[^[:alnum:]_])\.candidate(/[^/[:space:]]+/\.\.)*(/\.)*/scripts([/[:space:]]|$)' "must not execute normalized candidate scripts"
expect_excludes "macos-" "must not allocate a macOS runner"

expect_no_default_candidate_directory

for candidate_step in "Verify Supabase functions" "Start disposable Supabase database" "Run Supabase SQL suites" "Stop disposable Supabase database"; do
  expect_step_excludes "$candidate_step" "GH_TOKEN:" "must keep ${candidate_step} free of GH_TOKEN"
  expect_step_excludes "$candidate_step" "GITHUB_TOKEN:" "must keep ${candidate_step} free of GITHUB_TOKEN"
  expect_step_excludes "$candidate_step" "github.token" "must keep ${candidate_step} free of direct GitHub tokens"
  expect_step_excludes "$candidate_step" "secrets" "must keep ${candidate_step} free of secrets"
done

if awk '
  function finish_step() {
    if (candidate_directory && candidate_script) {
      bad = 1
    }
    candidate_directory = 0
    candidate_script = 0
  }
  /^      - name: / { finish_step() }
  {
    candidate_line = $0
    gsub(/[[:space:]\"\047]/, "", candidate_line)
  }
  candidate_line ~ /^working-directory:(\.\/)?\.candidate(\/\.)*\/?(#.*)?$/ { candidate_directory = 1 }
  index($0, "scripts/") { candidate_script = 1 }
  END { finish_step(); exit !bad }
' "$workflow"; then
  echo "FAIL: workflow must not execute scripts from a .candidate working directory" >&2
  failures=$((failures + 1))
fi

if [ "$failures" -ne 0 ]; then
  echo "${failures} trusted workflow structure assertion(s) failed." >&2
  exit 1
fi

echo "All trusted workflow structure assertions passed."
