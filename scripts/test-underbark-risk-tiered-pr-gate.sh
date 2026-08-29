#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workflow="${1:-$repo_root/.github/workflows/underbark-risk-tiered-pr-gate.yml}"

[[ -f "$workflow" ]] || {
  echo "Missing workflow: $workflow" >&2
  exit 1
}

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
expected_jobs = %w[classify functions database result]
raise "unexpected job graph" unless jobs.keys == expected_jobs
raise "pull request trigger is narrowed" unless workflow.fetch(true).fetch("pull_request").nil?
raise "required result name changed" unless jobs.fetch("result").fetch("name") == "Underbark PR Gate result"
required_result_count = jobs.values.count { |job| job["name"] == "Underbark PR Gate result" }
raise "required result name is not unique" unless required_result_count == 1
raise "classifier repository guard changed" unless jobs.fetch("classify")["if"] ==
  "${{ github.repository == 'Synapselabs-au/Underbark' }}"
raise "terminal dependencies changed" unless jobs.fetch("result").fetch("needs") == %w[classify functions database]
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
  "classify" => 10,
  "functions" => 45,
  "database" => 50,
  "result" => 10,
}
expected_permissions = {
  "classify" => {"contents" => "read", "pull-requests" => "read"},
  "functions" => {"contents" => "read"},
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

%w[functions database].each do |name|
  body = serialized(jobs.fetch(name))
  raise "#{name} received a GitHub token" if body.include?("github.token") || body.include?("GH_TOKEN")
  raise "#{name} received a secret" if body.include?("secrets")
  raise "#{name} can write a workflow command file" if %w[GITHUB_ENV GITHUB_PATH GITHUB_OUTPUT].any? { |key| body.include?(key) }
end

token_jobs = jobs.select { |_name, job| serialized(job).include?("github.token") }.keys
raise "token-bearing job boundary changed" unless token_jobs == %w[classify result]

expected_run_hashes = {
  "classify" => "f8803d6c422026259ce3a1d806dc07fd7a0ef561c8a140e1a4b73ba25da8e393",
  "functions" => "82f2b8709b490ba656f7e199c8ee4359efd58929a487956199bb33b3ba026192",
  "database" => "dcdf60915883f8607d4272b66d3e59dc04ce62e52915f666493e064077bf6d93",
  "result" => "74ddc71787346c4596a98626fdf715ac13b41f4a949c1a5a5c84090ff18b8afe",
}
expected_step_hashes = {
  "classify" => "e2c5ec289858a322d000bb3f174caa84e2282cd1cd695082bac4b86c5e682bdb",
  "functions" => "1f07b1aea95365070484a72c78fbce47b932c372e100a0ca65240753a76d04be",
  "database" => "13cc23605e02f80e41335d0444f6c155731d0d17941acb8815f1f162a82fdbee",
  "result" => "dc605f0653c15682675729a53c64c155eb366bfd4e894cd4089991a7264eee5c",
}
expected_run_hashes.each do |name, digest|
  job_scripts = scripts(jobs.fetch(name))
  actual = job_scripts.length == 1 ? Digest::SHA256.hexdigest(job_scripts.fetch(0)) : nil
  raise "#{name} run contract changed" unless actual == digest
  actual_steps = Digest::SHA256.hexdigest(serialized(jobs.fetch(name).fetch("steps")))
  raise "#{name} step contract changed" unless actual_steps == expected_step_hashes.fetch(name)
end

classify = scripts(jobs.fetch("classify")).fetch(0)
raise "event-base diff check missing" unless classify.include?('git -C .candidate diff --check "$EVENT_BASE_SHA...$EVENT_HEAD"')
raise "trusted path classifier missing" unless classify.include?("classify-underbark-pr.sh")
raise "Supabase config verifier missing" unless classify.include?("verify-underbark-supabase-config.py")
raise "head race guard missing" unless classify.include?("require_same_pr")
raise "dev target guard missing" unless classify.include?('EVENT_BASE_REF" != "dev')
raise "normal PR gate still binds to live dev ancestry" if classify.match?(/merge[-_]base|LIVE_BASE_SHA|require_current_main/)
raise "normal PR gate still contains release reservation logic" if classify.include?("release-in-flight") || classify.include?("verify-underbark-release-context")

functions = scripts(jobs.fetch("functions")).fetch(0)
raise "Deno image is not digest-pinned" unless functions.include?("denoland/deno:2.9.5@sha256:")
raise "Deno candidate code is host-mounted" if functions.include?("--mount") || functions.match?(/\s-v\s/)
raise "Deno container became privileged" if functions.include?("--privileged")
raise "Deno cleanup missing" unless functions.include?("trap cleanup EXIT")
raise "Deno lock is not frozen" unless functions.include?("deno check --frozen") && functions.include?("deno test --frozen")

database = scripts(jobs.fetch("database")).fetch(0)
raise "Postgres image is not digest-pinned" unless database.include?("ghcr.io/supabase/postgres@sha256:")
raise "database cleanup missing" unless database.include?("trap cleanup EXIT") && database.include?("supabase stop --workdir . --no-backup")
raise "candidate SQL is not copied into the disposable database" unless database.include?("docker cp supabase/tests/.")
raise "SQL does not fail closed" unless database.include?("ON_ERROR_STOP=1")

result = scripts(jobs.fetch("result")).fetch(0)
raise "selected backend lanes are not aggregated" unless result.include?("require_lane_result")
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
  ".candidate/scripts/",
  "macos-",
  "xcodebuild",
  "secrets.",
]
forbidden.each do |value|
  raise "forbidden workflow behavior present: #{value}" if body.include?(value)
end

puts "UNDERBARK_PR_GATE_TESTS_OK"
RUBY
