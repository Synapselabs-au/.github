#!/usr/bin/env python3

import hashlib
import json
import pathlib
import sys
import tomllib


# The approved Supabase configuration semantics. Keep this a tuple: a config
# change lands as a two-digest transition window (old + new) so open PRs that
# do not touch the configuration keep passing. Retire the old digest once the
# change merges to dev. The current approval is Underbark dev commit
# 79c3e3161952b9167395fbf5fcf0727ae0e4f641 after PR #885.
#
# Verify every incoming digest the same way: recompute it from config.toml,
# then diff the parsed configuration against the approved revision key by key
# rather than reading the text diff. The approval question is not "how many
# lines changed" but "what did the semantics gain, lose, or alter" — a
# reordering changes the text and not the digest, while a single flipped
# verify_jwt changes the digest and barely the text.
EXPECTED_SHA256S = (
    # Recomputed from Underbark dev commit
    # 79c3e3161952b9167395fbf5fcf0727ae0e4f641.
    # Compared with the last approved configuration at PR #545 merge commit
    # 5b82e7a76ff341dd5d5d5e59910980f4d6727cc3, the parsed TOML adds only:
    # [functions.push-attest] from PR #816 merge commit
    # 236d5e21524624d6ec2b45bccaa56681456f43e3,
    # [functions.apple-identity-notifications] from PR #878 merge commit
    # a2d575cfd3fdb8453074a425deeb60face04e767, and
    # [functions.sentry-routine-relay] from PR #885 merge commit
    # 879015db7d368ffdb154b3cfb02070c3a6736b18. Each addition has
    # verify_jwt = false. There are no removed or changed semantic keys and no
    # semantic changes outside [functions]. Comments and formatting are not
    # part of the canonical digest. The former PR #443 and PR #545 digests are
    # retired because both configurations have already merged to dev.
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
