import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.request


class QueueGuardError(Exception):
    code = "queue_guard"


class MergeQueueMissing(QueueGuardError):
    code = "merge_queue_missing"


class RulesUnavailable(QueueGuardError):
    code = "rules_unavailable"


def require_queue(repository):
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
        raise RulesUnavailable("The repository identifier is invalid.")
    # This endpoint returns active rules that apply to main, including inherited rulesets.
    # Public repositories require no permission. The automatic read-only token avoids the anonymous rate limit.
    headers = {"Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28"}
    token = os.environ.get("GH_TOKEN")
    if token:
        headers["Authorization"] = f"Bearer {token}"
    request = urllib.request.Request(
        f"https://api.github.com/repos/{repository}/rules/branches/main?per_page=100", headers=headers
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            link = response.headers.get("Link", "")
            if re.search(r'(?:^|[,;])\s*rel\s*=\s*(?:"[^"]*\bnext\b[^"]*"|next\b)', link, re.I):
                raise RulesUnavailable("The effective main rules have another page.")
            rules = json.load(response)
    except urllib.error.HTTPError as error:
        raise RulesUnavailable(f"Cannot read effective main rules: HTTP {error.code}.") from error
    except (OSError, urllib.error.URLError, ValueError) as error:
        raise RulesUnavailable("Cannot read a valid response for effective main rules.") from error
    if not isinstance(rules, list) or not all(isinstance(rule, dict) for rule in rules):
        raise RulesUnavailable("The effective main rules response has an invalid shape.")
    if not any(rule.get("type") == "merge_queue" for rule in rules):
        raise MergeQueueMissing(
            "Enable the merge_queue ruleset on main before using reduced pull request verification."
        )
    return rules


def allgreen_queue(repository):
    try:
        rules = require_queue(repository)
    except QueueGuardError as error:
        print(str(error), file=sys.stderr)
        return False
    queues = [rule for rule in rules if rule.get("type") == "merge_queue"]
    for rule in queues:
        parameters = rule.get("parameters")
        strategy = parameters.get("grouping_strategy") if isinstance(parameters, dict) else None
        if strategy != "ALLGREEN":
            reason = "HEADGREEN" if strategy == "HEADGREEN" else "missing or unrecognized"
            print(f"Queue grouping strategy is {reason}; ALLGREEN is required.", file=sys.stderr)
            return False
    return True


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--require-allgreen", action="store_true")
    parser.add_argument("repository")
    args = parser.parse_args()
    if args.require_allgreen:
        if not allgreen_queue(args.repository):
            print("ALLGREEN could not be verified; full macOS verification is required.")
            return 1
        print("The merge queue uses ALLGREEN.")
        return 0
    try:
        require_queue(args.repository)
    except QueueGuardError as error:
        print(f"::error::{error.code}: {error}", file=sys.stderr)
        return 1
    print("The merge_queue rule applies to main. Full Apple verification runs in the queue.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
