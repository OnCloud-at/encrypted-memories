import json
import pathlib
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(pathlib.Path(__file__).parent))
import replay_review  # noqa: E402
import review_pull_request  # noqa: E402

HEAD = "a" * 40
BASE = "b" * 40


def case(**overrides):
    value = {"pull_request": 7, "head_sha": HEAD, "base_sha": BASE, "adjudicated": []}
    value.update(overrides)
    return value


def write_cases(directory: str, cases: list, version: int = 1) -> pathlib.Path:
    path = pathlib.Path(directory) / "cases.json"
    path.write_text(json.dumps({"version": version, "cases": cases}), encoding="utf-8")
    return path


def finding(path: str, line: int, title: str = "Finding", severity: str = "warning") -> dict:
    return {"path": path, "line": line, "severity": severity, "title": title}


def verdict(path: str, line: int, value: str, severity: str = "warning", title: str = "Finding") -> dict:
    return {"path": path, "line": line, "severity": severity, "title": title, "verdict": value}


class CaseFileTests(unittest.TestCase):
    def test_the_committed_cases_load(self) -> None:
        cases = replay_review.load_cases()
        self.assertTrue(cases)
        self.assertEqual(len({item["pull_request"] for item in cases}), len(cases))

    def test_invalid_cases_are_rejected(self) -> None:
        invalid = [
            [case(), case()],
            [case(head_sha="abc")],
            [case(adjudicated=[dict(verdict("A.swift", 1, "true_finding"), verdict="maybe")])],
            [case(adjudicated=[verdict("A.swift", 0, "true_finding")])],
            [case(adjudicated=[dict(verdict("A.swift", 1, "true_finding"), title=" ")])],
            [case(adjudicated=[dict(verdict("A.swift", 1, "true_finding"), severity="high")])],
            [dict(case(), extra=True)],
        ]
        with tempfile.TemporaryDirectory() as directory:
            for cases in invalid:
                with self.subTest(cases=cases), self.assertRaises(ValueError):
                    replay_review.load_cases(write_cases(directory, cases))
            with self.assertRaises(ValueError):
                replay_review.load_cases(write_cases(directory, [case()], version=2))
            valid = replay_review.load_cases(write_cases(directory, [case(adjudicated=[verdict("A.swift", 1,
                                                                                               "false_positive")])]))
            self.assertEqual(len(valid), 1)

    def test_selection_by_pull_request_number(self) -> None:
        cases = [case(pull_request=1), case(pull_request=2)]
        self.assertEqual(replay_review.select_cases(cases, ""), cases)
        self.assertEqual(replay_review.select_cases(cases, " 2 "), [cases[1]])
        with self.assertRaises(ValueError):
            replay_review.select_cases(cases, "3")
        with self.assertRaises(ValueError):
            replay_review.select_cases(cases, "two")


class ComparisonTests(unittest.TestCase):
    def test_findings_carry_the_path_of_their_file_id(self) -> None:
        files = [{"filename": "App/A.swift"}, {"filename": "iOSApp/B.swift"}]
        review = {"findings": [{"file_id": "file-002", "line": 4, "severity": "warning", "title": "T"},
                               {"file_id": "file-009", "line": 1, "severity": "suggestion", "title": "U"}]}
        records = replay_review.finding_records(review, files)
        self.assertEqual([item["path"] for item in records], ["iOSApp/B.swift", ""])

    def test_classification_pairs_one_claim_per_verdict(self) -> None:
        adjudicated = [
            verdict("A.swift", 10, "true_finding"),
            verdict("A.swift", 40, "true_finding"),
            verdict("B.swift", 5, "false_positive"),
            verdict("C.swift", 5, "false_positive"),
            verdict("E.swift", 5, "true_finding", severity="blocking"),
        ]
        findings = [finding("A.swift", 13), finding("B.swift", 5), finding("D.swift", 1), finding("E.swift", 6)]
        result = replay_review.classify(findings, adjudicated, complete=True)
        self.assertEqual([item["line"] for item in result["true_found"]], [10])
        self.assertEqual([item["line"] for item in result["true_missed"]], [40, 5])
        self.assertEqual([item["path"] for item in result["false_reproduced"]], ["B.swift"])
        self.assertEqual([item["path"] for item in result["false_avoided"]], ["C.swift"])
        self.assertEqual([item["path"] for item in result["unadjudicated"]], ["D.swift", "E.swift"],
                         "a warning must not satisfy a blocking verdict at a nearby line")

    def test_an_incomplete_review_cannot_miss_or_avoid_a_verdict(self) -> None:
        adjudicated = [verdict("A.swift", 10, "true_finding"), verdict("B.swift", 5, "false_positive")]
        result = replay_review.classify([], adjudicated, complete=False)
        self.assertEqual(result["true_missed"], [])
        self.assertEqual(result["false_avoided"], [])
        self.assertEqual(len(result["inconclusive"]), 2)

    def test_nearby_competing_claims_stay_ambiguous(self) -> None:
        adjudicated = [verdict("A.swift", 10, "true_finding", title="Lost upload")]
        findings = [finding("A.swift", 9, "Lost upload first"), finding("A.swift", 11, "Lost upload second")]
        result = replay_review.classify(findings, adjudicated, complete=True)
        self.assertEqual(result["true_found"], [])
        self.assertEqual(result["true_missed"], [])
        self.assertEqual(len(result["ambiguous"]), 3)

    def test_unrelated_claims_at_the_same_location_stay_apart(self) -> None:
        adjudicated = [verdict("A.swift", 10, "false_positive", title="Unprotected account deletion")]
        findings = [finding("A.swift", 10, "Business logic belongs in shared package")]
        result = replay_review.classify(findings, adjudicated, complete=True)
        self.assertEqual(result["false_reproduced"], [])
        self.assertEqual(len(result["false_avoided"]), 1)
        self.assertEqual([item["title"] for item in result["unadjudicated"]],
                         ["Business logic belongs in shared package"])
        delta = replay_review.variant_delta(
            [finding("A.swift", 10, "Unprotected account deletion")], findings,
            baseline_complete=True, rules_complete=True)
        self.assertEqual(len(delta["only_with_rules"]), 1)
        self.assertEqual(len(delta["only_without_rules"]), 1)

    def test_similar_titles_about_different_operations_are_never_merged(self) -> None:
        adjudicated = [verdict("A.swift", 10, "false_positive", title="Cancel pending uploads on sign out")]
        findings = [finding("A.swift", 11, "Cancel pending downloads on sign out")]
        result = replay_review.classify(findings, adjudicated, complete=True)
        self.assertEqual(result["false_reproduced"], [])
        self.assertEqual(result["false_avoided"], [])
        self.assertEqual(len(result["ambiguous"]), 2)
        delta = replay_review.variant_delta(
            [finding("A.swift", 10, "Cancel pending uploads on sign out")], findings,
            baseline_complete=True, rules_complete=True)
        self.assertEqual(delta["only_with_rules"], [])
        self.assertEqual(delta["only_without_rules"], [])
        self.assertEqual(len(delta["ambiguous"]), 2, "a possible difference stays visible for the maintainer")

    def test_the_report_shows_ambiguity_when_both_variants_agree_or_one_fails(self) -> None:
        adjudicated = [verdict("A.swift", 10, "false_positive", title="Cancel pending uploads on sign out")]
        findings = [finding("A.swift", 11, "Cancel pending downloads on sign out")]
        limits = {"complete": True}
        variant = {"findings": findings, "limits": limits,
                   "classification": replay_review.classify(findings, adjudicated, complete=True)}
        agreeing = {"pull_request": 5, "variants": {"baseline": variant, "repository_rules": variant},
                    "delta": replay_review.variant_delta(findings, findings, baseline_complete=True,
                                                         rules_complete=True)}
        failing = {"pull_request": 6, "variants": {"baseline": variant, "repository_rules": {"error": "RuntimeError"}}}
        for result in (agreeing, failing):
            with self.subTest(pull_request=result["pull_request"]):
                report = replay_review.render_report([result])
                self.assertIn("Cancel pending uploads on sign out", report)
                self.assertIn("Cancel pending downloads on sign out", report)

    def test_the_report_lists_every_unadjudicated_finding(self) -> None:
        findings = [finding("A.swift", 3, "Shared logic in the app target")]
        variant = {"findings": findings, "limits": {"complete": True},
                   "classification": replay_review.classify(findings, [], complete=True)}
        result = {"pull_request": 8, "variants": {"baseline": variant, "repository_rules": variant},
                  "delta": replay_review.variant_delta(findings, findings, baseline_complete=True,
                                                       rules_complete=True)}
        self.assertIn("Shared logic in the app target", replay_review.render_report([result]))

    def test_delta_lists_findings_that_only_one_variant_reports(self) -> None:
        delta = replay_review.variant_delta(
            [finding("A.swift", 1), finding("B.swift", 9), finding("F.swift", 4, severity="blocking")],
            [finding("A.swift", 2), finding("C.swift", 3), finding("F.swift", 5)],
            baseline_complete=True, rules_complete=True)
        self.assertEqual([item["path"] for item in delta["only_with_rules"]], ["C.swift", "F.swift"])
        self.assertEqual([item["path"] for item in delta["only_without_rules"]], ["B.swift", "F.swift"])

    def test_delta_absence_needs_a_complete_other_side(self) -> None:
        delta = replay_review.variant_delta(
            [], [finding("C.swift", 3)], baseline_complete=False, rules_complete=True)
        self.assertIsNone(delta["only_with_rules"])
        self.assertEqual([item["path"] for item in delta["inconclusive"]], ["C.swift"])
        self.assertIn("not measurable", replay_review.render_report(
            [{"pull_request": 1, "variants": {}, "delta": delta}]))


class ReplayTests(unittest.TestCase):
    def _review_outcome(self, findings: list, **review: object) -> review_pull_request.BatchReviewOutcome:
        coverage = review_pull_request.ReviewCoverage(
            text_files=1, reviewed_files=1, text_lines=3, reviewed_lines=3, batches=1, completed_batches=1,
            text_gaps=(), unreviewed_files=())
        return review_pull_request.BatchReviewOutcome(
            review={"findings": findings, "review_notes": [], "testing_gaps": [], **review}, coverage=coverage)

    def _patches(self, review, files=None):
        return (
            patch.object(replay_review, "fetch_pull_request",
                         return_value={"number": 7, "head": {"sha": "c" * 40}, "base": {"ref": "main"}}),
            patch.object(replay_review, "github_request",
                         return_value={"files": files if files is not None else [{"filename": "App/A.swift"}]}),
            patch.object(replay_review, "llm_configuration", return_value=("https://llm.test", "model", None)),
            patch.object(replay_review, "review_idle_seconds", return_value=600.0),
            patch.object(replay_review, "review_pull_request_files", side_effect=review),
        )

    def test_each_case_runs_both_variants_on_the_recorded_snapshot(self) -> None:
        calls = []

        def review(pull_request, files, snapshot, repo, **kwargs):
            calls.append((pull_request["head"]["sha"], snapshot.base_sha, kwargs["repository_rules"]))
            findings = [{"file_id": "file-001", "line": 2, "severity": "warning", "title": "Rule"}]
            return self._review_outcome(findings if kwargs["repository_rules"] else [])

        first, second, third, fourth, fifth = self._patches(review)
        with first, second, third, fourth, fifth:
            result = replay_review.replay_case(
                case(), "example/repo", github_token="t", api_url="https://api.github.test", llm_token="k",
                rules="- Rule.")

        self.assertEqual(calls, [(HEAD, BASE, None), (HEAD, BASE, "- Rule.")])
        self.assertEqual([item["path"] for item in result["delta"]["only_with_rules"]], ["App/A.swift"])
        report = replay_review.render_report([result])
        self.assertIn("Only with the repository rules", report)
        self.assertIn("Nothing was published", report)

    def test_a_failing_variant_is_reported_without_provider_text(self) -> None:
        def review(*_, **kwargs):
            if kwargs["repository_rules"]:
                raise RuntimeError("provider said something private")
            return self._review_outcome([])

        first, second, third, fourth, fifth = self._patches(review, files=[])
        with first, second, third, fourth, fifth:
            result = replay_review.replay_case(
                case(), "example/repo", github_token="t", api_url="https://api.github.test", llm_token="k",
                rules="- Rule.")

        self.assertEqual(result["variants"]["repository_rules"], {"error": "RuntimeError"})
        self.assertNotIn("delta", result)
        self.assertNotIn("private", replay_review.render_report([result]))

    def test_an_unavailable_review_is_not_counted_as_no_findings(self) -> None:
        def review(*_, **kwargs):
            if kwargs["repository_rules"]:
                return self._review_outcome([], unavailable=True)
            return self._review_outcome([{"file_id": "file-001", "line": 2, "severity": "warning", "title": "T"}])

        first, second, third, fourth, fifth = self._patches(review)
        with first, second, third, fourth, fifth:
            result = replay_review.replay_case(
                case(adjudicated=[verdict("App/A.swift", 2, "true_finding")]), "example/repo", github_token="t",
                api_url="https://api.github.test", llm_token="k", rules="- Rule.")

        with_rules = result["variants"]["repository_rules"]
        self.assertFalse(with_rules["limits"]["complete"])
        self.assertEqual(with_rules["classification"]["true_missed"], [])
        self.assertIsNone(result["delta"]["only_without_rules"])

    def test_a_verification_gap_makes_the_variant_incomplete(self) -> None:
        outcome = self._review_outcome([], verification_gaps=["Head source was unavailable."])
        self.assertFalse(replay_review.completeness(outcome)["complete"])
        self.assertTrue(replay_review.completeness(self._review_outcome([]))["complete"])

    def test_a_capped_comparison_is_not_replayed(self) -> None:
        review_calls = []
        files = [{"filename": f"F{index}.swift"} for index in range(replay_review.COMPARE_FILE_LIMIT)]
        first, second, third, fourth, fifth = self._patches(lambda *a, **k: review_calls.append(k), files=files)
        with first, second, third, fourth, fifth, self.assertRaises(replay_review.TruncatedComparisonError):
            replay_review.replay_case(case(), "example/repo", github_token="t", api_url="https://api.github.test",
                                      llm_token="k", rules="- Rule.")
        self.assertEqual(review_calls, [])

    def test_no_review_starts_after_the_time_budget(self) -> None:
        review_calls = []
        first, second, third, fourth, fifth = self._patches(lambda *a, **k: review_calls.append(k))
        with first as fetch, second as compare, third, fourth, fifth:
            result = replay_review.replay_case(
                case(), "example/repo", github_token="t", api_url="https://api.github.test", llm_token="k",
                rules="- Rule.", has_time=lambda: False)
        self.assertEqual(review_calls, [])
        fetch.assert_not_called()
        compare.assert_not_called()
        self.assertEqual(result["variants"]["baseline"], {"skipped": "time budget"})
        self.assertIn("skipped: time budget", replay_review.render_report([result]))

    def test_results_are_written_after_every_case(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            output = pathlib.Path(directory)
            replay_review.write_results(output, [{"pull_request": 1, "variants": {
                "baseline": {"error": "RuntimeError"}, "repository_rules": {"error": "RuntimeError"}}}])
            self.assertEqual(json.loads((output / "results.json").read_text())[0]["pull_request"], 1)
            self.assertIn("#1", (output / "report.md").read_text())

    def test_the_replay_never_publishes(self) -> None:
        source = pathlib.Path(replay_review.__file__).read_text(encoding="utf-8")
        for name in ("upsert_review_comment", "publish_unavailable", "POST", "PATCH"):
            self.assertNotIn(name, source)


if __name__ == "__main__":
    unittest.main()
