#!/usr/bin/env python3
"""Create a GitHub issue before the configured LLM API key expires."""

from __future__ import annotations

import os
import re
import sys
from datetime import date, datetime, timezone
from typing import Any
from urllib.parse import urlencode

from triage_issue import RequestFailure, ensure_label, github_request


REMINDER_DAYS = (30, 14, 7, 1, 0)
REMINDER_LABEL = "maintenance"
USERNAME_PATTERN = re.compile(r"^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})$")


def parse_expiry(value: str) -> date:
    try:
        expiry = date.fromisoformat(value)
    except ValueError as error:
        raise RuntimeError("LLM_API_KEY_EXPIRES_AT must use YYYY-MM-DD") from error
    if expiry.isoformat() != value:
        raise RuntimeError("LLM_API_KEY_EXPIRES_AT must use YYYY-MM-DD")
    return expiry


def reminder_stage(days_remaining: int) -> int | None:
    applicable = [threshold for threshold in REMINDER_DAYS if days_remaining <= threshold]
    return min(applicable) if applicable else None


def reminder_title(expiry: date) -> str:
    return f"Rotate LLM API key before {expiry.isoformat()}"


def reminder_marker(expiry: date) -> str:
    return f"<!-- llm-api-key-expiry:{expiry.isoformat()} -->"


def stage_marker(stage: int) -> str:
    return f"<!-- llm-api-key-expiry-stage:{stage} -->"


def stage_message(expiry: date, days_remaining: int, stage: int) -> str:
    if stage == 0:
        if days_remaining < 0:
            timing = f"The configured LLM API key expired {-days_remaining} day(s) ago."
        else:
            timing = "The configured LLM API key expires today."
    else:
        timing = f"The configured LLM API key expires in {days_remaining} day(s)."
    return (
        f"{stage_marker(stage)}\n"
        f"{timing} The configured expiry date is **{expiry.isoformat()}**.\n\n"
        "Create a replacement key, update the `LLM_API_KEY` Actions secret, and set a new "
        "`LLM_API_KEY_EXPIRES_AT` value."
    )


def issue_body(expiry: date, days_remaining: int, stage: int, assignee: str) -> str:
    mention = f"@{assignee}, " if assignee else ""
    return (
        f"{reminder_marker(expiry)}\n"
        f"{stage_marker(stage)}\n"
        f"{mention}the LLM API key is approaching its configured expiry date.\n\n"
        f"- **Expiry:** {expiry.isoformat()}\n"
        f"- **Days remaining:** {days_remaining}\n\n"
        "Before expiry:\n\n"
        "- Create a replacement LLM API key.\n"
        "- Update the `LLM_API_KEY` GitHub Actions secret.\n"
        "- Update `LLM_API_KEY_EXPIRES_AT` with the next expiry date.\n"
        "- Close this issue after the new key is verified.\n\n"
        "This issue was created automatically. It does not contain the secret value."
    )


def find_reminder_issue(items: list[Any], title: str, marker: str) -> dict[str, Any] | None:
    for item in items:
        if not isinstance(item, dict) or "pull_request" in item:
            continue
        if item.get("title") == title and marker in str(item.get("body") or ""):
            return item
    return None


def search_reminder_issue(
    repo: str,
    title: str,
    marker: str,
    *,
    token: str,
    api_url: str,
) -> dict[str, Any] | None:
    query = urlencode({"q": f'repo:{repo} is:issue in:title "{title}"', "per_page": 100})
    result = github_request(
        "GET",
        f"/search/issues?{query}",
        token=token,
        api_url=api_url,
    )
    if not isinstance(result, dict) or not isinstance(result.get("items"), list):
        raise RuntimeError("GitHub returned invalid reminder search results")
    return find_reminder_issue(result["items"], title, marker)


def comment_has_stage(
    repo: str,
    issue_number: int,
    marker: str,
    *,
    token: str,
    api_url: str,
) -> bool:
    comments = github_request(
        "GET",
        f"/repos/{repo}/issues/{issue_number}/comments?per_page=100",
        token=token,
        api_url=api_url,
    )
    if not isinstance(comments, list):
        raise RuntimeError("GitHub returned invalid reminder comments")
    return any(marker in str(comment.get("body") or "") for comment in comments if isinstance(comment, dict))


def main(*, today: date | None = None) -> int:
    token = os.environ.get("GH_TOKEN", "")
    repo = os.environ.get("GITHUB_REPOSITORY", "")
    api_url = os.environ.get("GITHUB_API_URL", "https://api.github.com")
    expiry_value = os.environ.get("LLM_API_KEY_EXPIRES_AT", "").strip()
    assignee = os.environ.get("LLM_KEY_REMINDER_ASSIGNEE", "").strip()
    if not token or not repo:
        raise RuntimeError("Required GitHub Actions environment is missing")
    if not expiry_value:
        print("::warning::LLM_API_KEY_EXPIRES_AT is not configured; expiry reminder was skipped.")
        return 0
    if assignee and not USERNAME_PATTERN.fullmatch(assignee):
        raise RuntimeError("LLM_KEY_REMINDER_ASSIGNEE is not a valid GitHub username")

    expiry = parse_expiry(expiry_value)
    current_date = today or datetime.now(timezone.utc).date()
    days_remaining = (expiry - current_date).days
    stage = reminder_stage(days_remaining)
    if stage is None:
        print(f"LLM API key expiry check completed; {days_remaining} days remain.")
        return 0

    ensure_label(
        repo,
        REMINDER_LABEL,
        "5319e7",
        "Repository maintenance and credential rotation",
        token=token,
        api_url=api_url,
    )
    title = reminder_title(expiry)
    marker = reminder_marker(expiry)
    issue = search_reminder_issue(repo, title, marker, token=token, api_url=api_url)
    if issue is None:
        payload: dict[str, Any] = {
            "title": title,
            "body": issue_body(expiry, days_remaining, stage, assignee),
            "labels": [REMINDER_LABEL],
        }
        if assignee:
            payload["assignees"] = [assignee]
        github_request(
            "POST",
            f"/repos/{repo}/issues",
            token=token,
            api_url=api_url,
            payload=payload,
        )
        print(f"Created LLM API key expiry reminder for {expiry.isoformat()}.")
        return 0

    issue_number = issue.get("number")
    if not isinstance(issue_number, int):
        raise RuntimeError("GitHub returned an invalid reminder issue")
    if issue.get("state") != "open":
        if days_remaining > 1:
            print("The existing LLM API key expiry reminder is closed; no update was added.")
            return 0
        github_request(
            "PATCH",
            f"/repos/{repo}/issues/{issue_number}",
            token=token,
            api_url=api_url,
            payload={"state": "open"},
        )

    marker_for_stage = stage_marker(stage)
    if marker_for_stage in str(issue.get("body") or "") or comment_has_stage(
        repo,
        issue_number,
        marker_for_stage,
        token=token,
        api_url=api_url,
    ):
        print(f"LLM API key expiry reminder stage {stage} already exists.")
        return 0
    github_request(
        "POST",
        f"/repos/{repo}/issues/{issue_number}/comments",
        token=token,
        api_url=api_url,
        payload={"body": stage_message(expiry, days_remaining, stage)},
    )
    print(f"Updated LLM API key expiry reminder at stage {stage}.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (RequestFailure, RuntimeError) as error:
        print(f"::error::{error}", file=sys.stderr)
        raise SystemExit(1) from None
