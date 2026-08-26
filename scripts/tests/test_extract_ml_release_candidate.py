from __future__ import annotations

import importlib.util
import io
from pathlib import Path
import tarfile
import tempfile
import unittest


SCRIPT = Path(__file__).parents[1] / "extract-ml-release-candidate.py"
SPEC = importlib.util.spec_from_file_location("extract_ml_release_candidate", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class CandidateArchiveTests(unittest.TestCase):
    def test_extracts_regular_candidate(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive = root / "candidate.tar.gz"
            self._write_archive(
                archive,
                {
                    "source-repository-revision.txt": b"a" * 40,
                    "models/model/release-manifest.json": b"{}",
                    "evidence/model.json": b"{}",
                    "qualification/model.json": b"{}",
                    "notices/model.txt": b"license",
                },
            )
            destination = root / "candidate"
            MODULE.extract_candidate(archive, destination)
            self.assertEqual(
                (destination / "source-repository-revision.txt").read_bytes(),
                b"a" * 40,
            )

    def test_rejects_traversal_and_links(self) -> None:
        for name, link in [("../escape", None), ("models/link", "/private/tmp")]:
            with self.subTest(name=name):
                with tempfile.TemporaryDirectory() as directory:
                    root = Path(directory)
                    archive = root / "candidate.tar.gz"
                    with tarfile.open(archive, "w:gz") as output:
                        entry = tarfile.TarInfo(name)
                        if link is None:
                            entry.size = 1
                            output.addfile(entry, io.BytesIO(b"x"))
                        else:
                            entry.type = tarfile.SYMTYPE
                            entry.linkname = link
                            output.addfile(entry)
                    with self.assertRaises(ValueError):
                        MODULE.extract_candidate(archive, root / "candidate")

    @staticmethod
    def _write_archive(archive: Path, files: dict[str, bytes]) -> None:
        with tarfile.open(archive, "w:gz") as output:
            for name, contents in files.items():
                entry = tarfile.TarInfo(name)
                entry.size = len(contents)
                output.addfile(entry, io.BytesIO(contents))


if __name__ == "__main__":
    unittest.main()
