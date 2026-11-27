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
import subprocess
import sys
import tarfile
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[2]
OVERLAYS = REPO / 'scripts/upgrade-test/overlays'
KIT = 'Packages/EncryptedMemoriesKit/Sources'

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
        # The production scanner decides; this test only feeds it the candidate's payload
        # files at HEAD and requires an empty result against every earlier release.
        for tag in sorted(self.manifest):
            if source_has_own_test_entry(tag):
                continue
            pinned = {str(path.relative_to(OVERLAYS / (tag + '.payload')))
                      for path in (OVERLAYS / (tag + '.payload')).rglob('*') if path.is_file()}
            scanned = [name for name in build_apps.PAYLOAD if name not in pinned]
            self.assertTrue(scanned, msg=f'{tag}: every payload file is pinned, none to check')
            with tempfile.TemporaryDirectory() as scratch:
                source = Path(scratch)
                for name in scanned:
                    target = source / KIT / name
                    target.parent.mkdir(parents=True, exist_ok=True)
                    target.write_bytes(git_bytes('HEAD', KIT + '/' + name))
                unknown = build_apps.unbuildable_names(source, tag, payload=scanned, git_repo=REPO)
                self.assertEqual({}, unknown,
                                 msg=f'{tag}: candidate test-entry files use names the source never defines')


class OverlayApplicationTests(unittest.TestCase):
    """The overlay must apply to the real source era, not only to fixtures."""

    def v1_0_5_args(self, root, automation):
        tag = 'v1.0.5'
        commit = json.loads((OVERLAYS / 'versions.json').read_text())[tag]['commit']
        archive = str(Path(root) / 'source.tar')
        subprocess.run(['git', 'archive', '-o', archive, commit], cwd=REPO, check=True)
        source = Path(root) / 'source'
        with tarfile.open(archive) as tree:
            tree.extractall(source, filter='data')
        return source, automation, tag, commit

    def apply_v1_0_5(self, root, automation):
        source, automation, tag, commit = self.v1_0_5_args(root, automation)
        build_apps.apply_overlay(source, automation, tag, commit)
        return source

    def history_sharing_automation(self, root):
        # The real automation checkout is a git checkout whose history holds the release tag;
        # a shared clone gives the test the same discrimination instead of a bare file copy.
        automation = Path(root) / 'automation'
        subprocess.run(['git', 'clone', '--quiet', '--shared', str(REPO), str(automation)], check=True)
        return automation

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
            automation = self.history_sharing_automation(scratch)
            pinned = automation / 'scripts/upgrade-test/overlays' / 'v1.0.5.payload' / \
                'MLSearchAppleAdapter' / 'UpgradeTestSmartSearch.swift'
            text = pinned.read_text().replace('SHA256.hash(data: payload)', 'UnknownType.hash(data: payload)')
            pinned.write_text(text)
            with self.assertRaisesRegex(JourneyError, 'UnknownType'):
                self.apply_v1_0_5(scratch, automation)

    def test_apply_overlay_fails_when_a_test_file_mentions_an_unknown_type_without_a_member(self):
        # A bare type reference (constructor, cast, conformance) compiles only when the release
        # defines it. The run 45890080546 failure class includes names that never take a member.
        with tempfile.TemporaryDirectory() as scratch:
            automation = self.history_sharing_automation(scratch)
            pinned = automation / 'scripts/upgrade-test/overlays' / 'v1.0.5.payload' / \
                'MLSearchAppleAdapter' / 'UpgradeTestSmartSearch.swift'
            text = pinned.read_text().replace('import CryptoKit',
                                              'import CryptoKit\nlet evidence = MysteryFreeType()')
            pinned.write_text(text)
            with self.assertRaisesRegex(JourneyError, 'MysteryFreeType'):
                self.apply_v1_0_5(scratch, automation)

    def test_apply_overlay_ignores_names_that_only_appear_in_a_compilation_condition(self):
        # A directive line is not Swift code; a future condition name is not an unbuildable
        # type. The scan must drop directive lines, including their condition name.
        with tempfile.TemporaryDirectory() as scratch:
            automation = self.history_sharing_automation(scratch)
            pinned = automation / 'scripts/upgrade-test/overlays' / 'v1.0.5.payload' / \
                'MLSearchAppleAdapter' / 'UpgradeTestSmartSearch.swift'
            text = pinned.read_text().replace('#if ENCRYPTED_MEMORIES_UPGRADE_TEST',
                                              '#if ENCRYPTED_MEMORIES_UPGRADE_TEST\n'
                                              '#if SOME_FUTURE_CONDITION')
            pinned.write_text(text)
            build_apps.apply_overlay(*self.v1_0_5_args(scratch, automation))

    def test_apply_overlay_ignores_names_that_only_appear_in_a_multi_line_string(self):
        # Names inside multi-line string literals are text, not code; the scan must strip
        # triple-quoted literals before it collects names, including one on its own line.
        with tempfile.TemporaryDirectory() as scratch:
            automation = self.history_sharing_automation(scratch)
            pinned = automation / 'scripts/upgrade-test/overlays' / 'v1.0.5.payload' / \
                'MLSearchAppleAdapter' / 'UpgradeTestSmartSearch.swift'
            text = pinned.read_text().replace('import CryptoKit',
                                              'import CryptoKit\n'
                                              'let prose = """\n'
                                              'A FailureCancellation mention is text.\n'
                                              '"""')
            pinned.write_text(text)
            build_apps.apply_overlay(*self.v1_0_5_args(scratch, automation))

    def test_apply_overlay_fails_loudly_when_the_automation_history_cannot_read_the_tag(self):
        # A checkout without git history once made git grep fail for every word, so every
        # name looked unknown and the guard blocked for the wrong reason. That state must
        # now fail as an infrastructure error instead of impersonating an unknown name.
        with tempfile.TemporaryDirectory() as scratch:
            automation = Path(scratch) / 'automation'
            automation.mkdir()
            for item in ('scripts', KIT.split('/')[0]):
                subprocess.run(['cp', '-R', str(REPO / item), str(automation / item)])
            with self.assertRaisesRegex(JourneyError, 'Cannot read the tagged sources of v1.0.5'):
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

    def test_each_invalid_alternative_shape_fails_the_planner(self):
        key = ('iOS', '26', 'iPhone')
        shapes = [
            ('empty', [''], 'distinct non-empty builds'),
            ('whitespace', [' 23F73 '], 'distinct non-empty builds'),
            ('canonical repeat', ['23F77'], 'must not repeat the canonical build'),
            ('no evidence', None, 'requires pin_evidence'),
        ]
        for name, alternatives, message in shapes:
            with self.subTest(name):
                pins = {k: dict(v) for k, v in run_journey.PINS.items()}
                if alternatives is None:
                    del pins[key]['pin_evidence']
                else:
                    pins[key]['runtime_build_alternatives'] = alternatives
                with self.assertRaisesRegex(release_upgrade.UpgradeError, message):
                    release_upgrade.validate_pins(pins)

    def test_a_pin_without_alternatives_needs_no_evidence(self):
        pins = {key: dict(value) for key, value in run_journey.PINS.items()}
        del pins[('iOS', '26', 'iPhone')]['runtime_build_alternatives']
        del pins[('iOS', '26', 'iPhone')]['pin_evidence']
        release_upgrade.validate_pins(pins)


if __name__ == '__main__':
    unittest.main()
