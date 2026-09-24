"""Advisory policy, evidence rejection and real HTTP stream regression tests."""

import base64
import contextlib
import http.server
import io
import json
import pathlib
import sys
import threading
import time
import unittest
from unittest.mock import patch

sys.path.insert(0, str(pathlib.Path(__file__).parent))
import github_llm_client as client
import review_pull_request as review
from review_evidence import EvidenceValidationError, verify_findings
from review_monitor import ReviewMonitor, ReviewTimeout
from test_review_pull_request import changed_file, pull_request, valid_review


class EvidenceTests(unittest.TestCase):
    def verify(self, *, unavailable=False, retry_quote=False, testing_gaps=None, review_notes=None, **overrides):
        files = [changed_file()]
        plan = review.plan_review(pull_request(), files, model="test", reasoning_effort=None)
        payload, _, paths = review.batch_request(plan, plan.batches[0])
        candidate = {"severity": "blocking", "file_id": "file-001", "path": paths["file-001"],
                     "line": 1, "title": "Lost item", "detail": "An item is lost."}
        decision = {"id": "0", "decision": "confirmed", "severity": "high", "category": "data_loss",
                    "confidence": "high", "introduced": True, "line": 1, "quote": "new",
                    "trigger": "Retry runs after an error.", "impact": "The item is removed.",
                    "counterevidence": "The supplied guard does not cover retries.", "missing_context": ""}
        decision.update(overrides)
        source = {"type": "file", "encoding": "base64", "size": 3,
                  "content": base64.b64encode(b"new").decode()}
        def request(payload, validator):
            if not retry_quote:
                return validator(json.dumps({"decisions": [decision]}))
            broken = dict(decision, quote="fabricated source")
            responses = [json.dumps({"decisions": [value]}) for value in (broken, decision)]
            with patch.object(client, "request_llm_content", side_effect=responses) as generate:
                result = client.request_validated_llm_result(
                    "https://provider.test", token="test", payload=payload, validator=validator)
            self.assertEqual(generate.call_count, 2)
            return result

        with patch.object(review, "github_request", return_value=None if unavailable else source) as fetch:
            result = verify_findings(
                valid_review(
                    findings=[candidate],
                    testing_gaps=testing_gaps or [],
                    review_notes=review_notes or [],
                ),
                payload,
                files,
                review.pull_request_snapshot(pull_request()),
                "example/repo", token="test", api_url="https://api.github.test", fetch=fetch,
                redact=lambda text: [{"line": 1, "text": text}],
                request=request)
        self.assertIn("ref=abc123", fetch.call_args_list[0].args[1])
        self.assertIn("ref=base123", fetch.call_args_list[1].args[1])
        return result

    def test_serious_finding_requires_specific_evidence(self):
        self.assertEqual(self.verify()["findings"][0]["severity"], "blocking")

    def test_filtered_candidates_do_not_imply_missing_coverage(self):
        for change in ({"introduced": False}, {"confidence": "low"}):
            with self.subTest(change=change):
                result = self.verify(**change)
                self.assertEqual(result["findings"], [])
                self.assertEqual(result["testing_gaps"], [])
                self.assertIn("🟢", review.render_review(result, {}, "abc123", []))

    def test_nonblocking_model_test_notes_do_not_make_review_incomplete(self):
        result = self.verify(
            decision="dismissed",
            review_notes=["The test could assert one more cache invariant."],
        )
        self.assertEqual(result["findings"], [])
        self.assertEqual(result["testing_gaps"], [])
        self.assertEqual(result["review_notes"], ["The test could assert one more cache invariant."])
        body = review.render_review(result, {}, "abc123", [])
        self.assertIn("🟢", body)
        self.assertNotIn("⚪ Review incomplete", body)
        self.assertIn("Review notes", body)
        self.assertIn("cache invariant", body)

    def test_model_coverage_gaps_remain_incomplete(self):
        result = self.verify(testing_gaps=["The changed caller was not supplied."])
        self.assertEqual(result["testing_gaps"], ["The changed caller was not supplied."])
        body = review.render_review(result, {}, "abc123", [])
        self.assertIn("partial review", body)
        self.assertIn("The changed caller was not supplied.", body)

    def test_missing_context_stays_grey_with_specific_reason(self):
        result = self.verify(decision="uncertain", missing_context="The retry caller and its error contract.")
        body = review.render_review(result, {}, "abc123", [])
        self.assertIn("⚪", body)
        self.assertIn("retry caller", body)
        self.assertNotIn("No actionable findings", body)

    def test_uncertainty_requires_a_specific_context_request(self):
        with self.assertRaises(EvidenceValidationError):
            self.verify(decision="uncertain")

    def test_missing_head_source_is_a_real_coverage_gap(self):
        result = self.verify(unavailable=True)
        self.assertEqual(result["findings"], [])
        self.assertIn("Head source was unavailable", result["testing_gaps"][0])

    def test_invalid_evidence_requests_regeneration(self):
        for change in ({"quote": "invented"}, {"quote": ""}, {"line": 2}, {"trigger": ""},
                       {"counterevidence": ""}):
            with self.subTest(change=change), self.assertRaises(EvidenceValidationError):
                self.verify(**change)

    def test_regeneration_can_recover_invalid_evidence(self):
        self.assertEqual(len(self.verify(retry_quote=True)["findings"]), 1)

    def test_verification_logs_only_reason_counts(self):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            self.verify(decision="uncertain", missing_context="private-source-description")
        self.assertIn('"missing_context": 1', output.getvalue())
        self.assertNotIn("private-source-description", output.getvalue())

    def test_disproved_candidate_leaves_no_warning(self):
        self.assertEqual(self.verify(decision="dismissed")["testing_gaps"], [])
        self.assertEqual(self.verify(decision="dismissed")["findings"], [])

    def test_correctness_notice_does_not_inherit_original_blocker(self):
        self.assertEqual(self.verify(category="correctness")["findings"][0]["severity"], "warning")

    def test_invalid_decision_is_rejected(self):
        for change in ({"id": "unknown"}, {"line": True}, {"introduced": "yes"}, {"decision": []}):
            with self.subTest(change=change), self.assertRaises(RuntimeError):
                self.verify(**change)


class AdvisoryTests(unittest.TestCase):
    def test_failure_returns_success_without_exposing_error(self):
        output = io.StringIO()
        with (patch.dict("os.environ", {"LLM_API_KEY": "test"}),
              patch.object(review, "main", side_effect=RuntimeError("private-provider-content")),
              patch.object(review, "publish_unavailable") as publish,
              contextlib.redirect_stderr(output)):
            self.assertEqual(review.run_advisory(), 0)
        publish.assert_called_once()
        self.assertNotIn("private-provider-content", output.getvalue())

    def test_publication_failure_is_also_advisory(self):
        with (patch.dict("os.environ", {"LLM_API_KEY": ""}),
              patch.object(review, "publish_unavailable", side_effect=RuntimeError("no permission"))):
            self.assertEqual(review.run_advisory(), 0)

    def test_summary_shows_three_findings_and_keeps_all_evidence(self):
        findings = [{"severity": "warning", "title": f"Finding {index}", "path": "source.py",
                     "line": index + 1, "detail": f"Evidence {index}"} for index in range(8)]
        body = review.render_review(valid_review(findings=findings), {}, "a" * 40, [])
        visible = body.split("<details>")[0]
        self.assertEqual(visible.count("- **"), 3)
        self.assertLess(len(visible), 800)
        self.assertIn("Evidence 7", body)

    def test_code_links_cannot_inject_markdown(self):
        finding = {"severity": "warning", "title": "Check", "path": "a)![x](https://evil.test)",
                   "line": 1, "detail": "detail"}
        with patch.dict("os.environ", {"GITHUB_REPOSITORY": "example/repo"}):
            body = review.render_review(valid_review(findings=[finding]), {}, "a" * 40, [])
        self.assertNotIn("] (https://evil", body)
        self.assertIn("%29%21%5B", body)

    def test_workflow_is_optional_and_keeps_trusted_checkout(self):
        workflow = (pathlib.Path(__file__).parents[1] / "workflows/pull-request-review.yml").read_text()
        self.assertIn("continue-on-error: true", workflow)
        self.assertIn("ref: ${{ github.event.repository.default_branch }}", workflow)
        self.assertNotIn("pull_request.head", workflow)
        self.assertIn("--unavailable", workflow)


class StreamMonitorTests(unittest.TestCase):
    def test_transport_heartbeat_does_not_reset_model_progress(self):
        with patch("review_monitor.time.monotonic", return_value=0):
            monitor = ReviewMonitor(1000, 600)
        with patch("review_monitor.time.monotonic", return_value=599):
            monitor.activity("transport")
        status, reason = monitor.status(601)
        self.assertIn("network idle 2s", status)
        self.assertIsNotNone(reason)

    def test_reasoning_extends_idle_budget_but_not_total_budget(self):
        with patch("review_monitor.time.monotonic", return_value=0):
            monitor = ReviewMonitor(1000, 600)
        with patch("review_monitor.time.monotonic", return_value=590):
            monitor.activity("reasoning")
        self.assertIsNone(monitor.status(700)[1])
        self.assertIsNotNone(monitor.status(1001)[1])

    def test_blocked_reader_does_not_block_watchdog(self):
        release = threading.Event()
        monitor = ReviewMonitor(time.monotonic() + 2, idle_seconds=0.05, interval=0.01)
        try:
            with contextlib.redirect_stdout(io.StringIO()), self.assertRaises(ReviewTimeout):
                monitor.run(lambda: release.wait(2))
            self.assertTrue(monitor.cancelled.is_set())
        finally:
            release.set()

    def test_real_http_stream_tolerates_delayed_reasoning_and_returns_only_content(self):
        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def do_POST(self):
                self.rfile.read(int(self.headers["Content-Length"]))
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.end_headers()
                for delta in ({"reasoning_content": "private reasoning"}, {"content": "ok"}):
                    time.sleep(0.06)
                    self.wfile.write(("data: " + json.dumps({"choices": [{"delta": delta}]}) + "\n\n").encode())
                    self.wfile.flush()
                self.wfile.write(b'data: {"choices":[{"finish_reason":"stop","delta":{}}]}\n\ndata: [DONE]\n\n')

        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        monitor = ReviewMonitor(time.monotonic() + 5, idle_seconds=1, interval=0.02)
        output = io.StringIO()
        try:
            with contextlib.redirect_stdout(output):
                result = monitor.run(lambda: client.request_llm_content(
                    f"http://127.0.0.1:{server.server_port}", token="synthetic-test-token", payload={},
                    deadline=monitor.deadline, socket_seconds=1, on_activity=monitor.activity))
            self.assertEqual(result, "ok")
            self.assertNotIn("private reasoning", output.getvalue())
            self.assertEqual(monitor.kind, "content")
        finally:
            server.shutdown()
            server.server_close()


if __name__ == "__main__":
    unittest.main()
