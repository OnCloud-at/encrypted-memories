import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class ReportBuildStorage(unittest.TestCase):
    def report(self, build_root):
        environment = dict(os.environ, ENCRYPTED_MEMORIES_BUILD_ROOT=str(build_root))
        return subprocess.run(['bash', str(ROOT / 'scripts/report-build-storage.sh')], capture_output=True, text=True,
                              env=environment, cwd=ROOT)

    def test_each_folder_of_the_build_root_is_listed_with_its_size_and_the_total_counts_the_root_once(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / 'build'
            (root / 'SourcePackages.noindex').mkdir(parents=True)
            (root / 'XcodePackageCache.noindex').mkdir()
            (root / 'SourcePackages.noindex/big').write_bytes(b'0' * 3 * 1024 * 1024)
            (root / 'XcodePackageCache.noindex/small').write_bytes(b'0' * 1024 * 1024)
            result = self.report(root)
            self.assertEqual(result.returncode, 0, result.stderr)
            lines = result.stdout.splitlines()
            self.assertEqual(lines[0], 'Canonical Encrypted Memories build storage:')
            names = [match.group(1) for line in lines if (match := re.match(r'\s+[\d.]+ GiB {4}(\S+)$', line))]
            self.assertEqual(names, ['SourcePackages.noindex', 'XcodePackageCache.noindex'])
            total = float(re.search(r'Total reported build storage: ([\d.]+) GiB', result.stdout).group(1))
            root_size = float(re.search(r'\s+([\d.]+) GiB  ' + re.escape(str(root)), result.stdout).group(1))
            # The folders are part of the root: the total is the root, not the root plus its folders.
            self.assertAlmostEqual(total, root_size, delta=0.05)

    def test_a_missing_build_root_lists_nothing_and_succeeds(self):
        with tempfile.TemporaryDirectory() as directory:
            result = self.report(Path(directory) / 'missing')
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stderr, '')
            self.assertNotRegex(result.stdout, r'GiB {4}\S')

    def test_the_size_of_a_folder_is_in_gibibytes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / 'build'
            (root / 'data').mkdir(parents=True)
            (root / 'data/file').write_bytes(b'0' * 64 * 1024 * 1024)
            result = self.report(root)
            size = float(re.search(r'\s+([\d.]+) GiB {4}data$', result.stdout, re.MULTILINE).group(1))
            self.assertAlmostEqual(size, 64 / 1024, delta=0.01)

    def test_the_sizes_show_the_split_that_the_cache_measurement_needs(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / 'build'
            for name, megabytes in [('SourcePackages.noindex', 400), ('XcodePackageCache.noindex', 100)]:
                (root / name).mkdir(parents=True)
                (root / name / 'data').write_bytes(b'0' * megabytes * 1024 * 1024)
            result = self.report(root)
            sizes = {m.group(2): float(m.group(1)) for line in result.stdout.splitlines()
                     if (m := re.match(r'\s+([\d.]+) GiB {4}(\S+)$', line))}
            self.assertGreater(sizes['SourcePackages.noindex'], 3 * sizes['XcodePackageCache.noindex'])
            # The folders are part of the root: the total is the root, not the root plus its folders.
            total = float(re.search(r'Total reported build storage: ([\d.]+) GiB', result.stdout).group(1))
            root_size = float(re.search(r'\s+([\d.]+) GiB  ' + re.escape(str(root)), result.stdout).group(1))
            self.assertAlmostEqual(total, root_size, delta=0.05)


if __name__ == '__main__':
    unittest.main()
