#!/usr/bin/env python3
"""Guard the pins that keep the upgrade gate buildable and its runtime checks honest.

Three guards, one per failure class of hosted run 45890080546:

1. Payload provenance. A pinned test-entry file records the commit its bytes come from.
   Without the record, a pin silently drifts from history and nobody can tell which
   source era it matches.
2. Candidate compatibility. A source without its own test entry receives the candidate's
   five test-entry files. Each unpinned file must only use names that the source tree
   defines, that another payload file declares, or that a framework supplies. The
   hosted failures of run 45890080546 came from names added after v1.0.5 shipped:
   FailureCancellation, UploadError.internalFailure and SHA256.Digest.lowercaseHexString.
3. Runtime build set. xcodebuild -downloadPlatform selects an iOS version, never a
   build. Apple can serve more than one build for the same version within one run:
   shards of 45890080546 received 23F73 and 23F77 for iOS 26.5. The pin therefore
   names an accepted build set, with one canonical build, and the exported bundle
   check plus the installed-runtime lookup both compare against that set.
"""
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tarfile
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[2]
OVERLAYS = REPO / 'scripts/upgrade-test/overlays'
KIT = 'Packages/EncryptedMemoriesKit/Sources'
FRAMEWORK_ROOTS = frozenset({
    'FileManager', 'ProcessInfo', 'URLProtocol', 'URLSession', 'JSONSerialization', 'Task',
    'Insecure', 'SHA1', 'SHA256', 'Data', 'Int', 'Int64', 'Double', 'Bool', 'URL',
})
# Foundation member names that no historical kit source mentions. Extend only with a
# framework member and the release that needs it.
FRAMEWORK_MEMBERS = frozenset({'registerClass'})
MEMBER_EXEMPTIONS = frozenset({'self', 'init', 'some', 'utf8'})

sys.path.insert(0, str(REPO / 'scripts/upgrade-test'))
sys.path.insert(0, str(REPO / '.github/scripts'))
import build_apps  # noqa: E402
import release_upgrade  # noqa: E402
import run_journey  # noqa: E402
from journey import JourneyError  # noqa: E402


def git(*args):
    return subprocess.check_output(['git', *args], cwd=REPO, text=True)


def git_bytes(ref, path):
    return subprocess.check_output(['git', 'show', f'{ref}:{path}'], cwd=REPO)


def source_has_own_test_entry(tag):
    sentinel = 'Packages/EncryptedMemoriesKit/Sources/PhotosCore/UpgradeTestProbe.swift'
    return subprocess.run(['git', 'cat-file', '-e', f'{tag}:{sentinel}'], cwd=REPO,
                          capture_output=True).returncode == 0


def stripped_swift(text):
    """Comments and string literals hide words that no compiler sees. Remove both."""
    text = re.sub(r'/\*.*?\*/', '', text, flags=re.S)
    text = re.sub(r'//[^\n]*', '', text)
    text = re.sub(r'"(?:[^"\\\n]|\\.)*"', '""', text)
    return text


class PayloadProvenanceTests(unittest.TestCase):
    manifest = json.loads((OVERLAYS / 'versions.json').read_text())

    def test_every_pinned_payload_file_records_a_source_commit(self):
        for tag, record in sorted(self.manifest.items()):
            pinned = OVERLAYS / (tag + '.payload')
            on_disk = {str(path.relative_to(pinned)) for path in pinned.rglob('*') if path.is_file()}
            recorded = set(record.get('payload', {}))
            self.assertEqual(on_disk, recorded,
                             f'{tag}: pinned files and recorded payload provenance must match')

    def test_every_payload_pin_byte_matches_its_recorded_commit(self):
        for tag, record in sorted(self.manifest.items()):
            for relative, commit in sorted(record.get('payload', {}).items()):
                self.assertNotIn(relative, ('',), msg=tag)
                expected = git_bytes(commit, f'{KIT}/{relative}')
                actual = (OVERLAYS / (tag + '.payload') / relative).read_bytes()
                self.assertEqual(expected, actual,
                                 f'{tag}: payload pin {relative} differs from {commit}')

    def test_a_payload_pin_stays_inside_the_test_entry_payload(self):
        for tag, record in sorted(self.manifest.items()):
            outside = sorted(set(record.get('payload', {})) - set(build_apps.PAYLOAD))
            self.assertEqual(outside, [], msg=f'{tag}: pins outside the test entry payload')


class CandidateCompatibilityTests(unittest.TestCase):
    manifest = json.loads((OVERLAYS / 'versions.json').read_text())

    def test_unpinned_candidate_files_use_only_names_the_source_defines(self):
        for tag in sorted(self.manifest):
            if source_has_own_test_entry(tag):
                continue
            pinned = {str(path.relative_to(OVERLAYS / (tag + '.payload')))
                      for path in (OVERLAYS / (tag + '.payload')).rglob('*') if path.is_file()}
            scanned = [name for name in build_apps.PAYLOAD if name not in pinned]
            self.assertTrue(scanned, msg=f'{tag}: every payload file is pinned, none to check')
            texts = {}
            declared = set()
            for name in scanned:
                text = stripped_swift(subprocess.check_output(
                    ['git', 'show', f'HEAD:{KIT}/{name}'], cwd=REPO, text=True))
                texts[name] = text
                declared |= set(re.findall(
                    r'\b(?:func|var|let|case|associatedvalue|class|struct|enum|protocol|actor|typealias)\s+(\w+)',
                    text))
                declared |= set(re.findall(
                    r'\b(?:class|struct|enum|protocol|actor|typealias)\s+([A-Z]\w*)', text))

            def in_source(word):
                return subprocess.run(['git', 'grep', '-qw', '-e', word, tag, '--', KIT],
                                      cwd=REPO, capture_output=True).returncode == 0

            for name, text in texts.items():
                with self.subTest(tag=tag, file=name):
                    roots = sorted(set(re.findall(r'\b([A-Z]\w*)\s*\.', text)))
                    members = sorted(set(re.findall(r'(?:\b[A-Z]\w*|\))\s*\.\s*([a-z]\w*)', text)))
                    unknown_roots = [root for root in roots if root not in FRAMEWORK_ROOTS
                                     and root not in declared and not in_source(root)]
                    unknown_members = [member for member in members
                                        if member not in MEMBER_EXEMPTIONS
                                        and member not in FRAMEWORK_MEMBERS
                                        and member not in declared and not in_source(member)]
                    self.assertEqual([], unknown_roots,
                                     msg=f'{tag}: {name} uses names the source never defines')
                    self.assertEqual([], unknown_members,
                                     msg=f'{tag}: {name} uses members the source never defines')


class OverlayApplicationTests(unittest.TestCase):
    """The overlay must apply to the real source era, not only to fixtures."""

    def apply_v1_0_5(self, root, automation):
        tag, commit = 'v1.0.5', json.loads((OVERLAYS / 'versions.json').read_text())['v1.0.5']['commit']
        archive = str(Path(root) / 'source.tar')
        subprocess.run(['git', 'archive', '-o', archive, commit], cwd=REPO, check=True)
        source = Path(root) / 'source'
        with tarfile.open(archive) as tree:
            tree.extractall(source, filter='data')
        build_apps.apply_overlay(source, automation, tag, commit)
        return source

    def test_apply_overlay_installs_the_pinned_files_into_a_v1_0_5_source(self):
        with tempfile.TemporaryDirectory() as scratch:
            source = self.apply_v1_0_5(scratch, REPO)
            for relative in build_apps.PAYLOAD:
                pinned = OVERLAYS / ('v1.0.5.payload') / relative
                expected = pinned if pinned.is_file() else (REPO / KIT / relative)
                self.assertEqual((source / KIT / relative).read_bytes(), expected.read_bytes(),
                                 msg=f'v1.0.5: {relative} not overlaid from its pin')

    def test_apply_overlay_fails_when_a_test_file_uses_an_unknown_name(self):
        with tempfile.TemporaryDirectory() as scratch:
            automation = Path(scratch) / 'automation'
            automation.mkdir()
            for item in ('scripts', KIT.split('/')[0]):
                subprocess.run(['cp', '-R', str(REPO / item), str(automation / item)])
            pinned = automation / 'scripts/upgrade-test/overlays' / 'v1.0.5.payload' / \
                'MLSearchAppleAdapter' / 'UpgradeTestSmartSearch.swift'
            text = pinned.read_text().replace('SHA256.hash(data: payload)', 'UnknownType.hash(data: payload)')
            pinned.write_text(text)
            with self.assertRaisesRegex(Exception, 'UnknownType'):
                self.apply_v1_0_5(scratch, automation)


class RuntimePinTests(unittest.TestCase):
    PIN = {'runtime_version': '26.5', 'runtime_build': '23F77',
           'runtime_build_alternatives': ['23F73']}

    @classmethod
    def setUpClass(cls):
        import importlib.util
        location = REPO / 'scripts/upgrade-test/runtime_pin.py'
        spec = importlib.util.spec_from_file_location('runtime_pin', location)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        cls.runtime_pin = module

    def test_the_accepted_build_set_spans_pin_and_alternatives(self):
        self.assertEqual(self.runtime_pin.accepted_builds('26.5', '23F77', ['23F73']),
                         ['23F73', '23F77'])
        self.assertEqual(self.runtime_pin.accepted_builds('26.5', '23F77', []),
                         ['23F77'])

    def test_exported_bundle_check_accepts_any_accepted_build(self):
        accepted = ['23F73', '23F77']
        for build in ('23F73', '23F77'):
            with tempfile.TemporaryDirectory() as scratch:
                directory = Path(scratch) / 'export'
                bundle = directory / 'runtime.exportedBundle' / 'Restore'
                bundle.mkdir(parents=True)
                (bundle / 'runtime.dmg').write_bytes(b'image-' + build.encode())
                metadata = bundle.parent / 'ExportedMetadata.plist'
                metadata.write_bytes(plistlib.dumps({'MobileAssetProperties': {
                    'SimulatorVersion': '26.5', 'Build': build}}))
                image = self.runtime_pin.select_image(directory, {'version': '26.5', 'buildversions': accepted})
                self.assertEqual(image.read_bytes(), b'image-' + build.encode())
                excluding_self = [value for value in accepted if value != build]
                with self.assertRaisesRegex(ValueError, 'differs from the accepted builds'):
                    self.runtime_pin.select_image(directory, {'version': '26.5', 'buildversions': excluding_self})
                with self.assertRaisesRegex(ValueError, 'differs from the accepted builds 27.0'):
                    self.runtime_pin.select_image(directory, {'version': '27.0', 'buildversions': accepted})

    def test_the_installed_lookup_accepts_an_alternative_build(self):
        runtimes = [{'identifier': 'com.apple.CoreSimulator.SimRuntime.iOS-26-5',
                     'version': '26.5', 'buildversion': build, 'isAvailable': True}
                    for build in ('23F73',)]
        expected = {'identifier': 'com.apple.CoreSimulator.SimRuntime.iOS-26-5',
                    'version': '26.5', 'buildversion': '23F77',
                    'buildversions': ['23F73', '23F77']}
        selected = run_journey.select_ios_runtime(runtimes, expected)
        self.assertEqual(selected['buildversion'], '23F73')

    def test_the_installed_lookup_prefers_the_canonical_build_when_both_are_installed(self):
        runtimes = [{'identifier': 'com.apple.CoreSimulator.SimRuntime.iOS-26-5',
                     'version': '26.5', 'buildversion': build, 'isAvailable': True}
                    for build in ('23F73', '23F77')]
        expected = {'identifier': 'com.apple.CoreSimulator.SimRuntime.iOS-26-5',
                    'version': '26.5', 'buildversion': '23F77',
                    'buildversions': ['23F73', '23F77']}
        selected = run_journey.select_ios_runtime(runtimes, expected)
        self.assertEqual(selected['buildversion'], '23F77')

    def test_the_installed_lookup_rejects_a_build_outside_the_accepted_set(self):
        runtimes = [{'identifier': 'com.apple.CoreSimulator.SimRuntime.iOS-26-5',
                     'version': '26.5', 'buildversion': '23X99', 'isAvailable': True}]
        expected = {'identifier': 'com.apple.CoreSimulator.SimRuntime.iOS-26-5',
                    'version': '26.5', 'buildversion': '23F77',
                    'buildversions': ['23F73', '23F77']}
        with self.assertRaisesRegex(JourneyError, 'differs from the accepted builds'):
            run_journey.select_ios_runtime(runtimes, expected)

    def test_an_environment_pin_takes_its_accepted_set_from_the_config(self):
        environment = {'UPGRADE_RUNTIME_ID': 'com.apple.CoreSimulator.SimRuntime.iOS-26-5',
                        'UPGRADE_RUNTIME_VERSION': '26.5', 'UPGRADE_RUNTIME_BUILD': '23F77'}
        saved = {key: os.environ.get(key) for key in environment}
        try:
            os.environ.update(environment)
            expected = run_journey.requested_ios_runtime()
            self.assertEqual(expected['buildversions'], ['23F73', '23F77'])
        finally:
            for key, value in saved.items():
                if value is None:
                    os.environ.pop(key, None)
                else:
                    os.environ[key] = value

    def test_a_pin_without_alternatives_accepts_only_its_canonical_build(self):
        environment = {'UPGRADE_RUNTIME_ID': 'com.apple.CoreSimulator.SimRuntime.iOS-27-2',
                        'UPGRADE_RUNTIME_VERSION': '27.2', 'UPGRADE_RUNTIME_BUILD': '24B8117'}
        saved = {key: os.environ.get(key) for key in environment}
        try:
            os.environ.update(environment)
            expected = run_journey.requested_ios_runtime()
            self.assertEqual(expected['buildversions'], ['24B8117'])
        finally:
            for key, value in saved.items():
                if value is None:
                    os.environ.pop(key, None)
                else:
                    os.environ[key] = value

    def test_a_partial_runtime_environment_is_rejected(self):
        saved = os.environ.pop('UPGRADE_RUNTIME_BUILD', None)
        try:
            os.environ['UPGRADE_RUNTIME_ID'] = 'com.apple.CoreSimulator.SimRuntime.iOS-26-5'
            with self.assertRaisesRegex(JourneyError, 'must all be supplied'):
                run_journey.requested_ios_runtime()
        finally:
            if saved is None:
                os.environ.pop('UPGRADE_RUNTIME_ID', None)

    def test_alternative_builds_keep_the_config_shaped_and_evidenced(self):
        self.assertEqual(release_upgrade.PINS[('iOS', '26', 'iPhone')]['runtime_build_alternatives'],
                         ['23F73'])
        self.assertIn('45890080546', release_upgrade.PINS[('iOS', '26', 'iPhone')]['pin_evidence'])

    def test_invalid_alternatives_fail_the_planner_at_import_time(self):
        pins = {key: dict(value) for key, value in run_journey.PINS.items()}
        pins[('iOS', '26', 'iPhone')]['runtime_build_alternatives'] = ['23F73', '23F73']
        with self.assertRaisesRegex(release_upgrade.UpgradeError, 'distinct non-empty builds'):
            release_upgrade.validate_pins(pins)


if __name__ == '__main__':
    unittest.main()
