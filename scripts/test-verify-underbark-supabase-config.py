#!/usr/bin/env python3

import hashlib
import importlib.util
import json
import pathlib
import sys
import tempfile
import unittest


sys.dont_write_bytecode = True


SCRIPT = pathlib.Path(__file__).with_name("verify-underbark-supabase-config.py")
SPEC = importlib.util.spec_from_file_location("underbark_config_verifier", SCRIPT)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError("Unable to load the Supabase config verifier.")
VERIFIER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VERIFIER)


BASE_CONFIG = """\
project_id = "underbark"

[db]
major_version = 17

[auth]
enabled = true

[functions.delete-account]
verify_jwt = true
"""

EXPECTED_CANONICAL = {
    "auth": {"enabled": True},
    "db": {"major_version": 17},
    "functions": {"delete-account": {"verify_jwt": True}},
    "project_id": "underbark",
}
EXPECTED_BYTES = json.dumps(
    EXPECTED_CANONICAL, sort_keys=True, separators=(",", ":")
).encode("utf-8")
EXPECTED_DIGEST = hashlib.sha256(EXPECTED_BYTES).hexdigest()


class SupabaseConfigVerifierTests(unittest.TestCase):
    def test_default_transition_window_matches_current_and_candidate_digests(
        self,
    ) -> None:
        self.assertEqual(
            VERIFIER.EXPECTED_SHA256S,
            (
                "b62d1e8c6d076e9d29ff7a77984a572f7355e0ceb225b3b645cc42d57ad91284",
                "5f63e9f4c83233ae642699241ac9766dbd12e1c53cb98029b7613c88c314e600",
            ),
        )

    def verify_text(self, text: str, expected_digest: str = EXPECTED_DIGEST) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory, "config.toml")
            path.write_text(text, encoding="utf-8")
            VERIFIER.verify(path, expected_digest)

    def assert_rejected(self, text: str) -> None:
        with self.assertRaises(VERIFIER.VerificationError):
            self.verify_text(text)

    def test_positive_config_matches_complete_canonical_object(self) -> None:
        self.verify_text(BASE_CONFIG)
        self.assertEqual(VERIFIER.canonical_bytes(BASE_CONFIG), EXPECTED_BYTES)

    def test_comments_and_formatting_do_not_change_semantics(self) -> None:
        self.verify_text(
            """\
# trusted comment
project_id = "underbark" # inline comment
[db]
major_version = 17
[auth] # another comment
enabled = true
[functions.delete-account]
verify_jwt = true
"""
        )

    def test_malformed_toml_is_rejected(self) -> None:
        self.assert_rejected(BASE_CONFIG + "\n[broken\n")

    def test_auth_semantic_change_is_rejected(self) -> None:
        self.assert_rejected(BASE_CONFIG.replace("enabled = true", "enabled = false"))

    def test_function_semantic_change_is_rejected(self) -> None:
        self.assert_rejected(BASE_CONFIG.replace("verify_jwt = true", "verify_jwt = false"))

    def test_database_semantic_change_is_rejected(self) -> None:
        self.assert_rejected(BASE_CONFIG.replace("major_version = 17", "major_version = 16"))

    def test_type_change_is_rejected(self) -> None:
        self.assert_rejected(BASE_CONFIG.replace("major_version = 17", 'major_version = "17"'))

    def test_missing_file_is_rejected(self) -> None:
        with self.assertRaises(VERIFIER.VerificationError):
            VERIFIER.verify(pathlib.Path("does-not-exist.toml"), EXPECTED_DIGEST)

    def test_any_digest_in_a_transition_window_is_accepted(self) -> None:
        self.verify_text_with_digests(BASE_CONFIG, ("0" * 64, EXPECTED_DIGEST))

    def test_a_config_outside_the_transition_window_is_rejected(self) -> None:
        with self.assertRaises(VERIFIER.VerificationError):
            self.verify_text_with_digests(BASE_CONFIG, ("0" * 64, "1" * 64))

    def verify_text_with_digests(
        self, text: str, digests: tuple[str, ...]
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory, "config.toml")
            path.write_text(text, encoding="utf-8")
            VERIFIER.verify(path, digests)


if __name__ == "__main__":
    unittest.main()
