#!/usr/bin/env python3

import hashlib
import json
import pathlib
import sys
import tomllib


# The approved Supabase configuration semantics. Keep this a tuple so a future
# approved change can use a short transition window. Retire old digests after
# the matching configuration reaches dev so stale semantics fail closed.
#
# Verify every incoming digest the same way: recompute it from config.toml,
# then diff the parsed configuration against the approved revision key by key
# rather than reading the text diff. The approval question is not "how many
# lines changed" but "what did the semantics gain, lose, or alter" — a
# reordering changes the text and not the digest, while a single flipped
# verify_jwt changes the digest and barely the text.
EXPECTED_SHA256S = (
    # Current Underbark dev. Relative to the retired configuration, exactly
    # three function entries were added: push-attest,
    # apple-identity-notifications, and sentry-routine-relay. Each sets
    # verify_jwt = false because its handler performs the endpoint-specific
    # authentication required by its external caller. No function was removed,
    # no existing value changed, and no section outside [functions] changed.
    "ecabad5ba82e5f15ff56faa3e275d6c14ace9046fb7de63aaf8396ddf8006fc8",
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
