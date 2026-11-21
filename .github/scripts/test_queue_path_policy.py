import importlib.util
import os
import re
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).with_name('queue_path_policy.py')
REPO_ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('queue_path_policy', SCRIPT)
policy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(policy)


def git_fixture(root):
    def git(*args):
        return subprocess.run(['git', *args], cwd=root, check=True, capture_output=True, text=True).stdout.strip()
    git('init', '-q')
    git('config', 'user.name', 'Test')
    git('config', 'user.email', 'test@example.invalid')
    return git


def run_policy(root, base, head):
    output = root / 'output'
    output.write_text('')
    env = dict(os.environ, BASE_SHA=base, HEAD_SHA=head, GITHUB_OUTPUT=str(output))
    result = subprocess.run(['python3', str(SCRIPT)], cwd=root, env=env, check=True, capture_output=True)
    return output.read_text(), result.stdout.decode()


class QueuePathPolicyTests(unittest.TestCase):
    def test_allowlist(self):
        for paths in [['Wiki/page.txt'], ['site/index.html'], ['README.md'], ['SECURITY.md'], ['Wiki/a', 'site/b']]:
            with self.subTest(paths=paths):
                self.assertTrue(policy.can_skip(paths))

    def test_git_diff_renames_and_invalid_base_runs(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            git = git_fixture(root)
            (root / 'site').mkdir()
            (root / 'site/a.md').write_text('same content\n')
            git('add', '.')
            git('commit', '-qm', 'base')
            base = git('rev-parse', 'HEAD')
            (root / 'site/a.md').write_text('changed content\n')
            git('add', '-A')
            git('commit', '-qm', 'documentation')
            doc_head = git('rev-parse', 'HEAD')
            # A docs-only change skips the macOS jobs and with them the UI job.
            self.assertEqual('run_macos=false\nrun_ui=false\n', run_policy(root, base, doc_head)[0])
            (root / 'site/a.md').rename(root / 'unknown')
            git('add', '-A')
            git('commit', '-qm', 'rename')
            # The renamed destination is unknown, so all macOS jobs run; both rename
            # paths are UI-irrelevant, so the UI job still skips.
            self.assertEqual('run_macos=true\nrun_ui=false\n',
                             run_policy(root, doc_head, git('rev-parse', 'HEAD'))[0])
            (root / 'App').mkdir()
            (root / 'App/Thing.swift').write_text('unchanged contents\n')
            git('add', '-A')
            git('commit', '-qm', 'protected')
            protected_base = git('rev-parse', 'HEAD')
            (root / 'Wiki').mkdir()
            (root / 'App/Thing.swift').rename(root / 'Wiki/Thing.txt')
            git('add', '-A')
            git('commit', '-qm', 'move protected to wiki')
            # The rename touches a Swift file, so the macOS jobs run. Both paths are
            # UI-irrelevant (App is the macOS app), so the UI job still skips.
            self.assertEqual('run_macos=true\nrun_ui=false\n',
                             run_policy(root, protected_base, git('rev-parse', 'HEAD'))[0])
            # An invalid base runs everything: the decision fails toward more testing.
            output, stdout = run_policy(root, 'not-a-commit', git('rev-parse', 'HEAD'))
            self.assertEqual('run_macos=true\nrun_ui=false\n', output)
            self.assertIn('local UI gate applies', stdout)


class UiEndToEndTests(unittest.TestCase):
    """The queue never runs the iOS UI tests (run_ui is always false); the log names the local UI gate.

    Each row kills the mutant that removes the rule it names: without the rule
    the log of the row loses the local gate notice and the row fails.
    """

    def test_each_ui_rule_decides_the_verdict_end_to_end(self):
        rows = [
            ('iOSApp/MobileApp.swift', True, 'the iOS app source rule'),
            ('iOSApp/Info.plist', True, 'the iOS app source rule'),
            ('iOSUITests/TimelineTests.swift', True, 'the UI test source rule'),
            ('VendorPatches/sdk-swift/offline.patch', True, 'the vendored patch rule'),
            ('.github/workflows/pull-request.yml', True, 'the workflow file rule'),
            ('.github/workflows/duo-ui-tests.yml', True, 'the workflow file rule'),
            ('.github/workflows/nightly-ui-tests.yml', True, 'the workflow file rule'),
            ('.github/workflows/a-new-workflow.yml', True, 'the workflow file rule'),
            ('project.yml', True, 'the project manifest rule'),
            ('App/Info.plist', True, 'the app manifest rule'),
            ('Packages/EncryptedMemoriesKit/Package.swift', True, 'the package manifest rule'),
            ('Packages/EncryptedMemoriesKit/Package.resolved', True, 'the package manifest rule'),
            ('scripts/verify-ios-app-tests.sh', True, 'the UI tooling file rule'),
            ('Packages/EncryptedMemoriesKit/Sources/PhotosCore/Resources/Assets.json',
             True, 'the Resources bundle rule'),
            ('Packages/EncryptedMemoriesKit/Sources/AccountStateCore/Resources/FeatureFlags.json',
             True, 'the Resources bundle rule inside a module the UI tests cannot reach'),
            ('Packages/EncryptedMemoriesKit/Sources/PhotosCore/Library.swift',
             True, 'the UI-relevant module rule'),
            ('Packages/EncryptedMemoriesKit/Sources/AccountStateCore/State.swift',
             False, 'a module the UI tests cannot reach'),
            ('macOSTests/ThumbnailSupportHostTests.swift', False, 'the macOS hosted tests'),
            ('iOSTests/ListTests.swift', False, 'the iOS hosted tests, not the UI tests'),
            ('CONTRIBUTING.md', False, 'repository documentation'),
            ('.github/ISSUE_TEMPLATE/bug.yml', False, 'an issue template'),
            ('.github/scripts/test_review_pull_request.py', False, 'a review script'),
        ]
        for path, needed, rule in rows:
            with self.subTest(path=path, rule=rule):
                with tempfile.TemporaryDirectory() as directory:
                    root = Path(directory)
                    git = git_fixture(root)
                    Path(root, 'CONTRIBUTING.md').write_text('base\n')
                    git('add', '.')
                    git('commit', '-qm', 'base')
                    base = git('rev-parse', 'HEAD')
                    target = Path(root, path)
                    target.parent.mkdir(parents=True, exist_ok=True)
                    target.write_text('changed\n')
                    git('add', '.')
                    git('commit', '-qm', 'change')
                    output, stdout = run_policy(root, base, git('rev-parse', 'HEAD'))
                    self.assertEqual('run_macos=true\nrun_ui=false\n', output, path)
                    self.assertEqual(needed, 'local UI gate applies' in stdout, path)

    def test_a_rename_into_the_app_keeps_the_old_path_decided(self):
        # --no-renames lists the source path of a rename, so a file that moves out of
        # macOSTests into iOSApp decides from the destination, and a file that moves
        # out of a UI-relevant module decides from the source.
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            git = git_fixture(root)
            Path(root, 'macOSTests').mkdir()
            Path(root, 'macOSTests/Old.swift').write_text('x\n')
            git('add', '.')
            git('commit', '-qm', 'base')
            base = git('rev-parse', 'HEAD')
            Path(root, 'iOSApp').mkdir()
            (root / 'macOSTests/Old.swift').rename(root / 'iOSApp/New.swift')
            git('add', '-A')
            git('commit', '-qm', 'into the app')
            self.assertEqual('run_macos=true\nrun_ui=false\n',
                             run_policy(root, base, git('rev-parse', 'HEAD'))[0])
            module_dir = Path(root, 'Packages/EncryptedMemoriesKit/Sources/PhotosCore')
            module_dir.mkdir(parents=True)
            module_base = git('rev-parse', 'HEAD')
            (root / 'iOSApp/New.swift').rename(module_dir / 'Moved.swift')
            git('add', '-A')
            git('commit', '-qm', 'out of the app')
            self.assertEqual('run_macos=true\nrun_ui=false\n',
                             run_policy(root, module_base, git('rev-parse', 'HEAD'))[0])

    def test_an_undecodable_path_runs_the_macos_jobs_and_names_the_local_ui_gate(self):
        # A name that is not UTF-8 can carry no rule match; it must decide to run.
        # The diff bytes are injected in-process: a filesystem can reject such a name.
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / 'output'
            output.write_text('')

            class FakeDiff:
                stdout = b'Upload\xffd\xc3.md\x00'

            real_run = policy.subprocess.run
            saved_environ = os.environ.copy()
            try:
                os.environ.update(
                    BASE_SHA='base', HEAD_SHA='head', GITHUB_OUTPUT=str(output))
                policy.subprocess.run = lambda *args, **kwargs: FakeDiff()
                policy.main()
            finally:
                policy.subprocess.run = real_run
                os.environ.clear()
                os.environ.update(saved_environ)
            self.assertEqual('run_macos=true\nrun_ui=false\n', output.read_text())

    def test_an_empty_diff_runs_the_macos_jobs_and_no_ui_job(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            git = git_fixture(root)
            git('commit', '--allow-empty', '-qm', 'base')
            base = git('rev-parse', 'HEAD')
            git('commit', '--allow-empty', '-qm', 'still empty')
            output, stdout = run_policy(root, base, git('rev-parse', 'HEAD'))
            self.assertEqual('run_macos=true\nrun_ui=false\n', output)
            self.assertIn('local UI gate applies', stdout)


class UiRuleUnitTests(unittest.TestCase):
    """Per-rule rows for is_ui_relevant; each row fails when its rule is removed."""

    def test_every_named_tooling_file_is_relevant(self):
        for path in policy.UI_TOOLING:
            with self.subTest(path=path):
                self.assertTrue(policy.is_ui_relevant(path), path)

    def test_every_ui_relevant_module_is_relevant(self):
        self.assertGreater(len(policy.UI_RELEVANT_MODULES), 0)
        for module in policy.UI_RELEVANT_MODULES:
            path = f'Packages/EncryptedMemoriesKit/Sources/{module}/File.swift'
            with self.subTest(module=module):
                self.assertTrue(policy.is_ui_relevant(path), path)

    def test_ui_app_and_patch_roots_are_relevant(self):
        for path in ['iOSApp/App.swift', 'iOSApp/Resources/Assets.xcassets/Icon.png',
                     'iOSUITests/TimelineTests.swift']:
            with self.subTest(path=path):
                self.assertTrue(policy.is_ui_relevant(path))

    def test_manifests_and_resources_are_relevant_anywhere_in_packages(self):
        for path in ['Packages/EncryptedMemoriesKit/Package.swift',
                     'Packages/EncryptedMemoriesKit/Package.resolved',
                     'Packages/Other/Package.swift',
                     'Packages/EncryptedMemoriesKit/Sources/PhotosCore/Resources/en.lproj/Localizable.strings']:
            with self.subTest(path=path):
                self.assertTrue(policy.is_ui_relevant(path))

    def test_unreachable_paths_are_irrelevant(self):
        for path in ['README.md', 'CONTRIBUTING.md', 'Wiki/page.md', 'site/index.html',
                     'App/MainWindow.swift', 'macOSTests/ProbeTests.swift', 'iOSTests/CellTests.swift',
                     'BuildSupport/entitlements.plist', 'Branding/logo.svg', 'Tools/lint.py',
                     'TestFlight/notes.md', 'docs/guide.md',
                     '.github/ISSUE_TEMPLATE/bug.yml', '.github/PULL_REQUEST_TEMPLATE.md',
                     '.github/scripts/test_review_pull_request.py', '.github/actions/other/action.yml',
                     'scripts/verify-swift-style.sh', 'scripts/another-tool.sh',
                     'Packages/EncryptedMemoriesKit/Sources/AccountStateCore/State.swift',
                     'Packages/EncryptedMemoriesKit/Sources/DeviceRootAppleAdapter/Adapter.swift',
                     'Packages/EncryptedMemoriesKit/Tests/UploadCoreTests/UploaderTests.swift']:
            with self.subTest(path=path):
                self.assertFalse(policy.is_ui_relevant(path))

    def test_a_path_with_surrogate_escape_bytes_is_relevant(self):
        self.assertTrue(policy.is_ui_relevant(os.fsdecode(b'\xff\xfeUnknown\xfd.md')))

    def test_an_empty_module_list_needs_the_ui_tests_for_every_package_path(self):
        for path in ['Packages/EncryptedMemoriesKit/Sources/AccountStateCore/State.swift',
                     'Packages/EncryptedMemoriesKit/Sources/PhotosCore/Library.swift']:
            with self.subTest(path=path):
                self.assertTrue(policy.is_ui_relevant(path, modules=()), path)


class UiModulesDriftTests(unittest.TestCase):
    """Pin the embedded module list to the closure that Package.swift and project.yml define."""

    @staticmethod
    def package_targets():
        text = (REPO_ROOT / 'Packages' / 'EncryptedMemoriesKit' / 'Package.swift').read_text()
        targets = {}
        for match in re.finditer(r'\.(?:executableTarget|testTarget|target)\(', text):
            start = match.end() - 1
            depth = 0
            block = ''
            for index in range(start, len(text)):
                if text[index] == '(':
                    depth += 1
                elif text[index] == ')':
                    depth -= 1
                    if depth == 0:
                        block = text[start:index + 1]
                        break
            name = re.search(r'name:\s*"([^"]+)"', block)
            deps = []
            dep_match = re.search(r'dependencies:\s*\[', block)
            if dep_match:
                index = dep_match.end() - 1
                depth = 0
                for stop in range(index, len(block)):
                    if block[stop] == '[':
                        depth += 1
                    elif block[stop] == ']':
                        depth -= 1
                        if depth == 0:
                            break
                blob = block[index + 1:stop]
                stripped = re.sub(r'\.product\([^()]*\)', '', blob)
                deps.extend(re.findall(r'"([^"]+)"', stripped))
            if name:
                targets[name.group(1)] = sorted(set(deps))
        return targets

    @staticmethod
    def app_products():
        text = (REPO_ROOT / 'project.yml').read_text()
        start = text.index('EncryptedMemoriesMobile:')
        end = text.index('EncryptedMemoriesMobileTests:')
        block = text[start:end]
        return set(re.findall(r'package:\s*EncryptedMemoriesKit\s*\n\s*product:\s*(\w+)', block))

    @staticmethod
    def ui_importing_modules():
        markers = ('import SwiftUI', 'import UIKit', 'import AppKit')
        modules = set()
        for sources_dir in (REPO_ROOT / 'Packages').glob('*/Sources'):
            for module_dir in sources_dir.iterdir():
                if not module_dir.is_dir():
                    continue
                for swift_file in module_dir.rglob('*.swift'):
                    body = swift_file.read_text(errors='replace')
                    if any(marker in body for marker in markers):
                        modules.add(module_dir.name)
                        break
        return modules

    def test_the_embedded_list_pins_the_computed_closure(self):
        targets = self.package_targets()
        seeds = set(self.app_products()) | self.ui_importing_modules()
        closure = set()
        stack = sorted(seeds)
        while stack:
            target = stack.pop()
            if target in closure or target.endswith('Tests'):
                continue
            closure.add(target)
            for dep in targets.get(target, []):
                if not dep.endswith('Tests'):
                    stack.append(dep)
        listed = set(policy.UI_RELEVANT_MODULES)
        self.assertEqual(
            listed, closure,
            'UI_RELEVANT_MODULES drifted from the closure of Package.swift and project.yml:'
            f' add {sorted(closure - listed)}, remove {sorted(listed - closure)}')


class UiSourcesDriftTests(unittest.TestCase):
    """Every source that project.yml compiles into the iOS app or its UI tests belongs to the local UI gate."""

    @staticmethod
    def target_sources(target):
        text = (REPO_ROOT / 'project.yml').read_text()
        block = text[text.index(f'\n  {target}:\n'):]
        sources = re.search(r'\n    sources:\n((?:      - .+\n)+)', block)
        return [line.strip()[2:] for line in sources.group(1).splitlines()]

    def test_the_app_and_ui_test_sources_are_ui_relevant(self):
        for target in ('EncryptedMemoriesMobile', 'EncryptedMemoriesMobileUITests'):
            sources = self.target_sources(target)
            self.assertTrue(sources, target)
            for source in sources:
                with self.subTest(target=target, source=source):
                    # A directory source counts through a file below it.
                    path = source if (REPO_ROOT / source).is_file() else f'{source}/Any.swift'
                    self.assertTrue(policy.is_ui_relevant(path), f'{source} of {target} is no part of the local UI gate')


if __name__ == '__main__':
    unittest.main()
