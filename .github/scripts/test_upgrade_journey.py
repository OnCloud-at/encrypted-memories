#!/usr/bin/env python3
"""Exercise the loopback oracle and the fail-closed upgrade journey."""
import json
import plistlib
from pathlib import Path
import sys
import subprocess
import tempfile
import tarfile
import io
import unittest
from unittest.mock import patch
import signal
import os
import uuid
import select
import time
from contextlib import nullcontext

from urllib.request import Request, urlopen

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'scripts/upgrade-test'))
from build_apps import apply_overlay, Build
from journey import JourneyError, run_cases
from server import FixtureServer
import run_journey


class UpgradeJourneyTests(unittest.TestCase):
    @unittest.skipUnless(sys.platform == 'darwin', 'Native Settings controls require macOS')
    def test_native_macos_settings_pane_retries_only_unacknowledged_clicks(self):
        repo = Path(__file__).resolve().parents[2]
        scratch = Path(os.environ.get('ENCRYPTED_MEMORIES_BUILD_ROOT',
            str(Path.home() / 'Developer/xcode/EncryptedMemories'))) / 'UpgradeSettings'
        scratch.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=scratch) as temporary:
            root = Path(temporary)
            main = root / 'main.swift'
            main.write_text(r"""
for pane in ["Backup", "Smart Search"] {
    for dropped in 0...2 {
        var clicks = 0
        var acknowledged = false
        var success = false
        do {
            try SettingsPaneTestSupport.select(pane, click: {
                clicks += 1
                if clicks > dropped { acknowledged = true }
            }, isAcknowledged: { acknowledged }, waitForAcknowledgement: { acknowledged })
            success = true
        } catch SettingsPaneTestError.notAcknowledged(let name) {
            precondition(name == pane)
            precondition(String(describing: SettingsPaneTestError.notAcknowledged(name))
                == "Settings did not select the \(pane) pane after two clicks")
        } catch {
            fatalError("Unexpected Settings control error: \(error)")
        }
        print("\(pane)|\(dropped)|\(clicks)|\(success)")
    }
    var clicks = 0
    var checks = 0
    var success = false
    do {
        try SettingsPaneTestSupport.select(pane, click: { clicks += 1 }, isAcknowledged: {
            checks += 1
            return true
        }, waitForAcknowledgement: { false })
        success = true
    } catch SettingsPaneTestError.notAcknowledged(let name) {
        precondition(name == pane)
    } catch {
        fatalError("Unexpected Settings control error: \(error)")
    }
    print("\(pane)|late|\(clicks)|\(checks)|\(success)")
}
""")
            binary = root / 'settings-controls'
            subprocess.run(['xcrun', 'swiftc', '-O',
                str(repo / 'scripts/upgrade-test/UITests/SettingsPaneTestSupport.swift'),
                str(main), '-o', str(binary)], check=True, capture_output=True, text=True)
            result = subprocess.run([str(binary)], check=True, capture_output=True, text=True)
            rows = [line.split('|') for line in result.stdout.splitlines()]
            expected = []
            for pane in ['Backup', 'Smart Search']:
                expected.extend([[pane, '0', '1', 'true'], [pane, '1', '2', 'true'],
                                 [pane, '2', '2', 'false'], [pane, 'late', '1', '1', 'true']])
            self.assertEqual(len(rows), len(expected))
            for actual, wanted in zip(rows, expected):
                with self.subTest(pane=wanted[0], dropped=wanted[1]):
                    self.assertEqual(actual, wanted)

    def test_repeated_cancellation_does_not_interrupt_owned_cleanup(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            marker = root / 'owned-resource'
            marker.touch()
            script = """
import signal, sys, subprocess, os
from pathlib import Path
sys.path.insert(0, sys.argv[1])
from run_journey import terminate
signal.signal(signal.SIGTERM, terminate)
signal.signal(signal.SIGINT, terminate)
try:
    print('ready', flush=True)
    sys.stdin.readline()
finally:
    print('cleanup', flush=True)
    sys.stdin.readline()
    Path(sys.argv[2]).unlink()
    child = subprocess.run(['/bin/sh', '-c', 'kill -TERM $$'])
    if child.returncode != -signal.SIGTERM:
        Path(sys.argv[2]).touch()
"""
            with (root / 'cancel.log').open('w') as log:
                process = subprocess.Popen([sys.executable, '-c', script,
                    str(Path(__file__).resolve().parents[2] / 'scripts/upgrade-test'), str(marker)],
                    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log,
                    text=True, start_new_session=True)
                try:
                    self.assertEqual(process.stdout.readline().strip(), 'ready')
                    os.killpg(process.pid, signal.SIGTERM)
                    self.assertEqual(process.stdout.readline().strip(), 'cleanup')
                    os.killpg(process.pid, signal.SIGINT)
                    process.stdin.write('finish cleanup\n')
                    process.stdin.flush()
                    self.assertNotEqual(process.wait(timeout=5), 0, 'Cancellation must remain a failed run')
                    self.assertFalse(marker.exists(), 'Repeated cancellation interrupted owned resource cleanup')
                finally:
                    run_journey.stop_group(process)
                    process.stdin.close()
                    process.stdout.close()

    @unittest.skipUnless(os.environ.get('UPGRADE_NATIVE_PROBES') == '1', 'Native cleanup is opt-in')
    def test_native_cancellation_removes_owned_simulator_and_signing_identity(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            script = """
import json, os, signal, sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
from run_journey import InstalledApp, SigningIdentity, terminate
ready = os.fdopen(os.dup(sys.stdout.fileno()), 'w')
os.dup2(sys.stderr.fileno(), sys.stdout.fileno())
signal.signal(signal.SIGTERM, terminate)
signal.signal(signal.SIGINT, terminate)
root = Path(sys.argv[2])
with SigningIdentity(root) as signer:
    app = InstalledApp('iOS', root, signer)
    try:
        print(json.dumps({'simulator': app.simulator, 'directory': str(signer.directory)}), file=ready, flush=True)
        sys.stdin.readline()
    finally:
        print('cleanup', file=ready, flush=True)
        sys.stdin.readline()
        app.close()
"""
            def line(process):
                self.assertTrue(select.select([process.stdout], [], [], 120)[0], 'Native cleanup probe timed out')
                return process.stdout.readline().strip()
            with (root / 'native-cancel.log').open('w') as log:
                process = subprocess.Popen([sys.executable, '-c', script,
                    str(Path(__file__).resolve().parents[2] / 'scripts/upgrade-test'), str(root)],
                    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log,
                    text=True, start_new_session=True, env=run_journey.clean_environment())
                try:
                    resources = json.loads(line(process))
                    os.killpg(process.pid, signal.SIGINT)
                    self.assertEqual(line(process), 'cleanup')
                    os.killpg(process.pid, signal.SIGTERM)
                    process.stdin.write('finish cleanup\n')
                    process.stdin.flush()
                    self.assertNotEqual(process.wait(timeout=30), 0)
                    self.assertFalse(Path(resources['directory']).exists())
                    devices = json.loads(run_journey.output(['xcrun', 'simctl', 'list', 'devices', '--json']))['devices']
                    self.assertFalse(any(device['udid'] == resources['simulator'] for group in devices.values() for device in group))
                    print('PASS: repeated cancellation removed only the owned simulator and temporary signing identity', flush=True)
                finally:
                    run_journey.stop_group(process)
                    process.stdin.close()
                    process.stdout.close()

    def test_backup_consent_waits_for_delayed_flush_without_changing_preferences(self):
        with tempfile.TemporaryDirectory() as root:
            preferences = Path(root) / 'preferences.plist'
            preferences.write_bytes(plistlib.dumps({'unrelated': True}))
            flushed = plistlib.dumps({'unrelated': True, 'photoBackup.enabled.v1': True})
            with patch('time.monotonic', side_effect=[0, 0.2]), patch('time.sleep', side_effect=lambda _: preferences.write_bytes(flushed)) as pause:
                self.assertIs(run_journey.wait_saved_backup_consent(preferences, deadline=1), True)
            pause.assert_called_once()
            self.assertEqual(preferences.read_bytes(), flushed)

    def test_backup_consent_requires_the_exact_saved_true_key_within_the_existing_budget(self):
        for values in [{'unrelated': True}, {'photoBackup.enabled.v1': False}, {'photoBackup.enabled.v1': 1}]:
            with self.subTest(values=values), tempfile.TemporaryDirectory() as root:
                preferences = Path(root) / 'preferences.plist'
                original = plistlib.dumps(values)
                preferences.write_bytes(original)
                with patch('time.monotonic', return_value=1), patch('time.sleep') as pause:
                    with self.assertRaisesRegex(JourneyError, 'saved backup consent'):
                        run_journey.wait_saved_backup_consent(preferences, deadline=1)
                pause.assert_not_called()
                self.assertEqual(preferences.read_bytes(), original)

    def test_unreadable_backup_preferences_fail_without_waiting_or_repair(self):
        with tempfile.TemporaryDirectory() as root:
            preferences = Path(root) / 'preferences.plist'
            preferences.write_bytes(b'not a plist')
            with patch('time.sleep') as pause:
                with self.assertRaisesRegex(JourneyError, 'Unreadable backup preferences'):
                    run_journey.wait_saved_backup_consent(preferences, deadline=1)
            pause.assert_not_called()
            self.assertEqual(preferences.read_bytes(), b'not a plist')

    def test_install_over_must_retain_the_actually_saved_backup_consent(self):
        with tempfile.TemporaryDirectory() as root:
            preferences = Path(root) / 'preferences.plist'
            preferences.write_bytes(plistlib.dumps({'photoBackup.enabled.v1': True}))
            baseline = run_journey.wait_saved_backup_consent(preferences, deadline=0)
            run_journey.verify_saved_backup_consent(preferences, baseline)
            for values in [{}, {'photoBackup.enabled.v1': False}]:
                preferences.write_bytes(plistlib.dumps(values))
                with self.assertRaisesRegex(JourneyError, 'Saved backup consent changed'):
                    run_journey.verify_saved_backup_consent(preferences, baseline)

    def test_standalone_ui_runner_does_not_inherit_app_hardening(self):
        repo = Path(__file__).resolve().parents[2]
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            source = root / 'scratch/source'
            (source / 'UpgradeUITests').mkdir(parents=True)
            products = source.parent / 'build/DerivedData.noindex/Build/Products'
            products.mkdir(parents=True)
            (products / 'runner.xctestrun').touch()
            build = Build(root / 'fixture.app', source)
            arguments = ['run_journey', '--repo', str(repo), '--automation', str(repo),
                         '--root', str(root), '--target', 'HEAD', '--sources', 'v1.0.5', '--platform', 'macOS']
            with patch.object(sys, 'argv', arguments), patch.object(run_journey, 'build_app', return_value=build), \
                    patch('keychain_entitlements.snapshot', return_value={}), \
                    patch.object(run_journey, 'SigningIdentity'), patch.object(run_journey, 'run_cases'), \
                    patch.object(run_journey, 'output', return_value='arm64'), \
                    patch.object(run_journey, 'command') as command:
                run_journey.main()
            toolchain = next((root / 'evidence').glob('*/toolchain.json'))
            self.assertEqual(json.loads(toolchain.read_text()), {'xcode': 'arm64', 'platform': 'macOS', 'target': 'HEAD'})
            command.assert_any_call(['xcrun', 'swift', str(repo / 'scripts/upgrade-test/metal_devices.swift')])
            invocation = command.call_args.args[0]
            self.assertEqual(invocation[:3], ['xcrun', 'xcodebuild', 'build-for-testing'])
            self.assertIn('UpgradeJourney', invocation)
            self.assertIn('ENABLE_HARDENED_RUNTIME=NO', invocation)

    def test_macos_launch_passes_the_same_case_to_the_ui_runner_without_a_second_launcher(self):
        with tempfile.TemporaryDirectory() as root:
            app = run_journey.InstalledApp('macOS', Path(root))
            app.installed = Path(root) / 'installed.app'
            (app.installed / 'Contents').mkdir(parents=True)
            (app.installed / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable': 'Fixture'}))
            with patch.object(run_journey, 'owned_process') as launch:
                app.launch(type('Server', (), {'url': 'http://127.0.0.1:1234'})(), seed=True)
                launch.assert_not_called()
            self.assertIn(app.case_id, app.launch_arguments)
            self.assertIn('-EncryptedMemoriesUpgradeSeed', app.launch_arguments)
            app.launch(type('Server', (), {'url': 'http://127.0.0.1:1234'})())
            self.assertIn(app.case_id, app.launch_arguments)
            self.assertNotIn('-EncryptedMemoriesUpgradeSeed', app.launch_arguments)

    def test_macos_kill_requires_one_process_from_the_exact_owned_app_bundle(self):
        with tempfile.TemporaryDirectory() as root:
            app = run_journey.InstalledApp('macOS', Path(root))
            app.installed = Path(root) / 'installed.app'
            (app.installed / 'Contents').mkdir(parents=True)
            (app.installed / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable': 'Fixture'}))
            binary = str(app.installed / 'Contents/MacOS/Fixture')
            for processes in ['', '99 /foreign/Fixture', '41 ' + binary + '\n42 ' + binary]:
                with patch.object(run_journey, 'output', return_value=processes), patch.object(run_journey.os, 'kill') as kill:
                    with self.assertRaises(JourneyError):
                        app.kill_app()
                    kill.assert_not_called()
            with patch.object(run_journey, 'output', return_value='99 /foreign/Fixture\n42 ' + binary), \
                    patch.object(run_journey.os, 'kill') as kill:
                app.kill_app()
                kill.assert_called_once_with(42, signal.SIGKILL)

    def test_ui_runner_receives_the_owned_application_arguments(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            runner = root / 'runner.xctestrun'
            runner.write_bytes(plistlib.dumps({'Tests': {'IsUITestBundle': True}}))
            arguments = ['-EncryptedMemoriesUITestFixture', '-EncryptedMemoriesUpgradeCase', 'a' * 32]
            with patch.object(run_journey, 'owned_process'):
                process, log = run_journey.ui_run(runner, 'platform=macOS', 'backup.claimed', 'prepare',
                                                 root, root / 'installed.app', launch_arguments=arguments)
                log.close()
            configured = plistlib.loads((root / 'prepare.xctestrun').read_bytes())
            environment = configured['Tests']['EnvironmentVariables']
            self.assertEqual(json.loads(environment['UPGRADE_APP_ARGUMENTS']), arguments)

    def test_simulator_preparation_uses_screenshots_when_its_ui_group_is_interrupted(self):
        for destination, phase, capture in [
            ('platform=iOS Simulator,id=OWN-DEVICE', 'prepare', 'screenshots'),
            ('platform=iOS Simulator,id=OWN-DEVICE', 'verify', 'screenRecording'),
            ('platform=macOS', 'prepare', 'screenRecording'),
        ]:
            with self.subTest(destination=destination, phase=phase), tempfile.TemporaryDirectory() as root:
                root = Path(root)
                runner = root / 'runner.xctestrun'
                runner.write_bytes(plistlib.dumps({'TestConfigurations': [{'TestTargets': [
                    {'IsUITestBundle': True, 'PreferredScreenCaptureFormat': 'screenRecording'},
                    {'IsUITestBundle': False},
                ]}]}))
                with patch.object(run_journey, 'owned_process'):
                    _, log = run_journey.ui_run(runner, destination, 'backup.claimed', phase, root)
                    log.close()
                configured = plistlib.loads((root / (phase + '.xctestrun')).read_bytes())
                ui, unit = configured['TestConfigurations'][0]['TestTargets']
                self.assertEqual(ui['PreferredScreenCaptureFormat'], capture)
                self.assertNotIn('PreferredScreenCaptureFormat', unit)
                self.assertEqual(ui['EnvironmentVariables']['UPGRADE_POINT'], 'backup.claimed')
                self.assertEqual(ui['EnvironmentVariables']['UPGRADE_PHASE'], phase)

    @unittest.skipUnless(os.environ.get('UPGRADE_NATIVE_PROBES') == '1', 'Native signing and checkpoint probes are opt-in')
    def test_temporary_identity_signs_both_installations_and_is_removed(self):
        import shutil
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            with run_journey.SigningIdentity(root) as signer:
                directory = signer.directory
                requirements = []
                for name in ['old', 'new']:
                    installation = root / name
                    installation.mkdir()
                    executable = installation / 'fixture'
                    shutil.copyfile('/bin/echo', executable)
                    executable.chmod(0o755)
                    signer.sign(executable)
                    result = subprocess.run(['codesign', '-d', '-r-', str(executable)],
                                            capture_output=True, text=True, check=True)
                    requirement = result.stdout + result.stderr
                    self.assertIn('designated => ', requirement)
                    requirements.append(requirement.split('designated => ', 1)[1].splitlines()[0])
                self.assertEqual(*requirements)
            self.assertFalse(directory.exists())

    @unittest.skipUnless(os.environ.get('UPGRADE_NATIVE_PROBES') == '1', 'Native signing and checkpoint probes are opt-in')
    def test_native_checkpoint_stays_held_through_the_preparation_budget(self):
        repo = Path(__file__).resolve().parents[2]
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            # Only the unused identifier dependency is a stand-in. The compiled checkpoint is the actual source.
            main = root / 'main.swift'
            main.write_text('public struct PhotoUID { public init(volumeID: String, nodeID: String) {} }\n'
                            'UpgradeTestProbe.checkpoint("backup.claimed")\n')
            binary = root / 'checkpoint'
            subprocess.run(['xcrun', 'swiftc', '-O', '-D', 'ENCRYPTED_MEMORIES_UPGRADE_TEST',
                            str(repo / 'Packages/EncryptedMemoriesKit/Sources/PhotosCore/UpgradeTestProbe.swift'),
                            str(main), '-o', str(binary)], check=True)
            with FixtureServer(root, 'backup.claimed') as server, (root / 'app.log').open('w') as log:
                process = run_journey.owned_process([str(binary), '-EncryptedMemoriesUITestFixture',
                    '-EncryptedMemoriesUpgradeServer', server.url], log)
                try:
                    server.wait_checkpoint(timeout=10, preparing=process)
                    with self.assertRaises(subprocess.TimeoutExpired):
                        process.wait(timeout=185)
                    server.begin_upgrade()
                    self.assertEqual(process.wait(timeout=10), 0)
                finally:
                    server.begin_upgrade()
                    run_journey.stop_group(process)

    def test_simulator_kill_refuses_a_foreign_process(self):
        app = run_journey.InstalledApp.__new__(run_journey.InstalledApp)
        app.simulator = 'OWN-DEVICE'
        app.app_pid = 42
        with patch.object(run_journey, 'output', side_effect=[
            '/devices/OWN-DEVICE/data/Application/own.app',
            '/devices/FOREIGN-DEVICE/data/Application/foreign.app/App',
        ]), patch.object(run_journey.os, 'kill') as kill, patch.object(run_journey, 'command'):
            with self.assertRaisesRegex(JourneyError, 'owned Simulator'):
                app.kill_app()
            kill.assert_not_called()

    def test_owned_simulator_journey_preserves_a_foreign_booted_device(self):
        devices = {'FOREIGN-DEVICE': 'Booted'}
        operations = []
        def output(args):
            operation = args[2] if args[:2] == ['xcrun', 'simctl'] else 'ps'
            if operation == 'list':
                if args[3] == 'runtimes':
                    return json.dumps({'runtimes': [
                        {'isAvailable': True, 'identifier': 'com.apple.CoreSimulator.SimRuntime.iOS-27-1', 'version': '27.1'},
                        {'isAvailable': True, 'identifier': 'com.apple.CoreSimulator.SimRuntime.iOS-27-0', 'version': '27.0'},
                    ]})
                return json.dumps({'devicetypes': [{'name': 'iPhone 17', 'identifier': 'phone'}]})
            if operation == 'create':
                self.assertRegex(args[3], r'^EncryptedMemoriesUpgrade-[a-f0-9]{32}$')
                self.assertEqual(args[-1], 'com.apple.CoreSimulator.SimRuntime.iOS-27-0')
                devices['OWN-DEVICE'] = 'Shutdown'
                return 'OWN-DEVICE'
            self.assertEqual(args[3], 'OWN-DEVICE') if operation != 'ps' else None
            if operation == 'launch':
                return run_journey.BUNDLE + ': 42'
            if operation == 'get_app_container':
                return '/devices/OWN-DEVICE/data/Application/own.app'
            if operation == 'ps':
                return '/devices/OWN-DEVICE/data/Application/own.app/App'
            raise AssertionError(args)
        def command(args):
            operations.append(args)
            self.assertEqual(args[:2], ['xcrun', 'simctl'])
            self.assertEqual(args[3], 'OWN-DEVICE')
            if args[2] == 'boot':
                devices['OWN-DEVICE'] = 'Booted'
            elif args[2] == 'shutdown':
                devices['OWN-DEVICE'] = 'Shutdown'
            elif args[2] == 'delete':
                del devices['OWN-DEVICE']
        with tempfile.TemporaryDirectory() as directory, patch.object(run_journey, 'output', side_effect=output), \
                patch.object(run_journey, 'command', side_effect=command), patch.object(run_journey.os, 'kill') as kill:
            app = run_journey.InstalledApp('iOS', Path(directory))
            runtime = json.loads((Path(directory) / 'simulator-runtime.json').read_text())
            self.assertEqual(runtime['identifier'], 'com.apple.CoreSimulator.SimRuntime.iOS-27-0')
            self.assertEqual(runtime['version'], '27.0')
            self.assertEqual(app.destination, 'platform=iOS Simulator,id=OWN-DEVICE')
            app.install(Path('/old.app'))
            app.launch(type('Server', (), {'url': 'http://127.0.0.1:1234'})(), seed=True)
            app.kill_app()
            app.install(Path('/new.app'))
            app.close()
            kill.assert_called_once_with(42, signal.SIGKILL)
        self.assertEqual(devices, {'FOREIGN-DEVICE': 'Booted'})
        self.assertEqual([args[2] for args in operations], ['boot', 'bootstatus', 'install', 'install', 'shutdown', 'delete'])

    def test_ambiguous_selected_runtime_fails_before_creating_a_simulator(self):
        runtimes = {'runtimes': [
            {'isAvailable': True, 'identifier': 'com.apple.CoreSimulator.SimRuntime.iOS-27-0', 'version': '27.0', 'buildversion': build}
            for build in ['first', 'second']
        ]}
        replies = [json.dumps(runtimes), json.dumps({'devicetypes': [{'name': 'iPhone 17', 'identifier': 'phone'}]}), 'OWN-DEVICE']
        with tempfile.TemporaryDirectory() as root, patch.object(run_journey, 'output', side_effect=replies) as output, \
                patch.object(run_journey, 'command'):
            with self.assertRaisesRegex(JourneyError, 'Ambiguous Simulator runtime identifier: com.apple.CoreSimulator.SimRuntime.iOS-27-0'):
                run_journey.InstalledApp('iOS', Path(root))
            self.assertFalse(any(call.args[0][2] == 'create' for call in output.call_args_list))

    def test_boot_failure_still_deletes_only_the_owned_simulator(self):
        replies = [json.dumps({'runtimes': [{'isAvailable': True, 'identifier':
            'com.apple.CoreSimulator.SimRuntime.iOS-27-0', 'version': '27.0'}]}),
            json.dumps({'devicetypes': [{'name': 'iPhone 17', 'identifier': 'phone'}]}), 'OWN-DEVICE']
        with tempfile.TemporaryDirectory() as directory, patch.object(run_journey, 'output', side_effect=replies), \
                patch.object(run_journey, 'command', side_effect=[JourneyError('boot failed'), None, None]) as command:
            with self.assertRaisesRegex(JourneyError, 'boot failed'):
                run_journey.InstalledApp('iOS', Path(directory))
            self.assertEqual(command.call_args_list[-1].args[0], ['xcrun', 'simctl', 'delete', 'OWN-DEVICE'])

    @unittest.skipUnless(os.environ.get('UPGRADE_NATIVE_TARGET'), 'Native install-over rehearsal is opt-in')
    def test_native_journey_keeps_another_booted_simulator(self):
        sentinel = run_journey.output(['xcrun', 'simctl', 'create',
            'EncryptedMemoriesUpgradeIsolation-' + uuid.uuid4().hex,
            'com.apple.CoreSimulator.SimDeviceType.iPhone-17',
            'com.apple.CoreSimulator.SimRuntime.iOS-27-0'])
        try:
            run_journey.command(['xcrun', 'simctl', 'boot', sentinel])
            run_journey.command(['xcrun', 'simctl', 'bootstatus', sentinel, '-b'])
            home = Path(run_journey.output(['xcrun', 'simctl', 'getenv', sentinel, 'HOME']))
            self.assertIn(sentinel, home.parts)
            marker = home / 'tmp' / ('upgrade-isolation-' + uuid.uuid4().hex)
            marker.write_bytes(b'separate booted device remains unchanged')
            repo = Path(__file__).resolve().parents[2]
            args = ['bash', str(repo / 'scripts/test-release-upgrade.sh'), '--target',
                    os.environ['UPGRADE_NATIVE_TARGET'], '--sources', 'v1.0.5', '--platform', 'iOS']
            if os.environ.get('UPGRADE_NATIVE_WORKING_COPY') == '1':
                args.append('--working-copy')
            run_journey.command(args, cwd=repo)
            devices = json.loads(run_journey.output(['xcrun', 'simctl', 'list', 'devices', '--json']))['devices']
            observed = next(device for group in devices.values() for device in group if device['udid'] == sentinel)
            self.assertEqual(observed['state'], 'Booted')
            self.assertEqual(marker.read_bytes(), b'separate booted device remains unchanged')
            print('PASS: separate booted Simulator and its data survived the complete iOS journey', flush=True)
        finally:
            try:
                run_journey.command(['xcrun', 'simctl', 'shutdown', sentinel])
            finally:
                run_journey.command(['xcrun', 'simctl', 'delete', sentinel])

    def test_native_query_control_restores_handlers_after_owned_group_cancellation(self):
        with tempfile.TemporaryDirectory() as root:
            marker = Path(root) / 'owned-resource'
            marker.touch()
            script = """
import os, signal, sys
from pathlib import Path
from unittest.mock import patch
os.environ['UPGRADE_NATIVE_QUERY_TARGET'] = 'HEAD'
sys.path.insert(0, sys.argv[1])
from test_upgrade_journey import UpgradeJourneyTests
import run_journey
original = {value: signal.getsignal(value) for value in [signal.SIGINT, signal.SIGTERM]}
marker = Path(sys.argv[2])
def cancelled_main():
    try:
        os.killpg(os.getpid(), signal.SIGTERM)
    finally:
        marker.unlink()
try:
    with patch.object(run_journey, 'main', cancelled_main):
        UpgradeJourneyTests().test_native_pending_query_cannot_pass_with_the_retained_library()
except KeyboardInterrupt:
    assert not marker.exists()
    assert all(signal.getsignal(value) == handler for value, handler in original.items())
else:
    raise AssertionError('Cancellation did not propagate')
"""
            result = subprocess.run([sys.executable, '-c', script, str(Path(__file__).resolve().parent), str(marker)],
                                    start_new_session=True, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse(marker.exists(), 'Owned cancellation interrupted cleanup')

    @unittest.skipUnless(os.environ.get('UPGRADE_NATIVE_QUERY_TARGET'), 'Native pending-query control is opt-in')
    def test_native_pending_query_cannot_pass_with_the_retained_library(self):
        servers = []

        class PendingQueryServer(FixtureServer):
            def __init__(self, *args):
                super().__init__(*args)
                servers.append(self)

            def begin_upgrade(self):
                super().begin_upgrade()
                with self.lock:
                    self.point = 'query.encoded'
                    self.hold_phase = 'new'
                    self.release.clear()

        repo = Path(__file__).resolve().parents[2]
        root = Path(os.environ.get('ENCRYPTED_MEMORIES_BUILD_ROOT',
                    str(Path.home() / 'Developer/xcode/EncryptedMemories'))) / 'UpgradeCheck'
        argv = ['run_journey.py', '--repo', str(repo), '--automation', str(repo), '--root', str(root),
                '--target', os.environ['UPGRADE_NATIVE_QUERY_TARGET'], '--sources', 'v1.0.5',
                '--platform', os.environ.get('UPGRADE_NATIVE_QUERY_PLATFORM', 'macOS'),
                '--points', 'model.partial']
        if os.environ.get('UPGRADE_NATIVE_WORKING_COPY') == '1':
            argv.append('--working-copy')
        owned_process = run_journey.owned_process

        def installed_journey_only(args, *remaining, **kwargs):
            # Keep the negative control independent of the standalone oracle's unit tests.
            return owned_process(args + [
                '-only-testing:UpgradeJourneyUITests/UpgradeJourneyUITests/testInstalledAppJourney'],
                *remaining, **kwargs)

        handlers = {value: signal.getsignal(value) for value in [signal.SIGINT, signal.SIGTERM]}
        try:
            for value in handlers:
                signal.signal(value, run_journey.terminate)
            with patch.object(run_journey, 'FixtureServer', PendingQueryServer), \
                    patch.object(run_journey, 'owned_process', installed_journey_only), patch.object(sys, 'argv', argv):
                with self.assertRaisesRegex(JourneyError, 'UI verification failed'):
                    run_journey.main()
        finally:
            for value, handler in handlers.items():
                signal.signal(value, handler)
        self.assertEqual(len(servers), 1)
        self.assertTrue(any(request['phase'] == 'new' and request['path'] == '/checkpoint/query.encoded'
                            for request in servers[0].requests), 'The negative control never held a real query')
        ui_log = (servers[0].directory / 'verify-ui.log').read_text()
        self.assertIn('The saved index did not return all eight photos', ui_log)
        print('PASS: a held native query cannot use the eight retained library elements', flush=True)

    @unittest.skipUnless(os.environ.get('UPGRADE_NATIVE_SEED_TARGET'), 'Native seed regression is opt-in')
    def test_native_seed_identity_survives_restarts_and_reseeds_changed_cases_or_servers(self):
        handlers = {value: signal.getsignal(value) for value in [signal.SIGINT, signal.SIGTERM]}
        try:
            for value in handlers:
                signal.signal(value, run_journey.terminate)
            from build_apps import build_app
            repo = Path(__file__).resolve().parents[2]
            root = Path(os.environ.get('ENCRYPTED_MEMORIES_BUILD_ROOT',
                        str(Path.home() / 'Developer/xcode/EncryptedMemories'))) / 'UpgradeCheck'
            (root / 'scratch').mkdir(parents=True, exist_ok=True)
            evidence = root / 'evidence' / uuid.uuid4().hex
            evidence.mkdir(parents=True)
            platform = os.environ.get('UPGRADE_NATIVE_SEED_PLATFORM', 'macOS')
            (evidence / 'toolchain.json').write_text(json.dumps({
                'xcode': run_journey.output(['xcodebuild', '-version']), 'platform': platform}) + '\n')
            target = os.environ['UPGRADE_NATIVE_SEED_TARGET']
            for tag in [target, 'v1.0.5']:
                with self.subTest(tag=tag):
                    build = build_app(repo, repo, tag, platform, root,
                        working_copy=tag == target and os.environ.get('UPGRADE_NATIVE_WORKING_COPY') == '1')
                    case = evidence / platform / tag
                    case.mkdir(parents=True)
                    identity = run_journey.SigningIdentity(root) if platform == 'macOS' else nullcontext()
                    with identity as signer, FixtureServer(case / 'server', 'session.loaded') as server:
                        app = run_journey.InstalledApp(platform, case, signer)
                        try:
                            app.install(build.app)
                            def session_file():
                                return app.preferences_path.parents[2] / 'Library/Application Support/EncryptedMemories' / (
                                    'upgrade-fixture-account-' + app.case_id) / 'upgrade-fixture-session.json'

                            def launch(endpoint, seed=True):
                                endpoint.reached.clear()
                                endpoint.release.clear()
                                app.launch(endpoint, seed=seed)
                                expected = {'server': endpoint.url, 'account': 'upgrade-fixture-account-' + app.case_id}
                                process, log = None, None
                                if platform == 'macOS':
                                    info = plistlib.loads((app.installed / 'Contents/Info.plist').read_bytes())
                                    binary = app.installed / 'Contents/MacOS' / info['CFBundleExecutable']
                                    log = (case / (uuid.uuid4().hex + '.log')).open('w')
                                    process = run_journey.owned_process([str(binary), *app.launch_arguments], log)
                                try:
                                    endpoint.wait_checkpoint(timeout=20)
                                    # Read the app's own flush before interruption. Never repair its marker here.
                                    deadline = time.monotonic() + 20
                                    while True:
                                        try:
                                            marker = plistlib.loads(app.preferences_path.read_bytes()).get('upgrade.fixture.seeded')
                                        except FileNotFoundError:
                                            marker = None
                                        if marker == expected:
                                            break
                                        if time.monotonic() >= deadline:
                                            self.fail('The case/server seed marker did not reach the owned preferences file')
                                        time.sleep(0.2)
                                    (case / (uuid.uuid4().hex + '-marker.json')).write_text(json.dumps(marker) + '\n')
                                finally:
                                    if process is not None:
                                        if process.poll() is None:
                                            process.terminate()
                                        try:
                                            process.wait(timeout=10)
                                        except subprocess.TimeoutExpired:
                                            if process.poll() is None:
                                                process.kill()
                                            process.wait(timeout=10)
                                    else:
                                        app.kill_app()
                                    if log:
                                        log.close()
                                    endpoint.release.set()

                            if platform == 'iOS':
                                # A fresh owned device has never loaded this preference domain.
                                preferences = app.preferences_path
                                preferences.parent.mkdir(parents=True, exist_ok=True)
                                preferences.write_bytes(plistlib.dumps({'upgrade.fixture.seeded': server.url}))
                                self.assertEqual(plistlib.loads(preferences.read_bytes())['upgrade.fixture.seeded'], server.url)
                            launch(server)
                            first = app.case_id
                            app.case_id = uuid.uuid4().hex
                            self.assertNotEqual(first, app.case_id)
                            launch(server)  # Same port, different case: the original regression.
                            if platform == 'macOS':
                                path = session_file()
                                retained = json.loads(path.read_text())
                                retained['accessToken'] = 'synthetic-retained-access'
                                path.write_text(json.dumps(retained))
                            launch(server)
                            launch(server, seed=False)
                            if platform == 'macOS':
                                self.assertEqual(json.loads(path.read_text()), retained, 'An unchanged identity reseeded the session')

                            with FixtureServer(case / 'changed-server', 'session.loaded') as other:
                                self.assertNotEqual(server.url, other.url)
                                launch(other)  # Same case, different server.
                                if platform == 'macOS':
                                    self.assertEqual(json.loads(path.read_text())['accessToken'], 'synthetic-access',
                                                     'A changed server did not reseed the session')
                        finally:
                            if platform == 'iOS':
                                app.close()
                    print('PASS: native case/server reseeding and unchanged restart: ' + platform + ' / ' + tag, flush=True)
        finally:
            for value, handler in handlers.items():
                signal.signal(value, handler)

    @unittest.skipUnless(os.environ.get('UPGRADE_NATIVE_PROBES') == '1', 'Native identifier validation is opt-in')
    def test_native_case_identifier_accepts_only_exactly_32_ascii_hex_characters(self):
        repo = Path(__file__).resolve().parents[2]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            main = root / 'main.swift'
            # PhotoUID is unused by this probe; identity validation uses the real compiled source.
            main.write_text('public struct PhotoUID { public init(volumeID: String, nodeID: String) {} }\n'
                            'print(UpgradeTestProbe.accountUID)\n')
            binary = root / 'identity'
            subprocess.run(['xcrun', 'swiftc', '-O', '-D', 'ENCRYPTED_MEMORIES_UPGRADE_TEST',
                str(repo / 'Packages/EncryptedMemoriesKit/Sources/PhotosCore/UpgradeTestProbe.swift'),
                str(main), '-o', str(binary)], check=True, env=run_journey.clean_environment())
            for identifier in ['0123456789abcdef' * 2, '0123456789ABCDEF' * 2]:
                result = subprocess.run([str(binary), '-EncryptedMemoriesUpgradeCase', identifier],
                    capture_output=True, text=True, env=run_journey.clean_environment())
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), 'upgrade-fixture-account-' + identifier)
            for arguments in [[], ['-EncryptedMemoriesUpgradeCase']] + [
                ['-EncryptedMemoriesUpgradeCase', value]
                for value in ['', 'a' * 31, 'a' * 33, 'g' * 32, '../' + 'a' * 29, 'Ａ' * 32, 'a' * 31 + '\n']
            ]:
                result = subprocess.run([str(binary), *arguments], capture_output=True, text=True,
                    env=run_journey.clean_environment())
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('exactly 32 ASCII hexadecimal characters', result.stderr)

    def test_historical_overlays_apply_to_the_exact_published_tag(self):
        repo = Path(__file__).resolve().parents[2]
        overlay = repo / 'scripts/upgrade-test/overlays'
        for tag, metadata in json.loads((overlay / 'versions.json').read_text()).items():
            with self.subTest(tag=tag), tempfile.TemporaryDirectory() as root:
                sha = subprocess.check_output(['git', 'rev-parse', tag + '^{commit}'], cwd=repo, text=True).strip()
                self.assertEqual(sha, metadata['commit'])
                archive = subprocess.check_output(['git', 'archive', sha, 'Packages/EncryptedMemoriesKit/Sources'], cwd=repo)
                with tarfile.open(fileobj=io.BytesIO(archive)) as tree:
                    tree.extractall(root, filter='data')
                subprocess.run(['git', 'apply', '--check', '--unidiff-zero', str(overlay / (tag + '.patch'))], cwd=root, check=True)

    def test_unknown_predecessor_without_entry_fails(self):
        with tempfile.TemporaryDirectory() as root:
            with self.assertRaisesRegex(JourneyError, 'no reviewed overlay'):
                apply_overlay(Path(root), Path(__file__).resolve().parents[2], 'v1.2.0', 'a' * 40)

    def test_upload_ledger_survives_app_replacement_and_exposes_duplicates(self):
        with tempfile.TemporaryDirectory() as root, FixtureServer(Path(root), 'backup.claimed') as server:
            def upload():
                request = Request(server.url + '/upload', data=json.dumps({'name': 'Synthetic-0.png', 'hash': 'abc'}).encode(), headers={'Content-Type': 'application/json'})
                return json.load(urlopen(request))
            self.assertEqual(upload()['id'], 'link-0')
            self.assertEqual(json.load(urlopen(server.url + '/links'))[0]['hash'], 'abc')
            upload()
            with self.assertRaisesRegex(JourneyError, 'duplicate'):
                server.verify_uploads(expected=1)

    def test_model_supports_exact_resume_and_thumbnail_is_valid_png(self):
        with tempfile.TemporaryDirectory() as root, FixtureServer(Path(root), 'model.partial') as server:
            response = urlopen(Request(server.url + '/model', headers={'Range': 'bytes=4096-8191'}))
            self.assertEqual(response.status, 206)
            self.assertEqual(response.headers['Content-Range'], 'bytes 4096-8191/16384')
            self.assertEqual(response.read(), bytes([0xA7]) * 4096)
            self.assertTrue(urlopen(server.url + '/thumbnail/asset-0').read().startswith(b'\x89PNG\r\n\x1a\n'))

    def test_model_resume_requires_the_saved_partial_offset(self):
        with tempfile.TemporaryDirectory() as root, FixtureServer(Path(root), 'model.partial') as server:
            urlopen(Request(server.url + '/model', headers={'Range': 'bytes=0-8191'})).read()
            server.begin_upgrade()
            urlopen(Request(server.url + '/model', headers={'Range': 'bytes=8192-16383'})).read()
            server.verify_model_resume()

    def test_model_redownload_and_missing_resume_fail(self):
        for first_range in [None, 'bytes=0-8191']:
            with self.subTest(first_range=first_range), tempfile.TemporaryDirectory() as root:
                with FixtureServer(Path(root), 'model.partial') as server:
                    server.begin_upgrade()
                    if first_range:
                        urlopen(Request(server.url + '/model', headers={'Range': first_range})).read()
                    with self.assertRaisesRegex(JourneyError, 'saved partial'):
                        server.verify_model_resume()

    def test_failed_case_stops_before_the_next_case(self):
        calls = []
        def execute(source, point):
            calls.append((source, point))
            if point == 'model.partial':
                raise JourneyError('Model did not resume')
        with self.assertRaisesRegex(JourneyError, 'Model did not resume'):
            run_cases(['v1.0.5', 'v1.1.0'], ['backup.claimed', 'model.partial', 'index.embed'], execute)
        self.assertEqual(calls, [('v1.0.5', 'backup.claimed'), ('v1.0.5', 'model.partial')])

    def test_empty_source_or_case_set_never_reports_success(self):
        for sources, points in [([], ['backup.claimed']), (['v1.0.5'], [])]:
            with self.assertRaises(JourneyError):
                run_cases(sources, points, lambda *_: None)

    def test_failed_preparation_reports_its_exit_without_waiting_for_a_checkpoint(self):
        with tempfile.TemporaryDirectory() as root, FixtureServer(Path(root), 'backup.claimed') as server:
            process = subprocess.Popen([sys.executable, '-c', 'raise SystemExit(7)'])
            with self.assertRaisesRegex(JourneyError, r'UI preparation failed \(7\)'):
                server.wait_checkpoint(timeout=1, preparing=process)
            self.assertEqual(process.wait(), 7)

    def test_missing_checkpoint_fails_with_the_selected_boundary(self):
        with tempfile.TemporaryDirectory() as root, FixtureServer(Path(root), 'index.beforeCommit') as server:
            with self.assertRaisesRegex(JourneyError, 'index.beforeCommit'):
                server.wait_checkpoint(timeout=0.01)


if __name__ == '__main__':
    signal.signal(signal.SIGTERM, run_journey.terminate)
    signal.signal(signal.SIGINT, run_journey.terminate)
    unittest.main()
