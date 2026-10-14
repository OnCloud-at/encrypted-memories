#!/usr/bin/env python3
"""Exercise release selection and registration without building historical releases."""
import base64
import contextlib
import hashlib
import importlib.util
import io
import json
import os
import subprocess
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('upgrade_corpus', ROOT / 'Tools/upgrade-fixtures/corpus.py')
corpus = importlib.util.module_from_spec(spec)
spec.loader.exec_module(corpus)


class ReleaseCatalogTests(unittest.TestCase):
    def test_only_public_stable_tags_are_accepted(self):
        self.assertEqual(corpus.release_version('v1.0.5'), (1, 0, 5))
        self.assertEqual(corpus.release_version('v2.10.0'), (2, 10, 0))
        for tag in ('v1.0.0', 'v1.0.4', 'v1.1.0-beta.1', 'v1.1.0-rc.1', 'v01.0.5', '../v1.0.5'):
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                corpus.release_version(tag)

    def test_registration_preserves_existing_release_and_rejects_retargeting(self):
        with tempfile.TemporaryDirectory(prefix='upgrade-catalog-') as temporary:
            root = Path(temporary)
            metadata = dict(release='v1.0.5', commit='7' * 40, sdk='0.29.1')
            folder = root / metadata['release']
            folder.mkdir()
            (folder / 'manifest.json').write_text(json.dumps(dict(format=1, **metadata, scenarios={})))
            (folder / 'corpus.tar.gz').write_bytes(b'synthetic archive')
            (folder / 'wal-policy-proof.json').write_text('{}')
            original = {p.name: p.read_bytes() for p in folder.iterdir()}
            catalog = corpus.release_catalog(folder, metadata)
            (root / 'releases.json').write_text(json.dumps(catalog))
            future = dict(release='v1.1.0', commit='8' * 40, sdk='0.30.0')
            updated = corpus.release_catalog(root / 'v1.1.0', future)
            self.assertEqual([r['tag'] for r in updated['releases']], ['v1.0.5', 'v1.1.0'])
            self.assertEqual(updated['releases'][0], catalog['releases'][0])
            self.assertEqual(original, {p.name: p.read_bytes() for p in folder.iterdir()})
            with self.assertRaises(ValueError):
                corpus.release_catalog(folder, dict(metadata, commit='9' * 40))
            with self.assertRaises(ValueError):
                corpus.release_catalog(root / 'v1.1.1', future)
            (root / 'v9.0.0').mkdir()
            with self.assertRaises(ValueError):
                corpus.release_catalog(root / 'v1.1.0', future)
            (root / 'v9.0.0').rmdir()
            (folder / 'corpus.tar.gz').unlink()
            with self.assertRaises(ValueError):
                corpus.release_catalog(root / 'v1.1.0', future)


    def test_pack_adds_a_release_only_after_artifacts_fit_the_budget(self):
        with tempfile.TemporaryDirectory(prefix='upgrade-pack-') as temporary:
            root = Path(temporary) / 'Fixtures'
            baseline = dict(release='v1.0.5', commit='7' * 40, sdk='0.29.1')
            old = root / baseline['release']
            old.mkdir(parents=True)
            (old / 'manifest.json').write_text(json.dumps(dict(format=1, **baseline, scenarios={})))
            (old / 'corpus.tar.gz').write_bytes(b'synthetic baseline')
            (old / 'wal-policy-proof.json').write_text('{}')
            original = {p.name: p.read_bytes() for p in old.iterdir()}
            catalog_path = root / 'releases.json'
            catalog_path.write_text(json.dumps(corpus.release_catalog(old, baseline)))
            original_catalog = catalog_path.read_bytes()
            future = dict(release='v1.1.0', commit='8' * 40, sdk='0.30.0')
            recorded = Path(temporary) / 'run' / 'recorded'
            recorded.mkdir(parents=True)
            (recorded.parent / 'recording.json').write_text(json.dumps(future))
            payload = b'synthetic half-written file'
            for scenario in corpus.SCENARIOS:
                folder = recorded / scenario
                snapshot = folder / '000001'
                snapshot.mkdir(parents=True)
                (snapshot / 'Synthetic').write_bytes(payload)
                (folder / 'events.jsonl').write_text(json.dumps(dict(id=1, kind='write', path='/Synthetic')) + '\n')
                (folder / '000001.oracle.json').write_text(json.dumps(dict(generation=1, remote=[])))
            destination = root / future['release']
            destination.mkdir()
            (destination / 'wal-policy-proof.json').write_text('{}')
            with patch.object(corpus, 'BUDGET', 1), self.assertRaisesRegex(ValueError, 'budget'):
                corpus.pack(recorded, destination)
            self.assertEqual(catalog_path.read_bytes(), original_catalog)
            with contextlib.redirect_stdout(io.StringIO()):
                corpus.pack(recorded, destination)
            catalog = json.loads(catalog_path.read_text())
            self.assertEqual([r['tag'] for r in catalog['releases']], ['v1.0.5', 'v1.1.0'])
            manifest = json.loads((destination / 'manifest.json').read_text())
            self.assertEqual(manifest['release'], future['release'])
            self.assertEqual(set(manifest['scenarios']), set(corpus.SCENARIOS))
            digest = hashlib.sha256(payload).hexdigest()
            for snapshots in manifest['scenarios'].values():
                self.assertEqual(snapshots[0]['files'], {'Synthetic': digest})
            with tarfile.open(destination / 'corpus.tar.gz', 'r:gz') as archive:
                self.assertEqual(archive.getnames(), ['blobs/' + digest])
                self.assertEqual(archive.extractfile('blobs/' + digest).read(), payload)
            self.assertEqual(original, {p.name: p.read_bytes() for p in old.iterdir()})


class PrivatePathTests(unittest.TestCase):
    """A recorded corpus must hold no local home path. The names are synthetic, and every path is built from parts so
    that this file spells no home path itself."""

    @staticmethod
    def below(folder, name, tail='x', escaped=False):
        path = '/' + folder + '/' + name + '/' + tail
        return (path.replace('/', '\\/') if escaped else path).encode()

    @classmethod
    def setUpClass(cls):
        cls.ESCAPED = b'{"fileURL":"file:\\/\\/' + cls.below('Users', 'user', 'Developer/work/data/Exports/asset-1', True) + b'"}'

    def test_a_home_path_is_found_plain_and_json_escaped(self):
        below = self.below
        for data in (below('Users', 'user', 'Developer/work'), self.ESCAPED, below('home', 'user', 'work'),
                     below('home', 'user', 'work', True),
                     below('Users', 'user', escaped=True).replace(b'\\/', b'\\\\\\/'),  # a record inside a record
                     below('Users', 'user', escaped=True).replace(b'\\/', b'\\u002f'),
                     below('users', 'user'), below('Users', '\\u00fcnal', escaped=True), below('Users', 'Shared2')):
            with self.subTest(data=data), self.assertRaisesRegex(ValueError, 'Private path or hostname in label'):
                corpus.check_bytes(data, 'label')

    def test_a_staging_folder_that_an_interrupted_run_left_behind_is_removed(self):
        with tempfile.TemporaryDirectory() as temporary:
            recorded, destination = self.recording(Path(temporary), b'clean')
            (destination / 'wal-policy-proof.json').write_text('{}')
            stale = destination.parent / '.pack-interrupted'
            stale.mkdir()
            (stale / 'corpus.tar.gz').write_bytes(b'half written')
            with contextlib.redirect_stdout(io.StringIO()):
                corpus.pack(recorded, destination)
            self.assertFalse(stale.exists())
            self.assertEqual(sorted(path.name for path in destination.iterdir()),
                             ['corpus.tar.gz', 'manifest.json', 'wal-policy-proof.json'])

    def test_the_message_names_the_place_and_never_the_value(self):
        with self.assertRaises(ValueError) as caught:
            corpus.check_bytes(self.ESCAPED, 'backup/Account/queue.sqlite-wal')
        self.assertEqual(str(caught.exception), 'Private path or hostname in backup/Account/queue.sqlite-wal')

    def test_the_shared_and_runner_locations_are_allowed_in_every_form(self):
        below = self.below
        for data in (below('Users', 'Shared', 'EncryptedMemoriesUpgradeFixtures/v1/run/data'),
                     b'file:\\/\\/' + below('Users', 'Shared', escaped=True),
                     below('Users', 'runner', 'work/repo'), below('home', 'runner', 'work', True)):
            with self.subTest(data=data):
                corpus.check_bytes(data, 'label')

    def test_a_path_inside_a_backup_issue_record_is_found(self):
        record = base64.b64encode(self.ESCAPED)
        with self.assertRaisesRegex(ValueError, 'decoded backup issue'):
            corpus.check_bytes(b'encryptedmemories-backup-issue-v1:' + record, 'label', strict_issues=True)

    def published(self, directory, member=b'clean', manifest=b'{}', proof=b'{}'):
        archive = Path(directory) / 'corpus.tar.gz'
        with tarfile.open(archive, 'w:gz') as tar:
            info = tarfile.TarInfo('blobs/' + 'a' * 64)
            info.size = len(member)
            tar.addfile(info, io.BytesIO(member))
        (Path(directory) / 'manifest.json').write_bytes(manifest)
        (Path(directory) / 'wal-policy-proof.json').write_bytes(proof)
        return Path(directory)

    def test_the_published_files_are_scanned_member_by_member(self):
        with tempfile.TemporaryDirectory() as directory:
            corpus.check_published(self.published(directory))
        for name, parts in (('archive member', dict(member=self.ESCAPED)), ('manifest.json', dict(manifest=self.ESCAPED)),
                            ('wal-policy-proof.json', dict(proof=self.ESCAPED))):
            with self.subTest(place=name), tempfile.TemporaryDirectory() as directory:
                folder = self.published(directory, **parts)
                with self.assertRaisesRegex(ValueError, name):
                    corpus.check_published(folder)

    def recording(self, root, payload):
        """A minimal recording whose single file holds `payload`, and a destination that already has its proof."""
        future = dict(release='v1.1.0', commit='8' * 40, sdk='0.30.0')
        recorded = root / 'run' / 'recorded'
        recorded.mkdir(parents=True)
        (recorded.parent / 'recording.json').write_text(json.dumps(future))
        for scenario in corpus.SCENARIOS:
            folder = recorded / scenario
            (folder / '000001').mkdir(parents=True)
            (folder / '000001' / 'Synthetic').write_bytes(payload)
            (folder / 'events.jsonl').write_text(json.dumps(dict(id=1, kind='write', path='/Synthetic')) + '\n')
            (folder / '000001.oracle.json').write_text(json.dumps(dict(generation=1, remote=[])))
        fixtures = root / 'Fixtures'
        baseline = fixtures / 'v1.0.5'
        baseline.mkdir(parents=True)
        metadata = dict(release='v1.0.5', commit='7' * 40, sdk='0.29.1')
        (baseline / 'manifest.json').write_text(json.dumps(dict(format=1, **metadata, scenarios={})))
        (baseline / 'corpus.tar.gz').write_bytes(b'synthetic baseline')
        (baseline / 'wal-policy-proof.json').write_text('{}')
        (fixtures / 'releases.json').write_text(json.dumps(corpus.release_catalog(baseline, metadata)))
        destination = fixtures / 'v1.1.0'
        destination.mkdir()
        return recorded, destination

    def test_the_recorder_fails_on_a_hit_and_writes_nothing(self):
        with tempfile.TemporaryDirectory() as temporary:
            recorded, destination = self.recording(Path(temporary), self.ESCAPED)
            (destination / 'wal-policy-proof.json').write_text('{}')
            catalog = (destination.parent / 'releases.json').read_bytes()
            with self.assertRaisesRegex(ValueError, 'Private path or hostname'):
                corpus.pack(recorded, destination)
            self.assertEqual(sorted(path.name for path in destination.iterdir()), ['wal-policy-proof.json'])
            self.assertEqual((destination.parent / 'releases.json').read_bytes(), catalog)

    def test_the_recorder_fails_on_a_hit_in_the_policy_proof_and_writes_nothing(self):
        with tempfile.TemporaryDirectory() as temporary:
            recorded, destination = self.recording(Path(temporary), b'clean')
            (destination / 'wal-policy-proof.json').write_bytes(self.ESCAPED)
            catalog = (destination.parent / 'releases.json').read_bytes()
            with self.assertRaisesRegex(ValueError, 'wal-policy-proof.json'):
                corpus.pack(recorded, destination)
            self.assertEqual(sorted(path.name for path in destination.iterdir()), ['wal-policy-proof.json'])
            self.assertEqual((destination.parent / 'releases.json').read_bytes(), catalog)


class ObserverTests(unittest.TestCase):
    """The recorder's observer must see a file creation however Foundation opens the file."""

    @classmethod
    def setUpClass(cls):
        if sys.platform != 'darwin':
            raise unittest.SkipTest('The observer interposes the Darwin C library')
        cls.directory = tempfile.TemporaryDirectory(prefix='upgrade-observer-')
        cls.addClassCleanup(cls.directory.cleanup)
        cls.build = Path(cls.directory.name).resolve()
        recorder = ROOT / 'Tools/upgrade-fixtures/Recorder'
        program = cls.build / 'create.c'
        program.write_text(r'''
#include <fcntl.h>
#include <unistd.h>
extern int open_dprotected_np(const char *, int, int, int, ...);
int main(int argc, char **argv) {
    int plain = open(argv[1], O_WRONLY | O_CREAT | O_EXCL, 0644);
    int protected_file = open_dprotected_np(argv[2], O_WRONLY | O_CREAT | O_EXCL, 4, 0, 0644);
    if (plain < 0 || protected_file < 0) return 1;
    return write(plain, "x", 1) == 1 && write(protected_file, "y", 1) == 1 ? 0 : 2;
}
''')
        env = dict(os.environ, DEVELOPER_DIR=os.environ.get('DEVELOPER_DIR', '/Applications/Xcode.app/Contents/Developer'))
        subprocess.run(['xcrun', 'clang', '-dynamiclib', '-O2', str(recorder / 'observe.c'), str(recorder / 'temporary.m'),
                        '-framework', 'Foundation', '-lsqlite3', '-o', str(cls.build / 'observe.dylib')], check=True, env=env)
        subprocess.run(['xcrun', 'clang', '-O2', str(program), '-o', str(cls.build / 'create')], check=True, env=env)

    def test_creating_a_file_with_a_data_protection_class_is_a_boundary_like_a_plain_open(self):
        root = self.build / 'root'
        output = self.build / 'recorded'
        oracle = self.build / 'oracle.json'
        root.mkdir()
        output.mkdir()
        oracle.write_text('{"generation":1,"remote":[],"complete":[],"queueKeys":[]}\n')
        env = dict(PATH=os.environ['PATH'], DYLD_INSERT_LIBRARIES=str(self.build / 'observe.dylib'),
                   UPGRADE_RECORD_ROOT=str(root), UPGRADE_RECORD_OUTPUT=str(output), UPGRADE_RECORD_ORACLE=str(oracle))
        subprocess.run([str(self.build / 'create'), str(root / 'plain.bin'), str(root / 'protected.bin')], check=True, env=env)
        events = [json.loads(line) for line in (output / 'events.jsonl').read_text().splitlines()]
        creations = sorted(event['path'] for event in events if event['kind'] == 'create-or-truncate')
        self.assertEqual(creations, ['/plain.bin', '/protected.bin'])


if __name__ == '__main__':
    unittest.main()
