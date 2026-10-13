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
    devices = {'devices': {
        'com.apple.CoreSimulator.SimRuntime.iOS-26-0': [
            {'name': 'iPhone 17', 'udid': 'older-simulator-test', 'isAvailable': True}],
        'com.apple.CoreSimulator.SimRuntime.iOS-27-0': [
            {'name': 'iPhone 17', 'udid': 'simulator-test', 'isAvailable': True}],
        'com.apple.CoreSimulator.SimRuntime.iOS-27-1': [
            {'name': 'iPhone Duo', 'udid': 'duo-test', 'isAvailable': True}]}}
    if os.environ.get('TEST_PATCH_RUNTIME') == '1':
        devices['devices']['com.apple.CoreSimulator.SimRuntime.iOS-27-1-1'] = [
            {'name': 'iPhone Duo', 'udid': 'patched-duo-test', 'isAvailable': True}]
    print(json.dumps(devices))
if sys.argv[1:3] == ['simctl', 'bootstatus']:
    raise SystemExit(int(os.environ.get('TEST_BOOT_EXIT', '0')))
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
        environment.update(TEST_BOOT_EXIT="0", TEST_PATCH_RUNTIME="0")
        environment.update(options)
        (self.root / "commands.jsonl").write_text("")
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

    def test_explicit_simulator_id_boots_before_both_test_modes(self):
        for mode in ['hosted', 'ui']:
            with self.subTest(mode=mode):
                result = self.run_script(mode, IOS_TEST_DESTINATION='platform=iOS Simulator,id=simulator-test')
                self.assertEqual(result.returncode, 0, result.stderr)
                boot = ['simctl', 'bootstatus', 'simulator-test', '-b']
                self.assertIn(boot, self.commands)
                self.assertLess(self.commands.index(boot), len(self.commands) - 1)
                invocation = self.commands[-1]
                self.assertEqual(invocation[invocation.index('-destination') + 1],
                                 'platform=iOS Simulator,id=simulator-test')

    def test_named_simulator_override_boots_and_tests_the_same_device(self):
        result = self.run_script(IOS_TEST_DESTINATION='platform=iOS Simulator,name=iPhone Duo,OS=latest,arch=arm64')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(['simctl', 'bootstatus', 'duo-test', '-b'], self.commands)
        invocation = self.commands[-1]
        self.assertEqual(invocation[invocation.index('-destination') + 1],
                         'platform=iOS Simulator,arch=arm64,id=duo-test')

    def test_explicit_simulator_build_does_not_boot(self):
        result = self.run_script(IOS_TEST_DESTINATION='platform=iOS Simulator,id=simulator-test',
                                 IOS_TEST_ACTION='build-for-testing')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any(command[:2] == ['simctl', 'bootstatus'] for command in self.commands))

    def test_named_override_honors_an_explicit_runtime(self):
        result = self.run_script(IOS_TEST_DESTINATION='platform=iOS Simulator,name=iPhone 17,OS=26.0.0')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(['simctl', 'bootstatus', 'older-simulator-test', '-b'], self.commands)
        invocation = self.commands[-1]
        self.assertEqual(invocation[invocation.index('-destination') + 1],
                         'platform=iOS Simulator,id=older-simulator-test')

    def test_unavailable_or_invalid_named_runtime_stops_before_xcodebuild(self):
        for runtime, expected in [('27.0', 69), ('not-a-version', 64)]:
            with self.subTest(runtime=runtime):
                result = self.run_script(IOS_TEST_DESTINATION='platform=iOS Simulator,name=iPhone Duo,OS=' + runtime)
                self.assertEqual(result.returncode, expected)
                self.assertFalse(any(command and command[0] == 'xcodebuild' for command in self.commands))

    def test_partial_or_missing_runtime_selects_the_highest_matching_version(self):
        for runtime in ['27.1', '27', None]:
            with self.subTest(runtime=runtime):
                destination = 'platform=iOS Simulator,name=iPhone Duo'
                if runtime is not None:
                    destination += ',OS=' + runtime
                result = self.run_script(IOS_TEST_DESTINATION=destination, TEST_PATCH_RUNTIME='1')
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(['simctl', 'bootstatus', 'patched-duo-test', '-b'], self.commands)
                invocation = self.commands[-1]
                self.assertEqual(invocation[invocation.index('-destination') + 1],
                                 'platform=iOS Simulator,id=patched-duo-test')

    def test_three_component_runtime_matches_exactly(self):
        for runtime, simulator in [('27.1.0', 'duo-test'), ('27.1.1', 'patched-duo-test')]:
            with self.subTest(runtime=runtime):
                result = self.run_script(IOS_TEST_DESTINATION='platform=iOS Simulator,name=iPhone Duo,OS=' + runtime,
                                         TEST_PATCH_RUNTIME='1')
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(['simctl', 'bootstatus', simulator, '-b'], self.commands)
                invocation = self.commands[-1]
                self.assertEqual(invocation[invocation.index('-destination') + 1],
                                 'platform=iOS Simulator,id=' + simulator)

    def test_unmatched_partial_runtime_stops_before_xcodebuild(self):
        result = self.run_script(IOS_TEST_DESTINATION='platform=iOS Simulator,name=iPhone Duo,OS=28',
                                 TEST_PATCH_RUNTIME='1')
        self.assertEqual(result.returncode, 69, result.stderr)
        self.assertFalse(any(command and command[0] == 'xcodebuild' for command in self.commands))

    def test_empty_destination_id_stops_before_xcodebuild(self):
        for destination in ['platform=iOS Simulator,id=',
                            'platform=iOS Simulator,id=,name=iPhone Duo',
                            'platform=iOS Simulator,name=iPhone Duo,id=']:
            with self.subTest(destination=destination):
                result = self.run_script(IOS_TEST_DESTINATION=destination)
                self.assertEqual(result.returncode, 64, result.stderr)
                self.assertIn('destination id cannot be empty', result.stderr)
                self.assertFalse(any(command and command[0] == 'xcodebuild' for command in self.commands))

    def test_empty_destination_os_stops_before_xcodebuild(self):
        for destination in ['platform=iOS Simulator,name=iPhone Duo,OS=',
                            'platform=iOS Simulator,id=duo-test,OS=']:
            with self.subTest(destination=destination):
                result = self.run_script(IOS_TEST_DESTINATION=destination)
                self.assertEqual(result.returncode, 64, result.stderr)
                self.assertIn('destination OS cannot be empty', result.stderr)
                self.assertFalse(any(command and command[0] == 'xcodebuild' for command in self.commands))

    def test_destination_fields_without_equals_stop_before_xcodebuild(self):
        for destination in ['platform=iOS Simulator,name=iPhone Duo, Book',
                            'platform=iOS Simulator,name=iPhone Duo,',
                            'platform=iOS Simulator,,name=iPhone Duo']:
            with self.subTest(destination=destination):
                result = self.run_script(IOS_TEST_DESTINATION=destination)
                self.assertEqual(result.returncode, 64, result.stderr)
                self.assertIn('destination fields must use key=value', result.stderr)
                self.assertFalse(any(command and command[0] == 'xcodebuild' for command in self.commands))

    def test_failed_explicit_boot_stops_before_test_launch(self):
        result = self.run_script(IOS_TEST_DESTINATION='platform=iOS Simulator,id=duo-test',
                                 IOS_TEST_PREPARED='1', TEST_BOOT_EXIT='1')
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn('simulator did not finish booting', result.stderr)
        self.assertFalse(any(command and command[0] == 'xcodebuild' for command in self.commands))

    def test_other_platform_destination_does_not_boot_an_ios_simulator(self):
        result = self.run_script(IOS_TEST_DESTINATION='platform=macOS,id=host-test')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any(command[:2] == ['simctl', 'bootstatus'] for command in self.commands))

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

    def test_ui_diagnostics_wrap_the_complete_command_and_force_one_simulator(self):
        scripts = self.root / '.github/scripts'
        scripts.mkdir(parents=True)
        (scripts / 'collect_ui_wait_diagnostics.py').write_text(
            "import json, os, subprocess, sys\n"
            "from pathlib import Path\n"
            "Path(os.environ['TEST_ROOT'] + '/diagnostics.json').write_text(json.dumps(sys.argv[1:]))\n"
            "raise SystemExit(subprocess.call(sys.argv[sys.argv.index('--') + 1:]))\n")
        result = self.run_script('ui', IOS_TEST_ACTION='test-without-building', IOS_TEST_PREPARED='1',
                                 IOS_TEST_SCHEME='EncryptedMemoriesMobileCI',
                                 IOS_TEST_DIAGNOSTICS_PATH=str(self.root / 'diagnostics'))
        self.assertEqual(result.returncode, 0, result.stderr)
        arguments = json.loads((self.root / 'diagnostics.json').read_text())
        self.assertEqual(arguments[arguments.index('--simulator') + 1], 'simulator-test')
        self.assertEqual(arguments[arguments.index('--output') + 1], str(self.root / 'diagnostics'))
        self.assertIn('-only-testing:EncryptedMemoriesMobileUITests', self.commands[-1])
        self.assertEqual(self.commands[-1][self.commands[-1].index('-parallel-testing-enabled') + 1], 'NO')

    def test_diagnostics_reject_parallel_clones_and_unknown_destination_ownership(self):
        for options in [{'IOS_TEST_PARALLEL_WORKERS': '2'},
                        {'IOS_TEST_DESTINATION': 'generic/platform=iOS Simulator'},
                        {'IOS_TEST_DESTINATION': 'platform=macOS,id=host-test'}]:
            with self.subTest(options=options):
                result = self.run_script('ui', IOS_TEST_PREPARED='1',
                                         IOS_TEST_DIAGNOSTICS_PATH=str(self.root / 'diagnostics'), **options)
                self.assertEqual(result.returncode, 64)
                self.assertIn('diagnostics require one simulator', result.stderr)
                self.assertFalse(any(command and command[0] == 'xcodebuild' for command in self.commands))


if __name__ == '__main__':
    unittest.main()
