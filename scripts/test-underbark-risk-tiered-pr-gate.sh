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

def run_scripts(job)
  job.fetch("steps").map { |step| step["run"] }.compact
end

def logical_lines(script)
  lines = []
  buffer = ""
  script.each_line do |raw_line|
    line = raw_line.strip
    next if line.empty? && buffer.empty?
    buffer = buffer.empty? ? line : "#{buffer} #{line}"
    if buffer.end_with?("\\")
      buffer = buffer[0...-1].rstrip
    else
      lines << buffer unless buffer.empty?
      buffer = ""
    end
  end
  lines << buffer unless buffer.empty?
  lines
end

def shell_statements(script)
  logical_lines(script).flat_map do |line|
    statements = []
    buffer = +""
    quote = nil
    index = 0

    emit = lambda do |separator|
      command = buffer.strip
      statements << [command, separator] unless command.empty?
      buffer.clear
    end

    while index < line.length
      character = line[index]

      if quote == "'"
        buffer << character
        quote = nil if character == "'"
        index += 1
        next
      end

      if quote == '"'
        buffer << character
        if character == "\\"
          index += 1
          raise "unterminated shell escape in #{line.inspect}" if index >= line.length
          buffer << line[index]
        elsif character == '"'
          quote = nil
        end
        index += 1
        next
      end

      case character
      when "'", '"'
        quote = character
        buffer << character
        index += 1
      when "\\"
        buffer << character
        index += 1
        raise "unterminated shell escape in #{line.inspect}" if index >= line.length
        buffer << line[index]
        index += 1
      when ";"
        emit.call(:semicolon)
        index += 1
      when "&"
        if buffer.end_with?("<", ">") || line[index + 1] == ">"
          buffer << character
          index += 1
        elsif line[index + 1] == "&"
          emit.call(:and_if)
          index += 2
        else
          emit.call(:background)
          index += 1
        end
      when "|"
        if line[index + 1] == "|"
          emit.call(:or_if)
          index += 2
        else
          emit.call(:pipe)
          index += 1
        end
      else
        buffer << character
        index += 1
      end
    end

    raise "unterminated shell quote in #{line.inspect}" if quote
    emit.call(:newline)
    statements
  end
end

def require_exact_command_contract(label, statements, pattern, expected)
  actual = statements.select { |command, _separator| command.match?(pattern) }
  return if actual == expected

  raise "candidate #{label} command contract changed: #{actual.inspect}"
end

def validate_candidate_boundaries(workflow)
  jobs = workflow.fetch("jobs")
  candidate_checkouts = jobs.values.flat_map do |job|
    job.fetch("steps").select do |step|
      checkout = step["uses"].to_s.start_with?("actions/checkout@")
      inputs = step.fetch("with", {})
      candidate = inputs["path"] == ".candidate" ||
        inputs["repository"].to_s.include?("pull_request.head.repo.full_name") ||
        inputs["ref"].to_s.include?("pull_request.head.sha")
      checkout && candidate
    end
  end
  raise "candidate checkout coverage missing" if candidate_checkouts.empty?
  candidate_checkouts.each do |step|
    raise "candidate checkout persists credentials" unless step.fetch("with")["persist-credentials"] == false
  end

  %w[functions database].each do |name|
    body = serialized(jobs.fetch(name))
    raise "#{name} contains a GitHub token" if body.include?("github.token") || body.include?("GH_TOKEN")
    raise "#{name} contains a secret" if body.include?("secrets")
    raise "#{name} exposes a host workflow control file" if %w[GITHUB_ENV GITHUB_PATH GITHUB_OUTPUT].any? { |key| body.include?(key) }
  end

  trusted_body = %w[classify apple result].map { |name| serialized(jobs.fetch(name)) }.join("\n")
  raise "candidate Deno command contract changed: trusted job invocation" if trusted_body.match?(/\bdeno (?:fmt|check|test)\b/)
  raise "candidate psql command contract changed: trusted job invocation" if trusted_body.match?(/\bpsql(?:\s|$)/)
  raise "candidate Docker command contract changed: trusted job invocation" if trusted_body.match?(/\bdocker\b/)

  statements = %w[functions database].flat_map do |name|
    job = jobs.fetch(name)
    run_scripts(job).flat_map { |script| shell_statements(script) }
  end

  expected_deno = [
    ['timeout 10m docker exec "$container" deno fmt --check supabase/functions', :newline],
    ['timeout 10m docker exec "$container" deno check --config supabase/functions/deno.json supabase/functions/*/index.ts', :newline],
    ['timeout 10m docker exec "$container" deno test --config supabase/functions/deno.json supabase/functions', :newline],
  ]
  require_exact_command_contract(
    "Deno",
    statements,
    /\bdeno (?:fmt|check|test)\b/,
    expected_deno,
  )

  expected_psql = [
    ['timeout 10m docker exec supabase_db_underbark bash -euo pipefail -c \'for suite in /tmp/underbark-tests/*.sql; do psql "postgresql://postgres:postgres@127.0.0.1:5432/postgres" -v ON_ERROR_STOP=1 -f "$suite"; done\'', :newline],
  ]
  require_exact_command_contract("psql", statements, /\bpsql(?:\s|$)/, expected_psql)

  expected_docker = [
    ['timeout 2m docker rm -f "$container" >/dev/null 2>&1', :or_if],
    ['timeout 5m docker pull "$image"', :newline],
    ['timeout 1m docker create --pull never --name "$container" --network bridge --workdir /workspace "$image" eval \'setInterval(() => {}, 3600000)\'', :newline],
    ['timeout 1m docker start "$container" >/dev/null', :newline],
    ['timeout 1m docker cp supabase/. "$container:/workspace/supabase"', :newline],
    *expected_deno,
    ['timeout 1m docker exec supabase_db_underbark mkdir -p /tmp/underbark-tests', :newline],
    ['timeout 1m docker cp supabase/tests/. supabase_db_underbark:/tmp/underbark-tests', :newline],
    *expected_psql,
  ]
  require_exact_command_contract("Docker", statements, /\bdocker\b/, expected_docker)
end

def expect_boundary_rejection(label, workflow, expected_message)
  validate_candidate_boundaries(workflow)
rescue RuntimeError => error
  unless error.message.match?(expected_message)
    raise "negative boundary fixture was rejected for the wrong reason: #{label}: #{error.message.inspect}"
  end
  return
else
  raise "negative boundary fixture was accepted: #{label}"
end

validate_candidate_boundaries(workflow)

fixture = Marshal.load(Marshal.dump(workflow))
fixture.fetch("jobs").fetch("functions").fetch("steps").find { |step| step["run"] }.tap { |step| step["run"] << "\ndeno test supabase/functions\n" }
expect_boundary_rejection("host Deno", fixture, /\Acandidate Deno command contract changed:/)

fixture = Marshal.load(Marshal.dump(workflow))
deno_step = fixture.fetch("jobs").fetch("functions").fetch("steps").find { |step| step["run"].to_s.include?("deno fmt") }
raise "same-line Deno fixture construction failed" unless deno_step["run"].sub!(
  'timeout 10m docker exec "$container" deno fmt --check supabase/functions',
  'timeout 10m docker exec "$container" deno fmt --check supabase/functions; deno test supabase/functions',
)
expect_boundary_rejection("same-line host Deno", fixture, /\Acandidate Deno command contract changed:/)

fixture = Marshal.load(Marshal.dump(workflow))
deno_step = fixture.fetch("jobs").fetch("functions").fetch("steps").find { |step| step["run"].to_s.include?("deno fmt") }
deno_step["run"].sub!('docker exec "$container" deno fmt', 'docker exec wrong-container deno fmt')
expect_boundary_rejection("wrong Deno container", fixture, /\Acandidate Deno command contract changed:/)

fixture = Marshal.load(Marshal.dump(workflow))
fixture.fetch("jobs").fetch("database").fetch("steps").find { |step| step["run"] }.tap { |step| step["run"] << "\npsql postgresql://localhost/postgres -c 'select 1'\n" }
expect_boundary_rejection("host psql", fixture, /\Acandidate psql command contract changed:/)

fixture = Marshal.load(Marshal.dump(workflow))
database_step = fixture.fetch("jobs").fetch("database").fetch("steps").find { |step| step["run"].to_s.include?("psql") }
raise "same-line psql fixture construction failed" unless database_step["run"].sub!(
  "done'\n",
  "done' && psql postgresql://localhost/postgres -c 'select 1'\n",
)
expect_boundary_rejection("same-line host psql", fixture, /\Acandidate psql command contract changed:/)

fixture = Marshal.load(Marshal.dump(workflow))
database_step = fixture.fetch("jobs").fetch("database").fetch("steps").find { |step| step["run"].to_s.include?("psql") }
database_step["run"].sub!("docker exec supabase_db_underbark bash", "docker exec wrong-container bash")
expect_boundary_rejection("wrong psql container", fixture, /\Acandidate psql command contract changed:/)

fixture = Marshal.load(Marshal.dump(workflow))
checkout = fixture.fetch("jobs").values.flat_map { |job| job.fetch("steps") }.find { |step| step.fetch("with", {})["path"] == ".candidate" }
checkout.fetch("with").delete("persist-credentials")
expect_boundary_rejection("persisted checkout credentials", fixture, /\Acandidate checkout persists credentials\z/)

fixture = Marshal.load(Marshal.dump(workflow))
functions_step = fixture.fetch("jobs").fetch("functions").fetch("steps").find { |step| step["run"].to_s.include?("docker pull") }
raise "second Docker fixture construction failed" unless functions_step["run"].sub!(
  'timeout 5m docker pull "$image"',
  'timeout 5m docker pull "$image"; docker run --privileged alpine true',
)
expect_boundary_rejection("unsafe Docker after safe Docker", fixture, /\Acandidate Docker command contract changed:/)

fixture = Marshal.load(Marshal.dump(workflow))
functions_step = fixture.fetch("jobs").fetch("functions").fetch("steps").find { |step| step["run"].to_s.include?("docker create") }
raise "separate-value Docker fixture construction failed" unless functions_step["run"].sub!(
  "  --name \"$container\" \\\n  --network bridge \\\n",
  "  --name \"$container\" \\\n  --label underbark=test \\\n  --privileged \\\n  --network bridge \\\n",
)
expect_boundary_rejection("unsafe Docker after separate-value option", fixture, /\Acandidate Docker command contract changed:/)

unsafe_docker_fixtures = {
  "mount" => "docker run --mount type=bind,src=/tmp,dst=/work alpine true",
  "multiline short volume" => "docker run \\\n  -v /tmp:/work alpine true",
  "short environment" => "docker run -e TOKEN=value alpine true",
  "attached short environment" => "docker run -eTOKEN=value alpine true",
  "environment" => "docker run --env TOKEN=value alpine true",
  "environment file" => "docker run --env-file /tmp/env alpine true",
  "Docker socket" => "docker run -v /var/run/docker.sock:/var/run/docker.sock alpine true",
  "privileged" => "docker run --privileged alpine true",
  "host pid" => "docker run --pid host alpine true",
  "host network" => "docker run --network=host alpine true",
  "short host network" => "docker run --net host alpine true",
  "host IPC" => "docker run --ipc=host alpine true",
  "host UTS" => "docker run --uts host alpine true",
  "host user namespace" => "docker run --userns=host alpine true",
  "host cgroup namespace" => "docker run --cgroupns host alpine true",
  "capability addition" => "docker run --cap-add SYS_ADMIN alpine true",
  "device access" => "docker run --device=/dev/null alpine true",
  "security override" => "docker run --security-opt seccomp=unconfined alpine true",
  "inherited volumes" => "docker run --volumes-from trusted alpine true",
}
unsafe_docker_fixtures.each do |label, command|
  fixture = Marshal.load(Marshal.dump(workflow))
  fixture.fetch("jobs").fetch("functions").fetch("steps").find { |step| step["run"] }.tap { |step| step["run"] << "\n#{command}\n" }
  expect_boundary_rejection(label, fixture, /\Acandidate Docker command contract changed:/)
end

token_jobs = jobs.select { |_name, job| serialized(job).include?("github.token") }.keys
raise "token job boundary changed" unless token_jobs == %w[classify apple result]

database_run = run_scripts(jobs.fetch("database")).join("\n")
start_index = database_run.index("supabase start") or raise "database start missing"
sql_index = database_run.index("psql ") or raise "SQL suites missing"
cleanup_index = database_run.index("supabase stop") or raise "database cleanup missing"
trap_index = database_run.index("trap cleanup EXIT") or raise "cleanup trap missing"
raise "cleanup is not installed before untrusted SQL" unless trap_index < start_index
raise "database command ordering changed" unless cleanup_index < start_index && start_index < sql_index
raise "candidate SQL is not copied into the disposable container" unless database_run.include?("docker cp supabase/tests/. supabase_db_underbark:/tmp/underbark-tests")

result_run = run_scripts(jobs.fetch("result")).join("\n")
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

functions_run = run_scripts(jobs.fetch("functions")).join("\n")
raise "Deno container digest missing" unless functions_run.include?("denoland/deno:2.9.5@sha256:b429777c3dcff34a6488f365a1537db1640b2d48379b60f5e6206be034472463")
raise "candidate source is not copied into isolation" unless functions_run.include?("docker cp supabase/.")
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
