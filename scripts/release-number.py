#!/usr/bin/env python3
"""Reserve release numbers in a dedicated Git branch, independently of releases."""
import argparse
import base64
from datetime import datetime
import json
import os
import re
import subprocess

BRANCH = 'release-state'
FILE = 'release-numbers.json'


class APIError(RuntimeError):
    pass


def github_api(repo, method, path, data=None):
    command = ['gh', 'api', '--method', method, f'repos/{repo}/{path}']
    if data is not None:
        command += ['--input', '-']
    result = subprocess.run(command, input=json.dumps(data) if data is not None else None,
                            text=True, capture_output=True)
    if result.returncode:
        raise APIError(result.stderr.strip())
    return json.loads(result.stdout) if result.stdout.strip() else None


def validate(state):
    if (state.get('schema') != 1 or type(state.get('last_build')) is not int
            or state['last_build'] < 81 or not isinstance(state.get('runs'), dict)):
        raise ValueError('Invalid release ledger; refusing to allocate a number')
    numbers = []
    for run, record in state['runs'].items():
        if not run.isdigit() or type(record.get('build')) is not int:
            raise ValueError('Invalid release reservation')
        number = record['build']
        if number < 82 or number > state['last_build']:
            raise ValueError('Reservation outside ledger bounds')
        if not re.fullmatch(rf'[0-9]{{4}}\.[0-9]{{1,2}}\.{number}', record.get('version', '')):
            raise ValueError('Invalid reserved version')
        numbers.append(number)
    if len(numbers) != len(set(numbers)):
        raise ValueError('Duplicate build numbers in release ledger')


def commit_state(api, state, parent=None, tree=None):
    entry = {'path': FILE, 'mode': '100644', 'type': 'blob',
             'content': json.dumps(state, indent=2, sort_keys=True) + '\n'}
    tree_body = {'tree': [entry]}
    if tree:
        tree_body['base_tree'] = tree
    new_tree = api('POST', 'git/trees', tree_body)['sha']
    return api('POST', 'git/commits', {
        'message': f"Reserve release numbering through build {state['last_build']}",
        'tree': new_tree, 'parents': [parent] if parent else [],
    })['sha']


def initialize(api, last_build):
    state = {'schema': 1, 'last_build': last_build, 'runs': {}}
    validate(state)
    commit = commit_state(api, state)
    # Creation fails if the branch already exists; never overwrite a ledger.
    api('POST', 'git/refs', {'ref': f'refs/heads/{BRANCH}', 'sha': commit})


def reserve(api, run_id, created_at):
    if not re.fullmatch(r'[0-9]+', run_id):
        raise ValueError('Invalid workflow run ID')
    date = datetime.fromisoformat(created_at.replace('Z', '+00:00'))
    for _ in range(5):
        try:
            parent = api('GET', f'git/ref/heads/{BRANCH}')['object']['sha']
        except APIError as error:
            raise APIError('Release ledger unavailable. Restore it or explicitly initialize it; '
                           'never infer a reset from deleted releases. ' + str(error)) from error
        commit = api('GET', f'git/commits/{parent}')
        contents = api('GET', f'contents/{FILE}?ref={parent}')
        state = json.loads(base64.b64decode(contents['content']))
        validate(state)
        if run_id in state['runs']:
            return state['runs'][run_id]
        number = state['last_build'] + 1
        record = {'build': number, 'version': f'{date.year}.{date.month}.{number}'}
        state['last_build'] = number
        state['runs'][run_id] = record
        new_commit = commit_state(api, state, parent, commit['tree']['sha'])
        try:
            # A competing reservation creates divergent history. A non-force
            # ref update rejects it; retry from the new head rather than reuse.
            api('PATCH', f'git/refs/heads/{BRANCH}', {'sha': new_commit, 'force': False})
            return record
        except APIError:
            if api('GET', f'git/ref/heads/{BRANCH}')['object']['sha'] == parent:
                raise  # Permissions/rules failure, not a competing reservation.
    raise APIError('Release ledger changed repeatedly; rerun the workflow')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', default=os.environ.get('GITHUB_REPOSITORY'))
    commands = parser.add_subparsers(dest='command', required=True)
    init = commands.add_parser('initialize')
    init.add_argument('--last-build', required=True, type=int)
    allocation = commands.add_parser('reserve')
    allocation.add_argument('--run-id', required=True)
    allocation.add_argument('--created-at', required=True)
    args = parser.parse_args()
    if not args.repo:
        parser.error('--repo or GITHUB_REPOSITORY is required')
    api = lambda method, path, data=None: github_api(args.repo, method, path, data)
    if args.command == 'initialize':
        initialize(api, args.last_build)
    else:
        print(json.dumps(reserve(api, args.run_id, args.created_at)))
