#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -ne 7 ]]; then
  echo "usage: verify-underbark-release-context.sh <author-type> <head-repo> <repository> <live-base-ref> <merged-at> <release-base-ref> <release-merge-sha>" >&2
  exit 2
fi

author_type="$1"
head_repo="$2"
repository="$3"
live_base_ref="$4"
merged_at="$5"
release_base_ref="$6"
release_merge_sha="$7"

if [[ "$author_type" != "Bot" || "$head_repo" != "$repository" ]]; then
  echo "Ancestry syncs must be App-authored from the protected repository." >&2
  exit 1
fi

if [[ "$live_base_ref" != "dev" || -z "$merged_at" || "$release_base_ref" != "dev" || -z "$release_merge_sha" ]]; then
  echo "The release-in-flight marker must identify a merged release PR into dev." >&2
  exit 1
fi
