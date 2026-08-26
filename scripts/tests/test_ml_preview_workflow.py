from __future__ import annotations

import base64
from pathlib import Path
import re
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[2]
PREVIEW_WORKFLOW = ROOT / ".github/workflows/ml-model-preview.yml"
PRODUCTION_WORKFLOW = ROOT / ".github/workflows/ml-model-release.yml"
ROLLBACK_SCRIPT = ROOT / "scripts/rollback-ml-model-release.sh"


class MLPreviewWorkflowContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.preview = PREVIEW_WORKFLOW.read_text(encoding="utf-8")
        cls.production = PRODUCTION_WORKFLOW.read_text(encoding="utf-8")

    def test_preview_workflow_parses_as_yaml(self) -> None:
        result = subprocess.run(
            ["ruby", "-e", 'require "yaml"; YAML.load_file(ARGV.fetch(0))', str(PREVIEW_WORKFLOW)],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_preview_requires_confirmation_and_prerelease(self) -> None:
        self.assertIn("confirmation:", self.preview)
        self.assertIn("PUBLISH_PREVIEW", self.preview)
        self.assertRegex(self.preview, r'\.prerelease.*== true')
        self.assertIn("--allow-empty-v1", self.preview)
        self.assertIn("Verify public preview activation", self.preview)
        self.assertIn("active-pair.json?preview=", self.preview)
        self.assertIn('--expected-pair "$PAIR_ID"', self.preview)

    def test_preview_rejects_the_production_base_url(self) -> None:
        self.assertEqual(
            self.preview.count('ML_MODEL_PREVIEW_BASE_URL" != "https://models.oncloud.at/models/"'),
            2,
        )

    def test_preview_has_no_adjacent_duplicate_exit(self) -> None:
        self.assertNotRegex(self.preview, r"(?m)^\s*exit 1\s*$\n\s*exit 1\s*$")

    def test_preview_uses_only_protected_preview_configuration(self) -> None:
        self.assertIn("environment: ml-model-preview", self.preview)
        self.assertIn("ML_MODEL_PREVIEW_R2_BUCKET: ${{ vars.ML_MODEL_PREVIEW_R2_BUCKET }}", self.preview)
        self.assertIn("ML_MODEL_PREVIEW_BASE_URL: ${{ vars.ML_MODEL_PREVIEW_BASE_URL }}", self.preview)
        self.assertIn("ML_MODEL_PREVIEW_R2_ENDPOINT: ${{ secrets.ML_MODEL_PREVIEW_R2_ENDPOINT }}", self.preview)
        self.assertNotIn("ML_MODEL_R2_", self.preview)
        self.assertNotIn("ML_MODEL_BASE_URL", self.preview)
        self.assertNotIn("ml-model-production", self.preview)

    def test_preview_has_no_automatic_release_trigger(self) -> None:
        self.assertNotRegex(self.preview, r"(?m)^  release:")
        self.assertRegex(self.preview, r"(?m)^  workflow_dispatch:")
        self.assertIn("ml-model-preview-*", self.preview)

    def test_production_rejects_preview_tags(self) -> None:
        self.assertIn(
            '[[ "$tag" != ml-model-preview-* ]] || { echo "Preview tags cannot publish production models"',
            self.production,
        )

    def test_workflow_run_blocks_parse_as_bash(self) -> None:
        ruby = r'''
def walk(node, runs)
  case node
  when Hash
    node.each do |key, value|
      runs << value if key == "run" && value.is_a?(String)
      walk(value, runs)
    end
  when Array
    node.each { |value| walk(value, runs) }
  end
end
runs = []
walk(YAML.load_file(ARGV.fetch(0)), runs)
runs.each { |run| puts Base64.strict_encode64(run) }
'''
        for workflow in (PREVIEW_WORKFLOW, PRODUCTION_WORKFLOW):
            result = subprocess.run(
                ["ruby", "-ryaml", "-rbase64", "-e", ruby, str(workflow)],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            encoded_blocks = result.stdout.splitlines()
            self.assertGreater(len(encoded_blocks), 0)
            for index, encoded in enumerate(encoded_blocks):
                shell = subprocess.run(
                    ["bash", "-n"],
                    input=base64.b64decode(encoded),
                    capture_output=True,
                    check=False,
                )
                self.assertEqual(
                    shell.returncode,
                    0,
                    f"{workflow} run block {index}: {shell.stderr.decode()}",
                )

    def test_production_contract_has_no_duplicate_checks(self) -> None:
        self.assertEqual(
            self.production.count("--filter 'MLModelReleaseSchemaTests|MLRemoteModelCatalogTests|MLModelReleaseAutomationTests'"),
            1,
        )
        prepare = self.production.split("- name: Prepare and verify signed release", 1)[1]
        prepare = prepare.split("- name: Retain signed release evidence", 1)[0]
        self.assertEqual(
            len(re.findall(r'xcrun swift scripts/verify-ml-catalog-signature\.swift "\$RELEASE_ROOT/catalog-v2\.json"', prepare)),
            1,
        )

    def test_rollback_publishes_each_signature_before_its_catalog_and_pointer_last(self) -> None:
        rollback = ROLLBACK_SCRIPT.read_text(encoding="utf-8")
        calls = [
            rollback.index('publish_mutable_verified "$prepared/catalog-v1.sig" catalog-v1.sig'),
            rollback.index('publish_mutable_verified "$prepared/catalog-v1.json" catalog-v1.json'),
            rollback.index('publish_mutable_verified "$prepared/catalog-v2.sig" catalog-v2.sig'),
            rollback.index('publish_mutable_verified "$prepared/catalog-v2.json" catalog-v2.json'),
            rollback.index('publish_mutable_verified "$prepared/active-pair.json" active-pair.json'),
        ]
        self.assertEqual(calls, sorted(calls))


if __name__ == "__main__":
    unittest.main()
