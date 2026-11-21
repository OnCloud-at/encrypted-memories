#!/usr/bin/env python3
"""Collect the changed files of a pull request and publish the storage evidence label (issue #1142).

The workflow `storage-evidence.yml` runs this script on `pull_request_target` from the base branch. It never
checks out, reads or executes pull request content: the only inputs are the names, the status and the git modes
that the GitHub API reports. The classifier (storage_path_policy.py) decides; this script reads the API, hands
the recorded answers to the classifier and writes one label and one comment.

What the pull request controls: file names, rename sources, statuses, file modes, the number of files and the
head commit. Names stay inert data. They never reach a comment or the log; the job summary lists the paths that
make a result UNKNOWN, each as a JSON string with markup characters escaped.

Writes (all through ALLOWED): add or remove the label `storage`, create that label when it is missing, create or
update one comment that carries MARKER and was written by the workflow bot. Nothing blocks a merge.
"""
import http.client
import importlib.util
import json
import os
import re
import sys
import urllib.error
import urllib.request
from pathlib import Path

# A script that runs with -I has no sibling modules on sys.path; load the classifier from the same directory.
_SPEC = importlib.util.spec_from_file_location('storage_path_policy', Path(__file__).with_name('storage_path_policy.py'))
policy = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(policy)

LABEL = 'storage'
LABEL_COLOR = 'd93f0b'
LABEL_DESCRIPTION = 'Changes storage paths: extra review evidence is needed'
MARKER = '<!-- storage-evidence -->'
BOT_LOGIN = 'github-actions[bot]'
PER_PAGE = 100
MAX_FILE_PAGES = 30
MAX_COMMENT_PAGES = 10
MAX_LABEL_PAGES = 10
TIMEOUT_SECONDS = 30
MAX_RESPONSE_BYTES = 16 * 1024 * 1024
SHA = '[0-9a-f]{40}'
ALLOWED = tuple(re.compile(pattern) for pattern in (
    r'GET pulls/[0-9]+',
    rf'GET compare/{SHA}\.\.\.{SHA}\?per_page=1',
    r'GET pulls/[0-9]+/files\?per_page=100&page=[0-9]+',
    rf'GET git/trees/{SHA}\?recursive=1',
    r'GET issues/[0-9]+/labels\?per_page=100&page=[0-9]+',
    rf'GET labels/{LABEL}',
    r'POST labels',
    r'POST issues/[0-9]+/labels',
    rf'DELETE issues/[0-9]+/labels/{LABEL}',
    r'GET issues/[0-9]+/comments\?per_page=100&page=[0-9]+',
    r'POST issues/[0-9]+/comments',
    r'PATCH issues/comments/[0-9]+',
))
ESCAPED_CHARACTERS = '`<>&@[]():'
READ_ERRORS = (ValueError, KeyError, TypeError, IndexError, AttributeError)


class ApiError(Exception):
    pass


class NoRedirect(urllib.request.HTTPRedirectHandler):
    """A redirect would carry the token to another place; treat it as an error."""

    def redirect_request(self, *args, **kwargs):
        return None


class HttpApi:
    def __init__(self, token, repo, base_url='https://api.github.com'):
        self.token = token
        self.repo = repo
        self.base_url = base_url
        self.opener = urllib.request.build_opener(NoRedirect)

    def request(self, method, path, body=None):
        """One request to this repository. Only the endpoints of ALLOWED leave the process."""
        if not any(pattern.fullmatch(f'{method} {path}') for pattern in ALLOWED):
            raise ValueError('The request is not allowed.')
        headers = {
            'Authorization': f'Bearer {self.token}', 'Accept': 'application/vnd.github+json',
            'X-GitHub-Api-Version': '2022-11-28', 'User-Agent': 'storage-evidence',
        }
        data = None
        if body is not None:
            data = json.dumps(body).encode()
            headers['Content-Type'] = 'application/json'
        request = urllib.request.Request(f'{self.base_url}/repos/{self.repo}/{path}', data=data, method=method, headers=headers)
        try:
            with self.opener.open(request, timeout=TIMEOUT_SECONDS) as response:
                raw = response.read(MAX_RESPONSE_BYTES + 1)
                incomplete = bool(getattr(response, 'length', None))
        except urllib.error.HTTPError as error:
            error.close()
            raise ApiError(f'HTTP {error.code} for {method} {path}') from None
        except (http.client.HTTPException, OSError):  # a URLError is an OSError
            raise ApiError(f'The request failed: {method} {path}') from None
        if len(raw) > MAX_RESPONSE_BYTES:
            raise ApiError(f'The answer is too large: {method} {path}')
        if incomplete:
            raise ApiError(f'The answer is incomplete: {method} {path}')
        try:
            return json.loads(raw) if raw else None
        except ValueError:
            raise ApiError(f'The answer is not valid JSON: {method} {path}') from None


def read_snapshot(api, number):
    pull = api.request('GET', f'pulls/{number}')
    return {'base': pull['base']['sha'], 'head': pull['head']['sha'], 'changed_files': pull['changed_files']}


def read_file_pages(api, number):
    """The file pages up to the cap. A longer list gives 3000 records, which the classifier refuses."""
    chunks = []
    for page in range(1, MAX_FILE_PAGES + 1):
        items = api.request('GET', f'pulls/{number}/files?per_page={PER_PAGE}&page={page}')
        if not isinstance(items, list):
            raise TypeError('The file list is not a list.')
        if not items:
            break
        chunks.append(items)
        if len(items) < PER_PAGE:
            break
    return [{'items': chunk, 'has_next': index < len(chunks) - 1} for index, chunk in enumerate(chunks)]


def record_of(raw):
    """Only the name, the status and the old name of a file record reach the classifier."""
    item = {'filename': raw.get('filename'), 'status': raw.get('status')}
    if 'previous_filename' in raw:
        item['previous_filename'] = raw['previous_filename']
    return item


def read_modes(api, sha):
    """Path to git mode of a tree, or None when the tree is truncated and so not trustworthy."""
    tree = api.request('GET', f'git/trees/{sha}?recursive=1')
    if tree['truncated'] is not False:
        return None
    return {entry['path']: entry['mode'] for entry in tree['tree']}


def collect(api, number):
    """The recorded input of the classifier. Any failed or malformed answer yields {'error': True}."""
    try:
        before = read_snapshot(api, number)
        merge_base = api.request('GET', f"compare/{before['base']}...{before['head']}?per_page=1")['merge_base_commit']['sha']
        pages = read_file_pages(api, number)
        records = []
        for page in pages:
            page['items'] = [record_of(raw) for raw in page['items']]
            records.extend(page['items'])
        names = [name for item in records for name in (item['filename'], item.get('previous_filename'))]
        if any(isinstance(name, str) and policy.needs_mode(name) for name in names):
            base_modes, head_modes = read_modes(api, merge_base), read_modes(api, before['head'])
        else:
            base_modes = head_modes = None
        for item in records:
            old_name = item.get('previous_filename') or item['filename']
            item['base_mode'] = None if base_modes is None else base_modes.get(old_name)
            item['head_mode'] = None if head_modes is None else head_modes.get(item['filename'])
        after = read_snapshot(api, number)
        before_write = read_snapshot(api, number)
    except (ApiError, *READ_ERRORS):
        return {'error': True}
    return {'error': False, 'before': before, 'after': after, 'before_write': before_write, 'pages': pages}


def wants_evidence(result):
    return result['status'] == 'MATCH' or (result['status'] == 'UNKNOWN' and result.get('protected_present') is True)


def render(result):
    """The comment text. It never names a file."""
    lines = [MARKER]
    if wants_evidence(result):
        lines += ['**Storage paths: evidence needed**', '', 'This pull request changes storage paths.']
        if result['status'] == 'UNKNOWN':
            lines += ['Other changed paths could not be classified; the job summary of the workflow run lists them.']
        lines += [
            '', 'Required evidence:', '',
            '1. **Mutation evidence:** weaken or remove each safety guard once, show the failing test, restore the code '
            'byte for byte, and list one row per guard in the pull request.',
            '2. An **independent review** of the storage change before it merges.',
            '3. The full local storage gates of "Local verification" in CONTRIBUTING.md.',
            '', 'This check only informs. It does not block the merge and it is not a required check.',
        ]
    elif result['status'] == 'CLEAN':
        lines += ['**Storage paths:** No storage path changed in this pull request.']
    else:
        lines += [
            '**Storage paths: undetermined**', '',
            'The storage classification of this pull request is undetermined for its current head. '
            'The label and an earlier comment may be out of date. The job summary of the workflow run has the details.',
        ]
    lines += ['', result['summary']]
    return '\n'.join(lines)


def escape_path(name):
    """A path as a JSON string, with every markup character written as a \\u escape."""
    text = json.dumps(name)
    for character in ESCAPED_CHARACTERS:
        text = text.replace(character, f'\\u{ord(character):04x}')
    return text


def summary_text(result):
    """The job summary: the comment text plus every unclassified path, escaped and bounded."""
    lines = [render(result)]
    count = result.get('unknown_count') or 0
    if count:
        noun = 'unclassified path' if count == 1 else 'unclassified paths'
        lines += ['', f'{count} {noun}:', '']
        lines += [f'- path `{escape_path(name)}`' for name in result['unknown_paths']]
        if count > len(result['unknown_paths']):
            lines += [f'- {count - len(result["unknown_paths"])} more']
    return '\n'.join(lines) + '\n'


def read_list(api, path):
    answer = api.request('GET', path)
    if not isinstance(answer, list):
        raise TypeError('The answer is not a list.')
    return answer


def read_labels(api, number):
    """The label names of the pull request, page by page up to the cap."""
    names = []
    for page in range(1, MAX_LABEL_PAGES + 1):
        entries = read_list(api, f'issues/{number}/labels?per_page={PER_PAGE}&page={page}')
        names.extend(entry['name'] for entry in entries)
        if len(entries) < PER_PAGE:
            break
    return names


def find_comment(api, number):
    for page in range(1, MAX_COMMENT_PAGES + 1):
        comments = read_list(api, f'issues/{number}/comments?per_page={PER_PAGE}&page={page}')
        for entry in comments:
            user = entry.get('user')
            if (isinstance(user, dict) and user.get('login') == BOT_LOGIN and user.get('type') == 'Bot'
                    and isinstance(entry.get('body'), str) and entry['body'].startswith(MARKER)):
                return entry
        if len(comments) < PER_PAGE:
            break
    return None


def ensure_label(api):
    try:
        api.request('GET', f'labels/{LABEL}')
    except ApiError:
        api.request('POST', 'labels', {'name': LABEL, 'color': LABEL_COLOR, 'description': LABEL_DESCRIPTION})


def publish(api, number, result):
    """Add the label for a protected path, remove it only for a CLEAN result, keep one comment up to date.

    UNKNOWN never removes the label and never creates a comment unless a protected path was established.
    """
    labels = read_labels(api, number)
    if result.get('protected_present') is True and LABEL not in labels:
        ensure_label(api)
        api.request('POST', f'issues/{number}/labels', {'labels': [LABEL]})
    if result['status'] == 'CLEAN' and LABEL in labels:
        api.request('DELETE', f'issues/{number}/labels/{LABEL}')
    existing = find_comment(api, number)
    body = render(result)
    if existing is None:
        if wants_evidence(result):
            api.request('POST', f'issues/{number}/comments', {'body': body})
    elif existing['body'] != body:
        api.request('PATCH', f"issues/comments/{int(existing['id'])}", {'body': body})


def main(environ, api=None, stdout=None):
    stdout = stdout or sys.stdout
    token = environ.get('GH_TOKEN', '')
    repository = environ.get('GITHUB_REPOSITORY', '')
    number = environ.get('PR_NUMBER', '')
    if not (token and re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repository) and re.fullmatch(r'[1-9][0-9]{0,8}', number)):
        print('::error::The token, the repository or the pull request number is missing or invalid.', file=stdout)
        return 1
    api = api or HttpApi(token, repository)
    data = collect(api, int(number))
    result = policy.classify(data)
    if environ.get('GITHUB_STEP_SUMMARY'):
        with open(environ['GITHUB_STEP_SUMMARY'], 'a', encoding='utf-8') as handle:
            handle.write(summary_text(result))
    if data['error']:
        # A failed or malformed API answer ends the job red. Nothing is written: the label stays as it is.
        print('::error::The GitHub API could not be read, so the storage classification is undetermined. Nothing was changed.',
              file=stdout)
        return 1
    if result['annotation']:
        print(result['annotation'], file=stdout)
    try:
        publish(api, int(number), result)
    except (ApiError, *READ_ERRORS):
        print('::error::The storage label or the comment could not be written.', file=stdout)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main(os.environ))
