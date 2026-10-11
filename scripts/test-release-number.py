import base64
import importlib.util
import json
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('release_number', Path(__file__).with_name('release-number.py'))
number = importlib.util.module_from_spec(spec)
spec.loader.exec_module(number)


class Store:
    def __init__(self):
        self.head = None
        self.trees = {}
        self.commits = {}
        self.compete = False
        self.lose_response = False
        self.denied = False

    def __call__(self, method, path, data=None):
        if method == 'POST' and path == 'git/trees':
            key = f't{len(self.trees)}'
            self.trees[key] = data['tree'][0]['content']
            return {'sha': key}
        if method == 'POST' and path == 'git/commits':
            key = f'c{len(self.commits)}'
            self.commits[key] = data
            return {'sha': key}
        if method == 'POST' and path == 'git/refs':
            if self.head:
                raise number.APIError('already exists')
            self.head = data['sha']
            return {}
        if method == 'GET' and path == 'git/ref/heads/release-state':
            if not self.head:
                raise number.APIError('not found')
            return {'object': {'sha': self.head}}
        if method == 'GET' and path.startswith('git/commits/'):
            return {'tree': {'sha': self.commits[path.split('/')[-1]]['tree']}}
        if method == 'GET' and path.startswith('contents/'):
            commit = path.split('ref=')[1]
            return {'content': base64.b64encode(self.trees[self.commits[commit]['tree']].encode()).decode()}
        if method == 'PATCH':
            if self.denied:
                raise number.APIError('permission denied')
            if self.compete:
                self.compete = False
                number.reserve(self, '200', '2026-10-11T00:00:00Z')
            if data['force'] or self.commits[data['sha']]['parents'] != [self.head]:
                raise number.APIError('not fast forward')
            self.head = data['sha']
            if self.lose_response:
                self.lose_response = False
                raise number.APIError('connection lost after update')
            return {}
        raise AssertionError((method, path, data))


class NumberTests(unittest.TestCase):
    def setUp(self):
        self.api = Store()
        number.initialize(self.api, 81)

    def reserve(self, run='100', date='2026-10-11T00:00:00Z'):
        return number.reserve(self.api, run, date)

    def test_sequential_reservations_do_not_depend_on_tags_or_releases(self):
        self.assertEqual(self.reserve(), {'build': 82, 'version': '2026.10.82'})
        self.assertEqual(self.reserve('101', '2026-11-01T00:00:00Z'),
                         {'build': 83, 'version': '2026.11.83'})

    def test_retry_reuses_number_and_original_month(self):
        record = self.reserve()
        head = self.api.head
        self.assertEqual(self.reserve(date='2026-11-01T00:00:00Z'), record)
        self.assertEqual(self.api.head, head)

    def test_competing_reservation_retries_without_duplicate(self):
        self.api.compete = True
        self.assertEqual(self.reserve()['build'], 83)
        self.assertEqual(self.reserve('200')['build'], 82)

    def test_lost_success_response_does_not_allocate_twice(self):
        self.api.lose_response = True
        self.assertEqual(self.reserve()['build'], 82)
        self.assertEqual(self.reserve()['build'], 82)

    def test_missing_ledger_fails_closed(self):
        self.api.head = None
        with self.assertRaisesRegex(number.APIError, 'ledger unavailable'):
            self.reserve()

    def test_initialize_cannot_reset_existing_counter(self):
        self.reserve()
        with self.assertRaises(number.APIError):
            number.initialize(self.api, 81)
        self.assertEqual(self.reserve('101')['build'], 83)

    def test_permissions_failure_does_not_return_unreserved_number(self):
        self.api.denied = True
        with self.assertRaisesRegex(number.APIError, 'permission denied'):
            self.reserve()

    def test_corrupt_ledger_is_rejected(self):
        tree = self.api.commits[self.api.head]['tree']
        self.api.trees[tree] = '{"schema": 1, "last_build": 1, "runs": {}}'
        with self.assertRaises(ValueError):
            self.reserve()


if __name__ == '__main__':
    unittest.main()
