#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
verifier="${script_dir}/verify-underbark-ancestry-sync.sh"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

git -C "$scratch" init -q
git -C "$scratch" config user.name "Underbark Gate Test"
git -C "$scratch" config user.email "gate-test@invalid.example"

printf 'common\n' >"$scratch/common.txt"
git -C "$scratch" add common.txt
git -C "$scratch" commit -q -m "common history"
common="$(git -C "$scratch" rev-parse HEAD)"

printf 'release\n' >"$scratch/release.txt"
git -C "$scratch" add release.txt
git -C "$scratch" commit -q -m "release base"
base="$(git -C "$scratch" rev-parse HEAD)"
base_tree="$(git -C "$scratch" rev-parse "${base}^{tree}")"

git -C "$scratch" checkout -q --detach "$common"
printf 'main\n' >"$scratch/main.txt"
git -C "$scratch" add main.txt
git -C "$scratch" commit -q -m "main history"
main="$(git -C "$scratch" rev-parse HEAD)"

good="$(printf 'valid ancestry sync\n' | git -C "$scratch" commit-tree "$base_tree" -p "$base" -p "$main")"
reversed="$(printf 'reversed parents\n' | git -C "$scratch" commit-tree "$base_tree" -p "$main" -p "$base")"
one_parent="$(printf 'ordinary empty commit\n' | git -C "$scratch" commit-tree "$base_tree" -p "$base")"
three_parents="$(printf 'three parents\n' | git -C "$scratch" commit-tree "$base_tree" -p "$base" -p "$main" -p "$one_parent")"
changed_tree="$(git -C "$scratch" rev-parse "${main}^{tree}")"
changed="$(printf 'changed tree\n' | git -C "$scratch" commit-tree "$changed_tree" -p "$base" -p "$main")"
already_base="$(printf 'base already contains main\n' | git -C "$scratch" commit-tree "$base_tree" -p "$main")"
redundant="$(printf 'redundant ancestry sync\n' | git -C "$scratch" commit-tree "$base_tree" -p "$already_base" -p "$main")"
linear_main="$(printf 'main descends from base\n' | git -C "$scratch" commit-tree "$changed_tree" -p "$base")"
linear_sync="$(printf 'linear history disguised as sync\n' | git -C "$scratch" commit-tree "$base_tree" -p "$base" -p "$linear_main")"

expect_pass() {
  description="$1"
  shift
  if ! "$verifier" "$scratch" "$@"; then
    echo "FAIL: ${description}: expected success" >&2
    exit 1
  fi
}

expect_fail() {
  description="$1"
  shift
  if "$verifier" "$scratch" "$@" >/dev/null 2>&1; then
    echo "FAIL: ${description}: expected failure" >&2
    exit 1
  fi
}

expect_pass "exact tree-identical ancestry merge" "$base" "$good" "$main"
expect_fail "reversed parents" "$base" "$reversed" "$main"
expect_fail "ordinary empty commit" "$base" "$one_parent" "$main"
expect_fail "three-parent merge" "$base" "$three_parents" "$main"
expect_fail "changed tree" "$base" "$changed" "$main"
expect_fail "main already in base ancestry" "$already_base" "$redundant" "$main"
expect_fail "base already in main ancestry" "$base" "$linear_sync" "$linear_main"
expect_fail "unknown object" "$base" deadbeef "$main"

echo "All Underbark ancestry-sync fixtures passed."
