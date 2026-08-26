from __future__ import annotations

import importlib.util
from pathlib import Path
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "verify-apple-vision-sdk-surface.py"
SPEC = importlib.util.spec_from_file_location("verify_apple_vision_sdk_surface", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class ReviewedVisionRequestNamesTests(unittest.TestCase):
    def test_accepts_formatted_multiline_inventory_entries(self) -> None:
        source = """
        public static let entries = [
            entry(
                .textRecognition,
                "RecognizeTextRequest",
                "VNRecognizeTextRequest",
                "13"
            ),
            entry(.documentRecognition, "RecognizeDocumentsRequest", nil, "26"),
        ]
        public static let exclusions = [
            AppleVisionRequestExclusion(
                requestName: "CoreMLRequest",
                reason: "Handled by the Core ML runtime."
            )
        ]
        """

        modern, legacy = MODULE.reviewed_request_names(source)

        self.assertEqual(
            modern,
            {"RecognizeTextRequest", "RecognizeDocumentsRequest", "CoreMLRequest"},
        )
        self.assertIn("VNRecognizeTextRequest", legacy)

    def test_ignores_unrelated_request_strings(self) -> None:
        source = 'let diagnostic = "UnreviewedRequest"'

        modern, legacy = MODULE.reviewed_request_names(source)

        self.assertEqual(modern, set())
        self.assertEqual(legacy, set())


if __name__ == "__main__":
    unittest.main()
