"""Tests for storage_evidence.py: the collector and publisher of the storage evidence label (#1142).

The workflow runs this script from the base branch with pull-request write access. The tests use a fake API
that records every request, so they show which endpoints the script uses and what it writes.
"""
import http.server
import io
import json
import os
import pathlib
import tempfile
import socket
import threading
import time
import unittest
import unittest.mock

import storage_evidence as evidence
import storage_path_policy as policy

BASE = 'a' * 40
HEAD = 'b' * 40
MERGE_BASE = 'c' * 40
OTHER = 'd' * 40
STORAGE = 'Packages/EncryptedMemoriesKit/Sources/UploadCore/Backup/Queue.swift'
README = 'README.md'
WIKI = 'Wiki/Guide.md'
UNCLASSIFIED = 'App/Views/Other.swift'
NUMBER = 7
SECRET = 'secret-token-value'
BOT = {'login': 'github-actions[bot]', 'type': 'Bot'}


class FakeApi:
    """Answers (method, relative path) from a route table and records every call."""

    def __init__(self, routes):
        self.routes = dict(routes)
        self.calls = []

    def request(self, method, path, body=None):
        self.calls.append((method, path, body))
        key = (method, path)
        if key not in self.routes and method != 'GET':
            return {}
        if key not in self.routes:
            raise evidence.ApiError(f'404 {method} {path}')
        value = self.routes[key]
        if isinstance(value, Exception):
            raise value
        if isinstance(value, list) and value and all(isinstance(item, tuple) for item in value):
            return value.pop(0)[0] if len(value) > 1 else value[0][0]
        return value

    def writes(self):
        return [call for call in self.calls if call[0] != 'GET']

    def paths(self, prefix):
        return [call[1] for call in self.calls if call[1].startswith(prefix)]


def pull(base=BASE, head=HEAD, files=1):
    return {'base': {'sha': base}, 'head': {'sha': head}, 'changed_files': files}


def record(name, status='modified', previous=None):
    item = {'filename': name, 'status': status, 'sha': 'e' * 40, 'additions': 3, 'deletions': 1}
    if previous:
        item['previous_filename'] = previous
    return item


def tree(entries, truncated=False):
    return {'truncated': truncated, 'tree': [{'path': path, 'mode': mode, 'type': 'blob'} for path, mode in entries.items()]}


def snapshots(*heads):
    """A sequence of pull responses; the last one repeats."""
    return [(pull(head=head),) for head in heads]


def paged(items, size=100):
    """Chunks of a list as the API pages it; a list that fills its last page ends with an empty page."""
    chunks = [list(items[start:start + size]) for start in range(0, len(items), size)] or [[]]
    if items and len(items) % size == 0:
        chunks.append([])
    return chunks


def scenario(files, base_modes=None, head_modes=None, labels=(), comments=(), label_exists=True):
    """Routes of a complete, consistent pull request. Modes default to regular files for every changed name."""
    names = [item['filename'] for item in files]
    routes = {
        ('GET', f'pulls/{NUMBER}'): pull(files=len(files)),
        ('GET', f'compare/{BASE}...{HEAD}?per_page=1'): {'merge_base_commit': {'sha': MERGE_BASE}},
        ('GET', f'git/trees/{MERGE_BASE}?recursive=1'): tree(base_modes if base_modes is not None else {
            (item.get('previous_filename') or item['filename']): '100644' for item in files}),
        ('GET', f'git/trees/{HEAD}?recursive=1'): tree(head_modes if head_modes is not None else {name: '100644' for name in names}),
        ('GET', f'labels/{evidence.LABEL}'): {'name': evidence.LABEL} if label_exists else evidence.ApiError('404'),
    }
    for index, chunk in enumerate(paged([{'name': name} for name in labels]), start=1):
        routes[('GET', f'issues/{NUMBER}/labels?per_page=100&page={index}')] = chunk
    for index, chunk in enumerate(paged(list(comments)), start=1):
        routes[('GET', f'issues/{NUMBER}/comments?per_page=100&page={index}')] = chunk
    pages = [files[start:start + 100] for start in range(0, len(files), 100)] or [[]]
    for index, chunk in enumerate(pages, start=1):
        routes[('GET', f'pulls/{NUMBER}/files?per_page=100&page={index}')] = chunk
    if len(files) and len(files) % 100 == 0:
        routes[('GET', f'pulls/{NUMBER}/files?per_page=100&page={len(pages) + 1}')] = []
    return routes


def result_of(status, protected, reason='Storage evidence is needed.'):
    return policy.result(status, reason, {'base': BASE, 'head': HEAD}, protected)


def comment(identifier, body, user=BOT):
    return {'id': identifier, 'user': user, 'body': body}


class CollectTests(unittest.TestCase):
    def collect(self, files, **kwargs):
        api = FakeApi(scenario(files, **kwargs))
        return api, evidence.collect(api, NUMBER)

    def test_the_input_of_the_classifier_comes_from_the_pull_request_and_the_trees(self):
        api, data = self.collect([record(STORAGE), record(README)])
        self.assertIs(False, data['error'])
        expected = {'base': BASE, 'head': HEAD, 'changed_files': 2}
        self.assertEqual([expected] * 3, [data['before'], data['after'], data['before_write']])
        self.assertEqual([{'items': [
            {'filename': STORAGE, 'status': 'modified', 'base_mode': '100644', 'head_mode': '100644'},
            {'filename': README, 'status': 'modified', 'base_mode': '100644', 'head_mode': '100644'},
        ], 'has_next': False}], data['pages'])
        self.assertEqual('MATCH', policy.classify(data)['status'])

    def test_the_pull_request_is_read_before_and_after_the_listing_and_last_before_the_classification(self):
        api, _ = self.collect([record(STORAGE)])
        order = [call[1] for call in api.calls]
        reads = [index for index, path in enumerate(order) if path == f'pulls/{NUMBER}']
        self.assertEqual(3, len(reads))
        self.assertEqual(0, reads[0])
        self.assertEqual(len(order) - 1, reads[2])
        self.assertLess(order.index(f'pulls/{NUMBER}/files?per_page=100&page=1'), reads[1])

    def test_modes_come_from_the_merge_base_tree_and_never_from_the_base_branch_tip(self):
        api, data = self.collect([record(README)], base_modes={README: '100755'})
        self.assertEqual(f'git/trees/{MERGE_BASE}?recursive=1' in api.paths('git/trees'), True)
        self.assertNotIn(f'git/trees/{BASE}?recursive=1', api.paths('git/trees'))
        item = data['pages'][0]['items'][0]
        self.assertEqual(('100755', '100644'), (item['base_mode'], item['head_mode']))

    def test_a_rename_reads_the_old_name_in_the_base_tree_and_the_new_name_in_the_head_tree(self):
        api, data = self.collect([record('Wiki/New.md', 'renamed', previous='Wiki/Old.md')],
                                 base_modes={'Wiki/Old.md': '100755'}, head_modes={'Wiki/New.md': '100644'})
        item = data['pages'][0]['items'][0]
        self.assertEqual(('Wiki/Old.md', '100755', '100644'), (item['previous_filename'], item['base_mode'], item['head_mode']))
        self.assertEqual('CLEAN', policy.classify(data)['status'])

    def test_a_missing_name_has_no_mode(self):
        _, data = self.collect([record(WIKI, 'added')], base_modes={}, head_modes={WIKI: '100644'})
        item = data['pages'][0]['items'][0]
        self.assertEqual((None, '100644'), (item['base_mode'], item['head_mode']))

    def test_no_tree_is_read_when_no_path_needs_a_mode(self):
        api, data = self.collect([record(STORAGE), record(UNCLASSIFIED)])
        self.assertEqual([], api.paths('git/trees'))
        self.assertEqual('UNKNOWN', policy.classify(data)['status'])

    def test_an_unreadable_tree_leaves_the_modes_unknown_and_never_clean(self):
        for label, routes in [
            ('truncated', {('GET', f'git/trees/{HEAD}?recursive=1'): tree({README: '100644'}, truncated=True)}),
            ('missing head tree', {('GET', f'git/trees/{HEAD}?recursive=1'): evidence.ApiError('404')}),
            ('missing base tree', {('GET', f'git/trees/{MERGE_BASE}?recursive=1'): evidence.ApiError('404')}),
        ]:
            with self.subTest(label):
                table = scenario([record(README), record(STORAGE)])
                table.update(routes)
                data = evidence.collect(FakeApi(table), NUMBER)
                verdict = policy.classify(data)
                self.assertEqual('UNKNOWN', verdict['status'])

    def test_a_symlink_or_a_submodule_mode_is_never_clean(self):
        for mode in ('120000', '160000', '040000'):
            with self.subTest(mode):
                _, data = self.collect([record(README)], head_modes={README: mode})
                self.assertEqual('UNKNOWN', policy.classify(data)['status'])

    def test_pagination_sets_the_next_page_flag_and_ignores_an_empty_extra_page(self):
        files = [record(f'Packages/EncryptedMemoriesKit/Sources/UploadCore/F{index}.swift') for index in range(250)]
        _, data = self.collect(files)
        self.assertEqual([100, 100, 50], [len(page['items']) for page in data['pages']])
        self.assertEqual([True, True, False], [page['has_next'] for page in data['pages']])
        self.assertEqual('MATCH', policy.classify(data)['status'])
        exact = files[:100]
        _, data = self.collect(exact)
        self.assertEqual([False], [page['has_next'] for page in data['pages']])
        self.assertEqual('MATCH', policy.classify(data)['status'])

    def test_the_file_cap_is_unknown_and_pages_stop_at_the_cap(self):
        files = [record(f'Packages/EncryptedMemoriesKit/Sources/UploadCore/F{index}.swift') for index in range(3000)]
        table = scenario(files)
        table.pop(('GET', f'pulls/{NUMBER}/files?per_page=100&page=31'), None)
        api = FakeApi(table)
        data = evidence.collect(api, NUMBER)
        self.assertEqual('UNKNOWN', policy.classify(data)['status'])
        self.assertEqual([], [path for path in api.paths('pulls/') if 'page=31' in path])

    def test_a_list_that_never_ends_is_unknown(self):
        files = [record(f'Packages/EncryptedMemoriesKit/Sources/UploadCore/F{index}.swift') for index in range(100)]
        table = scenario(files)
        table[('GET', f'pulls/{NUMBER}')] = pull(files=100)
        for page in range(2, 40):
            table[('GET', f'pulls/{NUMBER}/files?per_page=100&page={page}')] = files
        api = FakeApi(table)
        self.assertEqual('UNKNOWN', policy.classify(evidence.collect(api, NUMBER))['status'])
        self.assertLessEqual(len(api.paths(f'pulls/{NUMBER}/files')), 30)

    def test_every_failing_request_makes_the_input_unavailable(self):
        base = scenario([record(README), record(STORAGE)])
        for key in [key for key in base if key[1].startswith(('pulls/', 'compare/', 'git/trees/'))]:
            with self.subTest(key[1]):
                table = dict(base)
                table[key] = evidence.ApiError('boom')
                data = evidence.collect(FakeApi(table), NUMBER)
                self.assertIs(True, data['error'])
                self.assertEqual('UNKNOWN', policy.classify(data)['status'])

    def test_malformed_responses_make_the_input_unavailable(self):
        base = scenario([record(README)])
        for label, key, value in [
            ('pull without a base', ('GET', f'pulls/{NUMBER}'), {'head': {'sha': HEAD}, 'changed_files': 1}),
            ('pull with a text count', ('GET', f'pulls/{NUMBER}'), pull(files='1')),
            ('pull is a list', ('GET', f'pulls/{NUMBER}'), []),
            ('compare without a merge base', ('GET', f'compare/{BASE}...{HEAD}?per_page=1'), {}),
            ('files is an object', ('GET', f'pulls/{NUMBER}/files?per_page=100&page=1'), {}),
            ('a file without a name', ('GET', f'pulls/{NUMBER}/files?per_page=100&page=1'), [{'status': 'modified'}]),
            ('tree is a list', ('GET', f'git/trees/{HEAD}?recursive=1'), []),
            ('tree entry without a path', ('GET', f'git/trees/{HEAD}?recursive=1'), {'truncated': False, 'tree': [{'mode': '100644'}]}),
        ]:
            with self.subTest(label):
                table = dict(base)
                table[key] = value
                data = evidence.collect(FakeApi(table), NUMBER)
                self.assertEqual('UNKNOWN', policy.classify(data)['status'])

    def test_a_pull_request_that_changes_while_it_is_read_is_unknown(self):
        for position in range(3):
            with self.subTest(position):
                table = scenario([record(STORAGE)])
                heads = [HEAD, HEAD, HEAD]
                heads[position] = OTHER
                table[('GET', f'pulls/{NUMBER}')] = [(pull(head=head, files=1),) for head in heads]
                data = evidence.collect(FakeApi(table), NUMBER)
                self.assertEqual('UNKNOWN', policy.classify(data)['status'])


class RenderTests(unittest.TestCase):
    def test_a_match_lists_the_required_evidence(self):
        body = evidence.render(result_of('MATCH', True))
        self.assertTrue(body.startswith(evidence.MARKER))
        for text in ('Mutation evidence', 'independent review', 'Local verification', 'CONTRIBUTING.md', 'does not block'):
            self.assertIn(text, body)

    def test_unknown_with_a_protected_path_asks_for_the_evidence_and_names_the_gap(self):
        body = evidence.render(result_of('UNKNOWN', True, 'A changed path is not classified. A protected path was also present.'))
        self.assertIn('Mutation evidence', body)
        self.assertIn('not classified', body)

    def test_unknown_is_never_presented_as_clean(self):
        body = evidence.render(result_of('UNKNOWN', False, 'A changed path is not classified.'))
        self.assertIn('undetermined', body)
        self.assertNotIn('Mutation evidence', body)
        for word in ('no storage', 'clean', 'safe'):
            self.assertNotIn(word, body.lower())

    def test_clean_says_that_no_storage_path_changed(self):
        body = evidence.render(result_of('CLEAN', False, 'Only allowlisted Wiki, site or root README.md paths changed.'))
        self.assertTrue(body.startswith(evidence.MARKER))
        self.assertIn('No storage path changed', body)
        self.assertNotIn('Mutation evidence', body)


class PublishTests(unittest.TestCase):
    def publish(self, result, **kwargs):
        api = FakeApi(scenario([record(STORAGE)], **kwargs))
        evidence.publish(api, NUMBER, result)
        return api

    def test_a_match_adds_the_label_and_posts_the_evidence_once(self):
        result = result_of('MATCH', True)
        api = self.publish(result)
        self.assertEqual([
            ('POST', f'issues/{NUMBER}/labels', {'labels': [evidence.LABEL]}),
            ('POST', f'issues/{NUMBER}/comments', {'body': evidence.render(result)}),
        ], api.writes())

    def test_a_repeated_match_writes_nothing(self):
        result = result_of('MATCH', True)
        api = self.publish(result, labels=[evidence.LABEL, 'bug'], comments=[comment(11, evidence.render(result))])
        self.assertEqual([], api.writes())

    def test_a_changed_text_updates_the_comment_in_place(self):
        result = result_of('MATCH', True)
        api = self.publish(result, labels=[evidence.LABEL], comments=[comment(11, evidence.MARKER + '\nold')])
        self.assertEqual([('PATCH', 'issues/comments/11', {'body': evidence.render(result)})], api.writes())

    def test_a_missing_label_is_created_before_it_is_added(self):
        api = self.publish(result_of('MATCH', True), label_exists=False)
        methods = [(call[0], call[1]) for call in api.writes()]
        self.assertEqual(('POST', 'labels'), methods[0])
        self.assertEqual(('POST', f'issues/{NUMBER}/labels'), methods[1])
        created = api.writes()[0][2]
        self.assertEqual(evidence.LABEL, created['name'])
        self.assertTrue(created['color'] and created['description'])

    def test_only_a_comment_of_the_workflow_bot_with_the_marker_is_updated(self):
        result = result_of('MATCH', True)
        foreign = comment(21, evidence.MARKER + '\nfake', user={'login': 'someone', 'type': 'User'})
        spoof = comment(22, evidence.MARKER + '\nfake', user={'login': 'github-actions[bot]', 'type': 'User'})
        plain = comment(23, 'no marker here')
        api = self.publish(result, labels=[evidence.LABEL], comments=[foreign, spoof, plain])
        self.assertEqual([('POST', f'issues/{NUMBER}/comments', {'body': evidence.render(result)})], api.writes())

    def test_a_bot_with_another_login_is_ignored_even_with_the_marker(self):
        result = result_of('MATCH', True)
        other_bot = comment(24, evidence.MARKER + '\nfake', user={'login': 'other-bot[bot]', 'type': 'Bot'})
        api = self.publish(result, labels=[evidence.LABEL], comments=[other_bot])
        self.assertEqual([('POST', f'issues/{NUMBER}/comments', {'body': evidence.render(result)})], api.writes())

    def test_the_label_is_found_on_a_later_page_of_a_long_label_list(self):
        others = [f'label-{index}' for index in range(150)]
        labels = others[:120] + [evidence.LABEL] + others[120:]
        clean = result_of('CLEAN', False, 'Only allowlisted Wiki, site or root README.md paths changed.')
        api = self.publish(clean, labels=labels)
        self.assertEqual([('DELETE', f'issues/{NUMBER}/labels/{evidence.LABEL}', None)], api.writes())
        match = result_of('MATCH', True)
        api = self.publish(match, labels=labels, comments=[comment(11, evidence.render(match))])
        self.assertEqual([], api.writes())

    def test_label_pages_stop_at_the_cap(self):
        labels = [f'label-{index}' for index in range(100 * evidence.MAX_LABEL_PAGES + 50)]
        table = scenario([record(STORAGE)], labels=labels)
        api = FakeApi(table)
        evidence.publish(api, NUMBER, result_of('CLEAN', False, 'Only allowlisted Wiki, site or root README.md paths changed.'))
        self.assertEqual(evidence.MAX_LABEL_PAGES, len(api.paths(f'issues/{NUMBER}/labels?')))

    def test_a_comment_on_a_later_page_is_found_and_updated(self):
        result = result_of('MATCH', True)
        foreign = [comment(1000 + index, 'plain') for index in range(100)]
        api = self.publish(result, labels=[evidence.LABEL], comments=foreign + [comment(11, evidence.MARKER + '\nold')])
        self.assertEqual([('PATCH', 'issues/comments/11', {'body': evidence.render(result)})], api.writes())

    def test_comment_pages_stop_at_the_cap_and_a_later_comment_is_not_found(self):
        result = result_of('MATCH', True)
        foreign = [comment(1000 + index, 'plain') for index in range(100 * evidence.MAX_COMMENT_PAGES)]
        table = scenario([record(STORAGE)], labels=[evidence.LABEL], comments=foreign + [comment(11, evidence.MARKER + '\nold')])
        api = FakeApi(table)
        evidence.publish(api, NUMBER, result)
        self.assertEqual(evidence.MAX_COMMENT_PAGES, len(api.paths(f'issues/{NUMBER}/comments?')))
        self.assertEqual([('POST', f'issues/{NUMBER}/comments', {'body': evidence.render(result)})], api.writes())

    def test_clean_removes_only_the_storage_label_and_updates_an_existing_comment(self):
        result = result_of('CLEAN', False, 'Only allowlisted Wiki, site or root README.md paths changed.')
        api = self.publish(result, labels=[evidence.LABEL, 'bug'], comments=[comment(11, evidence.MARKER + '\nold')])
        self.assertEqual([
            ('DELETE', f'issues/{NUMBER}/labels/{evidence.LABEL}', None),
            ('PATCH', 'issues/comments/11', {'body': evidence.render(result)}),
        ], api.writes())

    def test_clean_without_label_or_comment_stays_silent(self):
        api = self.publish(result_of('CLEAN', False, 'Only allowlisted Wiki, site or root README.md paths changed.'), labels=['bug'])
        self.assertEqual([], api.writes())

    def test_unknown_without_a_protected_path_changes_no_label_and_posts_no_comment(self):
        for protected in (False, None):
            with self.subTest(protected):
                api = self.publish(result_of('UNKNOWN', protected, 'A changed path is not classified.'), labels=[evidence.LABEL])
                self.assertEqual([], api.writes())

    def test_unknown_updates_an_old_evidence_comment_to_undetermined(self):
        result = result_of('UNKNOWN', None, 'The pull request changed while it was read.')
        api = self.publish(result, labels=[evidence.LABEL], comments=[comment(11, evidence.MARKER + '\nold')])
        self.assertEqual([('PATCH', 'issues/comments/11', {'body': evidence.render(result)})], api.writes())

    def test_unknown_with_a_protected_path_adds_the_label_and_the_evidence(self):
        result = result_of('UNKNOWN', True, 'A changed path is not classified. A protected path was also present.')
        api = self.publish(result)
        self.assertEqual(['issues/%d/labels' % NUMBER, 'issues/%d/comments' % NUMBER], [call[1] for call in api.writes()])

    def test_a_failing_write_is_an_error(self):
        table = scenario([record(STORAGE)])
        table[('POST', f'issues/{NUMBER}/labels')] = evidence.ApiError('403')
        with self.assertRaises(evidence.ApiError):
            evidence.publish(FakeApi(table), NUMBER, result_of('MATCH', True))


class EndToEndTests(unittest.TestCase):
    def run_main(self, files, environ=None, **kwargs):
        api = FakeApi(scenario(files, **kwargs))
        with tempfile.TemporaryDirectory() as directory:
            summary = os.path.join(directory, 'summary.md')
            env = {'GH_TOKEN': SECRET, 'GITHUB_REPOSITORY': 'o/r', 'PR_NUMBER': str(NUMBER), 'GITHUB_STEP_SUMMARY': summary}
            env.update(environ or {})
            out = io.StringIO()
            code = evidence.main(env, api=api, stdout=out)
            text = pathlib.Path(summary).read_text() if os.path.exists(summary) else ''
        return api, code, out.getvalue(), text

    def test_a_storage_change_is_labelled_and_the_summary_shows_the_evidence(self):
        api, code, out, summary = self.run_main([record(STORAGE)])
        self.assertEqual(0, code)
        self.assertIn(('POST', f'issues/{NUMBER}/labels', {'labels': [evidence.LABEL]}), api.writes())
        self.assertIn('Mutation evidence', summary)
        self.assertNotIn('::warning', out)
        self.assertNotIn('::notice', out)

    def test_an_undetermined_change_leaves_a_visible_notice_and_writes_nothing(self):
        api, code, out, summary = self.run_main([record(UNCLASSIFIED)])
        self.assertEqual(0, code)
        self.assertEqual([], api.writes())
        self.assertIn('::notice title=Storage path classification::Unknown; see the summary.', out)
        self.assertNotIn('::warning', out)
        self.assertNotIn('::error', out)
        self.assertIn('undetermined', summary)

    def run_with_summary(self, table):
        api = FakeApi(table)
        with tempfile.TemporaryDirectory() as directory:
            summary_path = os.path.join(directory, 'summary.md')
            out = io.StringIO()
            code = evidence.main({'GH_TOKEN': SECRET, 'GITHUB_REPOSITORY': 'o/r', 'PR_NUMBER': str(NUMBER),
                                  'GITHUB_STEP_SUMMARY': summary_path}, api=api, stdout=out)
            summary = pathlib.Path(summary_path).read_text() if os.path.exists(summary_path) else ''
        return api, code, out.getvalue(), summary

    def test_an_api_failure_ends_the_job_red_after_the_summary_and_writes_nothing(self):
        for label, key in [('files', ('GET', f'pulls/{NUMBER}/files?per_page=100&page=1')), ('pull request', ('GET', f'pulls/{NUMBER}')),
                           ('merge base', ('GET', f'compare/{BASE}...{HEAD}?per_page=1'))]:
            with self.subTest(label):
                table = scenario([record(STORAGE)], labels=[evidence.LABEL])
                table[key] = evidence.ApiError('boom')
                api, code, out, summary = self.run_with_summary(table)
                self.assertEqual(1, code)
                self.assertIn('::error::', out)
                self.assertNotIn(SECRET, out)
                self.assertEqual([], api.writes())
                self.assertIn('undetermined', summary)
                self.assertIn('unavailable', summary)

    def test_an_unreachable_api_ends_the_job_red_with_a_summary_and_no_traceback(self):
        with socket.socket() as probe:
            probe.bind(('127.0.0.1', 0))
            port = probe.getsockname()[1]
        api = evidence.HttpApi(SECRET, 'o/r', base_url=f'http://127.0.0.1:{port}')
        with tempfile.TemporaryDirectory() as directory:
            summary_path = os.path.join(directory, 'summary.md')
            out = io.StringIO()
            code = evidence.main({'GH_TOKEN': SECRET, 'GITHUB_REPOSITORY': 'o/r', 'PR_NUMBER': str(NUMBER),
                                  'GITHUB_STEP_SUMMARY': summary_path}, api=api, stdout=out)
            summary = pathlib.Path(summary_path).read_text()
        self.assertEqual(1, code)
        self.assertIn('::error::', out.getvalue())
        self.assertNotIn('Traceback', out.getvalue() + summary)
        self.assertNotIn(SECRET, out.getvalue() + summary)
        self.assertIn('undetermined', summary)

    def test_a_malformed_answer_is_an_api_failure_and_not_a_traceback(self):
        probes = [
            ('a file entry that is a text', ('GET', f'pulls/{NUMBER}/files?per_page=100&page=1'), ['x']),
            ('a file entry that is a number', ('GET', f'pulls/{NUMBER}/files?per_page=100&page=1'), [5]),
            ('a pull request that is a text', ('GET', f'pulls/{NUMBER}'), 'x'),
            ('a tree entry that is a text', ('GET', f'git/trees/{HEAD}?recursive=1'), {'truncated': False, 'tree': ['x']}),
        ]
        for label, key, value in probes:
            with self.subTest(label):
                table = scenario([record(README)])
                table[key] = value
                api, code, out, summary = self.run_with_summary(table)
                self.assertEqual(1, code)
                self.assertEqual([], api.writes())
                self.assertNotIn('Traceback', out + summary)

    def test_a_malformed_label_or_comment_list_fails_the_job_without_a_traceback(self):
        for label, key, value in [
            ('labels', ('GET', f'issues/{NUMBER}/labels?per_page=100&page=1'), ['x']),
            ('comments', ('GET', f'issues/{NUMBER}/comments?per_page=100&page=1'), ['x']),
            ('labels as an object', ('GET', f'issues/{NUMBER}/labels?per_page=100&page=1'), {}),
        ]:
            with self.subTest(label):
                table = scenario([record(STORAGE)])
                table[key] = value
                api, code, out, _ = self.run_with_summary(table)
                self.assertEqual(1, code)
                self.assertIn('::error::', out)
                self.assertNotIn('Traceback', out)

    def test_a_failing_write_fails_the_job_without_the_token_in_the_output(self):
        table = scenario([record(STORAGE)])
        table[('POST', f'issues/{NUMBER}/labels')] = evidence.ApiError('403')
        out = io.StringIO()
        code = evidence.main({'GH_TOKEN': SECRET, 'GITHUB_REPOSITORY': 'o/r', 'PR_NUMBER': str(NUMBER)}, api=FakeApi(table), stdout=out)
        self.assertEqual(1, code)
        self.assertIn('::error::', out.getvalue())
        self.assertNotIn(SECRET, out.getvalue())

    def test_a_bad_environment_fails_before_any_request(self):
        for label, environ in [
            ('number with text', {'PR_NUMBER': '7;id'}), ('zero', {'PR_NUMBER': '0'}), ('empty number', {'PR_NUMBER': ''}),
            ('repository with a space', {'GITHUB_REPOSITORY': 'o r/x'}), ('repository without owner', {'GITHUB_REPOSITORY': 'repo'}),
            ('missing token', {'GH_TOKEN': ''}),
        ]:
            with self.subTest(label):
                api = FakeApi({})
                env = {'GH_TOKEN': SECRET, 'GITHUB_REPOSITORY': 'o/r', 'PR_NUMBER': str(NUMBER)}
                env.update(environ)
                out = io.StringIO()
                self.assertEqual(1, evidence.main(env, api=api, stdout=out))
                self.assertEqual([], api.calls)
                self.assertIn('::error::', out.getvalue())

    def test_file_names_never_reach_a_comment_or_the_log(self):
        hostile = [
            'Packages/EncryptedMemoriesKit/Sources/UploadCore/@octocat `x` <b>bold</b> [link](http://evil.example).swift',
            'Packages/EncryptedMemoriesKit/Sources/UploadCore/line\n::error::injected.swift',
            'Wiki/\x1b[31mred.md',
            'scripts/@octocat `x` <b>bold</b> [link](http:evil.example) ::error::injected.sh',
        ]
        for name in hostile:
            for labels in ([], [evidence.LABEL]):
                with self.subTest(name=name, labels=labels):
                    api, code, out, summary = self.run_main([record(STORAGE), record(name)], labels=labels)
                    written = json.dumps([call[2] for call in api.writes()]) + out
                    for fragment in ('octocat', 'evil.example', 'injected', 'red.md', '<b>'):
                        self.assertNotIn(fragment, written)

    def test_the_summary_lists_each_unknown_path_escaped_and_nothing_else(self):
        names = ['scripts/@octocat `x` <b>bold</b> [l](http:evil.example) ::error::x.sh', UNCLASSIFIED]
        api, code, out, summary = self.run_main([record(STORAGE)] + [record(name) for name in names])
        self.assertEqual(0, code)
        listed = [line for line in summary.splitlines() if line.startswith('- path ')]
        self.assertEqual(2, len(listed))
        for fragment in ('@octocat', '`x`', '<b>', '[l](', '::error::'):
            self.assertNotIn(fragment, summary)
        self.assertIn('\\u0040octocat', summary)
        self.assertIn(json.dumps(UNCLASSIFIED), summary)
        self.assertNotIn(STORAGE, summary)
        self.assertIn('2 unclassified paths', summary)

    def test_a_long_unknown_list_is_bounded_and_counted(self):
        files = [record(f'scripts/tool{index}.sh') for index in range(120)]
        api, code, out, summary = self.run_main(files)
        self.assertEqual(policy.UNKNOWN_PATH_LIMIT, len([line for line in summary.splitlines() if line.startswith('- path ')]))
        self.assertIn('120 unclassified paths', summary)
        self.assertIn(f'{120 - policy.UNKNOWN_PATH_LIMIT} more', summary)

    def test_unknown_never_says_no_storage_and_never_removes_the_label(self):
        causes = []
        causes.append(('unclassified path', scenario([record(UNCLASSIFIED)], labels=[evidence.LABEL])))
        failing = scenario([record(STORAGE)], labels=[evidence.LABEL])
        failing[('GET', f'pulls/{NUMBER}/files?per_page=100&page=1')] = evidence.ApiError('boom')
        causes.append(('api failure', failing))
        racing = scenario([record(UNCLASSIFIED)], labels=[evidence.LABEL])
        racing[('GET', f'pulls/{NUMBER}')] = [(pull(head=head, files=1),) for head in (HEAD, HEAD, OTHER)]
        causes.append(('changed while read', racing))
        truncated = scenario([record(README)], labels=[evidence.LABEL])
        truncated[('GET', f'git/trees/{HEAD}?recursive=1')] = tree({README: '100644'}, truncated=True)
        causes.append(('unreadable tree', truncated))
        for label, table in causes:
            with self.subTest(label):
                api, code, out, summary = self.run_with_summary(table)
                # Only a failed API read is red; a classification that stays UNKNOWN is quiet and green.
                self.assertEqual(1 if label == 'api failure' else 0, code)
                self.assertEqual([], [call for call in api.writes() if call[0] == 'DELETE'])
                self.assertEqual([], api.writes())
                self.assertNotIn('No storage path changed', summary + out)
                self.assertIn('undetermined', summary)

    def test_only_the_documented_endpoints_are_used_and_no_file_content_is_read(self):
        used = []
        for files, kwargs in [
            ([record(STORAGE), record(README)], {}),
            ([record(WIKI)], {'labels': [evidence.LABEL]}),
            ([record(UNCLASSIFIED)], {}),
            ([record(STORAGE)], {'label_exists': False}),
        ]:
            api, _, _, _ = self.run_main(files, **kwargs)
            used.extend((call[0], call[1]) for call in api.calls)
        self.assertTrue(used)
        for method, path in used:
            self.assertTrue(any(pattern.fullmatch(f'{method} {path}') for pattern in evidence.ALLOWED), f'{method} {path}')
        for _, path in used:
            for forbidden in ('contents/', 'git/blobs', 'raw.githubusercontent', 'zipball', 'tarball', 'git/refs'):
                self.assertNotIn(forbidden, path)


class Handler(http.server.BaseHTTPRequestHandler):
    log = []

    def _answer(self):
        length = int(self.headers.get('Content-Length') or 0)
        body = self.rfile.read(length).decode() if length else ''
        Handler.log.append((self.command, self.path, dict(self.headers), body))
        status, payload = (404, b'{"message": "no secret here"}') if self.path.endswith('/pulls/404') else (
            (200, b'not json') if self.path.endswith('/pulls/500') else (200, b'{"ok": true}'))
        if self.path.endswith('/pulls/501'):
            self.send_response(200)
            self.send_header('Content-Length', '100')
            self.end_headers()
            self.wfile.write(b'{"a"')
            self.wfile.flush()
            self.close_connection = True
            return
        if self.path.endswith('/pulls/505'):
            time.sleep(1.5)
        if self.path.endswith('/pulls/503'):
            self.send_response(200)
            self.send_header('Transfer-Encoding', 'chunked')
            self.end_headers()
            self.wfile.write(b'10\r\n{"a"')
            self.wfile.flush()
            self.close_connection = True
            return
        if self.path.endswith('/pulls/504'):
            # A complete JSON value in a body that the header promises to be longer.
            self.send_response(200)
            self.send_header('Content-Length', '100')
            self.end_headers()
            self.wfile.write(b'{"ok": true}')
            self.wfile.flush()
            self.close_connection = True
            return
        if self.path.endswith('/pulls/502'):
            # Valid JSON whose first bytes are a complete value: only the size limit refuses it.
            payload = b'{"ok": true}' + b' ' * 300
        self.send_response(302 if self.path.endswith('/pulls/302') else status)
        if self.path.endswith('/pulls/302'):
            self.send_header('Location', '/elsewhere')
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        self.wfile.write(payload)

    do_GET = do_POST = do_PATCH = do_DELETE = _answer

    def log_message(self, *args):
        pass


class TransportTests(unittest.TestCase):
    def setUp(self):
        Handler.log = []
        self.server = http.server.HTTPServer(('127.0.0.1', 0), Handler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)
        self.api = evidence.HttpApi(SECRET, 'o/r', base_url=f'http://127.0.0.1:{self.server.server_port}')

    def test_a_request_carries_the_token_the_version_and_the_json_body(self):
        self.assertEqual({'ok': True}, self.api.request('POST', f'issues/{NUMBER}/labels', {'labels': ['storage']}))
        method, path, headers, body = Handler.log[0]
        self.assertEqual(('POST', f'/repos/o/r/issues/{NUMBER}/labels', {'labels': ['storage']}), (method, path, json.loads(body)))
        lowered = {name.lower(): value for name, value in headers.items()}
        self.assertEqual(f'Bearer {SECRET}', lowered['authorization'])
        self.assertEqual('2022-11-28', lowered['x-github-api-version'])

    def test_an_error_status_raises_without_the_token_or_the_body(self):
        with self.assertRaises(evidence.ApiError) as raised:
            self.api.request('GET', 'pulls/404')
        self.assertNotIn(SECRET, str(raised.exception))
        self.assertNotIn('no secret here', str(raised.exception))

    def test_a_redirect_is_an_error_and_is_not_followed(self):
        with self.assertRaises(evidence.ApiError):
            self.api.request('GET', 'pulls/302')
        self.assertEqual(['/repos/o/r/pulls/302'], [entry[1] for entry in Handler.log])

    def test_an_incomplete_answer_is_an_api_error(self):
        with self.assertRaises(evidence.ApiError) as raised:
            self.api.request('GET', 'pulls/501')
        self.assertNotIn(SECRET, str(raised.exception))

    def test_a_refused_connection_is_an_api_error(self):
        with socket.socket() as probe:
            probe.bind(('127.0.0.1', 0))
            port = probe.getsockname()[1]
        closed = evidence.HttpApi(SECRET, 'o/r', base_url=f'http://127.0.0.1:{port}')
        with self.assertRaises(evidence.ApiError) as raised:
            closed.request('GET', 'pulls/7')
        self.assertNotIn(SECRET, str(raised.exception))

    def test_a_timeout_is_an_api_error(self):
        with unittest.mock.patch.object(evidence, 'TIMEOUT_SECONDS', 0.2):
            with self.assertRaises(evidence.ApiError):
                self.api.request('GET', 'pulls/505')

    def test_a_short_body_with_a_complete_json_value_is_still_incomplete(self):
        with self.assertRaises(evidence.ApiError):
            self.api.request('GET', 'pulls/504')

    def test_a_truncated_chunked_answer_is_an_api_error(self):
        # http.client raises IncompleteRead for a chunked body that ends early.
        with self.assertRaises(evidence.ApiError):
            self.api.request('GET', 'pulls/503')

    def test_an_answer_above_the_size_limit_is_an_api_error(self):
        with unittest.mock.patch.object(evidence, 'MAX_RESPONSE_BYTES', 100):
            with self.assertRaises(evidence.ApiError):
                self.api.request('GET', 'pulls/502')
        self.assertEqual({'ok': True}, self.api.request('GET', 'pulls/7'))

    def test_an_answer_that_is_not_json_is_an_api_error(self):
        with self.assertRaises(evidence.ApiError):
            self.api.request('GET', 'pulls/500')

    def test_a_request_outside_the_allowed_endpoints_never_leaves_the_process(self):
        for method, path in [('GET', 'contents/App/Main.swift'), ('GET', 'git/blobs/' + 'a' * 40), ('PUT', 'issues/7/labels'),
                             ('DELETE', 'issues/7'), ('POST', 'pulls/7/merge'), ('GET', 'issues/seven/labels?per_page=100')]:
            with self.subTest(method=method, path=path):
                with self.assertRaises(ValueError):
                    self.api.request(method, path)
        self.assertEqual([], Handler.log)


if __name__ == '__main__':
    unittest.main()
