#!/usr/bin/env python3
"""Run install-over UI journeys on an owned simulator or the macOS runner."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import signal
import subprocess
import tempfile
import sys
import uuid
import time

from build_apps import build_app, clean_environment, command, output
from journey import JourneyError, run_cases
from server import FixtureServer

BUNDLE = 'at.oncloud.encryptedmemories.upgrade-test'
POINTS = ['backup.claimed', 'backup.remoteReceipt', 'backup.localRecord',
          'model.partial', 'model.installRecord', 'model.promoted',
          'index.embed', 'index.beforeCommit', 'index.afterCommit',
          'thumbnail.beforeLoad', 'thumbnail.afterLoad', 'thumbnail.stored']
LIMITATION = ('macOS-Keychain-Persistenz über das Update wird nicht im Prüfbau geprüft; '
              'abgedeckt durch iOS-Simulator und Entitlement-Vergleich.')
CONSENT_LIMITATION = ('The backup journey requires consent already saved on disk. The immediate v1.0.5 '
                     'Enable-to-SIGKILL case is a known historical limit and is not tested here.')

METADATA_LIMITATION = ('Bundle metadata parity with shipping artifacts is pending in #411. '
                       'These journeys verify commit, storage, and task paths. '
                       'They do not verify bundle metadata or external authentication headers.')


def summary(message):
    print(message, flush=True)
    if os.environ.get('GITHUB_STEP_SUMMARY'):
        with open(os.environ['GITHUB_STEP_SUMMARY'], 'a') as report:
            report.write(message + '\n\n')


def read_backup_consent(preferences):
    try:
        values = plistlib.loads(preferences.read_bytes())
    except FileNotFoundError:
        return None
    except (OSError, ValueError, plistlib.InvalidFileException) as error:
        raise JourneyError('Unreadable backup preferences in the owned app container') from error
    if not isinstance(values, dict):
        raise JourneyError('Unreadable backup preferences: expected a preference dictionary')
    return values.get('photoBackup.enabled.v1')


def wait_saved_backup_consent(preferences, deadline):
    # The selected task stays held. This wait uses the remainder of its preparation budget.
    while True:
        if read_backup_consent(preferences) is True:
            return True
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise JourneyError('The old app has no saved backup consent: photoBackup.enabled.v1 must be true')
        time.sleep(min(0.2, remaining))


def verify_saved_backup_consent(preferences, before):
    after = read_backup_consent(preferences)
    if before is not True or after is not before:
        raise JourneyError('Saved backup consent changed after install-over in the owned app container')
    return after


def owned_process(args, log, env=None):
    return subprocess.Popen(args, stdout=log, stderr=subprocess.STDOUT, env=env or clean_environment(), start_new_session=True)


def stop_group(process):
    if process.poll() is None:
        os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()


class SigningIdentity:
    """One temporary identity signs both macOS installations. No release credential is used."""
    def __init__(self, root):
        self.directory = Path(tempfile.mkdtemp(prefix='upgrade-signing-', dir=root))
        self.keychain = self.directory / 'fixture.keychain-db'
        self.password = os.urandom(32).hex()
        self.created = False

    def secure_command(self, args, operation, env=None):
        result = subprocess.run(args, env=env or clean_environment(), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if result.returncode:
            raise JourneyError(f'Temporary signing identity: {operation} failed ({result.returncode})')

    def __enter__(self):
        try:
            config = self.directory / 'certificate.conf'
            config.write_text('[req]\ndistinguished_name=dn\nx509_extensions=signing\nprompt=no\n'
                              '[dn]\nCN=Encrypted Memories Upgrade Fixture\n[signing]\n'
                              'keyUsage=critical,digitalSignature\nextendedKeyUsage=codeSigning\n')
            self.secure_command(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
                                 '-config', str(config), '-keyout', str(self.directory / 'key.pem'),
                                 '-out', str(self.directory / 'certificate.pem')], 'certificate creation')
            env = dict(clean_environment(), UPGRADE_SIGNING_PASSWORD=self.password)
            self.secure_command(['openssl', 'pkcs12', '-export', '-inkey', str(self.directory / 'key.pem'),
                                 '-in', str(self.directory / 'certificate.pem'), '-out', str(self.directory / 'identity.p12'),
                                 '-keypbe', 'PBE-SHA1-3DES', '-certpbe', 'PBE-SHA1-3DES', '-macalg', 'SHA1',
                                 '-passout', 'env:UPGRADE_SIGNING_PASSWORD'], 'identity export', env)
            self.secure_command(['security', 'create-keychain', '-p', self.password, str(self.keychain)], 'keychain creation')
            self.created = True
            self.secure_command(['security', 'unlock-keychain', '-p', self.password, str(self.keychain)], 'keychain unlock')
            self.secure_command(['security', 'import', str(self.directory / 'identity.p12'), '-k', str(self.keychain),
                                 '-P', self.password, '-T', '/usr/bin/codesign'], 'identity import')
            self.secure_command(['security', 'set-key-partition-list', '-S', 'apple-tool:,apple:,codesign:', '-s',
                                 '-k', self.password, str(self.keychain)], 'signing access')
            identities = output(['security', 'find-identity', '-p', 'codesigning', str(self.keychain)])
            match = re.search(r'\b([A-F0-9]{40})\b', identities)
            if not match:
                raise JourneyError('The temporary keychain contains no signing identity')
            self.identity = match[1]
            return self
        except BaseException:
            self.__exit__(*sys.exc_info())
            raise

    def sign(self, app, entitlements=None):
        args = ['codesign', '--force', '--deep', '--sign', self.identity, '--keychain', str(self.keychain), '--timestamp=none']
        if entitlements:
            args += ['--entitlements', str(entitlements)]
        command(args + [str(app)])
        command(['codesign', '--verify', '--deep', '--strict', str(app)])

    def __exit__(self, exc_type, *_):
        try:
            if self.created:
                self.secure_command(['security', 'delete-keychain', str(self.keychain)], 'keychain removal')
        except JourneyError as error:
            if exc_type is None:
                raise
            summary(str(error))
        finally:
            shutil.rmtree(self.directory)



class InstalledApp:
    def __init__(self, platform, directory, signer=None):
        self.platform = platform
        self.directory = directory
        self.signer = signer
        self.launch_arguments = []
        self.case_id = uuid.uuid4().hex
        self.simulator = None
        if platform == 'iOS':
            runtimes = json.loads(output(['xcrun', 'simctl', 'list', 'runtimes', '--json']))['runtimes']
            available = [r for r in runtimes if r.get('isAvailable') and r['identifier'].startswith('com.apple.CoreSimulator.SimRuntime.iOS-') and r['version'].split('.')[0] == '27']
            if not available:
                raise JourneyError('No installed iOS Simulator runtime is available')
            runtime = min(available, key=lambda r: tuple(map(int, r['version'].split('.'))))
            if sum(r['identifier'] == runtime['identifier'] for r in runtimes) != 1:
                raise JourneyError('Ambiguous Simulator runtime identifier: ' + runtime['identifier'])
            types = json.loads(output(['xcrun', 'simctl', 'list', 'devicetypes', '--json']))['devicetypes']
            phones = [d for d in types if d['name'] == 'iPhone 17']
            if not phones:
                raise JourneyError('No iPhone Simulator device type is available')
            self.simulator = output(['xcrun', 'simctl', 'create', 'EncryptedMemoriesUpgrade-' + self.case_id, phones[-1]['identifier'], runtime['identifier']])
            try:
                (directory / 'simulator.txt').write_text(self.simulator + '\n')
                (directory / 'simulator-runtime.json').write_text(json.dumps(runtime) + '\n')
                print('Owned iOS Simulator runtime: ' + runtime['identifier'] + ' (' + runtime['version'] + ')', flush=True)
                print('Owned iOS Simulator: ' + self.simulator, flush=True)
                command(['xcrun', 'simctl', 'boot', self.simulator])
                command(['xcrun', 'simctl', 'bootstatus', self.simulator, '-b'])
            except BaseException:
                try:
                    self.close()
                except (subprocess.CalledProcessError, OSError) as error:
                    summary(f'Owned Simulator cleanup failed: {error}')
                raise

    @property
    def destination(self):
        return 'platform=iOS Simulator,id=' + self.simulator if self.simulator else 'platform=macOS'

    def install(self, app):
        if self.simulator:
            # This always installs over the existing app. The upgrade phase never uninstalls or erases it.
            command(['xcrun', 'simctl', 'install', self.simulator, str(app)])
        else:
            self.installed = self.directory / 'installed.app'
            if self.installed.exists():
                shutil.rmtree(self.installed)  # Only the owned executable bundle, never its persisted data.
            shutil.copytree(app, self.installed, symlinks=True)
            entitlements = self.directory / 'fixture-entitlements.plist'
            entitlements.write_bytes(plistlib.dumps({
                'com.apple.security.app-sandbox': True, 'com.apple.security.network.client': True,
                'com.apple.security.files.user-selected.read-write': True,
                'com.apple.security.personal-information.photos-library': True}))
            self.signer.sign(self.installed, entitlements)

    @property
    def preferences_path(self):
        if self.simulator:
            container = Path(output(['xcrun', 'simctl', 'get_app_container', self.simulator, BUNDLE, 'data']))
        else:
            container = Path.home() / 'Library/Containers' / BUNDLE / 'Data'
        return container / 'Library/Preferences' / (BUNDLE + '.plist')

    def launch(self, server, seed=False):
        args = ['-EncryptedMemoriesUITestFixture', '-EncryptedMemoriesUpgradeServer', server.url,
                '-EncryptedMemoriesUpgradeCase', self.case_id,
                '-AppleLanguages', '(en)', '-AppleLocale', 'en_US']
        if seed:
            args += ['-EncryptedMemoriesUpgradeSeed']
        if self.simulator:
            result = output(['xcrun', 'simctl', 'launch', self.simulator, BUNDLE] + args)
            self.app_pid = int(result.rsplit(':', 1)[1].strip())
        else:
            # XCTest owns the LaunchServices start and passes these arguments to that exact app.
            self.launch_arguments = args

    def macos_app_pid(self):
        if not hasattr(self, 'installed'):
            return None
        info = plistlib.loads((self.installed / 'Contents/Info.plist').read_bytes())
        binary = str(self.installed / 'Contents/MacOS' / info['CFBundleExecutable'])
        matches = []
        for line in output(['/bin/ps', '-axo', 'pid=,comm=']).splitlines():
            fields = line.strip().split(None, 1)
            if len(fields) == 2 and fields[1] == binary:
                matches.append(int(fields[0]))
        if len(matches) > 1:
            raise JourneyError('Multiple processes use the exact owned macOS app bundle')
        return matches[0] if matches else None

    def kill_app(self):
        if self.simulator:
            # simctl launch reports a host PID. Check its exact device-owned executable before SIGKILL.
            bundle = output(['xcrun', 'simctl', 'get_app_container', self.simulator, BUNDLE, 'app'])
            executable = output(['/bin/ps', '-ww', '-p', str(self.app_pid), '-o', 'comm='])
            if not executable.startswith(bundle + '/'):
                raise JourneyError('Refusing to kill a process outside the owned Simulator app bundle')
            os.kill(self.app_pid, signal.SIGKILL)
        else:
            app_pid = self.macos_app_pid()
            if app_pid is None:
                raise JourneyError('The old macOS app exited before the selected interruption')
            os.kill(app_pid, signal.SIGKILL)

    def close(self):
        if self.simulator:
            try:
                command(['xcrun', 'simctl', 'shutdown', self.simulator])
            finally:
                command(['xcrun', 'simctl', 'delete', self.simulator])
                self.simulator = None
        else:
            app_pid = self.macos_app_pid()
            if app_pid is not None:
                os.kill(app_pid, signal.SIGTERM)


def ui_run(runner, destination, point, phase, evidence, app_path=None, launch_arguments=None):
    def resolve(value):
        if isinstance(value, str):
            return value.replace('__TESTROOT__', str(runner.parent))
        if isinstance(value, dict):
            return {key: resolve(item) for key, item in value.items()}
        if isinstance(value, list):
            return [resolve(item) for item in value]
        return value
    payload = resolve(plistlib.loads(runner.read_bytes()))
    def configure(value):
        if isinstance(value, dict):
            if value.get('IsUITestBundle'):
                if phase == 'prepare' and destination.startswith('platform=iOS Simulator,'):
                    # XCTest's automatic recording ended at the kill point, and SimRenderServer crashed in both runs at that moment.
                    value['PreferredScreenCaptureFormat'] = 'screenshots'
                value.setdefault('EnvironmentVariables', {}).update(
                    UPGRADE_POINT=point, UPGRADE_PHASE=phase, UPGRADE_APP_PATH=str(app_path or ''),
                    UPGRADE_APP_ARGUMENTS=json.dumps(launch_arguments or []),
                    DEVELOPER_DIR=os.environ.get('DEVELOPER_DIR', '/Applications/Xcode.app/Contents/Developer'))
            for item in value.values():
                configure(item)
        elif isinstance(value, list):
            for item in value:
                configure(item)
    configure(payload)
    configured = evidence / (phase + '.xctestrun')
    configured.write_bytes(plistlib.dumps(payload))
    log = open(evidence / (phase + '-ui.log'), 'w')
    process = owned_process(['xcrun', 'xcodebuild', 'test-without-building', '-xctestrun', str(configured),
                             '-destination', destination, '-parallel-testing-enabled', 'NO',
                             '-resultBundlePath', str(evidence / (phase + '.xcresult'))], log)
    return process, log


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', type=Path, required=True)
    parser.add_argument('--automation', type=Path, required=True)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--target', required=True)
    parser.add_argument('--sources', nargs='+', required=True)
    parser.add_argument('--platform', choices=['iOS', 'macOS'], required=True)
    parser.add_argument('--points', nargs='+', choices=POINTS, default=POINTS)
    parser.add_argument('--working-copy', action='store_true')
    args = parser.parse_args()
    toolchain = output(['xcodebuild', '-version'])
    summary('Xcode toolchain: ' + toolchain.replace('\n', '; '))
    summary(CONSENT_LIMITATION)
    summary(LIMITATION)
    summary(METADATA_LIMITATION)
    for path in [args.root / 'scratch', args.root / 'evidence']:
        path.mkdir(parents=True, exist_ok=True)
    sys.path.insert(0, str(args.automation / '.github/scripts'))
    from keychain_entitlements import compare_groups, snapshot
    stable = [tag for tag in args.sources if re.fullmatch(r'v[0-9]+\.[0-9]+\.[0-9]+', tag)]
    if not stable:
        raise JourneyError('No supported stable upgrade source was selected')
    previous = max(stable, key=lambda tag: tuple(map(int, tag[1:].split('.'))))
    compare_groups(snapshot(args.repo, previous),
                   snapshot(args.repo, None if args.working_copy else args.target))
    summary(f'Keychain access groups match {previous} (macOS and iOS).')
    current = build_app(args.repo, args.automation, args.target, args.platform, args.root,
                        historical=False, working_copy=args.working_copy)
    predecessors = {tag: build_app(args.repo, args.automation, tag, args.platform, args.root) for tag in args.sources}
    # Build the standalone UI runner from the current release, without an app dependency.
    source = current.source
    if source is None:
        raise JourneyError('The current build has no source for its UI runner')
    shutil.copy2(args.automation / 'scripts/upgrade-test/UITests/UpgradeJourneyUITests.swift', source / 'UpgradeUITests')
    dd = source.parent / 'build/DerivedData.noindex'
    sdk = 'iphonesimulator' if args.platform == 'iOS' else 'macosx'
    command(['xcrun', 'xcodebuild', 'build-for-testing', '-project', 'EncryptedMemories.xcodeproj',
             '-scheme', 'UpgradeJourney', '-configuration', 'Release', '-sdk', sdk,
             '-destination', 'generic/platform=iOS Simulator' if args.platform == 'iOS' else 'platform=macOS',
             '-derivedDataPath', str(dd),
             '-clonedSourcePackagesDirPath', str(source.parent / 'build/SourcePackages.noindex'),
             '-packageCachePath', str(source.parent / 'build/XcodePackageCache.noindex'),
             '-disableAutomaticPackageResolution', '-onlyUsePackageVersionsFromResolvedFile',
             'CODE_SIGN_IDENTITY=-', 'ENABLE_HARDENED_RUNTIME=NO',
             'ARCHS=' + output(['uname', '-m']), 'ONLY_ACTIVE_ARCH=YES'], cwd=source)
    runners = list((dd / 'Build/Products').glob('*.xctestrun'))
    if len(runners) != 1:
        raise JourneyError('Expected exactly one standalone UI runner')
    runner = runners[0]
    signer = SigningIdentity(args.root) if args.platform == 'macOS' else None
    if signer:
        signer.__enter__()
    evidence_root = args.root / 'evidence' / uuid.uuid4().hex
    try:
        evidence_root.mkdir(parents=True)
        (evidence_root / 'toolchain.json').write_text(json.dumps({
            'xcode': toolchain, 'platform': args.platform, 'target': args.target}) + '\n')
        def execute(tag, point):
            case = evidence_root / args.platform / tag / point
            case.mkdir(parents=True, exist_ok=True)
            with FixtureServer(case, point) as server:
                app = InstalledApp(args.platform, case, signer)
                preparing = None
                try:
                    app.install(predecessors[tag].app)
                    app.launch(server, seed=True)
                    preparation_deadline = time.monotonic() + 180
                    preparing, prepare_log = ui_run(runner, app.destination, point, 'prepare', case, getattr(app, 'installed', None), app.launch_arguments)
                    server.wait_checkpoint(timeout=max(0, preparation_deadline - time.monotonic()), preparing=preparing)
                    saved_consent = None
                    consent_evidence = {}
                    if point.startswith('backup.'):
                        saved_consent = wait_saved_backup_consent(app.preferences_path, preparation_deadline)
                        consent_evidence['before_kill'] = saved_consent
                        (case / 'backup-consent.json').write_text(json.dumps(consent_evidence) + '\n')
                    app.kill_app()
                    stop_group(preparing)
                    prepare_log.close()
                    server.begin_upgrade()
                    app.install(current.app)
                    if saved_consent is not None:
                        consent_evidence['after_install_over'] = verify_saved_backup_consent(app.preferences_path, saved_consent)
                        (case / 'backup-consent.json').write_text(json.dumps(consent_evidence) + '\n')
                    app.launch(server)
                    verifying, verify_log = ui_run(runner, app.destination, point, 'verify', case, getattr(app, 'installed', None), app.launch_arguments)
                    try:
                        code = verifying.wait(timeout=240)
                        if code:
                            raise JourneyError(f'{tag} / {point}: UI verification failed ({code})')
                    except subprocess.TimeoutExpired as error:
                        raise JourneyError(f'{tag} / {point}: UI verification timed out') from error
                    finally:
                        stop_group(verifying)
                        verify_log.close()
                    if point.startswith('backup.'):
                        consent_evidence['after_ui_verification'] = verify_saved_backup_consent(app.preferences_path, saved_consent)
                        (case / 'backup-consent.json').write_text(json.dumps(consent_evidence) + '\n')
                        server.verify_uploads()
                    if point == 'model.partial':
                        server.verify_model_resume()
                    if not any(r['phase'] == 'new' and r['path'] == '/checkpoint/session.loaded' for r in server.requests):
                        raise JourneyError(f'{tag} / {point}: the replacement app did not load the saved session')
                    if any(r['path'] == '/checkpoint/network.denied' for r in server.requests):
                        raise JourneyError(f'{tag} / {point}: the app attempted an external request')
                    summary(f'PASS {args.platform}: {tag} → {args.target}, {point}')
                finally:
                    if preparing:
                        stop_group(preparing)
                    app.close()
        run_cases(args.sources, args.points, execute)
    finally:
        if signer:
            signer.__exit__(*sys.exc_info())


# CI cancellation must unwind the owned UI/app groups and temporary signing material.
def terminate(*_):
    # Keep caught handlers during unwind; exec resets them for cleanup subprocesses.
    # SIG_IGN would also disable termination in those subprocesses.
    signal.signal(signal.SIGTERM, lambda *_: None)
    signal.signal(signal.SIGINT, lambda *_: None)
    raise KeyboardInterrupt('Upgrade journey cancelled')


if __name__ == '__main__':
    signal.signal(signal.SIGTERM, terminate)
    signal.signal(signal.SIGINT, terminate)
    try:
        main()
    except (JourneyError, subprocess.CalledProcessError, OSError, ValueError) as error:
        summary(f'**Upgrade check failed:** {error}. Re-run after correcting this cause, or use the explicit main-branch override.')
        raise SystemExit(1)
