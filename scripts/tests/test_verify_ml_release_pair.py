from __future__ import annotations

import hashlib
import importlib.util
import json
import base64
from pathlib import Path
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "verify-ml-release-pair.py"
SPEC = importlib.util.spec_from_file_location("verify_ml_release_pair", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class VerifyMLReleasePairTests(unittest.TestCase):
    def make_pair(self) -> tuple[tempfile.TemporaryDirectory[str], Path, dict]:
        temporary = tempfile.TemporaryDirectory()
        root = Path(temporary.name)
        catalogs = {
            "catalog-v1.json": {"schemaVersion": 1, "models": []},
            "catalog-v2.json": {
                "schemaVersion": 2,
                "catalogSequence": 4,
                "models": [
                    {
                        "id": "model-one",
                        "revision": "revision-1",
                        "releaseSequence": 3,
                    }
                ],
            },
        }
        for name, value in catalogs.items():
            (root / name).write_text(json.dumps(value), encoding="utf-8")
        (root / "catalog-v1.sig").write_bytes(b"a" * 64)
        (root / "catalog-v2.sig").write_bytes(b"b" * 64)

        files = []
        for name in sorted(MODULE.EXPECTED_FILES):
            data = (root / name).read_bytes()
            files.append(
                {
                    "path": name,
                    "sha256": hashlib.sha256(data).hexdigest(),
                    "bytes": len(data),
                }
            )
        manifest = {
            "schemaVersion": 1,
            "catalogSequence": 4,
            "files": files,
            "models": [{"id": "model-one", "revision": "revision-1"}],
        }
        (root / "release-pair.json").write_text(json.dumps(manifest), encoding="utf-8")
        return temporary, root, manifest

    def write_pointer(self, root: Path, pair_id: str, sequence: int = 4) -> None:
        objects = []
        for name in sorted(MODULE.POINTER_OBJECT_NAMES):
            path = root / name
            objects.append(
                {
                    "name": name,
                    "path": f"catalog-history/{pair_id}/{name}",
                    "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
                    "bytes": path.stat().st_size,
                }
            )
        pointer = {
            "payload": {
                "schemaVersion": 1,
                "pairID": pair_id,
                "catalogSequence": sequence,
                "objects": objects,
            },
            "signature": base64.b64encode(b"p" * 64).decode("ascii"),
        }
        (root / "active-pair.json").write_text(json.dumps(pointer), encoding="utf-8")

    def refresh_manifest_files(self, root: Path, manifest: dict) -> None:
        manifest["files"] = []
        for name in sorted(MODULE.EXPECTED_FILES):
            data = (root / name).read_bytes()
            manifest["files"].append(
                {
                    "path": name,
                    "sha256": hashlib.sha256(data).hexdigest(),
                    "bytes": len(data),
                }
            )
        (root / "release-pair.json").write_text(json.dumps(manifest), encoding="utf-8")

    def test_accepts_a_complete_pair(self) -> None:
        temporary, root, _ = self.make_pair()
        self.addCleanup(temporary.cleanup)
        expected = hashlib.sha256((root / "release-pair.json").read_bytes()).hexdigest()

        pair_id, sequence = MODULE.verify_pair(root, expected)

        self.assertEqual(pair_id, expected)
        self.assertEqual(sequence, 4)

    def test_rejects_duplicate_file_entries(self) -> None:
        temporary, root, manifest = self.make_pair()
        self.addCleanup(temporary.cleanup)
        manifest["files"].append(manifest["files"][0])
        (root / "release-pair.json").write_text(json.dumps(manifest), encoding="utf-8")

        with self.assertRaisesRegex(ValueError, "file set"):
            MODULE.verify_pair(root)

    def test_rejects_boolean_file_sizes(self) -> None:
        temporary, root, manifest = self.make_pair()
        self.addCleanup(temporary.cleanup)
        manifest["files"][0]["bytes"] = True
        (root / "release-pair.json").write_text(json.dumps(manifest), encoding="utf-8")

        with self.assertRaisesRegex(ValueError, "digest entry"):
            MODULE.verify_pair(root)

    def test_rejects_missing_model_release_sequence(self) -> None:
        temporary, root, _ = self.make_pair()
        self.addCleanup(temporary.cleanup)
        catalog = json.loads((root / "catalog-v2.json").read_text(encoding="utf-8"))
        del catalog["models"][0]["releaseSequence"]
        (root / "catalog-v2.json").write_text(json.dumps(catalog), encoding="utf-8")

        with self.assertRaises(ValueError):
            MODULE.verify_pair(root)

    def test_rejects_legacy_model_missing_from_v2(self) -> None:
        temporary, root, manifest = self.make_pair()
        self.addCleanup(temporary.cleanup)
        v1 = json.loads((root / "catalog-v1.json").read_text(encoding="utf-8"))
        v1["models"] = [
            {
                "id": "legacy-model",
                "revision": "revision-legacy",
                "artifacts": [
                    {
                        "path": "Model.mlmodelc/weights.bin",
                        "url": "https://models.example.test/models/legacy/weights.bin",
                        "sha256": "a" * 64,
                        "bytes": 1,
                    }
                ],
            }
        ]
        (root / "catalog-v1.json").write_text(json.dumps(v1), encoding="utf-8")
        self.refresh_manifest_files(root, manifest)

        with self.assertRaisesRegex(ValueError, "missing from catalog-v2"):
            MODULE.verify_pair(root)

    def test_rejects_legacy_model_artifact_divergence(self) -> None:
        temporary, root, manifest = self.make_pair()
        self.addCleanup(temporary.cleanup)
        legacy_artifact = {
            "path": "Model.mlmodelc/weights.bin",
            "url": "https://models.example.test/models/legacy/weights.bin",
            "sha256": "a" * 64,
            "bytes": 1,
        }
        v1 = {"schemaVersion": 1, "models": [{
            "id": "model-one",
            "revision": "revision-1",
            "artifacts": [legacy_artifact],
        }]}
        (root / "catalog-v1.json").write_text(json.dumps(v1), encoding="utf-8")
        v2 = json.loads((root / "catalog-v2.json").read_text(encoding="utf-8"))
        v2["models"][0]["artifacts"] = [dict(legacy_artifact, sha256="b" * 64)]
        (root / "catalog-v2.json").write_text(json.dumps(v2), encoding="utf-8")
        self.refresh_manifest_files(root, manifest)

        with self.assertRaisesRegex(ValueError, "diverges from catalog-v2"):
            MODULE.verify_pair(root)

    def test_artifact_list_emits_verified_r2_rows(self) -> None:
        temporary, root, _ = self.make_pair()
        self.addCleanup(temporary.cleanup)
        catalog = {
            "schemaVersion": 2,
            "models": [{
                "id": "model-one",
                "revision": "revision-1",
                "artifacts": [{
                    "path": "Model.mlmodelc/weights.bin",
                    "url": "https://models.oncloud.at/models/model-one/revision-1/Model.mlmodelc/weights.bin",
                    "sha256": "a" * 64,
                    "bytes": 7,
                }],
            }],
        }
        catalog_path = root / "artifact-catalog.json"
        catalog_path.write_text(json.dumps(catalog), encoding="utf-8")

        self.assertEqual(
            MODULE.verify_artifact_list(catalog_path, "https://models.oncloud.at/models/"),
            ["models/model-one/revision-1/Model.mlmodelc/weights.bin\t" + "a" * 64 + "\t7"],
        )

    def test_artifact_list_rejects_untrusted_url(self) -> None:
        temporary, root, _ = self.make_pair()
        self.addCleanup(temporary.cleanup)
        catalog = {
            "schemaVersion": 2,
            "models": [{
                "id": "model-one",
                "revision": "revision-1",
                "artifacts": [{
                    "path": "Model.mlmodelc/weights.bin",
                    "url": "https://example.test/models/model-one/revision-1/Model.mlmodelc/weights.bin",
                    "sha256": "a" * 64,
                    "bytes": 7,
                }],
            }],
        }
        catalog_path = root / "artifact-catalog.json"
        catalog_path.write_text(json.dumps(catalog), encoding="utf-8")

        with self.assertRaisesRegex(ValueError, "untrusted artifact URL"):
            MODULE.verify_artifact_list(catalog_path, "https://models.oncloud.at/models/")

    def test_artifact_list_matches_swift_model_id_and_revision_constraints(self) -> None:
        temporary, root, _ = self.make_pair()
        self.addCleanup(temporary.cleanup)

        def write_catalog(model_id: str, revision: str) -> Path:
            catalog_path = root / "artifact-catalog.json"
            artifact_path = "Model.mlmodelc/weights.bin"
            catalog_path.write_text(
                json.dumps(
                    {
                        "schemaVersion": 2,
                        "models": [{
                            "id": model_id,
                            "revision": revision,
                            "artifacts": [{
                                "path": artifact_path,
                                "url": f"https://models.oncloud.at/models/{model_id}/{revision}/{artifact_path}",
                                "sha256": "a" * 64,
                                "bytes": 7,
                            }],
                        }],
                    }
                ),
                encoding="utf-8",
            )
            return catalog_path

        self.assertEqual(
            MODULE.verify_artifact_list(write_catalog("x", "r1"), "https://models.oncloud.at/models/"),
            ["models/x/r1/Model.mlmodelc/weights.bin\t" + "a" * 64 + "\t7"],
        )
        for model_id in ("Model", "model.one", "model--one", "a" * 129):
            with self.subTest(model_id=model_id):
                with self.assertRaisesRegex(ValueError, "model metadata"):
                    MODULE.verify_artifact_list(write_catalog(model_id, "r1"), "https://models.oncloud.at/models/")
        for revision in ("revision.", "r" * 129):
            with self.subTest(revision=revision):
                with self.assertRaisesRegex(ValueError, "model metadata"):
                    MODULE.verify_artifact_list(write_catalog("x", revision), "https://models.oncloud.at/models/")

    def test_artifact_list_omits_retired_rows(self) -> None:
        temporary, root, _ = self.make_pair()
        self.addCleanup(temporary.cleanup)
        catalog = {
            "schemaVersion": 2,
            "models": [
                {"id": "retired", "revision": "old", "availability": "retired"},
                {
                    "id": "model-one",
                    "revision": "revision-1",
                    "artifacts": [{
                        "path": "Model.mlmodelc/weights.bin",
                        "url": "https://models.oncloud.at/models/model-one/revision-1/Model.mlmodelc/weights.bin",
                        "sha256": "a" * 64,
                        "bytes": 7,
                    }],
                },
            ],
        }
        catalog_path = root / "artifact-catalog.json"
        catalog_path.write_text(json.dumps(catalog), encoding="utf-8")

        self.assertEqual(
            MODULE.verify_artifact_list(catalog_path, "https://models.oncloud.at/models/"),
            ["models/model-one/revision-1/Model.mlmodelc/weights.bin\t" + "a" * 64 + "\t7"],
        )

    def test_pair_accepts_a_retired_tombstone(self) -> None:
        temporary, root, manifest = self.make_pair()
        self.addCleanup(temporary.cleanup)
        catalog = json.loads((root / "catalog-v2.json").read_text(encoding="utf-8"))
        catalog["models"][0]["availability"] = "retired"
        (root / "catalog-v2.json").write_text(json.dumps(catalog), encoding="utf-8")
        manifest["models"] = [{
            "id": "model-one",
            "revision": "revision-1",
            "availability": "retired",
        }]
        self.refresh_manifest_files(root, manifest)

        MODULE.verify_pair(root)

    def test_pair_rejects_a_legacy_mapping_to_a_retired_model(self) -> None:
        temporary, root, manifest = self.make_pair()
        self.addCleanup(temporary.cleanup)
        v1 = {
            "schemaVersion": 1,
            "models": [{
                "id": "model-one",
                "revision": "revision-1",
                "artifacts": [{"path": "Model.mlmodelc/weights.bin"}],
            }],
        }
        (root / "catalog-v1.json").write_text(json.dumps(v1), encoding="utf-8")
        v2 = json.loads((root / "catalog-v2.json").read_text(encoding="utf-8"))
        v2["models"][0]["availability"] = "retired"
        (root / "catalog-v2.json").write_text(json.dumps(v2), encoding="utf-8")
        manifest["models"] = [{
            "id": "model-one",
            "revision": "revision-1",
            "availability": "retired",
        }]
        self.refresh_manifest_files(root, manifest)

        with self.assertRaisesRegex(ValueError, "must map to an active V2 model"):
            MODULE.verify_pair(root)

    def test_pair_rejects_unknown_availability(self) -> None:
        temporary, root, manifest = self.make_pair()
        self.addCleanup(temporary.cleanup)
        catalog = json.loads((root / "catalog-v2.json").read_text(encoding="utf-8"))
        catalog["models"][0]["availability"] = "paused"
        (root / "catalog-v2.json").write_text(json.dumps(catalog), encoding="utf-8")
        self.refresh_manifest_files(root, manifest)

        with self.assertRaisesRegex(ValueError, "catalog model metadata"):
            MODULE.verify_pair(root)

    def test_accepts_a_valid_active_pointer(self) -> None:
        temporary, root, _ = self.make_pair()
        self.addCleanup(temporary.cleanup)
        pair_id = hashlib.sha256((root / "release-pair.json").read_bytes()).hexdigest()
        self.write_pointer(root, pair_id)

        self.assertEqual(MODULE.verify_pointer(root / "active-pair.json", pair_id), (pair_id, 4))
        self.assertEqual(MODULE.verify_pair(root, pair_id), (pair_id, 4))

    def test_rejects_active_pointer_path_escape(self) -> None:
        temporary, root, _ = self.make_pair()
        self.addCleanup(temporary.cleanup)
        pair_id = hashlib.sha256((root / "release-pair.json").read_bytes()).hexdigest()
        self.write_pointer(root, pair_id)
        pointer = json.loads((root / "active-pair.json").read_text(encoding="utf-8"))
        pointer["payload"]["objects"][0]["path"] = f"catalog-history/{pair_id}/../catalog-v1.json"
        (root / "active-pair.json").write_text(json.dumps(pointer), encoding="utf-8")

        with self.assertRaisesRegex(ValueError, "pointer object"):
            MODULE.verify_pointer(root / "active-pair.json", pair_id)

    def test_rejects_active_pointer_hash_mismatch(self) -> None:
        temporary, root, _ = self.make_pair()
        self.addCleanup(temporary.cleanup)
        pair_id = hashlib.sha256((root / "release-pair.json").read_bytes()).hexdigest()
        self.write_pointer(root, pair_id)
        pointer = json.loads((root / "active-pair.json").read_text(encoding="utf-8"))
        pointer["payload"]["objects"][0]["sha256"] = "0" * 64
        (root / "active-pair.json").write_text(json.dumps(pointer), encoding="utf-8")

        with self.assertRaisesRegex(ValueError, "active pointer file mismatch"):
            MODULE.verify_pair(root, pair_id)

    def test_rejects_stale_active_pointer_sequence(self) -> None:
        temporary, root, _ = self.make_pair()
        self.addCleanup(temporary.cleanup)
        pair_id = hashlib.sha256((root / "release-pair.json").read_bytes()).hexdigest()
        self.write_pointer(root, pair_id, sequence=3)

        with self.assertRaisesRegex(ValueError, "active pointer does not match"):
            MODULE.verify_pair(root, pair_id)

    def test_rejects_invalid_active_pointer_signature_encoding(self) -> None:
        temporary, root, _ = self.make_pair()
        self.addCleanup(temporary.cleanup)
        pair_id = hashlib.sha256((root / "release-pair.json").read_bytes()).hexdigest()
        self.write_pointer(root, pair_id)
        pointer = json.loads((root / "active-pair.json").read_text(encoding="utf-8"))
        pointer["signature"] = "not-base64"
        (root / "active-pair.json").write_text(json.dumps(pointer), encoding="utf-8")

        with self.assertRaisesRegex(ValueError, "pointer signature"):
            MODULE.verify_pointer(root / "active-pair.json", pair_id)


if __name__ == "__main__":
    unittest.main()
