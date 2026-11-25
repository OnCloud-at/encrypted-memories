import os
import re
import shutil
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def tool(directory, name, body):
    path = Path(directory) / name
    path.write_text('#!/usr/bin/env bash\n' + body)
    path.chmod(path.stat().st_mode | stat.S_IEXEC)
    return path


class SwiftStyleScripts(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        self.dir = Path(self.scratch.name)
        self.sample = 'Packages/EncryptedMemoriesKit/Sources/PhotosCore/TimelineMetadataStartGate.swift'
        self.assertTrue((ROOT / self.sample).is_file())

    def run_script(self, script, *arguments, **environment):
        env = dict(os.environ, **environment)
        for key in ['SWIFTLINT_EXECUTABLE', 'SWIFT_FORMAT_EXECUTABLE', 'BASE_SHA', 'HEAD_SHA']:
            if key not in environment:
                env.pop(key, None)
        return subprocess.run(['bash', str(ROOT / 'scripts' / script), *arguments], capture_output=True, text=True,
                              env=env, cwd=ROOT)

    def swiftlint(self, output, status=0, stream='1'):
        # The real tool prints its warnings on stderr; `stream` 2 does the same.
        return tool(self.dir, 'swiftlint', f'''if [[ "$1" == "version" ]]; then echo 0.65.1; exit 0; fi
echo "$@" > "{self.dir}/swiftlint-arguments"
cat <<'TEXT' >&{stream}
{output}
TEXT
exit {status}
''')

    def test_a_skipped_swiftlint_rule_fails_the_check(self):
        messages = [
            "warning: Skipping enabled rule 'custom_rules' because it requires SourceKit and SourceKit access is prohibited.",
            'warning: SourceKit-based rules will be skipped because sourcekitd has failed.',
        ]
        for message in messages:
            for stream in ['1', '2']:
                with self.subTest(message=message[:40], stream=stream):
                    tool_path = self.swiftlint(message, stream=stream)
                    result = self.run_script('lint-swift.sh', self.sample, SWIFTLINT_EXECUTABLE=str(tool_path))
                    self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                    self.assertIn('style check is incomplete', result.stderr)

    def test_a_clean_run_passes_and_gets_the_strict_arguments(self):
        tool_path = self.swiftlint('Done linting! Found 0 violations.')
        result = self.run_script('lint-swift.sh', self.sample, SWIFTLINT_EXECUTABLE=str(tool_path))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        arguments = (self.dir / 'swiftlint-arguments').read_text().split()
        self.assertEqual(arguments[:3], ['lint', '--strict', '--config'])
        self.assertEqual(arguments[-1], self.sample)

    def test_swiftlint_violations_keep_their_exit_code_and_output(self):
        tool_path = self.swiftlint('file.swift:1:1: error: a rule fired (trailing_whitespace)', status=2)
        result = self.run_script('lint-swift.sh', self.sample, SWIFTLINT_EXECUTABLE=str(tool_path))
        self.assertEqual(result.returncode, 2)
        self.assertIn('a rule fired', result.stdout)

    def test_the_wrong_swiftlint_version_stops_the_check(self):
        tool_path = tool(self.dir, 'swiftlint', 'echo 0.1.0\n')
        result = self.run_script('lint-swift.sh', self.sample, SWIFTLINT_EXECUTABLE=str(tool_path))
        self.assertEqual(result.returncode, 69)

    def test_swift_format_runs_the_given_executable_with_the_strict_configuration(self):
        tool_path = tool(self.dir, 'swift-format', f'echo "$@" > "{self.dir}/format-arguments"\n')
        result = self.run_script('check-swift-format.sh', self.sample, SWIFT_FORMAT_EXECUTABLE=str(tool_path))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        arguments = (self.dir / 'format-arguments').read_text().split()
        self.assertEqual(arguments[:3], ['lint', '--strict', '--parallel'])
        self.assertEqual(arguments[arguments.index('--configuration') + 1], str(ROOT / '.swift-format'))
        self.assertEqual(arguments[-1], self.sample)

    def test_swift_format_findings_fail_the_check(self):
        tool_path = tool(self.dir, 'swift-format', 'echo "a.swift:1:1: error: [Indentation] indent by 4 spaces"\nexit 1\n')
        result = self.run_script('check-swift-format.sh', self.sample, SWIFT_FORMAT_EXECUTABLE=str(tool_path))
        self.assertEqual(result.returncode, 1)

    def test_an_empty_selection_exits_cleanly_in_the_system_bash(self):
        # An empty file array under `set -u` was an unbound variable error in bash 3.2 and in 4.0 to 4.3, so this runs
        # /bin/bash on purpose; it only matters where that is an old bash (macOS).
        env = {key: value for key, value in os.environ.items() if key != 'SWIFT_FORMAT_EXECUTABLE'}
        result = subprocess.run(['/bin/bash', str(ROOT / 'scripts' / 'check-swift-format.sh'), '--diff', 'HEAD', 'HEAD'],
                                capture_output=True, text=True, env=env, cwd=ROOT)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('No Swift files require a format check.', result.stdout)

    def canary_swiftlint(self, fires=True, missed=0, extra=False, display_fires=False):
        # The canary files: a forbidden comment, and the decision-read canary, whose `expect` comments name the rule of
        # the next line. A working SwiftLint reports each of them with exit 2 and accepts the display-read canary.
        # `missed` drops that many expected sites; `extra` adds a site without an `expect` comment.
        body = f'''if [[ "$1" == "version" ]]; then echo 0.65.1; exit 0; fi
for argument in "$@"; do
  echo "$argument" >> "{self.dir}/linted-files"
  if [[ "$argument" == *StyleCanary.swift ]]; then {'echo "canary: no_em_dash_in_comments"; exit 2' if fires else 'exit 0'}; fi
  if [[ "$argument" == *DecisionReadCanary.swift ]]; then
    grep -n '// expect: ' "$argument" | tail -n +{missed + 1} | while IFS=: read -r line rest; do
      echo "$argument:$((line + 1)):5: error: Canary Violation: m. (${{rest##*// expect: }})"
    done
    {'echo "$argument:1:1: error: Canary Violation: m. (no_try_optional_in_store_lookup)"' if extra else ':'}
    exit 2
  fi
  if [[ "$argument" == *DisplayReadCanary.swift ]]; then {'echo "$argument:5:5: error: Canary Violation: m. (no_default_for_store_read_in_decision_code)"; exit 2' if display_fires else 'exit 0'}; fi
done
echo "Done linting!"
'''
        return tool(self.dir, 'swiftlint', body)

    def test_a_swiftlint_that_misses_or_adds_a_decision_read_fails_the_check(self):
        format_tool = tool(self.dir, 'swift-format', 'exit 0\n')
        for name, swiftlint in [('missed', self.canary_swiftlint(missed=1)), ('extra', self.canary_swiftlint(extra=True))]:
            with self.subTest(case=name):
                result = self.run_script('verify-swift-style.sh', SWIFTLINT_EXECUTABLE=str(swiftlint),
                                         SWIFT_FORMAT_EXECUTABLE=str(format_tool))
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn('did not report exactly the decision reads', result.stderr)
                self.assertIn('Canary Violation', result.stderr, 'the lint output explains the mismatch')

    def test_the_style_check_lints_the_core_and_the_host_canary_files_below_their_own_trees(self):
        swiftlint = self.canary_swiftlint()
        format_tool = tool(self.dir, 'swift-format', 'exit 0\n')
        result = self.run_script('verify-swift-style.sh', SWIFTLINT_EXECUTABLE=str(swiftlint),
                                 SWIFT_FORMAT_EXECUTABLE=str(format_tool), BASE_SHA='HEAD', HEAD_SHA='HEAD')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        linted = (self.dir / 'linted-files').read_text().split()
        for tree, names in [
            ('/Packages/EncryptedMemoriesKit/Sources/UploadCore/Backup/',
             ['DecisionReadCanary.swift', 'DisplayReadCanary.swift', 'DisabledReadCanary.swift']),
            ('/App/', ['HostDecisionReadCanary.swift', 'HostDisplayReadCanary.swift', 'HostDisabledReadCanary.swift']),
            ('/iOSApp/', ['HostPatternDecisionReadCanary.swift', 'HostPatternDisplayReadCanary.swift']),
            ('/App/leak-root/Packages/EncryptedMemoriesKit/Sources/PhotosCore/', ['LeakCanary.swift']),
        ]:
            for name in names:
                with self.subTest(file=name):
                    self.assertTrue(any(path.endswith(tree + name) for path in linted), f'{tree}{name} not linted')

    def test_a_missing_disabled_canary_stops_the_check_instead_of_skipping_it(self):
        # The sets of the core and of `App/` carry a disabled canary; a deleted or renamed file must not turn the
        # `swiftlint:disable` check into a silent pass.
        swiftlint = self.canary_swiftlint()
        format_tool = tool(self.dir, 'swift-format', 'exit 0\n')
        for name in ['Disabled.swift.txt', 'HostDisabled.swift.txt']:
            with self.subTest(missing=name):
                tree = self.dir / ('tree-' + name)
                shutil.copytree(ROOT / 'scripts', tree / 'scripts')
                for config in ['.swiftlint.yml', '.swiftlint-decision-reads.yml', '.swiftlint-decision-reads-baseline',
                               '.swift-format']:
                    shutil.copy(ROOT / config, tree / config)
                (tree / 'scripts' / 'decision-read-canary' / name).unlink()
                env = dict(os.environ, SWIFTLINT_EXECUTABLE=str(swiftlint), SWIFT_FORMAT_EXECUTABLE=str(format_tool))
                for key in ['BASE_SHA', 'HEAD_SHA']:
                    env.pop(key, None)
                result = subprocess.run(['bash', str(tree / 'scripts' / 'verify-swift-style.sh')], capture_output=True,
                                        text=True, env=env, cwd=tree)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn(name, result.stderr)

    def test_a_swiftlint_that_reports_a_display_read_fails_the_check(self):
        swiftlint = self.canary_swiftlint(display_fires=True)
        format_tool = tool(self.dir, 'swift-format', 'exit 0\n')
        result = self.run_script('verify-swift-style.sh', SWIFTLINT_EXECUTABLE=str(swiftlint),
                                 SWIFT_FORMAT_EXECUTABLE=str(format_tool))
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn('reported the display read', result.stderr)

    def test_a_swiftlint_that_does_not_report_the_canary_fails_the_check(self):
        swiftlint = self.canary_swiftlint(fires=False)
        format_tool = tool(self.dir, 'swift-format', 'exit 0\n')
        result = self.run_script('verify-swift-style.sh', SWIFTLINT_EXECUTABLE=str(swiftlint),
                                 SWIFT_FORMAT_EXECUTABLE=str(format_tool))
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn('does not run completely', result.stderr)

    def test_the_style_script_checks_the_changed_files_with_a_base_commit_and_all_files_without_one(self):
        head = subprocess.run(['git', 'rev-parse', 'HEAD'], capture_output=True, text=True, cwd=ROOT).stdout.strip()
        swiftlint = self.canary_swiftlint()
        format_tool = tool(self.dir, 'swift-format', f'echo "$#" > "{self.dir}/format-count"\n')
        for base, expected in [(head, 'No changed Swift files require linting.'), ('', 'Done linting')]:
            with self.subTest(base=bool(base)):
                result = self.run_script('verify-swift-style.sh', SWIFTLINT_EXECUTABLE=str(swiftlint),
                                         SWIFT_FORMAT_EXECUTABLE=str(format_tool), BASE_SHA=base, HEAD_SHA=head)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn(expected, result.stdout)
                self.assertGreater(int((self.dir / 'format-count').read_text()), 100)


class DecisionReadBaseline(unittest.TestCase):
    """Runs a copy of `lint-swift.sh` in a scratch repository, so each test sets its own baseline and commits."""

    RULE = 'no_try_optional_store_read_in_decision_code'
    FILE = 'Sources/UploadCore/Backup/Reader.swift'

    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        self.dir = Path(self.scratch.name)
        self.repo = self.dir / 'repo'
        (self.repo / 'scripts').mkdir(parents=True)
        for name in ['scripts/lint-swift.sh', 'scripts/swift-file-selection.sh', 'scripts/build-paths.sh', '.swiftlint.yml',
                     '.swiftlint-decision-reads.yml']:
            (self.repo / name).write_text((ROOT / name).read_text())
        (self.repo / 'Sources/UploadCore/Backup').mkdir(parents=True)
        (self.repo / self.FILE).write_text('let reader = 1\n')
        self.git('init', '-q', '-b', 'main')
        self.base = self.commit_baseline(f'2 {self.RULE} {self.FILE}\n')

    def git(self, *arguments):
        environment = dict(os.environ, GIT_AUTHOR_NAME='test', GIT_AUTHOR_EMAIL='test@example.invalid',
                           GIT_COMMITTER_NAME='test', GIT_COMMITTER_EMAIL='test@example.invalid')
        return subprocess.run(['git', *arguments], capture_output=True, text=True, cwd=self.repo, env=environment,
                              check=True).stdout.strip()

    def commit_baseline(self, text):
        baseline = self.repo / '.swiftlint-decision-reads-baseline'
        if text is None:
            baseline.unlink()
        else:
            baseline.write_text('# count rule file\n' + text)
        self.git('add', '-A')
        self.git('commit', '-q', '--allow-empty', '-m', 'baseline')
        return self.git('rev-parse', 'HEAD')

    def swiftlint(self, sites=0, decision_output=None, decision_status=None, rule=None, file=None):
        # The main configuration finds nothing; the decision-read configuration reports `sites` violations of `rule` in
        # `file` (RULE and FILE by default). Like the real tool, it prints the path with every symbolic link resolved.
        lines = decision_output if decision_output is not None else '\n'.join(
            f'{os.path.realpath(self.repo)}/{file or self.FILE}:{line}:5: error: Strict store read in decision code '
            f'Violation: m. ({rule or self.RULE})' for line in range(1, sites + 1))
        status = decision_status if decision_status is not None else (2 if sites else 0)
        return tool(self.dir, 'swiftlint', f'''if [[ "$1" == "version" ]]; then echo 0.65.1; exit 0; fi
if [[ "$*" == *.swiftlint-decision-reads.yml* ]]; then
for argument in "$@"; do [[ "$argument" == *.swiftlint-decision-reads.yml ]] && cp "$argument" "{self.dir}/decision-config"; done
cat <<'TEXT'
{lines}
TEXT
exit {status}
fi
echo "Done linting!"
''')

    def lint(self, swiftlint, *arguments, root=None):
        env = dict(os.environ, SWIFTLINT_EXECUTABLE=str(swiftlint))
        root = root or self.repo
        return subprocess.run(['bash', str(root / 'scripts/lint-swift.sh'), *arguments], capture_output=True,
                              text=True, env=env, cwd=root)

    def test_decision_reads_within_the_baseline_pass(self):
        for sites in [0, 1, 2]:
            with self.subTest(sites=sites):
                result = self.lint(self.swiftlint(sites), self.FILE)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    @staticmethod
    def included_patterns(config):
        """Returns the `included` pattern of each rule of a configuration, with its YAML aliases resolved."""
        anchors, patterns, rule = {}, {}, None
        for line in config.splitlines():
            if match := re.match(r'^  ([a-z_]+):\s*$', line):
                rule = match.group(1)
            elif match := re.match(r"^    included: (?:&(\w+) )?(?:\*(\w+)|'(.*)')$", line):
                value = anchors[match.group(2)] if match.group(2) else match.group(3)
                if match.group(1):
                    anchors[match.group(1)] = value
                patterns[rule] = value
        return patterns

    def test_the_host_rules_are_anchored_to_the_root_of_the_checkout(self):
        # SwiftLint matches the host rules against absolute paths, so a directory called App above the checkout would
        # make every file a host file. The configuration that SwiftLint reads names the root of the checkout; check
        # which paths its `included` pattern of each host rule accepts.
        self.assertEqual(self.lint(self.swiftlint(), self.FILE).returncode, 0)
        config = (self.dir / 'decision-config').read_text()
        self.assertNotIn('HOST_ROOT', config)
        root = os.path.realpath(self.repo)
        # The temporary directory is a symbolic link below /private on macOS; SwiftLint can print either spelling.
        other = root.removeprefix('/private') if root.startswith('/private/') else '/private' + root
        patterns = self.included_patterns(config)
        for rule in ['no_domain_error_decision_in_host', 'no_store_health_check_in_host']:
            pattern = re.compile(patterns[rule])
            for base in [root, other]:
                for path, is_host in [
                    (f'{base}/App/Views/MainView.swift', True),
                    (f'{base}/iOSApp/MobileLibraryModel.swift', True),
                    (f'{base}/Packages/EncryptedMemoriesKit/Sources/PhotosCore/App/Leak.swift', False),
                    (f'{base}/Packages/EncryptedMemoriesKit/Sources/PhotosCore/iOSApp/Leak.swift', False),
                    (f'{base}/{self.FILE}', False),
                    (f'{base}/Apps/Other.swift', False),
                    (f'{base}-other/App/Other.swift', False),
                    ('/elsewhere/App/Other.swift', False),
                ]:
                    with self.subTest(rule=rule, path=path.replace(base, '<root>')):
                        self.assertEqual(bool(pattern.search(path)), is_host)

    def test_a_decision_read_beyond_the_baseline_fails_and_names_its_site(self):
        result = self.lint(self.swiftlint(3), self.FILE)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn(f'{self.FILE}:3:5', result.stderr)
        self.assertIn('3 found, 2 allowed', result.stderr)

    def test_a_decision_read_in_a_file_without_a_baseline_entry_fails(self):
        self.commit_baseline('')
        result = self.lint(self.swiftlint(1), self.FILE)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn('1 found, 0 allowed', result.stderr)

    def test_a_repository_reached_through_a_symbolic_link_keeps_its_baseline(self):
        link = self.dir / 'link'
        link.symlink_to(self.repo, target_is_directory=True)
        result = self.lint(self.swiftlint(2), self.FILE, root=link)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_the_baseline_can_shrink_but_never_grow(self):
        swiftlint = self.swiftlint()
        cases = [
            (f'1 {self.RULE} {self.FILE}\n', 0),
            ('', 0),
            (f'3 {self.RULE} {self.FILE}\n', 1),
            (f'2 {self.RULE} {self.FILE}\n1 {self.RULE} Sources/UploadCore/Backup/Other.swift\n', 1),
            (f'2 {self.RULE} {self.FILE}\n1 no_try_optional_in_store_lookup {self.FILE}\n', 1),
        ]
        for text, status in cases:
            with self.subTest(baseline=text):
                head = self.commit_baseline(text)
                result = self.lint(swiftlint, '--diff', self.base, head)
                self.assertEqual(result.returncode, status, result.stdout + result.stderr)
                if status:
                    self.assertIn('baseline grew', result.stderr)

    def test_the_baseline_is_compared_with_the_merge_base_of_a_stale_head(self):
        # A pull request branched before the base branch lowered the baseline.
        self.git('checkout', '-q', '-b', 'pull')
        (self.repo / 'Unrelated.swift').write_text('let unrelated = 1\n')
        unchanged = self.commit_baseline(f'2 {self.RULE} {self.FILE}\n')
        raised = self.commit_baseline(f'3 {self.RULE} {self.FILE}\n')
        self.git('checkout', '-q', 'main')
        lowered = self.commit_baseline(f'1 {self.RULE} {self.FILE}\n')
        swiftlint = self.swiftlint()
        result = self.lint(swiftlint, '--diff', lowered, unchanged)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        result = self.lint(swiftlint, '--diff', lowered, raised)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn('baseline grew', result.stderr)

    def commit_rules(self, *rules, baseline):
        """Commits a rule configuration that names `rules` and the given baseline."""
        config = 'only_rules:\n  - custom_rules\n\ncustom_rules:\n' + ''.join(
            f"  {rule}:\n    regex: 'x'\n    message: m\n" for rule in rules)
        (self.repo / '.swiftlint-decision-reads.yml').write_text(config)
        return self.commit_baseline(baseline)

    def test_a_rule_that_the_change_adds_starts_with_its_own_baseline_lines(self):
        added = 'no_store_health_check_in_host'
        base = self.commit_rules(self.RULE, baseline=f'2 {self.RULE} {self.FILE}\n')
        head = self.commit_rules(
            self.RULE, added, baseline=f'2 {self.RULE} {self.FILE}\n3 {added} App/Reader.swift\n')
        result = self.lint(self.swiftlint(), '--diff', base, head)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_a_rule_of_the_merge_base_cannot_be_renamed_or_removed_with_an_inflated_baseline(self):
        base = self.commit_rules(self.RULE, baseline=f'2 {self.RULE} {self.FILE}\n')
        cases = [
            ('renamed', ['renamed_rule'], f'49 renamed_rule {self.FILE}\n'),
            ('removed', [], ''),
            ('renamed and another rule added', ['renamed_rule', 'another_rule'],
             f'2 renamed_rule {self.FILE}\n1 another_rule {self.FILE}\n'),
        ]
        for name, rules, baseline in cases:
            with self.subTest(case=name):
                head = self.commit_rules(*rules, baseline=baseline)
                result = self.lint(self.swiftlint(), '--diff', base, head)
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn(f'missing from the configuration: {self.RULE}', result.stderr)

    def test_a_rule_that_exists_at_the_merge_base_cannot_regrow_from_an_empty_baseline(self):
        base = self.commit_rules(self.RULE, baseline='')
        head = self.commit_rules(self.RULE, baseline=f'1 {self.RULE} {self.FILE}\n')
        result = self.lint(self.swiftlint(), '--diff', base, head)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn(f'{self.RULE}: 1 sites, 0 at the merge base', result.stderr)

    def test_a_rule_that_the_change_adds_cannot_hide_a_baseline_line_of_an_existing_rule(self):
        added = 'no_store_health_check_in_host'
        base = self.commit_rules(self.RULE, baseline=f'2 {self.RULE} {self.FILE}\n')
        head = self.commit_rules(
            self.RULE, added, baseline=f'3 {self.RULE} {self.FILE}\n1 {added} App/Reader.swift\n')
        result = self.lint(self.swiftlint(), '--diff', base, head)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn(f'{self.RULE}: 3 sites, 2 at the merge base', result.stderr)

    def test_a_base_without_a_baseline_lets_a_change_add_it(self):
        without = self.commit_baseline(None)
        added = self.commit_baseline(f'5 {self.RULE} {self.FILE}\n')
        result = self.lint(self.swiftlint(), '--diff', without, added)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_a_malformed_baseline_fails_the_check(self):
        cases = [
            (f'two {self.RULE} {self.FILE}\n', 'is not'),
            (f'0 {self.RULE} {self.FILE}\n', 'is not'),
            (f'1 {self.RULE} Sources/With Space.swift\n', 'is not'),
            (f'1 {self.RULE} {self.FILE}\n1 {self.RULE} {self.FILE}\n', 'repeats'),
        ]
        for text, message in cases:
            with self.subTest(baseline=text):
                head = self.commit_baseline(text)
                for arguments in [[self.FILE], ['--diff', self.base, head]]:
                    result = self.lint(self.swiftlint(), *arguments)
                    self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                    self.assertIn(message, result.stderr)

    def test_a_moved_renamed_or_split_baseline_line_passes_while_the_rule_total_does_not_rise(self):
        swiftlint = self.swiftlint()
        other = 'Sources/UploadCore/Backup/Other.swift'
        cases = [
            ('renamed', f'2 {self.RULE} {other}\n', 0),
            ('split', f'1 {self.RULE} {self.FILE}\n1 {self.RULE} {other}\n', 0),
            ('raised total', f'3 {self.RULE} {other}\n', 1),
            ('new line, raised total', f'2 {self.RULE} {self.FILE}\n1 {self.RULE} {other}\n', 1),
        ]
        for name, text, status in cases:
            with self.subTest(case=name):
                head = self.commit_baseline(text)
                result = self.lint(swiftlint, '--diff', self.base, head)
                self.assertEqual(result.returncode, status, result.stdout + result.stderr)
                if status:
                    self.assertIn('baseline grew', result.stderr)
                    self.assertIn(f'{self.RULE}: 3 sites, 2 at the merge base', result.stderr)

    def test_a_comment_that_turns_off_a_decision_read_rule_fails_the_check(self):
        for comment, status in [
            (f'// swiftlint:disable:next {self.RULE}', 1),
            ('// swiftlint:disable:this no_try_optional_in_store_lookup trailing_whitespace', 1),
            ('// swiftlint:disable custom_rules', 1),
            ('// swiftlint:disable all', 1),
            ('// swiftlint:disable:next trailing_whitespace', 0),
        ]:
            with self.subTest(comment=comment):
                (self.repo / self.FILE).write_text(f'{comment}\nlet reader = 1\n')
                result = self.lint(self.swiftlint(), self.FILE)
                self.assertEqual(result.returncode, status, result.stdout + result.stderr)
                if status:
                    self.assertIn('turns off a decision-read rule', result.stderr)
                    self.assertIn(self.FILE, result.stderr)

    def test_a_linted_file_below_its_baseline_gets_a_notice(self):
        result = self.lint(self.swiftlint(1), self.FILE)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(f'Notice: lower the decision-read baseline: {self.RULE} {self.FILE}: 1 found, 2 allowed',
                      result.stdout)
        result = self.lint(self.swiftlint(2), self.FILE)
        self.assertNotIn('Notice:', result.stdout)

    def test_the_checked_in_baseline_has_no_slack_for_its_existing_core_site(self):
        self.FILE = 'Packages/EncryptedMemoriesKit/Sources/AlbumSyncCore/AlbumSyncBackupReport.swift'
        rule = 'decision_code_receives_store_protocol'
        source = self.repo / self.FILE
        source.parent.mkdir(parents=True)
        source.write_text('let reader = 1\n')
        baseline = '.swiftlint-decision-reads-baseline'
        (self.repo / baseline).write_bytes((ROOT / baseline).read_bytes())
        # The real full lint reports one current site in this file. Use the checked-in allowance, not the scratch
        # baseline. The file must stay a site that the checked-in baseline still lists with one allowed read; when a
        # change removes the site, it lowers the baseline line and updates this test in the same commit (#1140 did both
        # for its four store-read sites).
        for sites, status in [(1, 0), (2, 1)]:
            with self.subTest(sites=sites):
                result = self.lint(self.swiftlint(sites, rule=rule), self.FILE)
                self.assertEqual(result.returncode, status, result.stdout + result.stderr)
                self.assertNotIn('Notice: lower the decision-read baseline:', result.stdout)

    def test_the_checked_in_host_baseline_lines_have_no_slack_for_their_existing_sites(self):
        # The real full lint reports exactly these host sites (#1157). Use the checked-in allowance, not the scratch
        # baseline. When a change removes a host site, it lowers its baseline line and its count here in the same commit.
        baseline = '.swiftlint-decision-reads-baseline'
        (self.repo / baseline).write_bytes((ROOT / baseline).read_bytes())
        for count, rule, file in [
            (1, 'no_domain_error_decision_in_host', 'App/FolderBackupController.swift'),
            (2, 'no_store_health_check_in_host', 'App/FolderBackupController.swift'),
            (1, 'no_store_health_check_in_host', 'App/Views/MainView.swift'),
            (1, 'no_store_health_check_in_host', 'iOSApp/MobileLibraryModel.swift'),
        ]:
            source = self.repo / file
            source.parent.mkdir(parents=True, exist_ok=True)
            source.write_text('let reader = 1\n')
            for sites, status in [(count, 0), (count + 1, 1)]:
                with self.subTest(rule=rule, file=file, sites=sites):
                    result = self.lint(self.swiftlint(sites, rule=rule, file=file), file)
                    self.assertEqual(result.returncode, status, result.stdout + result.stderr)
                    # A file with a line for another rule gets that rule's notice, because the run reports only `rule`.
                    self.assertNotIn(f'Notice: lower the decision-read baseline: {rule} {file}:', result.stdout)

    def test_a_malformed_baseline_at_the_head_fails_with_a_clean_working_tree(self):
        head = self.commit_baseline(f'two {self.RULE} {self.FILE}\n')
        (self.repo / '.swiftlint-decision-reads-baseline').write_text(f'2 {self.RULE} {self.FILE}\n')
        result = self.lint(self.swiftlint(), '--diff', self.base, head)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn(f'{head}:.swiftlint-decision-reads-baseline: line 2 is not', result.stderr)

    def test_a_failed_decision_read_pass_fails_the_check(self):
        result = self.lint(self.swiftlint(decision_output='Could not read the configuration.', decision_status=1),
                           self.FILE)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn('Could not read the configuration.', result.stdout + result.stderr)

    def test_a_skipped_decision_read_rule_fails_the_check(self):
        message = "warning: Skipping enabled rule 'custom_rules' because it requires SourceKit."
        result = self.lint(self.swiftlint(decision_output=message, decision_status=0), self.FILE)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn('style check is incomplete', result.stderr)


if __name__ == '__main__':
    unittest.main()
