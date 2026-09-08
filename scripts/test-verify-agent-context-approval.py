#!/usr/bin/env python3

import json
import pathlib
import subprocess
import sys
import tempfile
import unittest


sys.dont_write_bytecode = True


SCRIPT_DIR = pathlib.Path(__file__).resolve().parent
VERIFIER = SCRIPT_DIR / "verify-agent-context-approval.py"
MANIFEST = SCRIPT_DIR / "agent-context-protected-paths.json"

APP_REPOSITORY = "Synapselabs-au/Underbark"
WEBSITE_REPOSITORY = "Synapselabs-au/Underbark-Web"
APP_PROTECTED_PATHS = [
    ".github/CODEOWNERS",
    ".github/repo-integrity-policy.json",
    ".github/workflows/repo-integrity-sentinel.yml",
    "AGENTS.md",
    "Config/XcodeCloudPolicy.json",
    "ci_scripts/ci_pre_xcodebuild.sh",
    "docs/ENGINEERING_POLICY.md",
    "docs/PRODUCT_WORKFLOW.md",
    "docs/RELEASING.md",
    "docs/TRUSTED_VERIFICATION.md",
    "docs/USER_FACING_COPY_POLICY.md",
    "docs/XCODE_CLOUD.md",
    "docs/privacy/USER_FACING_CLAIMS.md",
    "scripts/repo_integrity/__init__.py",
    "scripts/repo_integrity/core.py",
    "scripts/repo_integrity/deterministic.py",
    "scripts/repo_integrity/github_checks.py",
    "scripts/repo_integrity/issues.py",
    "scripts/repo_integrity/reporting.py",
    "scripts/repo_integrity/runner.py",
    "scripts/repo_integrity/semantic.py",
    "scripts/repo_integrity_audit.py",
    "scripts/tests/test_repo_integrity_audit.py",
    "scripts/verify-governance.sh",
]
WEBSITE_PROTECTED_PATHS = [
    "AGENTS.md",
    "docs/USER_FACING_CLAIM_HANDOFF.md",
    "docs/USER_FACING_COPY_POLICY.md",
]


def git(repository: pathlib.Path, *arguments: str) -> str:
    result = subprocess.run(
        ["git", "-C", str(repository), *arguments],
        check=True,
        text=True,
        capture_output=True,
    )
    return result.stdout.strip()


class CandidateRepository:
    def __init__(self, root: pathlib.Path) -> None:
        self.root = root
        root.mkdir(parents=True)
        git(root, "init", "-q")
        git(root, "config", "user.name", "Trusted Gate Test")
        git(root, "config", "user.email", "gate-test@invalid.example")
        self.write("README.md", "base\n")
        self.write("AGENTS.md", "base rules\n")
        self.write("docs/USER_FACING_COPY_POLICY.md", "base copy policy\n")
        self.write("docs/USER_FACING_CLAIM_HANDOFF.md", "base handoff\n")
        git(root, "add", ".")
        git(root, "commit", "-q", "-m", "base")
        self.base = git(root, "rev-parse", "HEAD")

    def write(self, path: str, contents: str) -> None:
        target = self.root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(contents, encoding="utf-8")

    def commit(self, message: str, changes: dict[str, str | None]) -> str:
        for path, contents in changes.items():
            target = self.root / path
            if contents is None:
                target.unlink()
            else:
                self.write(path, contents)
        git(self.root, "add", "-A")
        git(self.root, "commit", "-q", "-m", message)
        return git(self.root, "rev-parse", "HEAD")

    def commit_symlink(self, message: str, path: str, target: str) -> str:
        link = self.root / path
        link.unlink()
        link.symlink_to(target)
        git(self.root, "add", "-A")
        git(self.root, "commit", "-q", "-m", message)
        return git(self.root, "rev-parse", "HEAD")


class AgentContextApprovalTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary_directory.cleanup)
        self.scratch = pathlib.Path(self.temporary_directory.name)
        self.candidate = CandidateRepository(self.scratch / "candidate")
        self.manifest = self.scratch / "manifest.json"
        self.manifest.write_text(MANIFEST.read_text(encoding="utf-8"), encoding="utf-8")
        self.approvals = self.scratch / "approvals.json"
        self.write_approvals([])

    def write_manifest(self, manifest: dict[str, object]) -> None:
        self.manifest.write_text(
            json.dumps(manifest, indent=2) + "\n",
            encoding="utf-8",
        )

    def write_approvals(self, approvals: list[dict[str, object]]) -> None:
        self.approvals.write_text(
            json.dumps({"version": 1, "approvals": approvals}, indent=2) + "\n",
            encoding="utf-8",
        )

    def approval(
        self,
        repository: str,
        head_sha: str,
        protected_paths: list[str],
    ) -> dict[str, object]:
        return {
            "repository": repository,
            "head_sha": head_sha,
            "protected_paths": protected_paths,
        }

    def verify(
        self,
        repository: str,
        head_sha: str,
    ) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                sys.executable,
                str(VERIFIER),
                "--repository",
                repository,
                "--repo-dir",
                str(self.candidate.root),
                "--base-sha",
                self.candidate.base,
                "--head-sha",
                head_sha,
                "--manifest",
                str(self.manifest),
                "--approvals",
                str(self.approvals),
            ],
            text=True,
            capture_output=True,
        )

    def assert_accepted(self, repository: str, head_sha: str) -> None:
        result = self.verify(repository, head_sha)
        self.assertEqual(result.returncode, 0, result.stderr)

    def assert_rejected(self, repository: str, head_sha: str) -> None:
        result = self.verify(repository, head_sha)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertNotIn("Traceback", result.stderr)

    def test_manifest_matches_the_complete_approved_path_sets(self) -> None:
        manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
        self.assertEqual(
            manifest,
            {
                "version": 1,
                "repositories": {
                    APP_REPOSITORY: {"protected_paths": APP_PROTECTED_PATHS},
                    WEBSITE_REPOSITORY: {
                        "protected_paths": WEBSITE_PROTECTED_PATHS
                    },
                },
            },
        )

    def test_ordinary_product_change_needs_no_approval(self) -> None:
        head = self.candidate.commit("product", {"Recovr/App.swift": "product\n"})
        self.assert_accepted(APP_REPOSITORY, head)

    def test_unapproved_app_context_change_is_rejected(self) -> None:
        head = self.candidate.commit("rules", {"AGENTS.md": "changed rules\n"})
        self.assert_rejected(APP_REPOSITORY, head)

    def test_protected_file_addition_is_rejected_without_approval(self) -> None:
        head = self.candidate.commit(
            "add policy", {"docs/ENGINEERING_POLICY.md": "new policy\n"}
        )
        self.assert_rejected(APP_REPOSITORY, head)

    def test_protected_file_type_change_is_rejected_without_approval(self) -> None:
        head = self.candidate.commit_symlink("replace rules", "AGENTS.md", "README.md")
        self.assert_rejected(APP_REPOSITORY, head)

    def test_unapproved_website_context_change_is_rejected(self) -> None:
        head = self.candidate.commit(
            "copy rules",
            {"docs/USER_FACING_COPY_POLICY.md": "changed copy policy\n"},
        )
        self.assert_rejected(WEBSITE_REPOSITORY, head)

    def test_approved_exact_head_and_complete_sorted_path_set_is_accepted(self) -> None:
        head = self.candidate.commit(
            "approved rules",
            {
                "AGENTS.md": "changed rules\n",
                "docs/USER_FACING_COPY_POLICY.md": "changed copy policy\n",
            },
        )
        self.write_approvals(
            [
                self.approval(
                    APP_REPOSITORY,
                    head,
                    ["AGENTS.md", "docs/USER_FACING_COPY_POLICY.md"],
                )
            ]
        )
        self.assert_accepted(APP_REPOSITORY, head)

    def test_later_head_invalidates_approval(self) -> None:
        approved_head = self.candidate.commit(
            "approved rules", {"AGENTS.md": "changed rules\n"}
        )
        later_head = self.candidate.commit(
            "later product change", {"Recovr/App.swift": "later product\n"}
        )
        self.write_approvals(
            [self.approval(APP_REPOSITORY, approved_head, ["AGENTS.md"])]
        )
        self.assert_rejected(APP_REPOSITORY, later_head)

    def test_mismatched_protected_path_set_is_rejected(self) -> None:
        head = self.candidate.commit(
            "two rules",
            {
                "AGENTS.md": "changed rules\n",
                "docs/USER_FACING_COPY_POLICY.md": "changed copy policy\n",
            },
        )
        self.write_approvals(
            [self.approval(APP_REPOSITORY, head, ["AGENTS.md"])]
        )
        self.assert_rejected(APP_REPOSITORY, head)

    def test_protected_file_deletion_is_rejected_without_approval(self) -> None:
        head = self.candidate.commit("delete rules", {"AGENTS.md": None})
        self.assert_rejected(APP_REPOSITORY, head)

    def test_protected_file_deletion_is_accepted_for_the_exact_head(self) -> None:
        head = self.candidate.commit("delete rules", {"AGENTS.md": None})
        self.write_approvals(
            [self.approval(APP_REPOSITORY, head, ["AGENTS.md"])]
        )
        self.assert_accepted(APP_REPOSITORY, head)

    def test_malformed_approval_register_is_rejected(self) -> None:
        head = self.candidate.commit("product", {"Recovr/App.swift": "product\n"})
        self.approvals.write_text(
            '{"version":1,"version":1,"approvals":[]}\n', encoding="utf-8"
        )
        self.assert_rejected(APP_REPOSITORY, head)

    def test_boolean_manifest_version_is_rejected(self) -> None:
        head = self.candidate.commit("product", {"Recovr/App.swift": "product\n"})
        manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
        manifest["version"] = True
        self.write_manifest(manifest)
        self.assert_rejected(APP_REPOSITORY, head)

    def test_boolean_approval_register_version_is_rejected(self) -> None:
        head = self.candidate.commit("product", {"Recovr/App.swift": "product\n"})
        self.approvals.write_text(
            json.dumps({"version": True, "approvals": []}) + "\n",
            encoding="utf-8",
        )
        self.assert_rejected(APP_REPOSITORY, head)

    def test_noncanonical_manifest_path_is_rejected_before_diff_matching(self) -> None:
        head = self.candidate.commit("rules", {"AGENTS.md": "changed rules\n"})
        manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
        paths = manifest["repositories"][APP_REPOSITORY]["protected_paths"]
        paths.remove("AGENTS.md")
        paths.append("./AGENTS.md")
        paths.sort()
        self.write_manifest(manifest)
        result = self.verify(APP_REPOSITORY, head)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("Invalid protected path", result.stderr)
        self.assertNotIn("Traceback", result.stderr)

    def test_noncanonical_approval_path_is_rejected_as_malformed(self) -> None:
        head = self.candidate.commit("rules", {"AGENTS.md": "changed rules\n"})
        self.write_approvals(
            [self.approval(APP_REPOSITORY, head, ["./AGENTS.md"])]
        )
        result = self.verify(APP_REPOSITORY, head)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("Invalid protected path", result.stderr)
        self.assertNotIn("Traceback", result.stderr)

    def test_malformed_approval_records_are_rejected_cleanly(self) -> None:
        head = self.candidate.commit("rules", {"AGENTS.md": "changed rules\n"})
        malformed_records = [
            {
                "repository": [APP_REPOSITORY],
                "head_sha": head,
                "protected_paths": ["AGENTS.md"],
            },
            {
                "repository": APP_REPOSITORY,
                "head_sha": "f" * 39,
                "protected_paths": ["AGENTS.md"],
            },
            {
                "repository": APP_REPOSITORY,
                "head_sha": head,
                "protected_paths": ["README.md"],
            },
        ]
        for record in malformed_records:
            with self.subTest(record=record):
                self.write_approvals([record])
                self.assert_rejected(APP_REPOSITORY, head)

    def test_duplicate_approval_records_are_rejected(self) -> None:
        head = self.candidate.commit("rules", {"AGENTS.md": "changed rules\n"})
        record = self.approval(APP_REPOSITORY, head, ["AGENTS.md"])
        self.write_approvals([record, record])
        self.assert_rejected(APP_REPOSITORY, head)

    def test_unsorted_or_duplicate_approved_paths_are_rejected(self) -> None:
        head = self.candidate.commit(
            "two rules",
            {
                "AGENTS.md": "changed rules\n",
                "docs/USER_FACING_COPY_POLICY.md": "changed copy policy\n",
            },
        )
        for protected_paths in (
            ["docs/USER_FACING_COPY_POLICY.md", "AGENTS.md"],
            ["AGENTS.md", "AGENTS.md"],
        ):
            with self.subTest(protected_paths=protected_paths):
                self.write_approvals(
                    [self.approval(APP_REPOSITORY, head, protected_paths)]
                )
                self.assert_rejected(APP_REPOSITORY, head)

    def test_unrecognized_repository_is_rejected(self) -> None:
        head = self.candidate.commit("product", {"Recovr/App.swift": "product\n"})
        self.assert_rejected("Synapselabs-au/Unknown", head)

    def test_unknown_well_formed_head_sha_is_rejected(self) -> None:
        self.assert_rejected(APP_REPOSITORY, "f" * 40)


if __name__ == "__main__":
    unittest.main()
