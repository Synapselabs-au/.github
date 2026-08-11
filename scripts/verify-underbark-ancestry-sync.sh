#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 4 ]; then
  echo "Usage: $0 <repository> <base-sha> <head-sha> <main-sha>" >&2
  exit 2
fi

repository="$1"
base_sha="$2"
head_sha="$3"
main_sha="$4"

for commit in "$base_sha" "$head_sha" "$main_sha"; do
  git -C "$repository" cat-file -e "${commit}^{commit}"
done

recorded_head=""
first_parent=""
second_parent=""
extra_parent=""
read -r recorded_head first_parent second_parent extra_parent < <(
  git -C "$repository" rev-list --parents -n 1 "$head_sha"
)

if [ "$recorded_head" != "$head_sha" ] \
  || [ "$first_parent" != "$base_sha" ] \
  || [ "$second_parent" != "$main_sha" ] \
  || [ -n "${extra_parent:-}" ]; then
  echo "Ancestry sync must have the live base as first parent and current main as its only second parent." >&2
  exit 1
fi

if ! git -C "$repository" diff --quiet "$base_sha" "$head_sha"; then
  echo "Ancestry sync changed the release tree." >&2
  exit 1
fi

if git -C "$repository" merge-base --is-ancestor "$main_sha" "$base_sha"; then
  echo "Current main is already an ancestor of the live base." >&2
  exit 1
fi

if git -C "$repository" merge-base --is-ancestor "$base_sha" "$main_sha"; then
  echo "The live base is already an ancestor of current main; histories do not require an ancestry sync." >&2
  exit 1
fi

git -C "$repository" merge-base --is-ancestor "$main_sha" "$head_sha"
