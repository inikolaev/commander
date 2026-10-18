#!/usr/bin/env python3
"""Exercise notarization failures without credentials or Apple network access."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent


class NotarizationTests(unittest.TestCase):
    def run_notarization(self, mode):
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            mock = work / 'xcrun'
            mock.write_text('''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
root = Path(os.environ['MOCK_ROOT'])
a = sys.argv[1:]
with (root / 'calls').open('a') as log: log.write(json.dumps(a) + '\\n')
key = a[0] + '-' + a[1]
p = root / key
n = int(p.read_text()) + 1 if p.exists() else 1
p.write_text(str(n))
mode = os.environ['MOCK_MODE']
if a[:2] == ['notarytool', 'submit']:
    print('{"id":"submission-123"}')
elif a[:2] == ['notarytool', 'wait']:
    assert a[2] == 'submission-123'
    if mode == 'transient' and n == 1:
        print('NSURLErrorDomain Code=-1005: network connection was lost', file=sys.stderr)
        sys.exit(68)
    print(json.dumps({'status': 'Invalid' if mode == 'rejected' else 'Accepted'}))
elif a[0] == 'stapler':
    if mode == 'permanent' or (mode == 'invalid-ticket' and a[1] == 'validate'):
        print('The code signature is invalid', file=sys.stderr)
        sys.exit(65)
    if mode == 'exhausted' or (mode == 'validate-exhausted' and a[1] == 'validate') or (mode == 'transient' and n < 3):
        print('NSURLErrorDomain Code=-1005: network connection was lost')
        sys.exit(68)
''')
            mock.chmod(0o755)
            sleep = work / 'sleep'
            sleep.write_text('#!/bin/sh\nexit 0\n')
            sleep.chmod(0o755)
            env = dict(os.environ, PATH=f'{work}:{os.environ["PATH"]}',
                       MOCK_ROOT=str(work), MOCK_MODE=mode,
                       NOTARY_KEYCHAIN='mock-keychain', GITHUB_STEP_SUMMARY=str(work / 'summary'))
            result = subprocess.run(['bash', str(ROOT / 'scripts/notarize-artifact.sh'),
                                     'payload.zip', 'Commander.app'], env=env,
                                    capture_output=True, text=True)
            calls = [json.loads(line) for line in (work / 'calls').read_text().splitlines()]
            return result, calls, (work / 'summary').read_text()

    def test_success(self):
        result, calls, summary = self.run_notarization('success')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([call[:2] for call in calls], [
            ['notarytool', 'submit'], ['notarytool', 'wait'],
            ['stapler', 'staple'], ['stapler', 'validate']])
        self.assertIn('submission-123', summary)

    def test_transient_failures_reuse_submission_and_preserve_json(self):
        result, calls, _ = self.run_notarization('transient')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(sum(c[:2] == ['notarytool', 'submit'] for c in calls), 1)
        self.assertEqual(sum(c[:2] == ['notarytool', 'wait'] for c in calls), 2)
        self.assertEqual(sum(c[:2] == ['stapler', 'staple'] for c in calls), 3)
        self.assertEqual(sum(c[:2] == ['stapler', 'validate'] for c in calls), 3)

    def test_rejected_submission_never_staples(self):
        result, calls, _ = self.run_notarization('rejected')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(c[0] == 'stapler' for c in calls))
        self.assertEqual(sum(c[:2] == ['notarytool', 'wait'] for c in calls), 1)

    def test_permanent_failure_does_not_retry(self):
        result, calls, _ = self.run_notarization('permanent')
        self.assertEqual(result.returncode, 65)
        self.assertEqual(sum(c[0] == 'stapler' for c in calls), 1)

    def test_retry_exhaustion_fails_closed(self):
        result, calls, _ = self.run_notarization('exhausted')
        self.assertEqual(result.returncode, 68)
        self.assertEqual(sum(c[:2] == ['stapler', 'staple'] for c in calls), 3)
        self.assertFalse(any(c[:2] == ['stapler', 'validate'] for c in calls))

    def test_ticket_validation_exhaustion_blocks_release(self):
        result, calls, _ = self.run_notarization('validate-exhausted')
        self.assertEqual(result.returncode, 68)
        self.assertEqual(sum(c[:2] == ['stapler', 'validate'] for c in calls), 3)

    def test_invalid_ticket_is_not_retried(self):
        result, calls, _ = self.run_notarization('invalid-ticket')
        self.assertEqual(result.returncode, 65)
        self.assertEqual(sum(c[:2] == ['stapler', 'validate'] for c in calls), 1)


if __name__ == '__main__':
    unittest.main()
