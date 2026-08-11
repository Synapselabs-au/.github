#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
verifier="${script_dir}/verify-underbark-release-context.sh"
failures=0

expect_result() {
  expected="$1"
  description="$2"
  shift 2
  set +e
  "$verifier" "$@" >/dev/null 2>&1
  actual="$?"
  set -e
  if [[ "$actual" -ne "$expected" ]]; then
    echo "FAIL: ${description}: expected ${expected}, got ${actual}" >&2
    failures=$((failures + 1))
  fi
}

valid=(Bot Synapselabs-au/Underbark Synapselabs-au/Underbark dev 2026-08-12T00:00:00Z dev deadbeef)
expect_result 0 "valid release context" "${valid[@]}"
expect_result 1 "human author" User "${valid[@]:1}"
expect_result 1 "fork head" Bot attacker/fork "${valid[@]:2}"
expect_result 1 "wrong live base" "${valid[@]:0:3}" main "${valid[@]:4}"
expect_result 1 "unmerged marker" "${valid[@]:0:4}" "" "${valid[@]:5}"
expect_result 1 "wrong release base" "${valid[@]:0:5}" main "${valid[@]:6}"
expect_result 1 "missing merge SHA" "${valid[@]:0:6}" ""
expect_result 2 "wrong argument count" Bot

if [[ "$failures" -ne 0 ]]; then
  echo "${failures} release-context fixture(s) failed." >&2
  exit 1
fi

echo "All Underbark release-context fixtures passed."
