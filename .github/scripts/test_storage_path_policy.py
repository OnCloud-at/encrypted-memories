import json
from pathlib import Path
import subprocess
import sys
import unittest

import storage_path_policy as policy

BASE = 'a' * 40
HEAD = 'b' * 40
STORAGE = 'Packages/EncryptedMemoriesKit/Sources/UploadCore/Backup/Queue.swift'
DOC = 'Wiki/Guide.md'
TEST = 'Packages/EncryptedMemoriesKit/Tests/UploadFeatureTests/QueueTests.swift'
EXPECTED_TEST_TARGETS = (
    'AccountStateCoreTests', 'AlbumSyncCoreTests', 'AppleSecurityCoreTests', 'DeviceRootAppleAdapterTests',
    'MLSearchAppleAdapterTests', 'MLSearchCoreTests', 'MediaByteCacheTests', 'MediaFeedCoreTests',
    'MediaLocationCoreTests', 'PhotosCoreTests', 'ProtonAuthTests', 'ProtonDriveBackendTests',
    'UploadFeatureTests', 'UpgradeFixtureTests',
)
EXPECTED_UNCLASSIFIED_MODULES = (
    'AlbumCore', 'AppRouteIntents', 'AlbumsFeature', 'DesignSystem', 'DesignSystemAppKitAdapter',
    'DesignSystemCore', 'DesignSystemUIKitAdapter', 'DeviceRootCore', 'GridCore',
    'LibraryRuntimeAppleAdapter', 'LibrarySourceRuntime', 'MLSearchBackgroundAppleAdapter',
    'MLSearchFeature', 'MapCore', 'MapFeature', 'MapUIKitAdapter', 'MediaCache',
    'MediaCacheAppKitAdapter', 'MediaCacheCore', 'MediaCacheUIKitAdapter', 'MediaDecodingCore',
    'MetalGridComposeCore', 'MetalGridTextureAppKitAdapter', 'MetalGridTextureCore',
    'MetalGridTextureUIKitAdapter', 'MetalRenderingCore', 'PhotoViewerCore', 'PhotoViewerFeature',
    'PhotoViewerUIKitAdapter', 'PrivacyFeature', 'TimelineCore', 'TimelineFeature',
    'TimelineAppleAdapter', 'TimelineUIKitAdapter', 'TimelineUIKitFeature', 'UploadFeature',
)
SOURCES_ROOT = Path(__file__).resolve().parents[2] / 'Packages' / 'EncryptedMemoriesKit' / 'Sources'


def snapshot(count=1, base=BASE, head=HEAD):
    return {'base': base, 'head': head, 'changed_files': count}


def item(path, status='modified', **extra):
    modes = {'base_mode': '100644', 'head_mode': '100644'}
    if status == 'added':
        modes['base_mode'] = None
    if status == 'removed':
        modes['head_mode'] = None
    return {'filename': path, 'status': status, **modes, **extra}


def page(items, has_next=False):
    return {'items': items, 'has_next': has_next}


def source_modules():
    return sorted(entry.name for entry in SOURCES_ROOT.iterdir() if entry.is_dir())


def new_source_modules(known, observed):
    return sorted(set(observed) - set(known))


class StoragePathPolicyTests(unittest.TestCase):
    def evaluate(self, pages, before=None, after=None, before_write=None, error=False):
        data = {'before': before or snapshot(), 'after': after or snapshot(),
                'before_write': before_write or snapshot(), 'pages': pages, 'error': error}
        return policy.classify(data)

    def test_complete_known_storage_change_is_match(self):
        self.assertEqual('MATCH', self.evaluate([page([item(STORAGE)])])['status'])

    def test_the_result_states_whether_a_protected_path_was_established(self):
        # True and False only for a complete, well-formed read; None when the input cannot be trusted.
        other = 'App/Views/Other.swift'
        matrix = [
            ('storage', [page([item(STORAGE)])], True),
            ('storage and an unclassified path', [page([item(STORAGE), item(other)])], True),
            ('storage and a path without a mode', [page([item(STORAGE), item(DOC, head_mode=None)])], True),
            ('only an unclassified path', [page([item(other)])], False),
            ('only a test path', [page([item(TEST)])], False),
            ('only documentation', [page([item(DOC)])], False),
        ]
        for label, pages, expected in matrix:
            with self.subTest(label):
                count = sum(len(entry['items']) for entry in pages)
                result = self.evaluate(pages, snapshot(count), snapshot(count), snapshot(count))
                self.assertIs(expected, result.get('protected_present'))
        for label, result in [
            ('an API error', self.evaluate([page([item(STORAGE)])], error=True)),
            ('a changed snapshot', self.evaluate([page([item(STORAGE)])], after=snapshot(head='c' * 40))),
            ('an incomplete file list', self.evaluate([page([item(STORAGE)], has_next=True)])),
            ('a hostile path after storage', self.evaluate([page([item(STORAGE), item('a/../b.swift')])])),
        ]:
            with self.subTest(label):
                self.assertEqual('UNKNOWN', result['status'])
                self.assertIsNone(result.get('protected_present'))
                self.assertIn('protected_present', result)

    def test_the_result_lists_every_path_that_makes_it_unknown(self):
        other = 'App/Views/Other.swift'
        second = 'scripts/tool.sh'
        base_item = item('Wiki/Old.md', 'renamed', previous_filename='docs/old.md')
        cases = [
            ('an unclassified path', [item(other)], [other]),
            ('two unclassified paths and storage', [item(STORAGE), item(other), item(second)], [other, second]),
            ('the unclassified old name of a rename', [base_item], ['docs/old.md']),
            ('an allowlisted path without a mode', [item(DOC, head_mode=None)], [DOC]),
            ('a test path without storage', [item(TEST)], [TEST]),
        ]
        for label, items, expected in cases:
            with self.subTest(label):
                result = self.evaluate([page(items)], snapshot(len(items)), snapshot(len(items)), snapshot(len(items)))
                self.assertEqual('UNKNOWN', result['status'])
                self.assertEqual(expected, result['unknown_paths'])
        for label, items in [('storage', [item(STORAGE)]), ('documentation', [item(DOC)])]:
            with self.subTest(label):
                self.assertEqual([], self.evaluate([page(items)])['unknown_paths'])
        # Unreadable input names no path: the reason carries the cause.
        self.assertEqual([], self.evaluate([page([item(STORAGE)])], error=True)['unknown_paths'])
        self.assertEqual([], self.evaluate([page([item(STORAGE), item('a/../b.swift')])],
                                           snapshot(2), snapshot(2), snapshot(2))['unknown_paths'])

    def test_a_path_is_listed_once_and_the_list_is_bounded(self):
        many = [item(f'scripts/tool{index}.sh') for index in range(120)]
        result = self.evaluate([page(many)], snapshot(120), snapshot(120), snapshot(120))
        self.assertEqual(policy.UNKNOWN_PATH_LIMIT, len(result['unknown_paths']))
        self.assertEqual('scripts/tool0.sh', result['unknown_paths'][0])
        self.assertEqual(120, result['unknown_count'])

    def test_needs_mode_names_the_paths_that_require_a_verified_mode(self):
        for name in ('Wiki/Guide.md', 'site/index.html', 'README.md', TEST):
            self.assertTrue(policy.needs_mode(name), name)
        for name in (STORAGE, 'App/Views/Other.swift', 'Wiki', 'README.md.bak',
                     'Packages/EncryptedMemoriesKit/Tests/UploadFeatureTests/Fixture.json'):
            self.assertFalse(policy.needs_mode(name), name)

    def test_allowlisted_wiki_site_and_readme_are_clean(self):
        self.assertEqual('CLEAN', self.evaluate([page([item(DOC)])])['status'])
        for path in ['site/index.html', 'README.md']:
            self.assertEqual('CLEAN', self.evaluate([page([item(path)])])['status'])

    def test_both_sides_of_a_rename_are_classified(self):
        for old, new in [(STORAGE, DOC), (DOC, STORAGE)]:
            with self.subTest(old=old, new=new):
                self.assertEqual('MATCH', self.evaluate([page([item(new, 'renamed', previous_filename=old)])])['status'])

    def test_renamed_file_without_old_path_is_unknown(self):
        self.assertEqual('UNKNOWN', self.evaluate([page([item(DOC, 'renamed')])])['status'])

    def test_unknown_overrides_a_known_match(self):
        changed = [item(STORAGE), item('App/NewStorageWriter.swift')]
        self.assertEqual('UNKNOWN', self.evaluate([page(changed)], snapshot(2), snapshot(2), snapshot(2))['status'])

    def test_storage_and_neutral_test_match_but_test_only_is_unknown(self):
        two = snapshot(2)
        self.assertEqual('MATCH', self.evaluate([page([item(STORAGE), item(TEST)])], two, two, two)['status'])
        self.assertEqual('UNKNOWN', self.evaluate([page([item(TEST)])])['status'])

    def test_neutral_rename_sides_and_adversarial_paths(self):
        for old, new in [(STORAGE, TEST), (TEST, STORAGE)]:
            with self.subTest(old=old, new=new):
                self.assertEqual('MATCH', self.evaluate([page([item(new, 'renamed', previous_filename=old)])])['status'])
        for old, new in [(DOC, TEST), (TEST, DOC)]:
            with self.subTest(old=old, new=new):
                self.assertEqual('UNKNOWN', self.evaluate([page([item(new, 'renamed', previous_filename=old)])])['status'])
        for path in ['Packages/EncryptedMemoriesKit/Tests/UploadFeatureTestsEvil/QueueTests.swift',
                     'Packages/EncryptedMemoriesKit/Tests/UnknownTests/QueueTests.swift',
                     'Packages/EncryptedMemoriesKit/Tests/UploadFeatureTests/QueueTests.SWIFT',
                     'Packages/EncryptedMemoriesKit/Tests/UploadFeatureTests/../bad.swift']:
            with self.subTest(path=path):
                two = snapshot(2)
                self.assertEqual('UNKNOWN', self.evaluate([page([item(STORAGE), item(path)])], two, two, two)['status'])

    def test_unknown_overrides_protected_and_neutral(self):
        three = snapshot(3)
        paths = [item(STORAGE), item(TEST), item('App/NewStorageWriter.swift')]
        self.assertEqual('UNKNOWN', self.evaluate([page(paths)], three, three, three)['status'])

    def test_unknown_summary_reports_a_verified_protected_path_in_either_order(self):
        two = snapshot(2)
        for paths in ([item(STORAGE), item('App/unknown.swift')], [item('App/unknown.swift'), item(STORAGE)]):
            with self.subTest(paths=paths):
                result = self.evaluate([page(paths)], two, two, two)
                self.assertEqual('UNKNOWN', result['status'])
                self.assertIn('A protected path was also present.', result['summary'])
                self.assertTrue(result['annotation'].startswith('::warning'))
                self.assertNotIn('label_action', result)

    def test_unknown_mode_summary_reports_protected_path_in_either_order(self):
        two = snapshot(2)
        missing_mode = item(DOC, head_mode=None)
        for paths in ([item(STORAGE), missing_mode], [missing_mode, item(STORAGE)]):
            with self.subTest(paths=paths):
                result = self.evaluate([page(paths)], two, two, two)
                self.assertEqual('UNKNOWN', result['status'])
                self.assertIn('A protected path was also present.', result['summary'])
                self.assertNotIn('label_action', result)

    def test_explicit_neutral_test_target_contract(self):
        two = snapshot(2)
        for target in EXPECTED_TEST_TARGETS:
            path = f'Packages/EncryptedMemoriesKit/Tests/{target}/nested/Case.swift'
            with self.subTest(target=target):
                self.assertEqual('MATCH', self.evaluate([page([item(STORAGE), item(path)])], two, two, two)['status'])
                self.assertEqual('UNKNOWN', self.evaluate([page([item(path)])])['status'])

    def test_unverified_or_symlink_mode_never_makes_safe_path_clean(self):
        for changes in [{'head_mode': None}, {'base_mode': None}, {'head_mode': '120000'},
                        {'base_mode': '120000'}, {'head_mode': []}]:
            with self.subTest(changes=changes):
                self.assertEqual('UNKNOWN', self.evaluate([page([item(DOC, **changes)])])['status'])
                two = snapshot(2)
                self.assertEqual('UNKNOWN', self.evaluate([page([item(STORAGE), item(TEST, **changes)])], two, two, two)['status'])

    def test_allowlisted_rename_requires_mode_for_the_relevant_side(self):
        for old, new, field in [(DOC, STORAGE, 'base_mode'), (STORAGE, DOC, 'head_mode')]:
            with self.subTest(old=old, new=new):
                change = item(new, 'renamed', previous_filename=old, **{field: '120000'})
                self.assertEqual('UNKNOWN', self.evaluate([page([change])])['status'])

    def test_regular_executable_mode_is_accepted(self):
        self.assertEqual('CLEAN', self.evaluate([page([item(DOC, base_mode='100755', head_mode='100755')])])['status'])

    def test_added_and_removed_allowlisted_paths_require_the_existing_side_mode(self):
        for status, missing in [('added', 'head_mode'), ('removed', 'base_mode')]:
            with self.subTest(status=status):
                self.assertEqual('CLEAN', self.evaluate([page([item(DOC, status)])])['status'])
                self.assertEqual('UNKNOWN', self.evaluate([page([item(DOC, status, **{missing: None})])])['status'])

    def test_invalid_revision_text_never_reaches_any_output(self):
        hostile = 'attacker::warning::injected\n' + 'x' * 40
        for slot in ('before', 'after', 'before_write'):
            for field in ('base', 'head'):
                with self.subTest(slot=slot, field=field):
                    data = {'before': snapshot(), 'after': snapshot(), 'before_write': snapshot(),
                            'pages': [page([item(STORAGE)])], 'error': False}
                    data[slot][field] = hostile
                    output = policy.classify(data)
                    self.assertEqual('UNKNOWN', output['status'])
                    self.assertNotIn(hostile, json.dumps(output))
                    self.assertNotIn('injected', json.dumps(output))

    def test_identical_invalid_revisions_are_unknown(self):
        for field in ('base', 'head'):
            invalid = snapshot(**{field: 'A' * 40})
            with self.subTest(field=field):
                self.assertEqual('UNKNOWN', self.evaluate([page([item(STORAGE)])], invalid, invalid, invalid)['status'])

    def test_stale_summary_identifies_before_snapshot(self):
        for slot in ('after', 'before_write'):
            with self.subTest(slot=slot):
                data = {'before': snapshot(), 'after': snapshot(), 'before_write': snapshot(),
                        'pages': [page([item(STORAGE)])], 'error': False}
                data[slot]['head'] = 'c' * 40
                result = policy.classify(data)
                self.assertEqual('UNKNOWN', result['status'])
                self.assertIn('Before snapshot', result['summary'])
                self.assertIn(HEAD, result['summary'])
                self.assertIn('changed', result['summary'])
                self.assertNotIn('c' * 40, result['summary'])

    def test_identical_observations_cannot_detect_unobserved_aba(self):
        # A -> B -> A between reads has the same supplied snapshots as no update.
        self.assertEqual('MATCH', self.evaluate([page([item(STORAGE)])])['status'])

    def test_control_boundaries_and_same_path_rename_are_unknown(self):
        for char in ('\x7f', '\x80', '\x9f'):
            with self.subTest(char=ord(char)):
                self.assertEqual('UNKNOWN', self.evaluate([page([item('Wiki/a' + char + 'b')])])['status'])
        self.assertEqual('UNKNOWN', self.evaluate([page([item(DOC, 'renamed', previous_filename=DOC)])])['status'])
        self.assertEqual('UNKNOWN', self.evaluate([dict(items=[item(DOC)], has_next=0)])['status'])

    def test_c0_boundaries_in_allowlisted_and_protected_paths(self):
        for prefix in ('Wiki/', 'Packages/EncryptedMemoriesKit/Sources/UploadCore/'):
            for char in ('\x00', '\x1f'):
                with self.subTest(prefix=prefix, code=ord(char)):
                    self.assertEqual('UNKNOWN', self.evaluate([page([item(prefix + 'a' + char + 'b')])])['status'])
            expected = 'CLEAN' if prefix == 'Wiki/' else 'MATCH'
            self.assertEqual(expected, self.evaluate([page([item(prefix + 'a b')])])['status'])

    def test_inconsistent_paths_across_renames_are_unknown_in_both_orders(self):
        source, first, second = 'Wiki/a.md', 'Wiki/b.md', 'Wiki/c.md'
        pairs = [
            [item(first, 'renamed', previous_filename=source), item(second, 'renamed', previous_filename=source)],
            [item(first, 'renamed', previous_filename=source), item(source, 'added')],
        ]
        two = snapshot(2)
        for pair in pairs:
            for ordered in (pair, list(reversed(pair))):
                with self.subTest(records=ordered):
                    self.assertEqual('UNKNOWN', self.evaluate([page([ordered[0]], True), page([ordered[1]])],
                                                               two, two, two)['status'])

    def test_page_completeness_and_count(self):
        first = page([item(DOC)], True)
        second = page([item(STORAGE)])
        two = snapshot(2)
        self.assertEqual('MATCH', self.evaluate([first, second], two, two, two)['status'])
        for pages in ([first], [page([item(DOC)]), second], [page([item(DOC)])]):
            with self.subTest(pages=pages):
                self.assertEqual('UNKNOWN', self.evaluate(pages, two, two, two)['status'])

    def test_errors_cap_and_stale_revisions_are_unknown(self):
        one = [page([item(STORAGE)])]
        self.assertEqual('UNKNOWN', self.evaluate(one, error=True)['status'])
        cap = snapshot(3000)
        self.assertEqual('UNKNOWN', self.evaluate(one, cap, cap, cap)['status'])
        stale = self.evaluate(one, after=snapshot(head='c' * 40))
        self.assertEqual('UNKNOWN', stale['status'])
        self.assertIn(BASE, stale['summary'])
        self.assertIn(HEAD, stale['summary'])
        self.assertEqual('UNKNOWN', self.evaluate(one, before_write=snapshot(base='d' * 40))['status'])

    def test_allowlisted_paths_at_api_cap_are_unknown_even_if_pages_appear_complete(self):
        count = 3000
        record = snapshot(count)
        pages = [page([item(f'Wiki/file-{i}.md') for i in range(count)])]
        self.assertEqual('UNKNOWN', self.evaluate(pages, record, record, record)['status'])

    def test_next_page_flag_with_matching_count_is_still_incomplete(self):
        self.assertEqual('UNKNOWN', self.evaluate([page([item(DOC)], True)])['status'])

    def test_malformed_unknown_and_hostile_paths_are_unknown(self):
        for path in ['wiki/Guide.md', 'Wiki/../bad', 'Wiki/evil\nname', 'App/$(touch x).swift',
                     'Packages/EncryptedMemoriesKit/Sources/NewCore/Writer.swift']:
            with self.subTest(path=path):
                result = self.evaluate([page([item(path)])])
                self.assertEqual('UNKNOWN', result['status'])
                self.assertIn('UNKNOWN', result['summary'])
                self.assertTrue(result['annotation'].startswith('::warning'))

    def test_duplicate_and_unrecognized_records_are_unknown(self):
        two = snapshot(2)
        self.assertEqual('UNKNOWN', self.evaluate([page([item(DOC), item(DOC)])], two, two, two)['status'])
        self.assertEqual('UNKNOWN', self.evaluate([page([item(DOC, 'mystery')])])['status'])

    def test_malformed_types_do_not_crash(self):
        for record in [None, {}, {'status': [], 'filename': DOC}, item(None), item(DOC, None)]:
            with self.subTest(record=record):
                try:
                    status = self.evaluate([page([record])])['status']
                except (TypeError, ValueError):
                    status = 'CRASH'
                self.assertEqual('UNKNOWN', status)

    def test_snapshot_and_page_shapes_are_validated(self):
        one = [page([item(DOC)])]
        for invalid in [None, {}, snapshot(count=True), snapshot(count=0), snapshot(head='A' * 40)]:
            with self.subTest(snapshot=invalid):
                data = {'before': invalid, 'after': snapshot(), 'before_write': snapshot(), 'pages': one, 'error': False}
                self.assertEqual('UNKNOWN', policy.classify(data)['status'])
        for pages in [None, [], [{}], [page([])], [dict(items=[item(DOC)], has_next=1)]]:
            with self.subTest(pages=pages):
                self.assertEqual('UNKNOWN', self.evaluate(pages)['status'])

    def test_removed_storage_and_added_allowlisted_path(self):
        self.assertEqual('MATCH', self.evaluate([page([item(STORAGE, 'removed')])])['status'])
        self.assertEqual('CLEAN', self.evaluate([page([item(DOC, 'added')])])['status'])

    def test_safe_paths_require_exact_case_and_component_boundary(self):
        for path in ['README.MD', 'WikiOther/Guide.md', 'sitewide/file.html', '/Wiki/Guide.md']:
            with self.subTest(path=path):
                self.assertEqual('UNKNOWN', self.evaluate([page([item(path)])])['status'])

    def test_explicit_storage_module_contract_and_unknown_module(self):
        for module in policy.PROTECTED_MODULES:
            with self.subTest(module=module):
                self.assertEqual('MATCH', self.evaluate([page([item('Packages/EncryptedMemoriesKit/Sources/' + module + '/File.swift')])])['status'])
        self.assertEqual('UNKNOWN', self.evaluate([page([item('Packages/EncryptedMemoriesKit/Sources/NewCore/File.swift')])])['status'])

    def test_the_keychain_source_and_its_test_are_a_match_without_noise(self):
        source = 'Packages/EncryptedMemoriesKit/Sources/AppleSecurityCore/AppleKeychainStore.swift'
        test = 'Packages/EncryptedMemoriesKit/Tests/AppleSecurityCoreTests/AppleKeychainStoreTests.swift'
        result = self.evaluate([page([item(source), item(test)])], snapshot(2), snapshot(2), snapshot(2))
        self.assertEqual(('MATCH', True, []), (result['status'], result['protected_present'], result['unknown_paths']))
        # A test alone is no storage change.
        self.assertEqual('UNKNOWN', self.evaluate([page([item(test)])])['status'])

    def test_the_keychain_module_is_a_storage_module(self):
        # AppleKeychainStore owns every SecItemAdd, SecItemUpdate and SecItemDelete call; the session lives there.
        path = 'Packages/EncryptedMemoriesKit/Sources/AppleSecurityCore/AppleKeychainStore.swift'
        result = self.evaluate([page([item(path)])])
        self.assertEqual(('MATCH', True), (result['status'], result['protected_present']))
        self.assertIn('AppleSecurityCore', policy.PROTECTED_MODULES)

    def test_explicit_unclassified_module_inventory_stays_unknown(self):
        for module in EXPECTED_UNCLASSIFIED_MODULES:
            with self.subTest(module=module):
                path = 'Packages/EncryptedMemoriesKit/Sources/' + module + '/IndirectWriter.swift'
                self.assertEqual('UNKNOWN', self.evaluate([page([item(path)])])['status'])

    def test_every_source_module_has_exactly_one_classification(self):
        # A new module needs a decision: add it to PROTECTED_MODULES in storage_path_policy.py when it holds a store
        # (database, journal, file store, keychain, deletion), otherwise to EXPECTED_UNCLASSIFIED_MODULES here.
        current = source_modules()
        self.assertTrue(current, 'The source directory is empty or missing; this test must see the modules')
        protected = set(policy.PROTECTED_MODULES)
        unclassified = set(EXPECTED_UNCLASSIFIED_MODULES)
        self.assertEqual(set(), protected & unclassified, 'A module is both protected and unclassified')
        self.assertEqual([], new_source_modules(protected | unclassified, current), 'New modules need an explicit classification')
        self.assertEqual([], new_source_modules(current, protected | unclassified), 'A listed module no longer exists')

    def test_inventory_surfaces_a_new_module(self):
        known = set(policy.PROTECTED_MODULES) | set(EXPECTED_UNCLASSIFIED_MODULES)
        self.assertEqual(['NewCore'], new_source_modules(known, sorted(known) + ['NewCore']))
        self.assertEqual('UNKNOWN', self.evaluate([page([item(
            'Packages/EncryptedMemoriesKit/Sources/NewCore/IndirectWriter.swift')])])['status'])

    def test_the_inventory_does_not_depend_on_the_working_directory(self):
        import os
        previous = os.getcwd()
        try:
            os.chdir('/')
            self.assertTrue(source_modules())
        finally:
            os.chdir(previous)

    def test_cli_unknown_is_visible_without_echoing_input(self):
        script = Path(__file__).with_name('storage_path_policy.py')
        payload = '{"credential":"synthetic-test-token", "broken":'
        proc = subprocess.run([sys.executable, '-I', str(script)], input=payload, capture_output=True, text=True,
                              timeout=10, check=True)
        result = json.loads(proc.stdout)
        self.assertEqual('UNKNOWN', result['status'])
        self.assertIn('UNKNOWN', result['summary'])
        self.assertTrue(result['annotation'].startswith('::warning'))
        self.assertNotIn('synthetic-test-token', proc.stdout + proc.stderr)

    def test_cli_does_not_echo_hostile_revisions(self):
        script = Path(__file__).with_name('storage_path_policy.py')
        hostile = 'attacker::warning::injected\n' + 'x' * 40
        for slot in ('before', 'after', 'before_write'):
            data = {'before': snapshot(), 'after': snapshot(), 'before_write': snapshot(),
                    'pages': [page([item(STORAGE)])], 'error': False}
            data[slot]['head'] = hostile
            with self.subTest(slot=slot):
                proc = subprocess.run([sys.executable, '-I', str(script)], input=json.dumps(data), capture_output=True,
                                      text=True, timeout=10, check=True)
                self.assertEqual('UNKNOWN', json.loads(proc.stdout)['status'])
                self.assertNotIn('injected', proc.stdout + proc.stderr)


if __name__ == '__main__':
    unittest.main()
