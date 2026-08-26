import os
import pathlib
import sys
import unittest
from datetime import date
from unittest.mock import patch


sys.path.insert(0, str(pathlib.Path(__file__).parent))
import remind_llm_key_expiry as reminder  # noqa: E402


class ReminderPolicyTests(unittest.TestCase):
    def test_reminder_stages_choose_the_most_urgent_threshold(self) -> None:
        expectations = {31: None, 30: 30, 29: 30, 14: 14, 8: 14, 7: 7, 1: 1, 0: 0, -2: 0}

        for days_remaining, expected in expectations.items():
            with self.subTest(days_remaining=days_remaining):
                self.assertEqual(reminder.reminder_stage(days_remaining), expected)

    def test_expiry_requires_exact_iso_date(self) -> None:
        self.assertEqual(reminder.parse_expiry("2027-08-24"), date(2027, 8, 24))

        for value in ("24.08.2027", "2027-8-24", "not-a-date"):
            with self.subTest(value=value):
                with self.assertRaisesRegex(RuntimeError, "YYYY-MM-DD"):
                    reminder.parse_expiry(value)

    def test_search_result_requires_exact_title_and_marker(self) -> None:
        title = "Rotate LLM API key before 2027-08-24"
        marker = "<!-- llm-api-key-expiry:2027-08-24 -->"
        items = [
            {"number": 1, "title": title, "body": "wrong marker"},
            {"number": 2, "title": title, "body": marker, "pull_request": {}},
            {"number": 3, "title": title, "body": marker},
        ]

        self.assertEqual(reminder.find_reminder_issue(items, title, marker)["number"], 3)


class ReminderFlowTests(unittest.TestCase):
    def setUp(self) -> None:
        self.environment = {
            "GH_TOKEN": "github-test-token",
            "GITHUB_REPOSITORY": "example/repo",
            "GITHUB_API_URL": "https://api.github.test",
            "LLM_API_KEY_EXPIRES_AT": "2027-08-24",
            "LLM_KEY_REMINDER_ASSIGNEE": "maintainer",
        }

    def test_no_github_calls_before_thirty_day_window(self) -> None:
        with (
            patch.dict(os.environ, self.environment, clear=True),
            patch.object(reminder, "ensure_label") as ensure_label,
            patch.object(reminder, "github_request") as github_request,
        ):
            result = reminder.main(today=date(2027, 7, 24))

        self.assertEqual(result, 0)
        ensure_label.assert_not_called()
        github_request.assert_not_called()

    def test_creates_assigned_issue_at_thirty_days(self) -> None:
        with (
            patch.dict(os.environ, self.environment, clear=True),
            patch.object(reminder, "ensure_label") as ensure_label,
            patch.object(
                reminder,
                "github_request",
                side_effect=[{"items": []}, {"number": 9}],
            ) as github_request,
        ):
            result = reminder.main(today=date(2027, 7, 25))

        self.assertEqual(result, 0)
        ensure_label.assert_called_once()
        create_call = github_request.call_args_list[1]
        self.assertEqual(create_call.args[:2], ("POST", "/repos/example/repo/issues"))
        self.assertEqual(create_call.kwargs["payload"]["assignees"], ["maintainer"])
        self.assertIn("2027-08-24", create_call.kwargs["payload"]["body"])
        self.assertNotIn("github-test-token", create_call.kwargs["payload"]["body"])

    def test_existing_stage_is_not_repeated(self) -> None:
        existing = {
            "number": 9,
            "title": "Rotate LLM API key before 2027-08-24",
            "body": "<!-- llm-api-key-expiry:2027-08-24 -->",
            "state": "open",
        }
        with (
            patch.dict(os.environ, self.environment, clear=True),
            patch.object(reminder, "ensure_label"),
            patch.object(
                reminder,
                "github_request",
                side_effect=[{"items": [existing]}, [{"body": "<!-- llm-api-key-expiry-stage:14 -->"}]],
            ) as github_request,
        ):
            result = reminder.main(today=date(2027, 8, 10))

        self.assertEqual(result, 0)
        self.assertEqual(github_request.call_count, 2)

    def test_closed_issue_is_reopened_on_final_day(self) -> None:
        existing = {
            "number": 9,
            "title": "Rotate LLM API key before 2027-08-24",
            "body": "<!-- llm-api-key-expiry:2027-08-24 -->",
            "state": "closed",
        }
        with (
            patch.dict(os.environ, self.environment, clear=True),
            patch.object(reminder, "ensure_label"),
            patch.object(
                reminder,
                "github_request",
                side_effect=[{"items": [existing]}, {}, [], {}],
            ) as github_request,
        ):
            result = reminder.main(today=date(2027, 8, 24))

        self.assertEqual(result, 0)
        self.assertEqual(github_request.call_args_list[1].args[0], "PATCH")
        self.assertEqual(github_request.call_args_list[-1].args[0], "POST")


if __name__ == "__main__":
    unittest.main()
