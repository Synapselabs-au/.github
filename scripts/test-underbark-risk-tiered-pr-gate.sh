#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workflow="${1:-$repo_root/.github/workflows/underbark-risk-tiered-pr-gate.yml}"

fail() {
  printf 'gate test failed: %s\n' "$1" >&2
  exit 1
}

[[ -f "$workflow" ]] || fail "workflow missing: $workflow"
grep -Fq 'name: Underbark PR Gate' "$workflow" || fail 'stable required-workflow name changed'
grep -Fq 'cancel-in-progress: true' "$workflow" || fail 'superseded runs are not cancelled'
grep -Fq 'persist-credentials: false' "$workflow" || fail 'candidate checkout may retain credentials'
grep -Fq 'name: Verify backend functions' "$workflow" || fail 'backend function verification was removed'
grep -Fq 'name: Verify backend database' "$workflow" || fail 'backend database verification was removed'
grep -Fq 'Apple runtime verification is release-scoped.' "$workflow" || fail 'release-scoped Apple policy marker is missing'

if grep -Eq 'Verify exact-head Apple result|APPLE_CHECK_NAME|APPLE_APP_ID|Waiting for exact-head Apple verification|sleep 30' "$workflow"; then
  fail 'normal PR gate still waits for paid Xcode Cloud evidence'
fi
if grep -Eq 'merge[_-]?base|LIVE_BASE_SHA|final_base_sha|inspected_base_sha' "$workflow"; then
  fail 'normal PR gate still invalidates work when dev moves'
fi
if grep -Eq 'secrets\.' "$workflow"; then
  fail 'workflow exposes an unexpected secret reference'
fi

grep -Fq 'needs: [classify, functions, database]' "$workflow" || fail 'terminal result has unexpected lane dependencies'
grep -Fq 'apple:0:0|apple-backend:1:0|apple-backend:0:1|apple-backend:1:1' "$workflow" || fail 'Apple classifications are not accepted without paid PR CI'
grep -Fq 'git -C .candidate diff --check "$EVENT_BASE_SHA...$EVENT_HEAD"' "$workflow" || fail 'cheap exact-event diff check is missing'
grep -Fq 'Refusing changed, closed, or wrong-base pull request state.' "$workflow" || fail 'head and PR-state race guard is missing'

python3 - "$workflow" <<'PY'
import pathlib
import sys
import yaml

path = pathlib.Path(sys.argv[1])
text = path.read_text()
yaml.safe_load(text)
PY

printf 'UNDERBARK_PR_GATE_TESTS_OK\n'
