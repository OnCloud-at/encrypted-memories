import contextlib
import io
import json
import unittest
import urllib.error
from unittest import mock

import require_merge_queue


class MergeQueueGuardTests(unittest.TestCase):
    def response(self, rules):
        return contextlib.closing(io.BytesIO(json.dumps(rules).encode()))

    def test_effective_main_queue_rule_is_required(self):
        with mock.patch("urllib.request.urlopen", return_value=self.response([
            {"type": "required_status_checks"}, {"type": "merge_queue"}
        ])) as request:
            require_merge_queue.require_queue("OnCloud-at/encrypted-memories")
        self.assertEqual(
            request.call_args.args[0].full_url,
            "https://api.github.com/repos/OnCloud-at/encrypted-memories/rules/branches/main",
        )

    def test_allgreen_is_required_for_policy_skip(self):
        for rules, allowed in [
            ([{"type": "merge_queue", "parameters": {"grouping_strategy": "ALLGREEN"}}], True),
            ([{"type": "merge_queue", "parameters": {"grouping_strategy": "HEADGREEN"}}], False),
            ([{"type": "merge_queue", "parameters": {}}], False),
            ([{"type": "merge_queue"}], False),
            ([{"type": "merge_queue", "parameters": {"grouping_strategy": "ALLGREEN"}},
              {"type": "merge_queue", "parameters": {"grouping_strategy": "HEADGREEN"}}], False),
            ([], False),
        ]:
            with self.subTest(rules=rules):
                with mock.patch("urllib.request.urlopen", return_value=self.response(rules)):
                    self.assertEqual(allowed, require_merge_queue.allgreen_queue("OnCloud-at/encrypted-memories"))

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
        with mock.patch("urllib.request.urlopen", return_value=contextlib.closing(io.BytesIO(b"invalid"))):
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
