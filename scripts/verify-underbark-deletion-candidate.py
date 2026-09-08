#!/usr/bin/env python3
"""Validate a fixed captured-source fixture without executing candidate code."""
import datetime
import hashlib
import json
from pathlib import Path
import re
import sys

ROOT = Path('docs/release/candidates/issue-691-delete-account')
FILES = ('deno.json', 'delete-account/index.ts', 'delete-account/handler.ts',
         '_shared/auth.ts', '_shared/http.ts', '_shared/database.ts', '_shared/runtime.ts')
FIELDS = {'project', 'function', 'version', 'verify_jwt', 'ezbr_sha256',
          'observed_date', 'purpose', 'observed_file_sha256'}

def verify():
    paths = [ROOT / 'observed.json', ROOT / 'handler_test.ts'] + [ROOT / 'source' / name for name in FILES]
    for path in paths:
        if path.is_symlink() or any(parent.is_symlink() for parent in path.parents):
            raise ValueError('symlink in captured candidate path')
        if not path.is_file():
            raise ValueError('captured candidate closure is incomplete')
    manifest = json.loads((ROOT / 'observed.json').read_text())
    if not isinstance(manifest, dict) or set(manifest) != FIELDS:
        raise ValueError('unexpected observation fields')
    if (not isinstance(manifest['project'], str) or not re.fullmatch('[a-z]{20}', manifest['project']) or
            manifest['function'] != 'delete-account' or manifest['verify_jwt'] is not True or
            type(manifest['version']) is not int or manifest['version'] < 1 or
            not isinstance(manifest['purpose'], str) or not manifest['purpose']):
        raise ValueError('invalid observation metadata')
    datetime.date.fromisoformat(manifest['observed_date'])
    hashes = manifest['observed_file_sha256']
    if not isinstance(hashes, dict) or set(hashes) != set(FILES):
        raise ValueError('unexpected observed source file set')
    for value in [manifest['ezbr_sha256'], *hashes.values()]:
        if not isinstance(value, str) or not re.fullmatch('[0-9a-f]{64}', value):
            raise ValueError('invalid source fingerprint')
    for name in FILES:
        actual = hashlib.sha256((ROOT / 'source' / name).read_bytes()).hexdigest()
        if name != 'delete-account/handler.ts' and actual != hashes[name]:
            raise ValueError('a file outside the sole handler repair changed')
    # The handler's recorded hash describes the ORIGINAL deployment, not the
    # corrected candidate. Manifest claims are review evidence, not independent
    # proof of production provenance. CI never contacts production to verify them.
    print('Captured candidate layout, observation structure and unchanged files verified.')

if __name__ == '__main__':
    if len(sys.argv) != 1:
        raise SystemExit('This verifier accepts no arguments.')
    try:
        verify()
    except (ValueError, TypeError, OSError) as error:
        raise SystemExit(str(error)) from error
