#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
workflow="${script_dir}/../.github/workflows/underbark-risk-tiered-pr-gate.yml"
failures=0

bash "${script_dir}/test-classify-underbark-pr.sh"
bash "${script_dir}/test-verify-underbark-release-context.sh"
python3 "${script_dir}/test-verify-underbark-supabase-config.py"

if ! ruby -ryaml - "$workflow" <<'RUBY'
require "digest"
require "json"

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
raise "classifier output contract changed" unless jobs.fetch("classify").fetch("outputs") == {
  "classification" => "${{ steps.classify.outputs.classification }}",
  "backend_functions" => "${{ steps.classify.outputs.backend_functions }}",
  "backend_database" => "${{ steps.classify.outputs.backend_database }}",
  "ancestry_sync" => "${{ steps.classify.outputs.ancestry_sync }}",
  "ancestry_main_sha" => "${{ steps.classify.outputs.ancestry_main_sha }}",
}
raise "superseded heads do not share one concurrency group" unless workflow.fetch("concurrency") == {
  "group" => "underbark-pr-gate-${{ github.repository }}-${{ github.event.pull_request.number }}",
  "cancel-in-progress" => true,
}
raise "continue-on-error is globally prohibited" if YAML.dump(workflow).include?("continue-on-error")

expected_timeouts = {
  "classify" => 10,
  "functions" => 45,
  "database" => 50,
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

EXPECTED_FUNCTIONS_RUN = <<~'BASH'
  set -euo pipefail

  container="underbark-deno-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}"
  image="denoland/deno:2.9.5@sha256:b429777c3dcff34a6488f365a1537db1640b2d48379b60f5e6206be034472463"
  cleanup() {
    original_status="$?"
    trap - EXIT
    cleanup_status=0
    timeout 2m docker rm -f "$container" >/dev/null 2>&1 || cleanup_status="$?"
    if [[ "$original_status" -ne 0 ]]; then
      exit "$original_status"
    fi
    exit "$cleanup_status"
  }
  trap cleanup EXIT

  timeout 5m docker pull "$image"
  timeout 1m docker create \
    --pull never \
    --name "$container" \
    --network bridge \
    --workdir /workspace \
    "$image" \
    eval 'setInterval(() => {}, 3600000)'
  timeout 1m docker start "$container" >/dev/null
  timeout 1m docker cp supabase/. "$container:/workspace/supabase"
  timeout 10m docker exec "$container" sh -euc '
    if find supabase/functions -type l -print -quit | grep -q .; then
      echo "Symlinks are not allowed under supabase/functions." >&2
      exit 1
    fi
    find supabase/functions -type f -name "*.ts" -print0 | LC_ALL=C sort -z > /tmp/underbark-typescript-files
    test -s /tmp/underbark-typescript-files
    xargs -0 deno fmt --check < /tmp/underbark-typescript-files
    xargs -0 deno check --frozen --config supabase/functions/deno.json < /tmp/underbark-typescript-files
    find supabase/functions -type f \( -name "*_test.ts" -o -name "*.test.ts" \) -print0 | LC_ALL=C sort -z > /tmp/underbark-deno-test-files
    test -s /tmp/underbark-deno-test-files
    xargs -0 deno test --frozen --config supabase/functions/deno.json < /tmp/underbark-deno-test-files
  '
BASH

EXPECTED_DATABASE_RUN = <<~'BASH'
  set -euo pipefail

  cleanup() {
    original_status="$?"
    trap - EXIT
    cleanup_status=0
    timeout 5m supabase stop --workdir . --no-backup || cleanup_status="$?"
    if [[ "$original_status" -ne 0 ]]; then
      exit "$original_status"
    fi
    exit "$cleanup_status"
  }
  trap cleanup EXIT

  expected_postgres_digest="public.ecr.aws/supabase/postgres@sha256:99b1729aeb0bac314445024fc149fbd39306170b61dd50800ccf180327ab3459"
  expected_postgres_tag="public.ecr.aws/supabase/postgres:17.6.1.158"
  timeout 10m docker pull "$expected_postgres_digest"
  preflight_image_id="$(timeout 1m docker image inspect "$expected_postgres_digest" --format '{{.Id}}')"
  timeout 1m docker tag "$preflight_image_id" "$expected_postgres_tag"
  tagged_image_id="$(timeout 1m docker image inspect "$expected_postgres_tag" --format '{{.Id}}')"
  if [[ "$tagged_image_id" != "$preflight_image_id" ]]; then
    echo "The Supabase CLI Postgres tag does not resolve to the trusted image." >&2
    exit 1
  fi
  timeout 15m supabase db start --workdir .
  running_image_id="$(timeout 1m docker inspect --format '{{.Image}}' supabase_db_underbark)"
  mapfile -t running_repo_digests < <(timeout 1m docker image inspect "$running_image_id" --format '{{range .RepoDigests}}{{println .}}{{end}}' | LC_ALL=C sort -u)
  digest_match=0
  for repo_digest in "${running_repo_digests[@]}"; do
    if [[ "$repo_digest" == "$expected_postgres_digest" ]]; then
      digest_match=1
    fi
  done
  if [[ "$running_image_id" != "$preflight_image_id" || "$digest_match" -ne 1 ]]; then
    echo "The disposable Postgres image does not match the trusted digest." >&2
    exit 1
  fi
  timeout 1m docker exec supabase_db_underbark mkdir -p /tmp/underbark-tests
  timeout 1m docker cp supabase/tests/. supabase_db_underbark:/tmp/underbark-tests
  timeout 10m docker exec supabase_db_underbark bash -euo pipefail -c '
    if find /tmp/underbark-tests -type l -print -quit | grep -q .; then
      echo "Symlinks are not allowed under supabase/tests." >&2
      exit 1
    fi
    find /tmp/underbark-tests -type f -name "*.sql" -print0 | LC_ALL=C sort -z > /tmp/underbark-sql-files
    test -s /tmp/underbark-sql-files
    while IFS= read -r -d "" suite; do
      psql "postgresql://postgres:postgres@127.0.0.1:5432/postgres" -v ON_ERROR_STOP=1 -f "$suite"
    done < /tmp/underbark-sql-files
  '
BASH

EXPECTED_FUNCTIONS_EXECUTION_STEP = {
  "name" => "Verify isolated Supabase functions",
  "working-directory" => ".candidate",
  "run" => EXPECTED_FUNCTIONS_RUN,
}.freeze

EXPECTED_DATABASE_EXECUTION_STEP = {
  "name" => "Verify disposable Supabase database",
  "working-directory" => ".candidate",
  "run" => EXPECTED_DATABASE_RUN,
}.freeze

EXPECTED_CANDIDATE_CHECKOUT_STEP = {
  "name" => "Check out candidate without persisted credentials",
  "uses" => "actions/checkout@fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09",
  "with" => {
    "repository" => "${{ github.event.pull_request.head.repo.full_name }}",
    "ref" => "${{ github.event.pull_request.head.sha }}",
    "path" => ".candidate",
    "persist-credentials" => false,
  },
}.freeze

EXPECTED_DATABASE_SETUP_STEP = {
  "name" => "Set up Supabase CLI",
  "uses" => "supabase/setup-cli@ab058987d8d6c725971f6cf9d0b5c98467e30bd1",
  "with" => {"version" => "2.113.0"},
}.freeze

EXPECTED_CANDIDATE_JOB_STEPS = {
  "functions" => [
    EXPECTED_CANDIDATE_CHECKOUT_STEP,
    EXPECTED_FUNCTIONS_EXECUTION_STEP,
  ],
  "database" => [
    EXPECTED_CANDIDATE_CHECKOUT_STEP,
    EXPECTED_DATABASE_SETUP_STEP,
    EXPECTED_DATABASE_EXECUTION_STEP,
  ],
}.freeze

EXPECTED_TRUSTED_RUN_SHA256 = {
  "classify" => "02f73cd26dcfb405985fb886258c7bdd315f6877a376cb190eac526ee5aab8b3",
  "apple" => "93d8d4164687158f2f6260d19e87547301e8e2b46031409180de101b9cf857bb",
  "result" => "799dae466b679261da5cc9ad2ebb8ff71eb593a065da0e7efd803a72d5e35df2",
}.freeze

EXPECTED_TRUSTED_STEPS_SHA256 = {
  "classify" => "59ab5e0bc6e55a988a7ca63be1a2b4cad4b7fe2771a186191e5f140f06eb4d06",
  "apple" => "fde3f5f3cda4723647241559b0a6c3b99fe4417da9a45b39581d8bb0c305baeb",
  "result" => "722e756803e12aa09e8066dead7cd10e6b6aa657e134c1bc04c6c80cec9de24b",
}.freeze

config_verifier = File.expand_path("../../scripts/verify-underbark-supabase-config.py", File.dirname(ARGV.fetch(0)))
raise "trusted Supabase config verifier contract changed" unless Digest::SHA256.file(config_verifier).hexdigest == "b890e0230ede657563052ac6e698237c55f4f7a7d5675ba155be601188f6be99"

def require_exact_candidate_job_contract(jobs, job_name, expected_steps)
  actual = jobs.fetch(job_name).fetch("steps")
  return if actual == expected_steps

  raise "candidate #{job_name} execution step contract changed"
end

def require_exact_trusted_run_contracts(jobs)
  EXPECTED_TRUSTED_RUN_SHA256.each do |job_name, expected_sha|
    scripts = run_scripts(jobs.fetch(job_name))
    actual_sha = scripts.length == 1 ? Digest::SHA256.hexdigest(scripts.fetch(0)) : nil
    next if actual_sha == expected_sha

    raise "trusted #{job_name} run script contract changed"
  end
  EXPECTED_TRUSTED_STEPS_SHA256.each do |job_name, expected_sha|
    actual_sha = Digest::SHA256.hexdigest(JSON.generate(jobs.fetch(job_name).fetch("steps")))
    next if actual_sha == expected_sha

    raise "trusted #{job_name} step contract changed"
  end
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

  require_exact_trusted_run_contracts(jobs)
  EXPECTED_CANDIDATE_JOB_STEPS.each do |job_name, expected_steps|
    require_exact_candidate_job_contract(jobs, job_name, expected_steps)
  end
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

classify_run = run_scripts(jobs.fetch("classify")).join("\n")
config_verify_index = classify_run.index("verify-underbark-supabase-config.py") or raise "trusted Supabase config verification missing"
ancestry_branch_index = classify_run.index('if git -C .candidate diff --quiet') or raise "ancestry branch missing"
classifier_index = classify_run.index("classify-underbark-pr.sh") or raise "path classifier missing"
raise "Supabase config semantics are not verified before success paths" unless config_verify_index < ancestry_branch_index && config_verify_index < classifier_index

fixture = Marshal.load(Marshal.dump(workflow))
fixture.fetch("jobs").fetch("classify").fetch("steps").find { |step| step["run"] }.tap { |step| step["run"] << "\ndock''er run --privileged alpine true\n" }
expect_boundary_rejection("composed Docker in trusted classification", fixture, /\Atrusted classify run script contract changed\z/)

fixture = Marshal.load(Marshal.dump(workflow))
fixture.fetch("jobs").fetch("apple").fetch("steps").unshift(
  {"name" => "Unexpected trusted action", "uses" => "example/action@0123456789abcdef"},
)
expect_boundary_rejection("additional action in token-bearing job", fixture, /\Atrusted apple step contract changed\z/)

fixture = Marshal.load(Marshal.dump(workflow))
fixture.fetch("jobs").fetch("functions").fetch("steps").insert(
  1,
  {"name" => "Unexpected action", "uses" => "example/action@0123456789abcdef"},
)
expect_boundary_rejection("additional candidate action", fixture, /\Acandidate functions execution step contract changed\z/)

fixture = Marshal.load(Marshal.dump(workflow))
fixture.fetch("jobs").fetch("functions").fetch("steps").find { |step| step["run"] }.tap { |step| step["run"] << "\ntrue\n" }
expect_boundary_rejection("additional unrelated functions command", fixture, /\Acandidate functions execution step contract changed\z/)

fixture = Marshal.load(Marshal.dump(workflow))
functions_step = fixture.fetch("jobs").fetch("functions").fetch("steps").find { |step| step["run"].to_s.include?("deno fmt") }
expected_deno_order = <<'BASH'
  xargs -0 deno fmt --check < /tmp/underbark-typescript-files
  xargs -0 deno check --frozen --config supabase/functions/deno.json < /tmp/underbark-typescript-files
BASH
reordered_deno = <<'BASH'
  xargs -0 deno check --frozen --config supabase/functions/deno.json < /tmp/underbark-typescript-files
  xargs -0 deno fmt --check < /tmp/underbark-typescript-files
BASH
raise "reordered Deno fixture construction failed" unless functions_step["run"].sub!(expected_deno_order, reordered_deno)
expect_boundary_rejection("reordered Deno commands", fixture, /\Acandidate functions execution step contract changed\z/)

fixture = Marshal.load(Marshal.dump(workflow))
functions_step = fixture.fetch("jobs").fetch("functions").fetch("steps").find { |step| step["run"].to_s.include?("set -euo pipefail") }
raise "shell-settings fixture construction failed" unless functions_step["run"].sub!("set -euo pipefail", "set -eo pipefail")
expect_boundary_rejection("weakened functions shell settings", fixture, /\Acandidate functions execution step contract changed\z/)

fixture = Marshal.load(Marshal.dump(workflow))
database_step = fixture.fetch("jobs").fetch("database").fetch("steps").find { |step| step["run"].to_s.include?("trap cleanup EXIT") }
raise "database trap fixture construction failed" unless database_step["run"].sub!("trap cleanup EXIT", "true")
expect_boundary_rejection("removed database cleanup trap", fixture, /\Acandidate database execution step contract changed\z/)

fixture = Marshal.load(Marshal.dump(workflow))
database_step = fixture.fetch("jobs").fetch("database").fetch("steps").find { |step| step["run"].to_s.include?("expected_postgres_digest") }
raise "preflight tag fixture construction failed" unless database_step["run"].sub!(
  'docker tag "$preflight_image_id" "$expected_postgres_tag"',
  'docker tag latest-postgres "$expected_postgres_tag"',
)
expect_boundary_rejection("untrusted Postgres preflight tag", fixture, /\Acandidate database execution step contract changed\z/)

fixture = Marshal.load(Marshal.dump(workflow))
fixture.fetch("jobs").fetch("functions").fetch("steps").find { |step| step["run"] }.tap { |step| step["run"] << "\ndeno test supabase/functions\n" }
expect_boundary_rejection("host Deno", fixture, /\Acandidate functions execution step contract changed\z/)

fixture = Marshal.load(Marshal.dump(workflow))
deno_step = fixture.fetch("jobs").fetch("functions").fetch("steps").find { |step| step["run"].to_s.include?("deno fmt") }
raise "same-line Deno fixture construction failed" unless deno_step["run"].sub!(
  'xargs -0 deno fmt --check < /tmp/underbark-typescript-files',
  'xargs -0 deno fmt --check < /tmp/underbark-typescript-files; deno test supabase/functions',
)
expect_boundary_rejection("same-line host Deno", fixture, /\Acandidate functions execution step contract changed\z/)

fixture = Marshal.load(Marshal.dump(workflow))
fixture.fetch("jobs").fetch("functions").fetch("steps").find { |step| step["run"] }.tap { |step| step["run"] << "\nde''no test supabase/functions\n" }
expect_boundary_rejection("quoted-composition host Deno", fixture, /\Acandidate functions execution step contract changed\z/)

fixture = Marshal.load(Marshal.dump(workflow))
fixture.fetch("jobs").fetch("functions").fetch("steps").find { |step| step["run"] }.tap { |step| step["run"] << "\nde\\\nno test supabase/functions\n" }
expect_boundary_rejection("continued-command host Deno", fixture, /\Acandidate functions execution step contract changed\z/)

fixture = Marshal.load(Marshal.dump(workflow))
deno_step = fixture.fetch("jobs").fetch("functions").fetch("steps").find { |step| step["run"].to_s.include?("deno fmt") }
raise "wrong Deno container fixture construction failed" unless deno_step["run"].sub!('docker exec "$container" sh', 'docker exec wrong-container sh')
expect_boundary_rejection("wrong Deno container", fixture, /\Acandidate functions execution step contract changed\z/)

fixture = Marshal.load(Marshal.dump(workflow))
fixture.fetch("jobs").fetch("database").fetch("steps").find { |step| step["run"] }.tap { |step| step["run"] << "\npsql postgresql://localhost/postgres -c 'select 1'\n" }
expect_boundary_rejection("host psql", fixture, /\Acandidate database execution step contract changed\z/)

fixture = Marshal.load(Marshal.dump(workflow))
database_step = fixture.fetch("jobs").fetch("database").fetch("steps").find { |step| step["run"].to_s.include?("psql") }
raise "same-line psql fixture construction failed" unless database_step["run"].sub!(
  '-v ON_ERROR_STOP=1 -f "$suite"',
  '-v ON_ERROR_STOP=1 -f "$suite"; psql postgresql://localhost/postgres -c "select 1"',
)
expect_boundary_rejection("same-line host psql", fixture, /\Acandidate database execution step contract changed\z/)

fixture = Marshal.load(Marshal.dump(workflow))
fixture.fetch("jobs").fetch("database").fetch("steps").find { |step| step["run"] }.tap { |step| step["run"] << "\nps''ql postgresql://localhost/postgres -c 'select 1'\n" }
expect_boundary_rejection("quoted-composition host psql", fixture, /\Acandidate database execution step contract changed\z/)

fixture = Marshal.load(Marshal.dump(workflow))
fixture.fetch("jobs").fetch("database").fetch("steps").find { |step| step["run"] }.tap { |step| step["run"] << "\nps\\\nql postgresql://localhost/postgres -c 'select 1'\n" }
expect_boundary_rejection("continued-command host psql", fixture, /\Acandidate database execution step contract changed\z/)

fixture = Marshal.load(Marshal.dump(workflow))
database_step = fixture.fetch("jobs").fetch("database").fetch("steps").find { |step| step["run"].to_s.include?("psql") }
database_step["run"].sub!("docker exec supabase_db_underbark bash", "docker exec wrong-container bash")
expect_boundary_rejection("wrong psql container", fixture, /\Acandidate database execution step contract changed\z/)

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
expect_boundary_rejection("unsafe Docker after safe Docker", fixture, /\Acandidate functions execution step contract changed\z/)

fixture = Marshal.load(Marshal.dump(workflow))
fixture.fetch("jobs").fetch("functions").fetch("steps").find { |step| step["run"] }.tap { |step| step["run"] << "\ndock''er run --privileged alpine true\n" }
expect_boundary_rejection("quoted-composition unsafe Docker", fixture, /\Acandidate functions execution step contract changed\z/)

fixture = Marshal.load(Marshal.dump(workflow))
fixture.fetch("jobs").fetch("functions").fetch("steps").find { |step| step["run"] }.tap { |step| step["run"] << "\ndock\\\ner run --privileged alpine true\n" }
expect_boundary_rejection("continued-command unsafe Docker", fixture, /\Acandidate functions execution step contract changed\z/)

fixture = Marshal.load(Marshal.dump(workflow))
functions_step = fixture.fetch("jobs").fetch("functions").fetch("steps").find { |step| step["run"].to_s.include?("docker create") }
raise "separate-value Docker fixture construction failed" unless functions_step["run"].sub!(
  "  --name \"$container\" \\\n  --network bridge \\\n",
  "  --name \"$container\" \\\n  --label underbark=test \\\n  --privileged \\\n  --network bridge \\\n",
)
expect_boundary_rejection("unsafe Docker after separate-value option", fixture, /\Acandidate functions execution step contract changed\z/)

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
  expect_boundary_rejection(label, fixture, /\Acandidate functions execution step contract changed\z/)
end

token_jobs = jobs.select { |_name, job| serialized(job).include?("github.token") }.keys
raise "token job boundary changed" unless token_jobs == %w[classify apple result]

database_run = run_scripts(jobs.fetch("database")).join("\n")
start_index = database_run.index("supabase db start") or raise "database start missing"
pull_index = database_run.index('docker pull "$expected_postgres_digest"') or raise "trusted Postgres preflight pull missing"
tag_index = database_run.index('docker tag "$preflight_image_id" "$expected_postgres_tag"') or raise "trusted Postgres CLI tag missing"
sql_index = database_run.index("psql ") or raise "SQL suites missing"
cleanup_index = database_run.index("supabase stop") or raise "database cleanup missing"
trap_index = database_run.index("trap cleanup EXIT") or raise "cleanup trap missing"
raise "cleanup is not installed before untrusted SQL" unless trap_index < start_index
raise "database command ordering changed" unless cleanup_index < start_index && start_index < sql_index
raise "Postgres preflight does not precede CLI startup" unless pull_index < tag_index && tag_index < start_index
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
raise "TypeScript discovery is not recursive and NUL-safe" unless functions_run.include?('find supabase/functions -type f -name "*.ts" -print0 | LC_ALL=C sort -z')
raise "Deno checking is not lock-frozen" unless functions_run.include?("deno check --frozen")
raise "Deno testing is not lock-frozen" unless functions_run.include?("deno test --frozen")
raise "Deno input discovery does not fail closed" unless functions_run.include?("test -s /tmp/underbark-typescript-files") && functions_run.include?("test -s /tmp/underbark-deno-test-files")

database_run = run_scripts(jobs.fetch("database")).join("\n")
digest_index = database_run.index("expected_postgres_digest=") or raise "trusted Postgres digest missing"
start_index = database_run.index("supabase db start") or raise "database start missing"
running_index = database_run.index("running_image_id=") or raise "running Postgres image verification missing"
copy_index = database_run.index("docker cp supabase/tests/.") or raise "SQL copy missing"
raise "Postgres digest is not pinned before startup and verified before SQL execution" unless digest_index < start_index && start_index < running_index && running_index < copy_index
raise "running Postgres RepoDigests are not inspected" unless database_run.include?("{{range .RepoDigests}}")
raise "SQL discovery is not recursive and NUL-safe" unless database_run.include?('find /tmp/underbark-tests -type f -name "*.sql" -print0 | LC_ALL=C sort -z')
raise "SQL discovery does not fail closed" unless database_run.include?("test -s /tmp/underbark-sql-files")

apple_run = run_scripts(jobs.fetch("apple")).join("\n")
raise "Apple check-run pagination missing" unless apple_run.include?("gh api --paginate --slurp")
raise "Apple check selection does not inspect every page" unless apple_run.include?("[.[].check_runs[]")
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
expect_job_contains database 'timeout-minutes: 50' "must bound immutable image preflight, database start, SQL, and cleanup"
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
expect_job_contains functions 'find supabase/functions -type f -name "*.ts" -print0 | LC_ALL=C sort -z' "must discover every TypeScript file recursively and deterministically"
expect_job_contains functions 'xargs -0 deno fmt --check' "must format every discovered TypeScript file"
expect_job_contains functions 'xargs -0 deno check --frozen --config supabase/functions/deno.json' "must type-check every TypeScript file against the frozen lock"
expect_job_contains functions 'xargs -0 deno test --frozen --config supabase/functions/deno.json' "must run every discovered Deno test against the frozen lock"

expect_job_contains database 'supabase/setup-cli@ab058987d8d6c725971f6cf9d0b5c98467e30bd1' "must pin Supabase setup"
expect_job_contains database 'version: 2.113.0' "must pin Supabase CLI 2.113.0"
expect_job_contains database 'trap cleanup EXIT' "must install same-step database cleanup"
expect_job_contains database 'timeout 15m supabase db start --workdir .' "must bound Postgres-only database startup"
expect_job_contains database 'public.ecr.aws/supabase/postgres@sha256:99b1729aeb0bac314445024fc149fbd39306170b61dd50800ccf180327ab3459' "must bind the disposable Postgres image to the trusted digest"
expect_job_contains database 'public.ecr.aws/supabase/postgres:17.6.1.158' "must bind the Supabase CLI expected Postgres tag"
expect_job_contains database 'docker pull "$expected_postgres_digest"' "must pull the immutable Postgres digest before CLI startup"
expect_job_contains database 'docker tag "$preflight_image_id" "$expected_postgres_tag"' "must make the CLI tag resolve to the preflight image"
expect_job_contains database "{{range .RepoDigests}}{{println .}}{{end}}" "must inspect the running image RepoDigests"
expect_job_contains database 'timeout 10m docker exec supabase_db_underbark bash -euo pipefail -c' "must bound SQL suites inside the disposable database container"
expect_job_contains database 'docker cp supabase/tests/. supabase_db_underbark:/tmp/underbark-tests' "must copy candidate SQL into the disposable container without a host mount"
expect_job_contains database 'docker exec supabase_db_underbark bash -euo pipefail -c' "must process candidate SQL only inside the disposable database container"
expect_job_contains database 'psql "postgresql://postgres:postgres@127.0.0.1:5432/postgres" -v ON_ERROR_STOP=1 -f "$suite"' "must keep psql meta-commands inside the disposable database container"
expect_job_contains database 'find /tmp/underbark-tests -type f -name "*.sql" -print0 | LC_ALL=C sort -z' "must discover every SQL suite recursively and deterministically"
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
expect_job_contains result 'Invalid terminal classifier outputs.' "must reject empty or inconsistent classifier outputs"
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
expect_excludes 'continue-on-error' "must not permit failed trusted or candidate steps to continue"
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
