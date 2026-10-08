import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class IOSTestCommands(unittest.TestCase):
    def setUp(self):
        build_root = Path.home() / 'Developer/xcode/EncryptedMemories'
        build_root.mkdir(parents=True, exist_ok=True)
        self.scratch = tempfile.TemporaryDirectory(prefix='ci-command-test-', dir=build_root)
        self.root = Path(self.scratch.name)
        (self.root / 'scripts').mkdir()
        (self.root / 'bin').mkdir()
        source = Path(__file__).resolve().parents[2] / 'scripts/verify-ios-app-tests.sh'
        shutil.copy(source, self.root / 'scripts')
        (self.root / 'scripts/build-paths.sh').write_text('''ENCRYPTED_MEMORIES_BUILD_ROOT="$TEST_ROOT"
ENCRYPTED_MEMORIES_XCODE_SOURCE_PACKAGES="$TEST_ROOT/packages"
ENCRYPTED_MEMORIES_XCODE_PACKAGE_CACHE="$TEST_ROOT/cache"
encryptedmemories_acquire_build_lock() { :; }
encryptedmemories_pin_generated_project_packages() { :; }
''')
        (self.root / 'BuildSupport').mkdir()
        (self.root / 'BuildSupport/Package.resolved').write_text('{}')
        pinned = self.root / 'EncryptedMemories.xcodeproj/project.xcworkspace/xcshareddata/swiftpm'
        pinned.mkdir(parents=True)
        (pinned / 'Package.resolved').write_text('{}')
        launcher = '''#!/usr/bin/env python3
import json, os, sys
with open(os.environ['TEST_ROOT'] + '/commands.jsonl', 'a') as log:
    log.write(json.dumps(sys.argv[1:]) + '\\n')
if sys.argv[1:4] == ['simctl', 'list', 'devices']:
    print(json.dumps({'devices': {'com.apple.CoreSimulator.SimRuntime.iOS-27-0': [
        {'name': 'iPhone 17', 'udid': 'simulator-test', 'isAvailable': True}]}}))
'''
        for name in ['xcrun', 'xcodegen']:
            command = self.root / 'bin' / name
            command.write_text(launcher)
            command.chmod(0o755)

    def tearDown(self):
        self.scratch.cleanup()

    def run_script(self, mode='hosted', **options):
        environment = dict(os.environ)
        for key in list(environment):
            if key.startswith('IOS_TEST_'):
                del environment[key]
        environment.update(TEST_ROOT=str(self.root), PATH=str(self.root / 'bin') + ':' + os.environ['PATH'])
        environment.update(options)
        result = subprocess.run(['bash', str(self.root / 'scripts/verify-ios-app-tests.sh'), mode],
                                env=environment, capture_output=True, text=True)
        commands = self.root / 'commands.jsonl'
        self.commands = [json.loads(line) for line in commands.read_text().splitlines()] if commands.exists() else []
        return result

    def test_default_commands_keep_both_local_modes(self):
        for mode, scheme in [('hosted', 'EncryptedMemoriesMobileTests'), ('ui', 'EncryptedMemoriesMobileUITests')]:
            with self.subTest(mode=mode):
                result = self.run_script(mode)
                self.assertEqual(result.returncode, 0, result.stderr)
                invocation = self.commands[-1]
                self.assertEqual(invocation[-1], 'test')
                self.assertEqual(invocation[invocation.index('-scheme') + 1], scheme)
                self.assertTrue(any('-resolvePackageDependencies' in command for command in self.commands))

    def test_prepared_build_builds_both_bundles_without_filtering(self):
        result = self.run_script(IOS_TEST_ACTION='build-for-testing', IOS_TEST_SCHEME='EncryptedMemoriesMobileCI',
                                 IOS_TEST_PREPARED='1')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.commands[-1][-1], 'build-for-testing')
        self.assertNotIn('-only-testing:EncryptedMemoriesMobileTests', self.commands[-1])
        self.assertFalse(any('-resolvePackageDependencies' in command for command in self.commands))

    def test_prepared_runs_select_the_complete_bundle(self):
        for mode, target in [('hosted', 'EncryptedMemoriesMobileTests'), ('ui', 'EncryptedMemoriesMobileUITests')]:
            with self.subTest(mode=mode):
                result = self.run_script(mode, IOS_TEST_ACTION='test-without-building',
                                         IOS_TEST_SCHEME='EncryptedMemoriesMobileCI', IOS_TEST_PREPARED='1',
                                         IOS_TEST_PARALLEL_WORKERS='2', IOS_TEST_RESULT_BUNDLE_PATH=str(self.root / 'results'))
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.commands[-1][-1], 'test-without-building')
                self.assertIn('-only-testing:' + target, self.commands[-1])
                self.assertIn('-resultBundlePath', self.commands[-1])
                self.assertFalse(any('-resolvePackageDependencies' in command for command in self.commands))
                if mode == 'ui':
                    self.assertIn('-parallel-testing-enabled', self.commands[-1])
                    self.assertEqual(self.commands[-1][self.commands[-1].index('-parallel-testing-worker-count') + 1], '2')

    def test_invalid_action_fails_before_xcodebuild(self):
        result = self.run_script(IOS_TEST_ACTION='archive')
        self.assertEqual(result.returncode, 64)
        self.assertFalse(any(command and command[0] == 'xcodebuild' for command in self.commands))

    def test_prepared_project_requires_the_pinned_graph(self):
        (self.root / 'BuildSupport/Package.resolved').write_text('{"changed":true}')
        result = self.run_script(IOS_TEST_PREPARED='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(command and command[0] == 'xcodebuild' for command in self.commands))


if __name__ == '__main__':
    unittest.main()
