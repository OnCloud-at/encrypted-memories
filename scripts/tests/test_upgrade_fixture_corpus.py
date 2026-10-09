#!/usr/bin/env python3
"""Exercise release selection and registration without building historical releases."""
import contextlib
import hashlib
import importlib.util
import io
import json
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


if __name__ == '__main__':
    unittest.main()
