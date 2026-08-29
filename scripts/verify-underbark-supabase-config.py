#!/usr/bin/env python3

import hashlib
import json
import pathlib
import sys
import tomllib


# The approved Supabase configuration semantics. Keep this a tuple: a config
# change lands as a two-digest transition window (old + new) so open PRs that
# do not touch the configuration keep passing, then the old digest is retired
# once the change merges to dev. Current window: dev as it stands after
# Underbark #384, plus Underbark #443's authenticated claim-entitlement
# endpoint.
#
# Verify every incoming digest the same way: recompute both digests from the
# two config.toml revisions, then diff the parsed configurations key by key
# rather than reading the text diff. The approval question is not "how many
# lines changed" but "what did the semantics gain, lose, or alter" — a
# reordering changes the text and not the digest, while a single flipped
# verify_jwt changes the digest and barely the text.
EXPECTED_SHA256S = (
    # Current dev after Underbark PR #384 added [functions.analytics-consent],
    # [functions.analytics-contribute] and [functions.analytics-revoke], all
    # three verify_jwt = true. Recomputed from both config.toml revisions
    # before approval: exactly three keys added, zero removed, zero changed,
    # no section outside [functions] altered, and every addition tightens auth
    # on a new endpoint. Approved by the owner on 2026-08-27.
    #
    # This REPLACES the digest approved for #384 earlier the same day
    # (dad6cd0a…), which named [functions.analytics-grant] where this names
    # [functions.analytics-contribute]. #384 folded its second Supabase
    # project into the main one, which deleted the grant endpoint and moved
    # the contribute endpoint into this project; the block count is unchanged
    # at three and every one is still verify_jwt = true. The earlier digest is
    # retired rather than kept beside this one: it describes a shape that no
    # longer exists on any branch that will merge.
    #
    # That entry in turn replaced PR #336's research digest. #336 was the
    # research contribution server, a design that ADR-046 superseded and
    # withdrew; that branch will not merge.
    "e8fbde2f09013fce820ac8e2b55e31f95fe7e8d608471e62b2cfecc33cc04bf0",
    # Underbark PR #443 adds only [functions.claim-entitlement] with
    # verify_jwt = true. This keeps the endpoint behind authenticated Supabase
    # requests. Recomputed from both config.toml revisions before approval:
    # exactly one function key added, zero removed, zero changed, and no
    # section outside [functions] altered. Approved by the owner on
    # 2026-08-29. Drop the preceding digest after #443 merges to dev.
    "b62d1e8c6d076e9d29ff7a77984a572f7355e0ceb225b3b645cc42d57ad91284",
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
