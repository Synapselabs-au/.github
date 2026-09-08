#!/usr/bin/env python3

import argparse
import json
import pathlib
import re
import subprocess
import sys
from typing import Any


SCRIPT_DIR = pathlib.Path(__file__).resolve().parent
DEFAULT_MANIFEST = SCRIPT_DIR / "agent-context-protected-paths.json"
DEFAULT_APPROVALS = SCRIPT_DIR / "agent-context-approvals.json"
SHA_PATTERN = re.compile(r"[0-9a-f]{40}")


class VerificationError(Exception):
    pass


def reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise VerificationError(f"Duplicate JSON key: {key}.")
        result[key] = value
    return result


def load_json(path: pathlib.Path, description: str) -> Any:
    try:
        with path.open("r", encoding="utf-8") as handle:
            return json.load(handle, object_pairs_hook=reject_duplicate_keys)
    except VerificationError:
        raise
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise VerificationError(f"Unable to read {description}: {error}") from error


def require_object_keys(
    value: Any,
    expected_keys: set[str],
    description: str,
) -> dict[str, Any]:
    if not isinstance(value, dict) or set(value) != expected_keys:
        raise VerificationError(
            f"{description} must contain exactly: {', '.join(sorted(expected_keys))}."
        )
    return value


def require_sorted_paths(value: Any, description: str) -> list[str]:
    if (
        not isinstance(value, list)
        or not value
        or not all(isinstance(path, str) and path for path in value)
    ):
        raise VerificationError(f"{description} must be a non-empty path list.")
    if value != sorted(set(value)):
        raise VerificationError(f"{description} must be sorted and contain no duplicates.")
    for path in value:
        candidate = pathlib.PurePosixPath(path)
        if (
            candidate.is_absolute()
            or candidate.as_posix() != path
            or path.endswith("/")
            or "//" in path
            or any(part in ("", ".", "..") for part in candidate.parts)
            or any(character in path for character in ("\0", "\n", "\r", "\t"))
        ):
            raise VerificationError(f"Invalid protected path: {path!r}.")
    return value


def load_manifest(path: pathlib.Path) -> dict[str, set[str]]:
    manifest = require_object_keys(
        load_json(path, "agent-context path manifest"),
        {"version", "repositories"},
        "Agent-context path manifest",
    )
    if (
        type(manifest["version"]) is not int
        or manifest["version"] != 1
        or not isinstance(manifest["repositories"], dict)
    ):
        raise VerificationError("Unsupported agent-context path manifest.")
    repositories: dict[str, set[str]] = {}
    for repository, value in manifest["repositories"].items():
        if not isinstance(repository, str) or not repository:
            raise VerificationError("The path manifest contains an invalid repository name.")
        entry = require_object_keys(
            value,
            {"protected_paths"},
            f"Manifest entry for {repository}",
        )
        repositories[repository] = set(
            require_sorted_paths(
                entry["protected_paths"],
                f"Protected paths for {repository}",
            )
        )
    if not repositories:
        raise VerificationError("The path manifest contains no repositories.")
    return repositories


def load_approvals(
    path: pathlib.Path,
    manifest: dict[str, set[str]],
) -> dict[tuple[str, str], list[str]]:
    register = require_object_keys(
        load_json(path, "agent-context approval register"),
        {"version", "approvals"},
        "Agent-context approval register",
    )
    if (
        type(register["version"]) is not int
        or register["version"] != 1
        or not isinstance(register["approvals"], list)
    ):
        raise VerificationError("Unsupported agent-context approval register.")
    approvals: dict[tuple[str, str], list[str]] = {}
    for index, value in enumerate(register["approvals"]):
        record = require_object_keys(
            value,
            {"head_sha", "protected_paths", "repository"},
            f"Approval record {index}",
        )
        repository = record["repository"]
        head_sha = record["head_sha"]
        if not isinstance(repository, str) or repository not in manifest:
            raise VerificationError(
                f"Approval record {index} names an unrecognized repository."
            )
        if not isinstance(head_sha, str) or SHA_PATTERN.fullmatch(head_sha) is None:
            raise VerificationError(
                f"Approval record {index} does not contain an exact 40-character head SHA."
            )
        protected_paths = require_sorted_paths(
            record["protected_paths"],
            f"Protected paths in approval record {index}",
        )
        if not set(protected_paths).issubset(manifest[repository]):
            raise VerificationError(
                f"Approval record {index} contains a path outside the trusted manifest."
            )
        key = (repository, head_sha)
        if key in approvals:
            raise VerificationError(
                f"Duplicate approval record for {repository} at {head_sha}."
            )
        approvals[key] = protected_paths
    return approvals


def run_git(repository: pathlib.Path, *arguments: str) -> bytes:
    try:
        result = subprocess.run(
            ["git", "-C", str(repository), *arguments],
            check=True,
            capture_output=True,
        )
    except (OSError, subprocess.CalledProcessError) as error:
        detail = ""
        if isinstance(error, subprocess.CalledProcessError):
            detail = error.stderr.decode("utf-8", errors="replace").strip()
        raise VerificationError(
            f"Unable to inspect the candidate Git repository{': ' + detail if detail else '.'}"
        ) from error
    return result.stdout


def verify_commit(repository: pathlib.Path, sha: str, description: str) -> None:
    if SHA_PATTERN.fullmatch(sha) is None:
        raise VerificationError(
            f"{description} must be an exact lowercase 40-character SHA."
        )
    resolved = run_git(repository, "rev-parse", "--verify", f"{sha}^{{commit}}")
    if resolved.decode("ascii", errors="strict").strip() != sha:
        raise VerificationError(f"{description} does not resolve to the exact commit.")


def changed_paths(
    repository: pathlib.Path,
    base_sha: str,
    head_sha: str,
) -> set[str]:
    raw = run_git(
        repository,
        "diff",
        "--name-status",
        "--no-renames",
        "-z",
        f"{base_sha}...{head_sha}",
        "--",
    )
    fields = raw.split(b"\0")
    if fields and fields[-1] == b"":
        fields.pop()
    if len(fields) % 2 != 0:
        raise VerificationError("The candidate diff contains a malformed status record.")
    paths: set[str] = set()
    for offset in range(0, len(fields), 2):
        try:
            status = fields[offset].decode("ascii")
            path = fields[offset + 1].decode("utf-8")
        except UnicodeDecodeError as error:
            raise VerificationError("The candidate diff contains an invalid path.") from error
        if status not in {"A", "C", "D", "M", "T", "U", "X", "B"}:
            raise VerificationError(f"The candidate diff contains invalid status {status!r}.")
        if not path:
            raise VerificationError("The candidate diff contains an empty path.")
        paths.add(path)
    return paths


def verify(
    repository_name: str,
    repository: pathlib.Path,
    base_sha: str,
    head_sha: str,
    manifest_path: pathlib.Path,
    approvals_path: pathlib.Path,
) -> list[str]:
    manifest = load_manifest(manifest_path)
    approvals = load_approvals(approvals_path, manifest)
    if repository_name not in manifest:
        raise VerificationError(f"Unrecognized repository: {repository_name}.")
    if not repository.is_dir():
        raise VerificationError("The candidate Git repository does not exist.")
    verify_commit(repository, base_sha, "Base SHA")
    verify_commit(repository, head_sha, "Head SHA")
    protected_paths = sorted(
        changed_paths(repository, base_sha, head_sha) & manifest[repository_name]
    )
    if not protected_paths:
        return []
    approved_paths = approvals.get((repository_name, head_sha))
    if approved_paths is None:
        raise VerificationError(
            "No trusted owner approval exists for this repository and exact head SHA."
        )
    if approved_paths != protected_paths:
        raise VerificationError(
            "The trusted owner approval does not match the complete protected-path set."
        )
    return protected_paths


def parse_arguments(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Verify exact-head owner approval for agent-context changes."
    )
    parser.add_argument("--repository", required=True)
    parser.add_argument("--repo-dir", required=True, type=pathlib.Path)
    parser.add_argument("--base-sha", required=True)
    parser.add_argument("--head-sha", required=True)
    parser.add_argument("--manifest", type=pathlib.Path, default=DEFAULT_MANIFEST)
    parser.add_argument("--approvals", type=pathlib.Path, default=DEFAULT_APPROVALS)
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    arguments = parse_arguments(argv)
    try:
        protected_paths = verify(
            arguments.repository,
            arguments.repo_dir,
            arguments.base_sha,
            arguments.head_sha,
            arguments.manifest,
            arguments.approvals,
        )
    except VerificationError as error:
        print(error, file=sys.stderr)
        return 1
    if protected_paths:
        print("Trusted owner approval matches the exact head and protected-path set.")
    else:
        print("No protected agent-context paths changed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
