#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
workflow="${script_dir}/../.github/workflows/underbark-risk-tiered-pr-gate.yml"
failures=0

bash "${script_dir}/test-classify-underbark-pr.sh"
bash "${script_dir}/test-verify-underbark-release-context.sh"

if ! ruby -ryaml - "$workflow" <<'RUBY'
def reject_duplicate_keys(node, path = "$")
  case node
  when Psych::Nodes::Stream, Psych::Nodes::Document, Psych::Nodes::Sequence
    node.children.each_with_index { |child, index| reject_duplicate_keys(child, "#{path}[#{index}]") }
  when Psych::Nodes::Mapping
    keys = {}
    node.children.each_slice(2) do |key_node, value_node|
      key = key_node.respond_to?(:value) ? key_node.value : key_node.to_s
      raise "duplicate YAML key #{key.inspect} at #{path}" if keys.key?(key)
      keys[key] = true
      reject_duplicate_keys(value_node, "#{path}.#{key}")
    end
  end
end

begin
  reject_duplicate_keys(Psych.parse_stream("env:\n  APPLE_APP_ID: one\n  APPLE_APP_ID: two\n"))
  raise "duplicate-key detector accepted a duplicate fixture"
rescue RuntimeError => error
  raise unless error.message.include?("duplicate YAML key")
end
reject_duplicate_keys(Psych.parse_stream(File.read(ARGV.fetch(0))))
workflow = YAML.load_file(ARGV.fetch(0))
jobs = workflow.fetch("jobs")
expected_jobs = %w[classify functions database apple result]
raise "unexpected job graph" unless jobs.keys == expected_jobs
raise "required status changed" unless jobs.fetch("result").fetch("name") == "Underbark PR Gate result"
raise "aggregation is not terminal" unless jobs.fetch("result").fetch("needs") == expected_jobs.first(4)
raise "aggregation is not always-run" unless jobs.fetch("result").fetch("if").include?("always()")

expected_timeouts = {
  "classify" => 10,
  "functions" => 45,
  "database" => 40,
  "apple" => 65,
  "result" => 10,
}
expected_timeouts.each do |name, timeout|
  raise "#{name} timeout mismatch" unless jobs.fetch(name).fetch("timeout-minutes") == timeout
  raise "#{name} is not Linux" unless jobs.fetch(name).fetch("runs-on") == "ubuntu-latest"
end

expected_permissions = {
  "classify" => {"contents" => "read", "pull-requests" => "read"},
  "functions" => {"contents" => "read"},
  "database" => {"contents" => "read"},
  "apple" => {"checks" => "read", "contents" => "read", "pull-requests" => "read"},
  "result" => {"contents" => "read", "pull-requests" => "read"},
}
raise "workflow permissions must default to none" unless workflow.fetch("permissions") == {}
expected_permissions.each do |name, permissions|
  raise "#{name} permissions mismatch" unless jobs.fetch(name).fetch("permissions") == permissions
end

def serialized(job)
  YAML.dump(job)
end

%w[functions database].each do |name|
  body = serialized(jobs.fetch(name))
  raise "#{name} contains a GitHub token" if body.include?("github.token") || body.include?("GH_TOKEN")
  raise "#{name} contains a secret" if body.include?("secrets")
  raise "#{name} exposes a host workflow control file" if %w[GITHUB_ENV GITHUB_PATH GITHUB_OUTPUT].any? { |key| body.include?(key) }
end

token_jobs = jobs.select { |_name, job| serialized(job).include?("github.token") }.keys
raise "token job boundary changed" unless token_jobs == %w[classify apple result]
raise "candidate Deno escaped its runner" if serialized(jobs.fetch("classify")).include?("deno test") || serialized(jobs.fetch("result")).include?("deno test")
raise "candidate SQL escaped its runner" if serialized(jobs.fetch("classify")).include?("psql ") || serialized(jobs.fetch("result")).include?("psql ")

database_run = jobs.fetch("database").fetch("steps").map { |step| step["run"] }.compact.join("\n")
start_index = database_run.index("supabase start") or raise "database start missing"
sql_index = database_run.index("psql ") or raise "SQL suites missing"
cleanup_index = database_run.index("supabase stop") or raise "database cleanup missing"
trap_index = database_run.index("trap cleanup EXIT") or raise "cleanup trap missing"
raise "cleanup is not installed before untrusted SQL" unless trap_index < start_index
raise "database command ordering changed" unless cleanup_index < start_index && start_index < sql_index
raise "candidate SQL is not copied into the disposable container" unless database_run.include?("docker cp supabase/tests/. supabase_db_underbark:/tmp/underbark-tests")
raise "candidate SQL runs on the host" unless database_run.include?("docker exec supabase_db_underbark bash")
raise "host shell reads candidate SQL" if database_run.include?("< \"$suite\"")

result_run = jobs.fetch("result").fetch("steps").map { |step| step["run"] }.compact.join("\n")
raise "lane aggregation missing" unless result_run.include?("require_lane_result")
raise "terminal tuple read missing" unless result_run.include?("pulls/${PR_NUMBER}")
local_ancestry_index = result_run.index("verify-underbark-ancestry-sync.sh") or raise "local ancestry validation missing"
final_tuple_index = result_run.index("read -r final_head") or raise "fresh terminal tuple read missing"
final_main_index = result_run.index("final_main=\"") or raise "fresh terminal main read missing"
final_release_index = result_run.index("final_release_locks=\"") or raise "fresh terminal release read missing"
success_index = result_run.index("Final exact pull request tuple and selected verification results verified.") or raise "terminal success missing"
raise "local ancestry work occurs after terminal reads" unless local_ancestry_index < final_tuple_index
raise "terminal read ordering changed" unless final_tuple_index < final_main_index && final_main_index < final_release_index && final_release_index < success_index
raise "terminal success is not the final operation" unless result_run.lines.reject { |line| line.strip.empty? }.last.include?("Final exact pull request tuple")

functions_run = jobs.fetch("functions").fetch("steps").map { |step| step["run"] }.compact.join("\n")
raise "Deno container digest missing" unless functions_run.include?("denoland/deno:2.9.5@sha256:b429777c3dcff34a6488f365a1537db1640b2d48379b60f5e6206be034472463")
raise "candidate source is not copied into isolation" unless functions_run.include?("docker cp supabase/.")
raise "candidate Deno does not execute in isolation" unless functions_run.scan("docker exec").length >= 3
raise "a Deno command escaped the isolation container" unless functions_run.lines.grep(/deno (fmt|check|test)/).all? { |line| line.include?("docker exec") }
raise "candidate container receives host environment" if functions_run.include?("--env") || functions_run.include?("--env-file")
raise "candidate container has a host write mount" if functions_run.include?("--volume") || functions_run.match?(/docker (create|run).*\s-v\s/)
RUBY
then
  echo "FAIL: parsed workflow trust-boundary assertions failed" >&2
  failures=$((failures + 1))
fi

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

expect_excludes_regex() {
  pattern="$1"
  description="$2"
  if grep -Eq -- "$pattern" "$workflow"; then
    echo "FAIL: workflow ${description}" >&2
    failures=$((failures + 1))
  fi
}

expect_job_excludes() {
  job_name="$1"
  pattern="$2"
  description="$3"
  if awk -v job_name="$job_name" -v pattern="$pattern" '
    $0 == "  " job_name ":" { in_job = 1; next }
    in_job && /^  [[:alnum:]_-]+:$/ { exit }
    in_job && index($0, pattern) { found = 1 }
    END { exit !found }
  ' "$workflow"; then
    echo "FAIL: workflow ${description}" >&2
    failures=$((failures + 1))
  fi
}

expect_job_contains() {
  job_name="$1"
  pattern="$2"
  description="$3"
  if ! awk -v job_name="$job_name" -v pattern="$pattern" '
    $0 == "  " job_name ":" { in_job = 1; seen = 1; next }
    in_job && /^  [[:alnum:]_-]+:$/ { in_job = 0 }
    in_job && index($0, pattern) { found = 1 }
    END { exit !(seen && found) }
  ' "$workflow"; then
    echo "FAIL: workflow ${description}" >&2
    failures=$((failures + 1))
  fi
}

expect_job_contains classify 'timeout-minutes: 10' "must bound classification to 10 minutes"
expect_job_contains functions 'timeout-minutes: 45' "must bound image pull, container setup, serial Deno commands, and cleanup"
expect_job_contains database 'timeout-minutes: 40' "must bound database start, SQL, and cleanup"
expect_job_contains apple 'timeout-minutes: 65' "must contain the 60-minute Apple polling window"
expect_job_contains result 'timeout-minutes: 10' "must bound final aggregation"

expect_job_contains functions "needs: classify" "must run functions only after trusted classification"
expect_job_contains functions "needs.classify.outputs.backend_functions == '1'" "must select functions from immutable classifier output"
expect_job_contains database "needs: classify" "must run database only after trusted classification"
expect_job_contains database "needs.classify.outputs.backend_database == '1'" "must select database from immutable classifier output"
expect_job_contains apple "needs: classify" "must run Apple polling only after trusted classification"
expect_job_contains apple "needs.classify.outputs.classification == 'apple'" "must select Apple work from immutable classifier output"
expect_job_contains result 'if: ${{ always()' "must always aggregate selected lane results on a fresh runner"
expect_job_contains result 'needs: [classify, functions, database, apple]' "must depend on every verification lane"
expect_job_contains result 'name: Underbark PR Gate result' "must retain the one stable required status"

expect_job_contains functions 'permissions:' "must declare job-local least privilege"
expect_job_contains functions 'contents: read' "must limit checkout permission to repository contents"
expect_job_contains functions 'denoland/deno:2.9.5@sha256:b429777c3dcff34a6488f365a1537db1640b2d48379b60f5e6206be034472463' "must pin the isolated Deno image"
expect_job_contains functions 'docker cp supabase/. "$container:/workspace/supabase"' "must copy candidate files without a host mount"
expect_job_contains functions 'timeout 10m docker exec "$container" deno fmt --check supabase/functions' "must isolate fixed Deno formatting"
expect_job_contains functions 'timeout 10m docker exec "$container" deno check --config supabase/functions/deno.json supabase/functions/*/index.ts' "must isolate fixed Deno checking"
expect_job_contains functions 'timeout 10m docker exec "$container" deno test --config supabase/functions/deno.json supabase/functions' "must isolate fixed Deno tests"

expect_job_contains database 'supabase/setup-cli@ab058987d8d6c725971f6cf9d0b5c98467e30bd1' "must pin Supabase setup"
expect_job_contains database 'version: 2.113.0' "must pin Supabase CLI 2.113.0"
expect_job_contains database 'trap cleanup EXIT' "must install same-step database cleanup"
expect_job_contains database 'timeout 15m supabase start --workdir .' "must bound disposable database startup"
expect_job_contains database 'timeout 10m docker exec supabase_db_underbark bash -euo pipefail -c' "must bound SQL suites inside the disposable database container"
expect_job_contains database 'docker cp supabase/tests/. supabase_db_underbark:/tmp/underbark-tests' "must copy candidate SQL into the disposable container without a host mount"
expect_job_contains database 'docker exec supabase_db_underbark bash -euo pipefail -c' "must process candidate SQL only inside the disposable database container"
expect_job_contains database 'psql "postgresql://postgres:postgres@127.0.0.1:5432/postgres" -v ON_ERROR_STOP=1 -f "$suite"' "must keep psql meta-commands inside the disposable database container"
expect_job_contains database 'timeout 5m supabase stop --workdir . --no-backup' "must bound cleanup and disable backup"

for untrusted_job in functions database; do
  expect_job_excludes "$untrusted_job" 'GH_TOKEN:' "must keep ${untrusted_job} candidate commands free of an explicit GitHub token"
  expect_job_excludes "$untrusted_job" 'github.token' "must not pass the workflow token directly to ${untrusted_job} candidate commands"
  expect_job_excludes "$untrusted_job" 'secrets' "must keep ${untrusted_job} candidate commands free of secrets"
done

expect_job_excludes classify 'deno test' "must not execute candidate Deno before authenticated classification"
expect_job_excludes classify 'psql ' "must not execute candidate SQL before authenticated classification"
expect_job_excludes apple 'deno test' "must not execute candidate Deno on the Apple token runner"
expect_job_excludes apple 'psql ' "must not execute candidate SQL on the Apple token runner"
expect_job_excludes result 'deno test' "must not execute candidate Deno before final authentication"
expect_job_excludes result 'psql ' "must not execute candidate SQL before final authentication"

token_count="$(grep -c '^[[:space:]]*GH_TOKEN:' "$workflow" || true)"
github_token_count="$(grep -cF '${{ github.token }}' "$workflow" || true)"
apple_app_id_count="$(grep -c '^[[:space:]]*APPLE_APP_ID:' "$workflow" || true)"
if [[ "$token_count" -ne 3 || "$github_token_count" -ne 3 || "$apple_app_id_count" -ne 1 ]]; then
  echo "FAIL: workflow token boundary or unique Apple App ID declaration changed" >&2
  failures=$((failures + 1))
fi
expect_job_contains classify 'GH_TOKEN: ${{ github.token }}' "must authenticate trusted classification"
expect_job_contains apple 'GH_TOKEN: ${{ github.token }}' "must authenticate exact Apple polling"
expect_job_contains result 'GH_TOKEN: ${{ github.token }}' "must authenticate terminal tuple validation"

expect_job_contains result 'CLASSIFY_RESULT: ${{ needs.classify.result }}' "must aggregate classification outcome explicitly"
expect_job_contains result 'FUNCTIONS_RESULT: ${{ needs.functions.result }}' "must aggregate functions outcome explicitly"
expect_job_contains result 'DATABASE_RESULT: ${{ needs.database.result }}' "must aggregate database outcome explicitly"
expect_job_contains result 'APPLE_RESULT: ${{ needs.apple.result }}' "must aggregate Apple outcome explicitly"
expect_job_contains result 'require_lane_result "$BACKEND_FUNCTIONS" "$FUNCTIONS_RESULT"' "must reject a missing selected functions result"
expect_job_contains result 'require_lane_result "$BACKEND_DATABASE" "$DATABASE_RESULT"' "must reject a missing selected database result"
expect_job_contains result 'require_lane_result 1 "$APPLE_RESULT"' "must reject a missing selected Apple result"
expect_job_contains result 'verify-underbark-release-context.sh' "must execute final release-context predicates"
expect_job_contains result 'verify-underbark-ancestry-sync.sh' "must repeat exact ancestry validation at terminal success"
expect_job_contains result 'Final exact pull request tuple and selected verification results verified.' "must end with fresh tuple evidence"

expect_excludes_regex '\|\|[[:space:]]*\[' "must not use malformed single-bracket OR lists"
expect_excludes_regex '&&[[:space:]]*\[' "must not use malformed single-bracket AND lists"
expect_excludes 'Stop disposable Supabase database' "must not defer cleanup to a later shared-runner step"
expect_excludes 'cache:' "must not enable caches"
expect_excludes 'actions/cache' "must not use an Actions cache"
expect_excludes 'upload-artifact' "must not upload artifacts"
expect_excludes 'download-artifact' "must not download artifacts"
expect_excludes 'matrix:' "must not use a matrix"
expect_excludes 'deployment' "must not deploy"
expect_excludes '.candidate/scripts/' "must not execute candidate scripts"
expect_excludes 'macos-' "must not allocate a macOS runner"
expect_excludes 'xcodebuild' "must not run Xcode"
expect_excludes 'secrets.' "must not expose repository secrets"
expect_excludes_regex 'secrets[[:space:]]*\[' "must not expose bracket-form secrets"

job_count="$(grep -c '^    runs-on:' "$workflow")"
stable_name_count="$(grep -c '^    name: Underbark PR Gate result$' "$workflow")"
if [[ "$job_count" -ne 5 || "$stable_name_count" -ne 1 ]]; then
  echo "FAIL: workflow must have five isolated jobs and one stable required status" >&2
  failures=$((failures + 1))
fi

if [[ "$failures" -ne 0 ]]; then
  echo "${failures} trusted workflow structure assertion(s) failed." >&2
  exit 1
fi

echo "All trusted workflow structure assertions passed."
