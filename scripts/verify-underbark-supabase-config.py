#!/usr/bin/env python3

import hashlib
import json
import pathlib
import sys
import tomllib


# The approved Supabase configuration semantics. Keep this a tuple: a config
# change lands as a two-digest transition window (old + new) so open PRs that
# do not touch the configuration keep passing, then the old digest is retired
# once the change merges to dev. Current window: dev after Underbark #443,
# plus Underbark #545's dormant continuity reconciliation endpoint.
#
# Verify every incoming digest the same way: recompute both digests from the
# two config.toml revisions, then diff the parsed configurations key by key
# rather than reading the text diff. The approval question is not "how many
# lines changed" but "what did the semantics gain, lose, or alter" — a
# reordering changes the text and not the digest, while a single flipped
# verify_jwt changes the digest and barely the text.
EXPECTED_SHA256S = (
    # Current dev after Underbark PR #443. Recomputed from origin/dev before
    # approval. The older pre-#443 digest is retired because #443 has merged.
    "b62d1e8c6d076e9d29ff7a77984a572f7355e0ceb225b3b645cc42d57ad91284",
    # Underbark PR #545 adds only [functions.continuity-reconcile] with
    # verify_jwt = false. The function remains release-disabled and dormant.
    # Its handler requires an exact scheduler secret before it makes any
    # database or Storage call. Recomputed from origin/dev and PR #545 before
    # approval: exactly one function key was added, zero were removed, zero
    # were changed, and no section outside [functions] changed. Approved by
    # the owner on 2026-09-02. Drop the preceding digest after #545 merges to
    # dev.
    "5f63e9f4c83233ae642699241ac9766dbd12e1c53cb98029b7613c88c314e600",
)


class VerificationError(Exception):
    pass


def canonical_bytes(text: str) -> bytes:
    try:
        semantic_config = tomllib.loads(text)
        canonical = json.dumps(
            semantic_config,
            sort_keys=True,
            separators=(",", ":"),
            allow_nan=False,
        )
    except (tomllib.TOMLDecodeError, TypeError, ValueError) as error:
        raise VerificationError(f"Invalid Supabase configuration: {error}") from error
    return canonical.encode("utf-8")


def verify(
    path: pathlib.Path,
    expected_digests: str | tuple[str, ...] = EXPECTED_SHA256S,
) -> None:
    if isinstance(expected_digests, str):
        expected_digests = (expected_digests,)
    try:
        text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as error:
        raise VerificationError(f"Unable to read Supabase configuration: {error}") from error

    actual_digest = hashlib.sha256(canonical_bytes(text)).hexdigest()
    if actual_digest not in expected_digests:
        raise VerificationError(
            "Supabase configuration semantics are not approved by the trusted gate. "
            f"Expected one of {', '.join(expected_digests)}, got {actual_digest}."
        )


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(f"usage: {argv[0]} <supabase-config.toml>", file=sys.stderr)
        return 2
    try:
        verify(pathlib.Path(argv[1]))
    except VerificationError as error:
        print(error, file=sys.stderr)
        return 1
    print("Trusted Supabase configuration semantics verified.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
