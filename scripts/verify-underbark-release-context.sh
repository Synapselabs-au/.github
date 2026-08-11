#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -ne 9 ]]; then
  echo "usage: verify-underbark-release-context.sh <author-login> <author-id> <author-type> <head-repo> <repository> <live-base-ref> <merged-at> <release-base-ref> <release-merge-sha>" >&2
  exit 2
fi

author_login="$1"
author_id="$2"
author_type="$3"
head_repo="$4"
repository="$5"
live_base_ref="$6"
merged_at="$7"
release_base_ref="$8"
release_merge_sha="$9"

if [[ "$author_login" != 'synapse-recovr-agents[bot]' \
  || "$author_id" != "312981088" \
  || "$author_type" != "Bot" \
  || "$head_repo" != "$repository" ]]; then
  echo "Ancestry syncs must be App-authored from the protected repository." >&2
  exit 1
fi

if [[ "$live_base_ref" != "dev" || -z "$merged_at" || "$release_base_ref" != "dev" || -z "$release_merge_sha" ]]; then
  echo "The release-in-flight marker must identify a merged release PR into dev." >&2
  exit 1
fi
