#!/usr/bin/env python3

import hashlib
import json
import pathlib
import sys
import tomllib


# The approved Supabase configuration semantics. Keep this a tuple: a config
# change lands as a two-digest transition window (old + new) so open PRs that
# do not touch the configuration keep passing, then the old digest is retired
# once the change merges to dev. Current window: dev after Underbark #261,
# plus Underbark #317 (ADR-042 dormant continuity backup server).
#
# The #317 digest adds exactly four keys and removes or changes none:
#   functions.continuity-{status,upload,download,delete}.verify_jwt = true
# Verified by recomputing both digests from the two config.toml revisions
# before approval; every addition tightens auth on a new endpoint. Retire
# b2157fa0 once #317 merges to dev.
# ([functions.app-feedback], verify_jwt = false).
EXPECTED_SHA256S = (
    # Current dev.
    "fbc0abc43022192ce6291a5070dffa3f61a7d5855d5d6a19f2dae17a2c70e5f0",
    # Underbark PR #336: adds [functions.research-contribute] and
    # [functions.research-revoke], both verify_jwt = true. Approved by the owner
    # on 2026-08-25 after reviewing the nine-line diff. Drop this entry once #336
    # has merged and the entry above is no longer the incoming value.
    "eadbcb24de8495e51d4d39c56a55655ead4fbb62db736c16371855dd5692b07d",
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
