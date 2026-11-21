"""Tests for nightly_ui_evidence.py, the evidence file of the nightly UI test jobs (#1134, read by #1166)."""
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest

SCRIPT = pathlib.Path(__file__).resolve().parent / "nightly_ui_evidence.py"
COMMIT = "0123456789abcdef0123456789abcdef01234567"
OTHER_COMMIT = "fedcba9876543210fedcba9876543210fedcba98"
RUN_ID = "43090077070"
RUN_ATTEMPT = "2"


def device(name="iPhone 17", os_version="27.1"):
    return {"deviceId": "ABC", "deviceName": name, "architecture": "arm64", "modelName": "iPhone",
            "platform": "iOS Simulator", "osVersion": os_version, "osBuildNumber": "24B1"}


def summary(passed=10, failed=0, skipped=0, expected=0, devices=None, total=None):
    """The shape of `xcresulttool get test-results summary` (schema 0.5.0); an empty bundle has no device."""
    if devices is None:
        devices = [device()]
    return {
        "title": "Test", "environmentDescription": "T", "topInsights": [], "result": "unknown",
        "totalTestCount": passed + failed + skipped + expected if total is None else total,
        "passedTests": passed, "failedTests": failed, "skippedTests": skipped, "expectedFailures": expected,
        "statistics": [], "testFailures": [], "runtimeWarnings": [],
        "devicesAndConfigurations": [{"device": d, "passedTests": passed, "failedTests": failed,
                                      "skippedTests": skipped, "expectedFailures": expected} for d in devices],
    }


class Result:
    def __init__(self, completed, evidence):
        self.returncode = completed.returncode
        self.stdout = completed.stdout
        self.stderr = completed.stderr
        self.evidence = evidence


def run_script(payload, job="default-simulator", commit=COMMIT, head=COMMIT, raw=None, bundle=True, xcrun_status=0,
               run_id=RUN_ID, run_attempt=RUN_ATTEMPT):
    """Run the script with a fake `xcrun` that prints the payload as the summary of the result bundle."""
    with tempfile.TemporaryDirectory() as directory:
        root = pathlib.Path(directory)
        (root / "summary.json").write_text(raw if raw is not None else json.dumps(payload))
        stub = root / "bin" / "xcrun"
        stub.parent.mkdir()
        stub.write_text(
            "#!/bin/sh\n"
            '[ "$1 $2 $3 $4 $5" = "xcresulttool get test-results summary --path" ] || exit 64\n'
            f"cat '{root / 'summary.json'}'\nexit {xcrun_status}\n")
        stub.chmod(0o755)
        if bundle:
            (root / "ios-ui.xcresult").mkdir()
        out = root / "nested" / "ui-evidence.json"
        completed = subprocess.run(
            [sys.executable, "-I", str(SCRIPT), "--job", job, "--result", str(root / "ios-ui.xcresult"),
             "--run-id", run_id, "--run-attempt", run_attempt,
             "--commit", commit, "--checkout-head", head, "--out", str(out)],
            capture_output=True, text=True, env={"PATH": f"{stub.parent}:/usr/bin:/bin"},
        )
        return Result(completed, json.loads(out.read_text()) if out.exists() else None)


class NightlyUiEvidenceTests(unittest.TestCase):
    def test_passing_run_writes_the_evidence_and_succeeds(self):
        result = run_script(summary(passed=95, skipped=3))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.evidence, {
            "schema": 1, "job": "default-simulator", "run_id": 43090077070, "run_attempt": 2, "commit": COMMIT,
            "simulator": {"name": "iPhone 17", "os": "27.1"},
            "executed": 98, "passed": 95, "failed": 0, "skipped": 3, "expected_failures": 0, "ok": True,
        })

    def test_the_evidence_has_exactly_the_documented_fields(self):
        result = run_script(summary())
        self.assertIsNotNone(result.evidence)
        self.assertEqual(sorted(result.evidence), sorted([
            "schema", "job", "run_id", "run_attempt", "commit", "simulator",
            "executed", "passed", "failed", "skipped", "expected_failures", "ok"]))

    def test_the_duo_job_name_is_recorded(self):
        result = run_script(summary(), job="iphone-duo")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIsNotNone(result.evidence)
        self.assertEqual(result.evidence["job"], "iphone-duo")

    def test_every_count_is_explicit_and_the_invariant_holds(self):
        result = run_script(summary(passed=5, failed=0, skipped=1, expected=2))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIsNotNone(result.evidence)
        evidence = result.evidence
        self.assertEqual((evidence["executed"], evidence["passed"], evidence["failed"], evidence["skipped"], evidence["expected_failures"]),
                         (8, 5, 0, 1, 2))
        self.assertEqual(evidence["executed"], evidence["passed"] + evidence["failed"] + evidence["skipped"] + evidence["expected_failures"])

    def test_expected_failures_never_count_as_a_pass(self):
        result = run_script(summary(passed=0, expected=3))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no UI test passed", result.stderr)
        self.assertEqual(result.evidence["passed"], 0)
        self.assertEqual(result.evidence["expected_failures"], 3)
        self.assertIs(result.evidence["ok"], False)

    def test_all_tests_skipped_fails_with_a_message_and_records_zero_passed(self):
        result = run_script(summary(passed=0, skipped=98))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("::error::", result.stderr)
        self.assertIn("no UI test passed", result.stderr)
        self.assertIsNotNone(result.evidence)
        self.assertEqual((result.evidence["executed"], result.evidence["passed"], result.evidence["skipped"]), (98, 0, 98))
        self.assertIs(result.evidence["ok"], False)

    def test_a_bundle_with_a_simulator_but_no_test_fails_as_executed_zero(self):
        result = run_script(summary(passed=0))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no UI test ran", result.stderr)
        self.assertIsNotNone(result.evidence)
        self.assertEqual(result.evidence["executed"], 0)
        self.assertIs(result.evidence["ok"], False)

    def test_the_run_identity_is_recorded_as_numbers_and_must_be_valid(self):
        result = run_script(summary(), run_id="7", run_attempt="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIsNotNone(result.evidence)
        self.assertEqual((result.evidence["run_id"], result.evidence["run_attempt"]), (7, 1))
        for bad_id, bad_attempt in [("", "1"), ("abc", "1"), ("0", "1"), ("-5", "1"), ("07", "1"), ("1.5", "1"),
                                    ("7", ""), ("7", "0"), ("7", "x"), ("7", "01")]:
            with self.subTest(run_id=bad_id, run_attempt=bad_attempt):
                bad = run_script(summary(), run_id=bad_id, run_attempt=bad_attempt)
                self.assertNotEqual(bad.returncode, 0)
                self.assertIsNone(bad.evidence)

    def test_a_bundle_without_tests_fails(self):
        # The bundle of a run that never started has no device and no test; nothing may be written as evidence.
        result = run_script(summary(passed=0, devices=[]))
        self.assertNotEqual(result.returncode, 0)
        self.assertIsNone(result.evidence)

    def test_a_missing_simulator_in_a_bundle_with_tests_fails_without_evidence(self):
        result = run_script(summary(passed=10, devices=[]))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("exactly one simulator", result.stderr)
        self.assertIsNone(result.evidence)

    def test_two_simulators_fail_without_evidence(self):
        result = run_script(summary(devices=[device("iPhone 17"), device("iPhone Duo")]))
        self.assertNotEqual(result.returncode, 0)
        self.assertIsNone(result.evidence)

    def test_the_same_simulator_in_two_test_plan_configurations_counts_once(self):
        result = run_script(summary(devices=[device(), device()]))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIsNotNone(result.evidence)
        self.assertEqual(result.evidence["simulator"], {"name": "iPhone 17", "os": "27.1"})

    def test_one_failed_test_fails_and_is_recorded(self):
        result = run_script(summary(passed=9, failed=1))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("1 UI test failed", result.stderr)
        self.assertIsNotNone(result.evidence)
        self.assertEqual(result.evidence["failed"], 1)
        self.assertIs(result.evidence["ok"], False)

    def test_a_checkout_that_differs_from_the_run_commit_fails_without_evidence(self):
        result = run_script(summary(), head=OTHER_COMMIT)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("commit", result.stderr)
        self.assertIsNone(result.evidence)

    def test_a_commit_that_is_not_a_full_lowercase_sha_fails(self):
        for bad in ["", "abc123", COMMIT.upper(), COMMIT + "0", "main", "g" * 40]:
            with self.subTest(commit=bad):
                result = run_script(summary(), commit=bad, head=bad)
                self.assertNotEqual(result.returncode, 0)
                self.assertIsNone(result.evidence)

    def test_an_unknown_job_name_fails(self):
        result = run_script(summary(), job="other")
        self.assertNotEqual(result.returncode, 0)
        self.assertIsNone(result.evidence)

    def test_inconsistent_counts_fail_without_evidence(self):
        # passed=12, skipped=-2 and total=10 keep the sum right, so only the check for negative counts rejects them.
        for payload in [summary(total=99), summary(passed=-1, total=9), summary(total=9), summary(passed=12, skipped=-2, total=10)]:
            with self.subTest(total=payload["totalTestCount"]):
                result = run_script(payload)
                self.assertNotEqual(result.returncode, 0)
                self.assertIsNone(result.evidence)

    def test_malformed_input_fails_without_evidence(self):
        broken = summary()
        del broken["failedTests"]
        boolean = summary()
        boolean["passedTests"] = True
        text = summary()
        text["totalTestCount"] = "10"
        # `false` equals 0 in Python and keeps the sum right, so only the type check rejects it.
        false_count = summary()
        false_count["failedTests"] = False
        for raw in ["", "not json", "[]", json.dumps(broken), json.dumps(boolean), json.dumps(text), json.dumps(false_count)]:
            with self.subTest(raw=raw[:20]):
                result = run_script(None, raw=raw)
                self.assertNotEqual(result.returncode, 0)
                self.assertIsNone(result.evidence)

    def test_a_device_without_a_name_or_os_fails(self):
        for bad in [device(name=""), device(os_version=""), {"deviceId": "x"}]:
            with self.subTest(device=bad):
                result = run_script(summary(devices=[bad]))
                self.assertNotEqual(result.returncode, 0)
                self.assertIsNone(result.evidence)

    def test_a_missing_result_bundle_fails_with_a_message_and_no_evidence(self):
        result = run_script(summary(), bundle=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("::error::", result.stderr)
        self.assertIn("no UI test ran", result.stderr)
        self.assertIsNone(result.evidence)

    def test_an_unreadable_result_bundle_fails_without_evidence(self):
        result = run_script(summary(), xcrun_status=1)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("could not read", result.stderr)
        self.assertIsNone(result.evidence)

    def test_an_old_evidence_file_never_survives_a_failing_run(self):
        with tempfile.TemporaryDirectory() as directory:
            out = pathlib.Path(directory) / "ui-evidence.json"
            out.write_text('{"ok": true}')
            completed = subprocess.run(
                [sys.executable, "-I", str(SCRIPT), "--job", "iphone-duo", "--result", str(pathlib.Path(directory) / "missing.xcresult"),
                 "--run-id", RUN_ID, "--run-attempt", RUN_ATTEMPT, "--commit", COMMIT, "--checkout-head", COMMIT, "--out", str(out)],
                capture_output=True, text=True)
            self.assertNotEqual(completed.returncode, 0)
            self.assertFalse(out.exists())


if __name__ == "__main__":
    unittest.main()
