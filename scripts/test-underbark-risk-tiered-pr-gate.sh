#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workflow="${1:-$repo_root/.github/workflows/underbark-risk-tiered-pr-gate.yml}"
classifier="$repo_root/scripts/classify-underbark-pr.sh"

[[ -f "$workflow" ]] || {
  echo "Missing workflow: $workflow" >&2
  exit 1
}

empty_diff_scratch="$(mktemp -d "${TMPDIR:-/tmp}/underbark-diff-gate-tests.XXXXXX")"
trap 'rm -rf "$empty_diff_scratch"' EXIT
git -C "$empty_diff_scratch" init -q
git -C "$empty_diff_scratch" config user.name "Underbark Gate Test"
git -C "$empty_diff_scratch" config user.email "gate-test@invalid.example"
printf 'base\n' >"$empty_diff_scratch/tracked.txt"
git -C "$empty_diff_scratch" add tracked.txt
git -C "$empty_diff_scratch" commit -q -m "base"
empty_diff_base="$(git -C "$empty_diff_scratch" rev-parse HEAD)"
git -C "$empty_diff_scratch" commit -q --allow-empty -m "linear empty commit"
empty_diff_head="$(git -C "$empty_diff_scratch" rev-parse HEAD)"

[[ "$empty_diff_base" != "$empty_diff_head" ]] || {
  echo "Linear empty-diff fixture did not create two commits." >&2
  exit 1
}
[[ "$(git -C "$empty_diff_scratch" rev-parse "${empty_diff_base}^{tree}")" \
  == "$(git -C "$empty_diff_scratch" rev-parse "${empty_diff_head}^{tree}")" ]] || {
  echo "Linear empty-diff fixture trees differ." >&2
  exit 1
}
empty_diff_classification="$(
  git -C "$empty_diff_scratch" diff --name-status --no-renames -z \
    "$empty_diff_base...$empty_diff_head" \
    | "$classifier"
)"
[[ "$empty_diff_classification" == $'blocked\t0\t0' ]] || {
  echo "Linear empty diff did not fail closed: $empty_diff_classification" >&2
  exit 1
}

ruby -ryaml -rtmpdir -rfileutils -ropen3 -rjson - "$workflow" <<'RUBY'
jobs = YAML.load_file(ARGV.fetch(0)).fetch("jobs")
worker = jobs.fetch("worker") { abort "FAIL: isolated Worker verification job missing" }
body = worker.fetch("steps").map { |step| step["run"] }.compact.fetch(0)
# Execute the shipped shell block. Stub only external dependency tools, avoiding downloads.
Dir.mktmpdir("underbark-worker-fixtures-") do |root|
  script = File.join(root, "verify.sh")
  File.write(script, body)
  cases = %w[absent services-absent valid noop-scripts empty-tests parent-symlink dangling-parent worker-symlink dangling-worker nested-symlink file-parent file-worker install-failure types-failure tsc-failure tests-failure check-failure bundle-failure production-audit-failure audit-failure]
  cases.each do |name|
    candidate = File.join(root, name)
    service = File.join(candidate, "services/push-edge")
    FileUtils.mkdir_p(File.join(service, "test"))
    File.write(File.join(service, "test/worker.test.ts"), "test fixture")
    File.write(File.join(service, "package.json"), JSON.generate({scripts: {test: "true", typecheck: "true", types: "true"}}))
    File.write(File.join(service, "package-lock.json"), "{}")
    case name
    when "absent" then FileUtils.rm_rf(service)
    when "services-absent" then FileUtils.rm_rf(File.dirname(service))
    when "empty-tests" then FileUtils.rm_rf(File.join(service, "test"))
    when "parent-symlink", "dangling-parent"
      FileUtils.mv(File.dirname(service), File.join(candidate, "real-services"))
      File.symlink(name == "parent-symlink" ? "real-services" : "missing", File.dirname(service))
    when "worker-symlink", "dangling-worker"
      FileUtils.mv(service, File.join(candidate, "real-worker"))
      File.symlink(name == "worker-symlink" ? "../real-worker" : "missing", service)
    when "nested-symlink" then File.symlink("missing", File.join(service, "nested"))
    when "file-parent", "file-worker"
      target = name == "file-parent" ? File.dirname(service) : service
      FileUtils.rm_rf(target)
      File.write(target, "not a directory")
    end
    bin = File.join(candidate, "bin")
    FileUtils.mkdir_p(bin)
    File.write(File.join(bin, "npm"), <<~'SH')
      #!/bin/bash
      case "$*" in
        "ci --ignore-scripts") operation=install ;;
        "audit --omit=dev") operation=production-audit ;;
        "audit") operation=audit ;;
        *) exit 91 ;;
      esac
      echo "$operation" >> "$FIXTURE_LOG"
      [[ "$FIXTURE_CASE" != "$operation-failure" ]]
    SH
    File.write(File.join(bin, "node"), <<~'SH')
      #!/bin/bash
      case "$*" in
        "node_modules/wrangler/bin/wrangler.js types") operation=types ;;
        "node_modules/typescript/bin/tsc --noEmit") operation=tsc ;;
        "node_modules/vitest/vitest.mjs run --passWithNoTests=false") operation=tests ;;
        "node_modules/wrangler/bin/wrangler.js types --check") operation=check ;;
        "node_modules/wrangler/bin/wrangler.js deploy --dry-run --outdir "*)
          [[ "$5" == "$TMPDIR"/* ]] || exit 92
          [[ -d "$5" ]] || exit 93
          operation=bundle ;;
        *) exit 94 ;;
      esac
      echo "$operation" >> "$FIXTURE_LOG"
      [[ "$FIXTURE_CASE" != "$operation-failure" ]] || exit 1
      [[ "$FIXTURE_CASE" != noop-scripts || "$operation" != tests ]]
    SH
    FileUtils.chmod(0755, Dir[File.join(bin, "*")])
    scratch = File.join(candidate, "scratch")
    FileUtils.mkdir_p(scratch)
    log = File.join(candidate, "commands.log")
    output, status = Open3.capture2e({"PATH" => "#{bin}:#{ENV.fetch('PATH')}", "TMPDIR" => scratch,
      "FIXTURE_CASE" => name, "FIXTURE_LOG" => log}, "bash", script, chdir: candidate)
    wanted = %w[absent services-absent valid].include?(name)
    raise "Worker fixture #{name}: unexpected status #{status.exitstatus}: #{output}" unless status.success? == wanted
    raise "Worker scratch leaked in #{name}" unless Dir.children(scratch).empty?
    commands = File.exist?(log) ? File.readlines(log, chomp: true) : []
    raise "Worker commands missing or reordered" if name == "valid" && commands != %w[install types tsc tests check bundle production-audit audit]
    if %w[absent services-absent empty-tests parent-symlink dangling-parent worker-symlink dangling-worker nested-symlink file-parent file-worker].include?(name)
      raise "Rejected Worker executed tools: #{name}" unless commands.empty?
    end
  end
  result_script = File.join(root, "result.sh")
  File.write(result_script, jobs.fetch("result").fetch("steps").fetch(0).fetch("run"))
  result_bin = File.join(root, "result-bin")
  FileUtils.mkdir_p(result_bin)
  File.write(File.join(result_bin, "gh"), "#!/bin/bash\nprintf 'fixture-head\\tdev\\topen\\n'\n")
  FileUtils.chmod(0755, File.join(result_bin, "gh"))
  [["1", "success", true], ["1", "failure", false], ["1", "cancelled", false],
   ["1", "skipped", false], ["0", "skipped", true], ["0", "success", false]].each do |selected, actual, wanted|
    output, status = Open3.capture2e({"PATH" => "#{result_bin}:#{ENV.fetch('PATH')}",
      "CLASSIFY_RESULT" => "success", "CLASSIFICATION" => selected == "1" ? "backend" : "static",
      "BACKEND_FUNCTIONS" => selected, "BACKEND_DATABASE" => "0", "DATABASE_RESULT" => "skipped",
      "FUNCTIONS_RESULT" => selected == "1" ? "success" : "skipped", "WORKER_RESULT" => actual,
      "EVENT_HEAD" => "fixture-head", "EVENT_BASE_REF" => "dev", "GITHUB_REPOSITORY" => "fixture/repo",
      "PR_NUMBER" => "1"}, "bash", result_script)
    raise "Worker aggregator selected=#{selected} actual=#{actual}: #{output}" unless status.success? == wanted
  end
end
puts "UNDERBARK_WORKER_BEHAVIOR_FIXTURES_OK"
RUBY

ruby -ryaml -rdigest -rjson - "$workflow" <<'RUBY'
require "psych"

path = ARGV.fetch(0)

def reject_duplicate_keys(node, location = "$")
  case node
  when Psych::Nodes::Stream, Psych::Nodes::Document, Psych::Nodes::Sequence
    node.children.each_with_index do |child, index|
      reject_duplicate_keys(child, "#{location}[#{index}]")
    end
  when Psych::Nodes::Mapping
    seen = {}
    node.children.each_slice(2) do |key_node, value_node|
      key = key_node.respond_to?(:value) ? key_node.value : key_node.to_s
      raise "duplicate YAML key #{key.inspect} at #{location}" if seen.key?(key)
      seen[key] = true
      reject_duplicate_keys(value_node, "#{location}.#{key}")
    end
  end
end

reject_duplicate_keys(Psych.parse_stream(File.read(path)))
workflow = YAML.load_file(path)
jobs = workflow.fetch("jobs")
expected_jobs = %w[governance_claims classify website_context functions worker database result]
raise "unexpected job graph" unless jobs.keys == expected_jobs
raise "pull request trigger is narrowed" unless workflow.fetch(true).fetch("pull_request").nil?
raise "required result name changed" unless jobs.fetch("result").fetch("name") == "Underbark PR Gate result"
required_result_count = jobs.values.count { |job| job["name"] == "Underbark PR Gate result" }
raise "required result name is not unique" unless required_result_count == 1
raise "classifier repository guard changed" unless jobs.fetch("classify")["if"] ==
  "${{ github.repository == 'Synapselabs-au/Underbark' && needs.governance_claims.result == 'success' }}"
raise "governance claims repository guard changed" unless jobs.fetch("governance_claims")["if"] ==
  "${{ github.repository == 'Synapselabs-au/Underbark' }}"
raise "classifier does not depend on isolated governance claims" unless
  jobs.fetch("classify").fetch("needs") == "governance_claims"
raise "website context repository guard missing" unless jobs.fetch("website_context")["if"] ==
  "${{ github.repository == 'Synapselabs-au/Underbark-Web' }}"
raise "terminal dependencies changed" unless jobs.fetch("result").fetch("needs") ==
  %w[governance_claims classify functions worker database]
raise "terminal job is not always-run" unless jobs.fetch("result").fetch("if").include?("always()")
raise "workflow permissions must default to none" unless workflow.fetch("permissions") == {}
raise "concurrency changed" unless workflow.fetch("concurrency") == {
  "group" => "underbark-pr-gate-${{ github.repository }}-${{ github.event.pull_request.number }}",
  "cancel-in-progress" => true,
}

expected_outputs = {
  "classification" => "${{ steps.classify.outputs.classification }}",
  "backend_functions" => "${{ steps.classify.outputs.backend_functions }}",
  "backend_database" => "${{ steps.classify.outputs.backend_database }}",
}
raise "classifier output contract changed" unless jobs.fetch("classify").fetch("outputs") == expected_outputs

expected_timeouts = {
  "governance_claims" => 10,
  "classify" => 10,
  "website_context" => 10,
  "functions" => 45,
  "worker" => 15,
  "database" => 50,
  "result" => 10,
}
expected_permissions = {
  "governance_claims" => {"contents" => "read"},
  "classify" => {"contents" => "read", "pull-requests" => "read"},
  "website_context" => {"contents" => "read", "pull-requests" => "read"},
  "functions" => {"contents" => "read"},
  "worker" => {"contents" => "read"},
  "database" => {"contents" => "read"},
  "result" => {"contents" => "read", "pull-requests" => "read"},
}
expected_timeouts.each do |name, timeout|
  job = jobs.fetch(name)
  raise "#{name} timeout changed" unless job.fetch("timeout-minutes") == timeout
  raise "#{name} runner changed" unless job.fetch("runs-on") == "ubuntu-latest"
  raise "#{name} permissions changed" unless job.fetch("permissions") == expected_permissions.fetch(name)
end

def scripts(job)
  job.fetch("steps").map { |step| step["run"] }.compact
end

def serialized(value)
  JSON.generate(value)
end

jobs.each do |name, job|
  job.fetch("steps").each do |step|
    action = step["uses"]
    next unless action
    raise "#{name} action is not pinned: #{action}" unless action.match?(/@[0-9a-f]{40}\z/)

    inputs = step.fetch("with", {})
    candidate = inputs["path"] == ".candidate" ||
      inputs["repository"].to_s.include?("pull_request.head.repo.full_name") ||
      inputs["ref"].to_s.include?("pull_request.head.sha")
    if candidate && inputs["persist-credentials"] != false
      raise "#{name} candidate checkout persists credentials"
    end
  end
end

%w[governance_claims functions worker database].each do |name|
  body = serialized(jobs.fetch(name))
  raise "#{name} received a GitHub token" if body.include?("github.token") || body.include?("GH_TOKEN")
  raise "#{name} received a secret" if body.include?("secrets")
  raise "#{name} can write a workflow command file" if %w[GITHUB_ENV GITHUB_PATH GITHUB_OUTPUT].any? { |key| body.include?(key) }
end

token_jobs = jobs.select { |_name, job| serialized(job).include?("github.token") }.keys
raise "token-bearing job boundary changed" unless token_jobs == %w[classify website_context result]

expected_run_hashes = {
  "governance_claims" => "0ddd464456f46c99c4482305babc2a55292691faeae29812c962c13b948720b4",
  "classify" => "a66726736e8f36dbeb1e6179a7fa83fea000f95d11fd27a82507bdf34ac983fa",
  "website_context" => "a297051acb70e8a8957a8669c49624e425e04823ce0a221b986410a52e13308b",
  "functions" => "70540c360a85f9fe5768ace078a4540097ad53ff4a81e07ef6531d9e4cb74143",
  "worker" => "a5c2577b91baa7bf7230e65ca267f1d65f3842581d79b10a10569b1b0f717d2a",
  "database" => "dcdf60915883f8607d4272b66d3e59dc04ce62e52915f666493e064077bf6d93",
  "result" => "a9bd8bf648b68eae328045d74d93d8ec69613dd1672a24bce5c104cc0842eb5a",
}
expected_step_hashes = {
  "governance_claims" => "e165ec599022601a803b26689fb15157ef1e025cae7614e7f14fd1083ca553ba",
  "classify" => "ec9d0e759eb3374d7fb8e2a686d2485992d6764acea5fa15280053269f14e244",
  "website_context" => "be4c80bba94d426b1af86b3f5b625f3aeed884b524c9b63a9214c85d93ff137e",
  "functions" => "de34e4fb1202e46c24988d5a70776102cf54a95fbdc4ee97574e9ae5268933fa",
  "worker" => "e7a5a6b0cf7a2ac33daf63cf541085f9aee21ce0a0dc07c0ca5519145b65d2d9",
  "database" => "13cc23605e02f80e41335d0444f6c155731d0d17941acb8815f1f162a82fdbee",
  "result" => "adc8772659de234003859202abf8a40dc18ee6ca0f59c9eb59fca28c891f6373",
}
expected_run_hashes.each do |name, digest|
  job_scripts = scripts(jobs.fetch(name))
  actual = job_scripts.length == 1 ? Digest::SHA256.hexdigest(job_scripts.fetch(0)) : nil
  raise "#{name} run contract changed" unless actual == digest
  actual_steps = Digest::SHA256.hexdigest(serialized(jobs.fetch(name).fetch("steps")))
  raise "#{name} step contract changed" unless actual_steps == expected_step_hashes.fetch(name)
end

governance_claims = jobs.fetch("governance_claims")
governance_steps = governance_claims.fetch("steps")
raise "governance claims job must have exactly one checkout and one run step" unless
  governance_steps.length == 2
raise "governance claims candidate checkout changed" unless governance_steps.fetch(0).fetch("with") == {
  "repository" => "${{ github.event.pull_request.head.repo.full_name }}",
  "ref" => "${{ github.event.pull_request.head.sha }}",
  "path" => ".candidate",
  "persist-credentials" => false,
}
governance_body = scripts(governance_claims).fetch(0)
raise "governance claims script execution missing" unless
  governance_body.include?("bash .candidate/scripts/verify-claims-register.sh")
raise "governance claims job can mutate the trusted gate" if governance_body.include?(".gate/")
raise "governance claims job receives a GitHub token" if
  serialized(governance_claims).include?("github.token") || serialized(governance_claims).include?("GH_TOKEN")

classify = scripts(jobs.fetch("classify")).fetch(0)
raise "trusted classifier executes candidate scripts" if
  serialized(jobs.fetch("classify")).include?(".candidate/scripts/")
raise "event-base diff check missing" unless classify.include?('git -C .candidate diff --check "$EVENT_BASE_SHA...$EVENT_HEAD"')
approval_index = classify.index(".gate/scripts/verify-agent-context-approval.py")
raise "trusted agent-context approval verifier missing" unless approval_index
raise "agent-context approval runs before exact head commit check" unless
  classify.index('git -C .candidate cat-file -e "${EVENT_HEAD}^{commit}"') < approval_index
raise "agent-context approval runs before diff check" unless
  classify.index('git -C .candidate diff --check "$EVENT_BASE_SHA...$EVENT_HEAD"') < approval_index
raise "agent-context approval runs after Supabase verification" unless
  approval_index < classify.index("verify-underbark-supabase-config.py")
raise "agent-context approval runs after classification" unless
  approval_index < classify.index("classify-underbark-pr.sh")
raise "trusted path classifier missing" unless classify.include?("classify-underbark-pr.sh")
raise "ordinary empty diff bypasses the classifier" if classify.include?("diff --quiet") || classify.match?(/classification\s*=\s*["']static["']/)
raise "Supabase config verifier missing" unless classify.include?("verify-underbark-supabase-config.py")
raise "head race guard missing" unless classify.include?("require_same_pr")
raise "dev target guard missing" unless classify.include?('EVENT_BASE_REF" != "dev')
raise "normal PR gate still binds to live dev ancestry" if classify.match?(/merge[-_]base|LIVE_BASE_SHA|require_current_main/)
raise "normal PR gate still contains release reservation logic" if classify.include?("release-in-flight") || classify.include?("verify-underbark-release-context")

website_context = scripts(jobs.fetch("website_context")).fetch(0)
website_steps = jobs.fetch("website_context").fetch("steps")
website_trusted_checkout = website_steps.fetch(0)
raise "website trusted checkout changed" unless website_trusted_checkout.fetch("with") == {
  "repository" => "Synapselabs-au/.github",
  "ref" => "${{ github.workflow_sha }}",
  "path" => ".gate",
  "persist-credentials" => false,
}
website_candidate_checkout = website_steps.fetch(1)
raise "website candidate checkout changed" unless website_candidate_checkout.fetch("with") == {
  "repository" => "${{ github.event.pull_request.head.repo.full_name }}",
  "ref" => "${{ github.event.pull_request.head.sha }}",
  "fetch-depth" => 0,
  "path" => ".candidate",
  "persist-credentials" => false,
}
raise "website target guard missing" unless website_context.include?('EVENT_BASE_REF" != "dev')
raise "website live-state guard missing" unless website_context.include?("require_same_pr")
raise "website live state is not checked before and after verification" unless
  website_context.scan("require_same_pr").length == 3
raise "website base commit check missing" unless
  website_context.include?('git -C .candidate cat-file -e "${EVENT_BASE_SHA}^{commit}"')
raise "website head commit check missing" unless
  website_context.include?('git -C .candidate cat-file -e "${EVENT_HEAD}^{commit}"')
raise "website diff check missing" unless
  website_context.include?('git -C .candidate diff --check "$EVENT_BASE_SHA...$EVENT_HEAD"')
raise "website trusted approval verifier missing" unless
  website_context.include?(".gate/scripts/verify-agent-context-approval.py")
raise "website context job executes candidate scripts" if website_context.include?(".candidate/scripts/")

functions_job = jobs.fetch("functions")
functions_steps = functions_job.fetch("steps")
raise "functions job must check out, set up Node, and verify" unless functions_steps.length == 3
setup_node = functions_steps.fetch(1)
raise "Node setup action changed" unless
  setup_node.fetch("uses") == "actions/setup-node@249970729cb0ef3589644e2896645e5dc5ba9c38"
raise "Node setup version changed" unless setup_node.fetch("with") == {"node-version" => "24"}

functions = scripts(functions_job).fetch(0)
worker_job = jobs.fetch("worker")
raise "Worker selection changed" unless worker_job.fetch("needs") == "classify" &&
  worker_job.fetch("if") == functions_job.fetch("if")
worker_steps = worker_job.fetch("steps")
raise "Worker must execute in a separate candidate job" unless worker_steps.length == 3 &&
  worker_steps.fetch(0) == functions_steps.fetch(0) &&
  worker_steps.fetch(1) == setup_node &&
  worker_steps.fetch(2).fetch("working-directory") == ".candidate"
raise "Worker job can access trusted gate" if serialized(worker_job).include?(".gate")
raise "Worker verification leaked into existing functions job" if functions.include?("push-edge")
raise "Deno image is not digest-pinned" unless functions.include?("denoland/deno:2.9.5@sha256:")
raise "Deno candidate code is host-mounted" if functions.include?("--mount") || functions.match?(/\s-v\s/)
raise "Deno container became privileged" if functions.include?("--privileged")
raise "Deno cleanup missing" unless functions.include?("trap cleanup EXIT")
raise "Deno lock is not frozen" unless functions.include?("deno check --frozen") && functions.include?("deno test --frozen")
raise "Node service presence guard missing" unless functions.include?('if [[ -d services/apple-notifications ]]; then')
raise "Node service symlink guard missing" unless
  functions.include?("find services/apple-notifications -type l -print -quit")
raise "Node dependencies can execute lifecycle scripts" unless
  functions.include?("npm --prefix services/apple-notifications ci --ignore-scripts")
raise "Node service tests are candidate-script controlled" unless
  functions.include?("node --import tsx --test 'test/**/*.test.ts'") &&
    !functions.include?("npm --prefix services/apple-notifications test")
raise "Node service typecheck is candidate-script controlled" unless
  functions.include?("node node_modules/typescript/bin/tsc --noEmit") &&
    !functions.include?("npm --prefix services/apple-notifications run typecheck")
raise "Node production audit missing" unless
  functions.include?("npm --prefix services/apple-notifications audit --omit=dev")
raise "Node verification can alter Deno evidence" unless
  functions.index("deno test --frozen") <
    functions.index("npm --prefix services/apple-notifications ci --ignore-scripts")

database = scripts(jobs.fetch("database")).fetch(0)
raise "Postgres image is not digest-pinned" unless database.include?("ghcr.io/supabase/postgres@sha256:")
raise "database cleanup missing" unless database.include?("trap cleanup EXIT") && database.include?("supabase stop --workdir . --no-backup")
raise "candidate SQL is not copied into the disposable database" unless database.include?("docker cp supabase/tests/.")
raise "SQL does not fail closed" unless database.include?("ON_ERROR_STOP=1")

result = scripts(jobs.fetch("result")).fetch(0)
raise "selected backend lanes are not aggregated" unless result.include?("require_lane_result")
raise "Worker result is not required by the function selector" unless
  result.include?('require_lane_result "$BACKEND_FUNCTIONS" "$WORKER_RESULT" "Worker"') &&
  jobs.fetch("result").fetch("steps").fetch(0).fetch("env").fetch("WORKER_RESULT") == "${{ needs.worker.result }}"
raise "Apple classifications are not accepted" unless result.include?("apple:0:0|apple-backend:1:0|apple-backend:0:1|apple-backend:1:1")
raise "head race guard missing from terminal result" unless result.include?("Refusing changed, closed, or wrong-base pull request state.")
raise "terminal result still waits for Apple PR evidence" if result.include?("APPLE_RESULT") || result.include?("APPLE_CHECK_NAME")

body = File.read(path)
forbidden = [
  "Verify exact-head Apple result",
  "Waiting for exact-head Apple verification",
  "APPLE_APP_ID",
  "APPLE_CHECK_NAME",
  "actions/cache",
  "upload-artifact",
  "download-artifact",
  "matrix:",
  "continue-on-error",
  "macos-",
  "xcodebuild",
  "secrets.",
]
forbidden.each do |value|
  raise "forbidden workflow behavior present: #{value}" if body.include?(value)
end

puts "UNDERBARK_PR_GATE_TESTS_OK"
RUBY

fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/underbark-node-gate-tests.XXXXXX")"
cleanup_fixture_root() {
  case "$fixture_root" in
    "${TMPDIR:-/tmp}"/underbark-node-gate-tests.*)
      rm -rf -- "$fixture_root"
      ;;
    *)
      echo "Refusing to remove unexpected fixture root: $fixture_root" >&2
      return 1
      ;;
  esac
}
trap 'cleanup_fixture_root; rm -rf -- "$empty_diff_scratch"' EXIT

node_verification="$fixture_root/node-verification.sh"
ruby -ryaml - "$workflow" "$node_verification" <<'RUBY'
workflow_path, output_path = ARGV
workflow = YAML.load_file(workflow_path)
body = workflow.fetch("jobs").fetch("functions").fetch("steps").map { |step| step["run"] }.compact.fetch(0)
start = body.index("if [[ -d services/apple-notifications ]]; then")
raise "Node verification block missing" unless start

File.write(output_path, "set -euo pipefail\n#{body[start..]}")
RUBY

fixture_failures=0
run_node_fixture() {
  fixture_name="$1"
  candidate_root="$fixture_root/$fixture_name"
  mkdir -p "$candidate_root/services/apple-notifications"
  cp -R "$repo_root/scripts/fixtures/underbark-node-gate/$fixture_name/." \
    "$candidate_root/services/apple-notifications/"

  set +e
  (
    cd "$candidate_root"
    timeout() {
      shift
      "$@"
    }
    npm() {
      if [[ "$*" == "--prefix services/apple-notifications audit --omit=dev" ]]; then
        return 0
      fi
      command npm "$@"
    }
    export -f timeout
    export -f npm
    GITHUB_RUN_ID="fixture-$fixture_name" \
      GITHUB_RUN_ATTEMPT=1 \
      bash "$node_verification"
  ) >"$candidate_root/output.log" 2>&1
  fixture_status=$?
  set -e
}

run_node_fixture install-hook
if [[ -e "$candidate_root/services/apple-notifications/install-hook-ran" ]]; then
  echo "FAIL: candidate npm install lifecycle hook executed" >&2
  fixture_failures=$((fixture_failures + 1))
fi

run_node_fixture noop-scripts
if [[ "$fixture_status" -eq 0 ]]; then
  echo "FAIL: candidate no-op test and typecheck scripts passed trusted verification" >&2
  fixture_failures=$((fixture_failures + 1))
fi

if [[ "$fixture_failures" -ne 0 ]]; then
  exit 1
fi

echo "UNDERBARK_NODE_ADVERSARIAL_FIXTURES_OK"

# Execute the diagnostic selection from the actual workflow with a container-boundary stub.
diagnostic_verification="$empty_diff_scratch/diagnostic-verification.sh"
ruby -ryaml - "$workflow" "$diagnostic_verification" <<'RUBY'
workflow = YAML.load_file(ARGV.fetch(0))
script = workflow.fetch("jobs").fetch("functions").fetch("steps").find { |step| step["name"] == "Verify isolated backend functions" }.fetch("run")
block = script[/^if \[\[ -e scripts\/load\/entitlement-timing\.ts.*?(?=^if \[\[ -d services\/apple-notifications)/m]
raise "Missing executable entitlement diagnostic verification" unless block
File.write(ARGV.fetch(1), "set -euo pipefail\n" + block)
RUBY
run_diagnostic_fixture() (
  fixture="$empty_diff_scratch/diagnostic-$1"
  mkdir -p "$fixture/scripts/load" "$fixture/scripts/tests"
  cd "$fixture"
  case "$1" in
    absent) ;;
    missing) touch scripts/load/entitlement-timing.ts ;;
    symlink) touch scripts/tests/entitlement-timing-tests.ts; ln -s /dev/null scripts/load/entitlement-timing.ts ;;
    parent-symlink) mv scripts/load real-load; ln -s ../real-load scripts/load; touch real-load/entitlement-timing.ts scripts/tests/entitlement-timing-tests.ts ;;
    *) touch scripts/load/entitlement-timing.ts scripts/tests/entitlement-timing-tests.ts ;;
  esac
  container=fixture
  export container
  timeout() { shift; "$@"; }
  deno() {
    printf '%s\n' "$*" >> "$fixture/deno.log"
    [[ "$1" != test || "$fixture" != *test-failure ]]
  }
  docker() {
    printf '%s\n' "$*" >> "$fixture/docker.log"
    if [[ "$1" == exec && "$3" == sh ]]; then
      bash -euc "$5"
    fi
  }
  export fixture
  export -f timeout docker deno
  bash "$diagnostic_verification"
)
run_diagnostic_fixture absent
[[ ! -e "$empty_diff_scratch/diagnostic-absent/docker.log" ]]
run_diagnostic_fixture valid
for operation in fmt check test; do
  grep -q "^$operation " "$empty_diff_scratch/diagnostic-valid/deno.log"
done
grep -q '^test --frozen --config supabase/functions/deno.json scripts/tests/entitlement-timing-tests.ts$' "$empty_diff_scratch/diagnostic-valid/deno.log"
[[ "$(grep -c '^cp ' "$empty_diff_scratch/diagnostic-valid/docker.log")" == 2 ]]
for invalid in missing symlink parent-symlink test-failure; do
  if run_diagnostic_fixture "$invalid"; then
    echo "Diagnostic fixture incorrectly passed: $invalid" >&2
    exit 1
  fi
done
echo "All entitlement diagnostic workflow fixtures passed."
