#!/usr/bin/env python3
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

VERIFIER = Path(__file__).with_name('verify-underbark-deletion-candidate.py').resolve()
FILES = ('deno.json','delete-account/index.ts','delete-account/handler.ts',
         '_shared/auth.ts','_shared/http.ts','_shared/database.ts','_shared/runtime.ts')

class CandidateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='underbark-candidate-gate-')
        self.addCleanup(self.temp.cleanup)
        self.cwd = Path(self.temp.name)
        self.root = self.cwd / 'docs/release/candidates/issue-691-delete-account'
        for name in FILES:
            path=self.root/'source'/name
            path.parent.mkdir(parents=True,exist_ok=True)
            path.write_text('original fixture\n')
        self.manifest={'project':'a'*20,'function':'delete-account','version':6,'verify_jwt':True,
                       'ezbr_sha256':'a'*64,'observed_date':'2026-09-08','purpose':'synthetic gate fixture',
                       'observed_file_sha256':{name:hashlib.sha256((self.root/'source'/name).read_bytes()).hexdigest() for name in FILES}}
        (self.root/'source/delete-account/handler.ts').write_text('corrected fixture\n')
        (self.root/'handler_test.ts').write_text('import "./source/delete-account/handler.ts"\n')
        self.write_manifest()

    def write_manifest(self):
        (self.root/'observed.json').write_text(json.dumps(self.manifest))

    def run_check(self):
        return subprocess.run([sys.executable,str(VERIFIER)],cwd=self.cwd,capture_output=True,text=True,timeout=10).returncode

    def test_original_handler_hash_is_not_candidate_hash(self):
        self.assertEqual(self.run_check(),0)

    def test_unchanged_dependency_hash_mismatch(self):
        (self.root/'source/_shared/auth.ts').write_text('unexpected change')
        self.assertNotEqual(self.run_check(),0)

    def test_missing_test(self):
        (self.root/'handler_test.ts').unlink()
        self.assertNotEqual(self.run_check(),0)

    def test_missing_source(self):
        (self.root/'source/_shared/auth.ts').unlink()
        self.assertNotEqual(self.run_check(),0)

    def test_source_symlink(self):
        p=self.root/'source/_shared/auth.ts';p.unlink();p.symlink_to('/dev/null')
        self.assertNotEqual(self.run_check(),0)

    def test_parent_symlink(self):
        source=self.root/'source';source.rename(self.root/'other');source.symlink_to('other')
        self.assertNotEqual(self.run_check(),0)

    def test_invalid_manifest(self):
        (self.root/'observed.json').write_text('{')
        self.assertNotEqual(self.run_check(),0)

    def test_wrong_file_set(self):
        self.manifest['observed_file_sha256']['../other.ts']='b'*64;self.write_manifest()
        self.assertNotEqual(self.run_check(),0)

    def test_wrong_jwt_or_version(self):
        for field,value in [('verify_jwt',False),('version',True)]:
            original=self.manifest[field];self.manifest[field]=value;self.write_manifest()
            self.assertNotEqual(self.run_check(),0)
            self.manifest[field]=original

if __name__=='__main__': unittest.main()
