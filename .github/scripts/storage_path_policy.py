#!/usr/bin/env python3
"""Classify recorded PR file pages without executing or reading PR source code.

The protected registry consists of all paths below the listed Sources modules. Paths
below Wiki/ or site/, and root README.md, are allowlisted. Swift files under the named
package test targets are neutral only alongside a protected path. Every other path is
unclassified. Matching is case-sensitive and never normalizes paths. Rename records
classify both names; a path repeated across records yields UNKNOWN. Unknown input or
any unclassified path yields UNKNOWN, even when another path matches. A complete,
well-formed UNKNOWN reports whether a protected path was also present, in its summary and in
protected_present (True or False; None whenever the input cannot be trusted). The result also
lists the paths that make it UNKNOWN (unknown_paths, at most UNKNOWN_PATH_LIMIT, and unknown_count);
unreadable input names no path. Allowlisted and
neutral paths require trusted regular-file mode evidence for every relevant side; absent
or symlink modes yield UNKNOWN.

The caller must obtain all pages and three independent PR snapshots from trusted code:
before listing, after listing, and immediately before any label operation. This module
does not access GitHub or write labels. The caller must surface its summary and annotation.
An unobserved A-to-B-to-A update remains indistinguishable from no update. These checks
cannot make a later label write atomic with a head or base update. Mode evidence must come
from the trusted base and head trees, not from the pull request's file-list records alone.
"""

import json
import re
import sys

SOURCE_ROOT = 'Packages/EncryptedMemoriesKit/Sources/'
PROTECTED_MODULES = (
    'AccountStateCore', 'AlbumSyncCore', 'AppleSecurityCore', 'DeviceRootAppleAdapter', 'MLSearchAppleAdapter',
    'MLSearchCore', 'MediaByteCache', 'MediaFeedCore', 'MediaLocationCore',
    'PhotoLibraryBackupAdapter', 'PhotosCore', 'ProtonAuth', 'ProtonDriveBackend', 'UploadCore',
)
PROTECTED_PREFIXES = tuple(f'{SOURCE_ROOT}{module}/' for module in PROTECTED_MODULES)
TEST_ROOT = 'Packages/EncryptedMemoriesKit/Tests/'
NEUTRAL_TEST_TARGETS = (
    'AccountStateCoreTests', 'AlbumSyncCoreTests', 'AppleSecurityCoreTests', 'DeviceRootAppleAdapterTests',
    'MLSearchAppleAdapterTests', 'MLSearchCoreTests', 'MediaByteCacheTests', 'MediaFeedCoreTests',
    'MediaLocationCoreTests', 'PhotosCoreTests', 'ProtonAuthTests', 'ProtonDriveBackendTests',
    'UploadFeatureTests', 'UpgradeFixtureTests',
)
NEUTRAL_TEST_PREFIXES = tuple(f'{TEST_ROOT}{target}/' for target in NEUTRAL_TEST_TARGETS)
SAFE_PREFIXES = ('Wiki/', 'site/')
SAFE_FILES = frozenset({'README.md'})
REGULAR_MODES = frozenset({'100644', '100755'})
SHA = re.compile(r'[0-9a-f]{40}\Z')
STATUSES = frozenset({'added', 'modified', 'removed', 'renamed'})
UNKNOWN_PATH_LIMIT = 50


def needs_mode(name):
    """True for the paths that are neutral or allowlisted and so need a verified regular-file mode."""
    return ((name.startswith(NEUTRAL_TEST_PREFIXES) and name.endswith('.swift'))
            or name.startswith(SAFE_PREFIXES) or name in SAFE_FILES)


def result(status, reason, revision=None, protected_present=None, unknown_paths=()):
    summary = f'Storage path classification: {status}. {reason}'
    if (isinstance(revision, dict) and isinstance(revision.get('base'), str)
            and SHA.fullmatch(revision['base']) is not None and isinstance(revision.get('head'), str)
            and SHA.fullmatch(revision['head']) is not None):
        summary += f" Before snapshot base {revision['base']} and head {revision['head']}."
    annotation = ('::warning title=Storage path classification::Unknown; see the summary.'
                  if status == 'UNKNOWN' else '')
    return {'status': status, 'summary': summary, 'annotation': annotation,
            'protected_present': protected_present, 'unknown_paths': list(unknown_paths)[:UNKNOWN_PATH_LIMIT],
            'unknown_count': len(unknown_paths)}


def valid_path(value):
    return (isinstance(value, str) and bool(value) and not value.startswith('/')
            and not any(ord(char) < 32 or 127 <= ord(char) <= 159 for char in value)
            and all(component not in ('', '.', '..') for component in value.split('/')))


def valid_snapshot(value):
    return (isinstance(value, dict) and isinstance(value.get('base'), str)
            and SHA.fullmatch(value['base']) is not None and isinstance(value.get('head'), str)
            and SHA.fullmatch(value['head']) is not None and type(value.get('changed_files')) is int
            and 0 < value['changed_files'] < 3000)


def classify(data):
    revision = data.get('before') if isinstance(data, dict) else None
    unknown = lambda reason, protected_present=None, paths=(): result('UNKNOWN', reason, revision, protected_present, paths)
    if not isinstance(data, dict) or data.get('error') is not False:
        return unknown('The API input is unavailable or invalid.')
    snapshots = [data.get(name) for name in ('before', 'after', 'before_write')]
    if not all(valid_snapshot(value) for value in snapshots):
        return unknown('A snapshot is invalid or the file limit was reached.')
    if any(value != snapshots[0] for value in snapshots[1:]):
        return unknown('The pull request changed while it was read.')
    pages = data.get('pages')
    if not isinstance(pages, list) or not pages:
        return unknown('The file list is incomplete.')
    records = []
    for index, page in enumerate(pages):
        if (not isinstance(page, dict) or type(page.get('has_next')) is not bool
                or page['has_next'] != (index < len(pages) - 1)
                or not isinstance(page.get('items'), list) or not page['items']):
            return unknown('The file list is incomplete.')
        records.extend(page['items'])
    if len(records) != snapshots[0]['changed_files']:
        return unknown('The file count does not match the pull request.')
    seen = set()
    matched = False
    neutral = False
    uncertainty = None
    unknown_paths = []
    neutral_paths = []
    for item in records:
        if not isinstance(item, dict) or not isinstance(item.get('status'), str) or item['status'] not in STATUSES:
            return unknown('A file record is invalid.')
        path = item.get('filename')
        if not valid_path(path) or path in seen:
            return unknown('A file path is invalid or repeated.')
        seen.add(path)
        status = item['status']
        paths = [(path, 'base'), (path, 'head')] if status == 'modified' else [
            (path, 'base' if status == 'removed' else 'head')
        ]
        if item['status'] == 'renamed':
            previous = item.get('previous_filename')
            if not valid_path(previous) or previous == path:
                return unknown('A rename is missing its previous path.')
            if previous in seen:
                return unknown('A file path is invalid or repeated.')
            seen.add(previous)
            paths.append((previous, 'base'))
        for name, side in paths:
            if name.startswith(PROTECTED_PREFIXES):
                matched = True
            elif needs_mode(name):
                mode = item.get(f'{side}_mode')
                if not isinstance(mode, str) or mode not in REGULAR_MODES:
                    uncertainty = 'An allowlisted or test path lacks a verified regular-file mode.'
                    if name not in unknown_paths:
                        unknown_paths.append(name)
                if name.startswith(NEUTRAL_TEST_PREFIXES) and name not in neutral_paths:
                    neutral_paths.append(name)
                neutral = neutral or name.startswith(NEUTRAL_TEST_PREFIXES)
                continue
            else:
                uncertainty = 'A changed path is not classified.'
                if name not in unknown_paths:
                    unknown_paths.append(name)
    if uncertainty:
        return unknown(uncertainty + (' A protected path was also present.' if matched else ''), matched, unknown_paths)
    if neutral and not matched:
        return unknown('A test path is not accompanied by a protected path.', False, neutral_paths)
    return (result('MATCH', 'Storage evidence is needed.', revision, True) if matched
            else result('CLEAN', 'Only allowlisted Wiki, site or root README.md paths changed.', revision, False))


def main():
    try:
        data = json.load(sys.stdin)
    except (ValueError, RecursionError):
        data = None
    print(json.dumps(classify(data)))


if __name__ == '__main__':
    main()
