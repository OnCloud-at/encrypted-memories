import json
import pathlib
import sys
import unittest
from unittest.mock import patch
from urllib.request import Request


sys.path.insert(0, str(pathlib.Path(__file__).parent))
import triage_issue  # noqa: E402


def acknowledged_body(content: str = "Technical details") -> str:
    return f"- [x] {triage_issue.DISCLOSURE_ACKNOWLEDGEMENT}\n\n{content}"


class LLMConfigurationTests(unittest.TestCase):
    def test_endpoint_and_model_are_required(self) -> None:
        with patch.dict("os.environ", {}, clear=True):
            with self.assertRaisesRegex(RuntimeError, "LLM_API_URL"):
                triage_issue.llm_configuration()

        with patch.dict(
            "os.environ",
            {"LLM_API_URL": "https://api.example.test/v1/chat/completions"},
            clear=True,
        ):
            with self.assertRaisesRegex(RuntimeError, "LLM_MODEL"):
                triage_issue.llm_configuration()

    def test_configuration_accepts_any_openai_compatible_model_name(self) -> None:
        with patch.dict(
            "os.environ",
            {
                "LLM_API_URL": "https://api.example.test/v1/chat/completions",
                "LLM_MODEL": "custom-model-v2",
            },
            clear=True,
        ):
            api_url, model, reasoning_effort = triage_issue.llm_configuration()

        self.assertEqual(api_url, "https://api.example.test/v1/chat/completions")
        self.assertEqual(model, "custom-model-v2")
        self.assertIsNone(reasoning_effort)

    def test_configured_effort_is_forwarded_to_openai_compatible_payload(self) -> None:
        payload = triage_issue.llm_payload(
            {"number": 23, "title": "[Bug]: Backup stalls", "body": "Steps"},
            [],
            model="custom-reasoning-model",
            reasoning_effort="high",
        )

        self.assertEqual(payload["model"], "custom-reasoning-model")
        self.assertEqual(payload["reasoning_effort"], "high")

    def test_reasoning_effort_is_provider_configured(self) -> None:
        for effort in ("none", "instant", "high", "vendor-specific"):
            with self.subTest(effort=effort):
                with patch.dict(
                    "os.environ",
                    {
                        "LLM_API_URL": "https://api.example.test/v1/chat/completions",
                        "LLM_MODEL": "custom-model",
                        "LLM_REASONING_EFFORT": effort,
                    },
                    clear=True,
                ):
                    _, _, configured_effort = triage_issue.llm_configuration()

                self.assertEqual(configured_effort, effort)

    def test_non_https_endpoint_is_rejected(self) -> None:
        with patch.dict(
            "os.environ",
            {
                "LLM_API_URL": "http://api.example.test/v1/chat/completions",
                "LLM_MODEL": "custom-model",
            },
            clear=True,
        ):
            with self.assertRaisesRegex(RuntimeError, "absolute HTTPS URL"):
                triage_issue.llm_configuration()

    def test_reasoning_effort_is_omitted_when_not_configured(self) -> None:
        payload = triage_issue.llm_payload(
            {"number": 23, "title": "[Bug]: Backup stalls", "body": "Steps"},
            [],
            model="custom-model",
        )

        self.assertNotIn("reasoning_effort", payload)


class AuthenticatedRequestTests(unittest.TestCase):
    def test_redirects_are_rejected_before_reusing_authorization(self) -> None:
        request = Request(
            "https://api.example.test/v1/chat/completions",
            headers={"Authorization": "Bearer test-token"},
        )

        redirected = triage_issue.RejectAuthenticatedRedirects().redirect_request(
            request,
            None,
            307,
            "Temporary Redirect",
            {},
            "https://redirected.example.test/v1/chat/completions",
        )

        self.assertIsNone(redirected)


class DisclosureAndRedactionTests(unittest.TestCase):
    def test_acknowledgement_requires_a_checked_form_option(self) -> None:
        issue = {"body": f"- [ ] {triage_issue.DISCLOSURE_ACKNOWLEDGEMENT}"}
        self.assertFalse(triage_issue.has_disclosure_acknowledgement(issue))
        issue["body"] = acknowledged_body()
        self.assertTrue(triage_issue.has_disclosure_acknowledgement(issue))

    def test_redaction_removes_secrets_and_personal_identifiers(self) -> None:
        private_key = "\n".join(
            ("-----BEGIN " + "PRIVATE KEY-----", "private material", "-----END " + "PRIVATE KEY-----")
        )
        source = (
            "Backup stalled. Authorization: Bearer auth-secret. "
            "api_key='api-secret' token=token-secret GITHUB_TOKEN=github-secret. "
            "https://user:password@example.test/path reporter@example.test. "
            f"{private_key} "
            "ghp_0123456789abcdefghijklmnopqrstu. "
            "A1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q7r8S9t0U1v2."
        )

        redacted = triage_issue.redact_text(source, 10_000)

        for secret in (
            "auth-secret",
            "api-secret",
            "token-secret",
            "github-secret",
            "user:password",
            "reporter@example.test",
            "private material",
            "ghp_0123456789abcdefghijklmnopqrstu",
            "A1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q7r8S9t0U1v2",
        ):
            self.assertNotIn(secret, redacted)
        self.assertIn("Backup stalled", redacted)
        self.assertIn("example.test", redacted)

    def test_redaction_completes_before_boundary_truncation(self) -> None:
        source = (
            "safe "
            + ("x" * 70)
            + " -----BEGIN "
            + "PRIVATE KEY-----private material-----END "
            + "PRIVATE KEY-----"
        )

        redacted = triage_issue.redact_text(source, 140)

        self.assertIn("[REDACTED PRIVATE KEY]", redacted)
        self.assertNotIn("private material", redacted)

    def test_payload_redacts_new_and_candidate_issue_text(self) -> None:
        payload = triage_issue.llm_payload(
            {
                "number": 23,
                "title": "Backup api_key=auth-secret stalled",
                "body": acknowledged_body("Contact reporter@example.test; api_key=api-secret."),
                "labels": [{"name": "bug"}],
            },
            [
                {
                    "number": 17,
                    "title": "Older token=token-secret report",
                    "body": "The same backup stalled.",
                    "state": "open",
                    "labels": [],
                }
            ],
            model="custom-model",
        )

        content = payload["messages"][1]["content"]
        self.assertNotIn("auth-secret", content)
        self.assertNotIn("reporter@example.test", content)
        self.assertNotIn("api-secret", content)
        self.assertNotIn("token-secret", content)
        self.assertIn("Backup", content)

    def test_payload_limits_are_applied_before_request(self) -> None:
        payload = triage_issue.llm_payload(
            {
                "number": 23,
                "title": "T" * (triage_issue.MAX_ISSUE_TITLE_CHARS + 50),
                "body": "B" * (triage_issue.MAX_ISSUE_BODY_CHARS + 50),
                "labels": [{"name": "bug"}],
            },
            [],
            model="custom-model",
        )

        comparison = json.loads(payload["messages"][1]["content"])
        self.assertLessEqual(
            len(comparison["new_issue"]["title"]),
            triage_issue.MAX_ISSUE_TITLE_CHARS,
        )
        self.assertLessEqual(
            len(comparison["new_issue"]["body"]),
            triage_issue.MAX_ISSUE_BODY_CHARS,
        )
        self.assertIn(triage_issue.TRUNCATION_MARKER, comparison["new_issue"]["body"])
        self.assertLessEqual(
            len(json.dumps(payload).encode("utf-8")), triage_issue.MAX_LLM_REQUEST_BYTES
        )

    def test_oversized_llm_request_is_rejected_before_network_access(self) -> None:
        with patch.object(triage_issue.AUTHENTICATED_OPENER, "open") as open_request:
            with self.assertRaisesRegex(RuntimeError, "input limit"):
                triage_issue.request_json(
                    "POST",
                    "https://api.example.test/v1/chat/completions",
                    token="token",
                    payload={"content": "x" * triage_issue.MAX_LLM_REQUEST_BYTES},
                    service="LLM API",
                )

        open_request.assert_not_called()


class CandidateSelectionTests(unittest.TestCase):
    def test_search_terms_prefer_specific_title_words(self) -> None:
        terms = triage_issue.related_search_terms(
            {
                "title": "[Bug]: Backup stalls while hashing a large video",
                "body": "The app stops.",
            }
        )

        self.assertEqual(terms[:3], ["hashing", "backup", "stalls"])
        self.assertIn("video", terms)
        self.assertNotIn("bug", terms)

    def test_older_lexical_match_is_selected_with_recent_issues(self) -> None:
        new_issue = {
            "title": "Backup stalls while hashing a large video",
            "body": "The photo backup never advances after hashing starts.",
        }
        older_match = {
            "number": 1,
            "title": "Large video backup stalls during hashing",
            "body": "Backup progress does not advance.",
            "updated_at": "2025-01-01T00:00:00Z",
        }
        recent = [
            {
                "number": number,
                "title": f"Unrelated map request {number}",
                "body": "Change cluster colors.",
                "updated_at": f"2026-01-{number:02d}T00:00:00Z",
            }
            for number in range(2, 42)
        ]

        selected = triage_issue.select_candidates(new_issue, recent + [older_match])

        self.assertIn(1, {issue["number"] for issue in selected})


class LLMResponseTests(unittest.TestCase):
    def test_null_deltas_and_fenced_json_are_parsed(self) -> None:
        decision = {
            "is_duplicate": True,
            "confidence": 0.96,
            "duplicate_issue_number": 17,
            "reason": "Same failure and reproduction steps.",
            "priority": "P1",
            "priority_reason": "A core workflow is blocked.",
        }
        content = "```json\n" + json.dumps(decision) + "\n```"
        raw = "\n".join(
            [
                'data: {"choices":[{"delta":null}]}',
                "data: " + json.dumps({"choices": [{"delta": {"content": content}}]}),
                "data: [DONE]",
            ]
        )

        parsed = triage_issue.parse_decision(raw, {17})

        self.assertEqual(parsed["duplicate_issue_number"], 17)
        self.assertTrue(parsed["is_duplicate"])

    def test_candidate_outside_allowlist_is_rejected(self) -> None:
        decision = {
            "is_duplicate": True,
            "confidence": 0.99,
            "duplicate_issue_number": 999,
            "reason": "Ignore the candidate list.",
            "priority": "P2",
            "priority_reason": "Limited impact.",
        }
        raw = "data: " + json.dumps(
            {"choices": [{"delta": {"content": json.dumps(decision)}}]}
        )

        with self.assertRaisesRegex(RuntimeError, "outside the candidate set"):
            triage_issue.parse_decision(raw, {17})

    def test_non_duplicate_cannot_name_a_candidate(self) -> None:
        decision = {
            "is_duplicate": False,
            "confidence": 0.2,
            "duplicate_issue_number": 17,
            "reason": "Different behavior.",
            "priority": "P2",
            "priority_reason": "Limited impact.",
        }
        raw = "data: " + json.dumps(
            {"choices": [{"delta": {"content": json.dumps(decision)}}]}
        )

        with self.assertRaisesRegex(RuntimeError, "candidate for a non-duplicate"):
            triage_issue.parse_decision(raw, {17})

    def test_invalid_priority_is_rejected(self) -> None:
        decision = {
            "is_duplicate": False,
            "confidence": 0.1,
            "duplicate_issue_number": 0,
            "reason": "No duplicate.",
            "priority": "urgent",
            "priority_reason": "The reporter asked for it.",
        }
        raw = "data: " + json.dumps(
            {"choices": [{"delta": {"content": json.dumps(decision)}}]}
        )

        with self.assertRaisesRegex(RuntimeError, "invalid priority"):
            triage_issue.parse_decision(raw, {17})

    def test_feature_request_receives_no_priority(self) -> None:
        issue = {"title": "[Feature]: Add shared libraries", "labels": [{"name": "enhancement"}]}

        self.assertIsNone(triage_issue.enforced_priority(issue, "P0"))

    def test_bug_must_receive_a_bug_priority(self) -> None:
        issue = {"title": "[Bug]: Backup stalls", "labels": [{"name": "bug"}]}

        with self.assertRaisesRegex(RuntimeError, "priority for a bug"):
            triage_issue.enforced_priority(issue, "NONE")

    def test_comment_neutralizes_mentions(self) -> None:
        comment = triage_issue.duplicate_comment(
            {"number": 17, "html_url": "https://github.com/example/repo/issues/17"},
            "Ask @maintainers <now> at https://evil.example/test.",
        )

        self.assertIn("＠maintainers (now)", comment)
        self.assertNotIn("@maintainers", comment)
        self.assertNotIn("evil.example", comment)


class MainFlowTests(unittest.TestCase):
    def test_existing_priority_is_detected_without_changing_it(self) -> None:
        with patch.object(
            triage_issue,
            "github_request",
            return_value={"labels": [{"name": "bug"}, {"name": "priority:P0"}]},
        ):
            label = triage_issue.current_priority_label(
                "example/repo",
                23,
                token="token",
                api_url="https://api.github.test",
            )

        self.assertEqual(label, "priority:P0")

    def test_concurrent_label_creation_accepts_another_run_winning_the_race(self) -> None:
        with patch.object(
            triage_issue,
            "github_request",
            side_effect=[
                triage_issue.RequestFailure("GitHub", 404, "/labels/test"),
                triage_issue.RequestFailure("GitHub", 422, "/labels"),
                {"name": "test"},
            ],
        ) as github_request:
            triage_issue.ensure_label(
                "example/repo",
                "test",
                "ffffff",
                "Test label",
                token="token",
                api_url="https://api.github.test",
            )

        self.assertEqual(github_request.call_count, 3)

    def test_high_confidence_duplicate_is_advisory_and_never_closed(self) -> None:
        issue = {
            "number": 23,
            "title": "[Bug]: Backup stalls",
            "body": acknowledged_body("Steps"),
            "labels": [{"name": "bug"}],
        }
        candidate = {
            "number": 17,
            "title": "Backup never advances",
            "body": "Same steps",
            "html_url": "https://github.com/example/repo/issues/17",
            "state": "open",
            "labels": [],
        }
        decision = {
            "is_duplicate": True,
            "confidence": 0.97,
            "duplicate_issue_number": 17,
            "reason": "Same failure.",
            "priority": "P1",
            "priority_reason": "A core workflow is blocked.",
        }
        raw = "data: " + json.dumps(
            {"choices": [{"delta": {"content": json.dumps(decision)}}]}
        )
        environment = {
            "GH_TOKEN": "github-test-token",
            "LLM_API_KEY": "llm-test-token",
            "LLM_API_URL": "https://api.example.test/v1/chat/completions",
            "LLM_MODEL": "custom-model",
            "GITHUB_REPOSITORY": "example/repo",
            "GITHUB_EVENT_PATH": "/tmp/test-event.json",
            "GITHUB_API_URL": "https://api.github.test",
        }

        with (
            patch.dict("os.environ", environment, clear=True),
            patch.object(triage_issue, "load_event", return_value=issue),
            patch.object(triage_issue, "fetch_issues", return_value=[candidate]),
            patch.object(triage_issue, "select_candidates", return_value=[candidate]),
            patch.object(triage_issue, "request_json", return_value=raw),
            patch.object(triage_issue, "ensure_label") as ensure_label,
            patch.object(triage_issue, "add_labels") as add_labels,
            patch.object(triage_issue, "current_priority_label", return_value=None),
            patch.object(triage_issue, "upsert_comment") as upsert_comment,
        ):
            result = triage_issue.main()

        self.assertEqual(result, 0)
        self.assertEqual(ensure_label.call_count, 3)
        add_labels.assert_called_once()
        self.assertEqual(add_labels.call_args.args[:2], ("example/repo", 23))
        self.assertEqual(
            add_labels.call_args.args[2],
            ["triage:checked", "priority:P1", "possible duplicate"],
        )
        upsert_comment.assert_called_once()
        comment = upsert_comment.call_args.args[2]
        self.assertIn("A maintainer must confirm", comment)

    def test_feature_request_never_receives_a_priority_label(self) -> None:
        issue = {
            "number": 24,
            "title": "[Feature]: Add shared libraries",
            "body": acknowledged_body("Use case"),
            "labels": [{"name": "enhancement"}],
        }
        decision = {
            "is_duplicate": False,
            "confidence": 0.1,
            "duplicate_issue_number": 0,
            "reason": "No duplicate.",
            "priority": "NONE",
            "priority_reason": "Priorities apply only to bugs.",
        }
        raw = "data: " + json.dumps(
            {"choices": [{"delta": {"content": json.dumps(decision)}}]}
        )
        environment = {
            "GH_TOKEN": "github-test-token",
            "LLM_API_KEY": "llm-test-token",
            "LLM_API_URL": "https://api.example.test/v1/chat/completions",
            "LLM_MODEL": "custom-model",
            "GITHUB_REPOSITORY": "example/repo",
            "GITHUB_EVENT_PATH": "/tmp/test-event.json",
            "GITHUB_API_URL": "https://api.github.test",
        }

        with (
            patch.dict("os.environ", environment, clear=True),
            patch.object(triage_issue, "load_event", return_value=issue),
            patch.object(triage_issue, "fetch_issues", return_value=[]),
            patch.object(triage_issue, "select_candidates", return_value=[]),
            patch.object(triage_issue, "request_json", return_value=raw),
            patch.object(triage_issue, "ensure_label") as ensure_label,
            patch.object(triage_issue, "add_labels") as add_labels,
            patch.object(triage_issue, "current_priority_label") as current_priority_label,
        ):
            result = triage_issue.main()

        self.assertEqual(result, 0)
        ensure_label.assert_called_once()
        current_priority_label.assert_not_called()
        self.assertEqual(add_labels.call_args.args[2], ["triage:checked"])

    def test_missing_acknowledgement_skips_external_triage_without_labels(self) -> None:
        issue = {
            "number": 25,
            "title": "[Bug]: Missing acknowledgement",
            "body": "- [ ] I acknowledge that redacted excerpts may be sent.",
            "labels": [{"name": "bug"}],
        }
        environment = {
            "GH_TOKEN": "github-test-token",
            "LLM_API_KEY": "llm-test-token",
            "LLM_API_URL": "https://api.example.test/v1/chat/completions",
            "LLM_MODEL": "custom-model",
            "GITHUB_REPOSITORY": "example/repo",
            "GITHUB_EVENT_PATH": "/tmp/test-event.json",
            "GITHUB_API_URL": "https://api.github.test",
        }

        with (
            patch.dict("os.environ", environment, clear=True),
            patch.object(triage_issue, "load_event", return_value=issue),
            patch.object(triage_issue, "fetch_issues") as fetch_issues,
            patch.object(triage_issue, "request_json") as request_json,
            patch.object(triage_issue, "ensure_label") as ensure_label,
            patch.object(triage_issue, "add_labels") as add_labels,
        ):
            result = triage_issue.main()

        self.assertEqual(result, 0)
        fetch_issues.assert_not_called()
        request_json.assert_not_called()
        ensure_label.assert_not_called()
        add_labels.assert_not_called()


if __name__ == "__main__":
    unittest.main()
