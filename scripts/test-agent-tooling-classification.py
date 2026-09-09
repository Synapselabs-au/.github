"""Regression tests for the exact Underbark agent-tooling admission paths.

Run with: python3 scripts/test-agent-tooling-classification.py
No GitHub access, credentials, Apple jobs or repository mutations are used.
"""
from pathlib import Path
import subprocess
import unittest

CLASSIFIER = Path(__file__).with_name('classify-underbark-pr.sh')
TOOLS = ('scripts/agent_git.py', 'scripts/tests/test_agent_git.py',
         'scripts/tests/test_swift_verification_routing.py')


def classify(*entries):
    payload = b''.join(status.encode() + b'\0' + path.encode() + b'\0'
                       for status, path in entries)
    result = subprocess.run(['bash', str(CLASSIFIER)], input=payload,
                            capture_output=True, timeout=5, check=True)
    return result.stdout.decode().strip()


class AgentToolingClassification(unittest.TestCase):
    def test_only_named_tool_files_are_static(self):
        for path in TOOLS:
            for status in ('A', 'M', 'D'):
                with self.subTest(path=path, status=status):
                    self.assertEqual(classify((status, path)), 'static\t0\t0')

    def test_workspace_pr_is_static(self):
        self.assertEqual(classify(*[('A', p) for p in TOOLS[:2]],
                                  ('A', 'docs/agent-work/PARALLEL_EXECUTION_HANDOFF_2026_09_09.md')),
                         'static\t0\t0')

    def test_workflow_pr_keeps_apple_classification(self):
        self.assertEqual(classify(('M', '.github/workflows/swift-verification.yml'),
                                  ('A', TOOLS[2])), 'apple\t0\t0')

    def test_tool_changes_do_not_hide_backend_scope(self):
        self.assertEqual(classify(('M', TOOLS[0]), ('M', 'supabase/functions/example/index.ts')),
                         'backend\t1\t0')
        self.assertEqual(classify(('M', TOOLS[0]), ('M', 'supabase/config.toml')),
                         'backend\t1\t1')

    def test_tool_changes_do_not_hide_mixed_apple_scope(self):
        self.assertEqual(classify(('M', TOOLS[1]), ('M', 'Recovr/App.swift'),
                                  ('M', 'supabase/migrations/example.sql')), 'apple-backend\t0\t1')

    def test_unrelated_scripts_and_similar_names_remain_blocked(self):
        for path in ('scripts/agent_git.py.bak', 'scripts/agent_git_extra.py',
                     'scripts/tests/test_agent_git_extra.py', 'scripts/new_tool.py',
                     '.github/workflows/new-runner.yml'):
            with self.subTest(path=path):
                self.assertEqual(classify(('M', TOOLS[0]), ('A', path)), 'blocked\t0\t0')

    def test_unsafe_paths_and_empty_diff_remain_blocked(self):
        self.assertEqual(classify(), 'blocked\t0\t0')
        for path in ('../scripts/agent_git.py', 'scripts/../scripts/agent_git.py',
                     '/scripts/agent_git.py', 'scripts/agent_git.py\n', 'scripts//agent_git.py'):
            with self.subTest(path=path):
                self.assertEqual(classify(('A', path)), 'blocked\t0\t0')

    def test_retired_workflows_stay_retired(self):
        self.assertEqual(classify(('A', '.github/workflows/ci.yml')), 'blocked\t0\t0')
        self.assertEqual(classify(('D', '.github/workflows/ci.yml')), 'static\t0\t0')


if __name__ == '__main__':
    unittest.main(verbosity=2)
