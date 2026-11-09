import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).with_name('queue_path_policy.py')
spec = importlib.util.spec_from_file_location('queue_path_policy', SCRIPT)
policy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(policy)


class QueuePathPolicyTests(unittest.TestCase):
    def test_allowlist_and_denials(self):
        for paths in [['Wiki/page.txt'], ['site/index.html'], ['docs/guide.md'], ['README.md'], ['Wiki/a', 'site/b']]:
            with self.subTest(paths=paths):
                self.assertTrue(policy.can_skip(paths))
        for path in ['.github/a.md', 'scripts/a.md', 'project.yml', 'BuildSupport/a.md',
                     'VendorPatches/a.md', 'site/a.swift', 'Wiki/a.Swift', 'App/a.md',
                     'CONTRIBUTING.md', 'AGENTS.md', 'CLAUDE.md', 'PROJECT-TRAPS.md', 'unknown']:
            with self.subTest(path=path):
                self.assertFalse(policy.can_skip([path]))
                self.assertFalse(policy.can_skip(['site/index.html', path]))
        self.assertFalse(policy.can_skip([]))

    def test_git_diff_counts_both_sides_of_rename_and_invalid_base_runs(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            def git(*args):
                return subprocess.run(['git', *args], cwd=root, check=True, capture_output=True, text=True).stdout.strip()
            git('init', '-q')
            git('config', 'user.name', 'Test')
            git('config', 'user.email', 'test@example.invalid')
            (root / 'site').mkdir()
            (root / 'site/a.md').write_text('same content\n')
            git('add', '.')
            git('commit', '-qm', 'base')
            base = git('rev-parse', 'HEAD')
            (root / 'site/a.md').write_text('changed content\n')
            git('add', '-A')
            git('commit', '-qm', 'documentation')
            doc_head = git('rev-parse', 'HEAD')
            output = root / 'output'
            env = dict(os.environ, BASE_SHA=base, HEAD_SHA=doc_head, GITHUB_OUTPUT=str(output))
            subprocess.run(['python3', str(SCRIPT)], cwd=root, env=env, check=True, capture_output=True)
            self.assertEqual('run_macos=false\n', output.read_text())
            output.unlink()
            (root / 'site/a.md').rename(root / 'unknown')
            git('add', '-A')
            git('commit', '-qm', 'rename')
            env.update(BASE_SHA=doc_head, HEAD_SHA=git('rev-parse', 'HEAD'))
            subprocess.run(['python3', str(SCRIPT)], cwd=root, env=env, check=True, capture_output=True)
            self.assertEqual('run_macos=true\n', output.read_text())
            output.unlink()
            env['BASE_SHA'] = 'not-a-commit'
            subprocess.run(['python3', str(SCRIPT)], cwd=root, env=env, check=True, capture_output=True)
            self.assertEqual('run_macos=true\n', output.read_text())


if __name__ == '__main__':
    unittest.main()
