import contextlib
import io
import json
import unittest
import urllib.error
from unittest import mock

import require_merge_queue


class MergeQueueGuardTests(unittest.TestCase):
    def response(self, rules, headers=None):
        stream = io.BytesIO(json.dumps(rules).encode())
        stream.headers = headers or {}
        return contextlib.closing(stream)

    def test_effective_main_queue_rule_is_required(self):
        with mock.patch("urllib.request.urlopen", return_value=self.response([
            {"type": "required_status_checks"}, {"type": "merge_queue"}
        ])) as request:
            require_merge_queue.require_queue("OnCloud-at/encrypted-memories")
        self.assertEqual(
            request.call_args.args[0].full_url,
            "https://api.github.com/repos/OnCloud-at/encrypted-memories/rules/branches/main?per_page=100",
        )

    def test_allgreen_is_required_for_policy_skip(self):
        for rules, allowed in [
            ([{"type": "merge_queue", "parameters": {"grouping_strategy": "ALLGREEN"}}], True),
            ([{"type": "merge_queue", "parameters": {"grouping_strategy": "HEADGREEN"}}], False),
            ([{"type": "merge_queue", "parameters": {"grouping_strategy": "allgreen"}}], False),
            ([{"type": "merge_queue", "parameters": {}}], False),
            ([{"type": "merge_queue"}], False),
            ([{"type": "merge_queue", "parameters": {"grouping_strategy": "ALLGREEN"}},
              {"type": "merge_queue", "parameters": {"grouping_strategy": "HEADGREEN"}}], False),
            ([], False),
        ]:
            with self.subTest(rules=rules):
                with mock.patch("urllib.request.urlopen", return_value=self.response(rules)):
                    self.assertEqual(allowed, require_merge_queue.allgreen_queue("OnCloud-at/encrypted-memories"))

    def test_next_link_fails_closed_but_last_link_is_allowed(self):
        rules = [{"type": "merge_queue", "parameters": {"grouping_strategy": "ALLGREEN"}}]
        for link, allowed in [('<https://example.invalid/?page=2>; rel="next"', False),
                              ('<https://example.invalid/?page=2>; rel="last"', True)]:
            with self.subTest(link=link):
                with mock.patch("urllib.request.urlopen", return_value=self.response(rules, {"Link": link})):
                    with contextlib.redirect_stderr(io.StringIO()):
                        self.assertEqual(allowed, require_merge_queue.allgreen_queue("OnCloud-at/encrypted-memories"))

    def test_allgreen_diagnostics_show_reason_without_token(self):
        for value, expected in [(urllib.error.HTTPError("url", 403, "Forbidden", {}, None), "HTTP 403"),
                                ([{"type": "merge_queue", "parameters": {"grouping_strategy": "HEADGREEN"}}], "HEADGREEN"),
                                (urllib.error.URLError("synthetic-test-token"), "Cannot read a valid response")]:
            stream = io.StringIO()
            with mock.patch.dict("os.environ", {"GH_TOKEN": "synthetic-test-token"}):
                patch = mock.patch("urllib.request.urlopen", side_effect=value) if isinstance(value, Exception) else mock.patch("urllib.request.urlopen", return_value=self.response(value))
                with patch, contextlib.redirect_stderr(stream):
                    self.assertFalse(require_merge_queue.allgreen_queue("OnCloud-at/encrypted-memories"))
            self.assertIn(expected, stream.getvalue())
            self.assertNotIn("synthetic-test-token", stream.getvalue())

    def test_allgreen_cannot_be_verified_when_rules_are_unavailable(self):
        with mock.patch("urllib.request.urlopen", side_effect=urllib.error.URLError("unavailable")):
            self.assertFalse(require_merge_queue.allgreen_queue("OnCloud-at/encrypted-memories"))

    def test_allgreen_cli_rejects_headgreen(self):
        rules = [{"type": "merge_queue", "parameters": {"grouping_strategy": "HEADGREEN"}}]
        with mock.patch("sys.argv", ["guard", "--require-allgreen", "OnCloud-at/encrypted-memories"]):
            with mock.patch("urllib.request.urlopen", return_value=self.response(rules)):
                with contextlib.redirect_stdout(io.StringIO()):
                    self.assertEqual(1, require_merge_queue.main())

    def test_missing_queue_rule_fails_closed(self):
        with mock.patch("urllib.request.urlopen", return_value=self.response([
            {"type": "required_status_checks"}
        ])):
            with self.assertRaises(require_merge_queue.MergeQueueMissing):
                require_merge_queue.require_queue("OnCloud-at/encrypted-memories")

    def test_api_failure_fails_closed(self):
        error = urllib.error.HTTPError("https://api.github.com", 403, "Forbidden", {}, None)
        with mock.patch("urllib.request.urlopen", side_effect=error):
            with self.assertRaises(require_merge_queue.RulesUnavailable) as result:
                require_merge_queue.require_queue("OnCloud-at/encrypted-memories")
        self.assertIn("403", str(result.exception))

    def test_malformed_response_fails_closed(self):
        for value in [{"type": "merge_queue"}, [None], "merge_queue"]:
            with self.subTest(value=value):
                with mock.patch("urllib.request.urlopen", return_value=self.response(value)):
                    with self.assertRaises(require_merge_queue.RulesUnavailable):
                        require_merge_queue.require_queue("OnCloud-at/encrypted-memories")

    def test_invalid_json_fails_closed(self):
        stream = io.BytesIO(b"invalid")
        stream.headers = {}
        with mock.patch("urllib.request.urlopen", return_value=contextlib.closing(stream)):
            with self.assertRaises(require_merge_queue.RulesUnavailable):
                require_merge_queue.require_queue("OnCloud-at/encrypted-memories")

    def test_network_failure_does_not_expose_request_data(self):
        with mock.patch("urllib.request.urlopen", side_effect=urllib.error.URLError("private request detail")):
            with self.assertRaises(require_merge_queue.RulesUnavailable) as result:
                require_merge_queue.require_queue("OnCloud-at/encrypted-memories")
        self.assertNotIn("private request detail", str(result.exception))

    def test_public_request_needs_no_write_permission_or_secret(self):
        with mock.patch.dict("os.environ", {}, clear=True):
            with mock.patch("urllib.request.urlopen", return_value=self.response([{"type": "merge_queue"}])) as request:
                require_merge_queue.require_queue("OnCloud-at/encrypted-memories")
        self.assertNotIn("Authorization", request.call_args.args[0].headers)


if __name__ == "__main__":
    unittest.main()
