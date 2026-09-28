#!/usr/bin/env python3
"""Replay the automated review on recorded pull request snapshots, with and without the repository rules.

Maintainers dispatch this from the default branch to measure a reviewer change that ships behind a switch before
the switch is turned on. It publishes nothing: no comment, no review, no status. It writes a JSON result and a
Markdown report for maintainer adjudication.
"""

from __future__ import annotations

import json
import os
import pathlib
import re
import sys
import time
from collections.abc import Callable
from typing import Any

sys.path.insert(0, str(pathlib.Path(__file__).parent))
from github_llm_client import github_request  # noqa: E402
from review_pull_request import (  # noqa: E402
    REPOSITORY_ROOT,
    REVIEW_LLM_TOTAL_SECONDS,
    BatchReviewOutcome,
    PullRequestSnapshot,
    fetch_pull_request,
    llm_configuration,
    load_repository_rules,
    review_idle_seconds,
    review_pull_request_files,
)

CASES_PATH = REPOSITORY_ROOT / ".github" / "review-replay" / "cases.json"
# Two findings can be the same claim when they are in the same file within this many lines, because a model can
# anchor a claim on a neighboring changed line. Proximity only proposes a pair; see `pair_findings`.
MATCH_LINE_WINDOW = 3
VERDICTS = ("true_finding", "false_positive")
VARIANTS = ("baseline", "repository_rules")
# GitHub's compare endpoint lists at most 300 files and has no further pages.
COMPARE_FILE_LIMIT = 300
# The workflow stops the job after 350 minutes. The replay stops starting reviews early enough to write its files.
DEFAULT_BUDGET_SECONDS = 300 * 60
# Evidence verification reads source files outside the review's model deadline. Eight candidates in distinct files
# read 16 sources, and each read can take about three minutes with GitHub's retries.
SOURCE_READ_RESERVE_SECONDS = 3_000
# Titles that share at least this share of their words may describe the same claim. Only a maintainer decides that.
SIMILAR_TITLE_OVERLAP = 0.5
_STOP_WORDS = frozenset(
    "a an and are as at be by can for from in into is it its of on or that the this to when with".split())
_SHA = re.compile(r"[0-9a-f]{40}")


class TruncatedComparisonError(RuntimeError):
    """The recorded snapshot changes more files than GitHub's compare endpoint lists."""


def load_cases(path: pathlib.Path = CASES_PATH) -> list[dict[str, Any]]:
    document = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(document, dict) or document.get("version") != 1 or not isinstance(document.get("cases"), list):
        raise ValueError("The replay case file needs version 1 and a case list")
    seen: set[int] = set()
    for case in document["cases"]:
        if not isinstance(case, dict) or set(case) != {"pull_request", "head_sha", "base_sha", "adjudicated"}:
            raise ValueError("A replay case has unexpected fields")
        number = case["pull_request"]
        if type(number) is not int or number < 1 or number in seen:
            raise ValueError("A replay case needs a unique pull request number")
        seen.add(number)
        if not all(isinstance(case[key], str) and _SHA.fullmatch(case[key]) for key in ("head_sha", "base_sha")):
            raise ValueError(f"Replay case {number} needs full commit SHAs")
        if not isinstance(case["adjudicated"], list):
            raise ValueError(f"Replay case {number} needs an adjudication list")
        for item in case["adjudicated"]:
            # The title and severity identify the adjudicated claim; the location alone can hold several claims.
            if (not isinstance(item, dict) or set(item) - {"path", "line", "severity", "title", "verdict", "note"}
                    or not isinstance(item.get("path"), str) or not item["path"]
                    or type(item.get("line")) is not int or item["line"] < 1
                    or item.get("severity") not in ("blocking", "warning", "suggestion")
                    or not isinstance(item.get("title"), str) or not item["title"].strip()
                    or item.get("verdict") not in VERDICTS
                    or not isinstance(item.get("note", ""), str)):
                raise ValueError(f"Replay case {number} has an invalid adjudication")
    return document["cases"]


def select_cases(cases: list[dict[str, Any]], selection: str) -> list[dict[str, Any]]:
    """The cases named in a comma-separated list of pull request numbers; all cases for an empty selection."""
    requested = {part.strip() for part in selection.split(",") if part.strip()}
    if not requested:
        return cases
    if not all(part.isdigit() for part in requested):
        raise ValueError("Select cases by pull request number")
    numbers = {int(part) for part in requested}
    unknown = numbers - {case["pull_request"] for case in cases}
    if unknown:
        raise ValueError(f"No replay case for pull requests {sorted(unknown)}")
    return [case for case in cases if case["pull_request"] in numbers]


def finding_records(review: dict[str, Any], files: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Findings with their file path. The reviewer numbers files as `file-001` in GitHub's order."""
    records = []
    for finding in review.get("findings", []):
        match = re.fullmatch(r"file-(\d{3})", str(finding.get("file_id", "")))
        index = int(match.group(1)) - 1 if match else -1
        path = files[index].get("filename") if 0 <= index < len(files) else None
        records.append({
            "path": path if isinstance(path, str) else "",
            "line": finding.get("line"),
            "severity": finding.get("severity"),
            "title": finding.get("title", ""),
            "detail": finding.get("detail", ""),
        })
    return records


def completeness(outcome: BatchReviewOutcome) -> dict[str, Any]:
    """The same limitations that make the published review 'incomplete'. Absence proves nothing when any is set."""
    review, coverage = outcome.review, outcome.coverage
    model_gaps = review.get("testing_gaps", []) if "review_notes" in review else []
    limits = {
        "unavailable": bool(review.get("unavailable")),
        "text_gaps": len(coverage.text_gaps),
        "unreviewed_files": len(coverage.unreviewed_files),
        "verification_gaps": len(review.get("verification_gaps", [])),
        "model_gaps": len(model_gaps),
        "reviewed_lines": coverage.reviewed_lines,
        "text_lines": coverage.text_lines,
    }
    limits["complete"] = not (
        limits["unavailable"] or limits["text_gaps"] or limits["unreviewed_files"]
        or limits["verification_gaps"] or limits["model_gaps"] or coverage.reviewed_lines < coverage.text_lines)
    return limits


def _claim_words(title: object) -> set[str]:
    return {word for word in re.findall(r"[a-z0-9]+", str(title).lower()) if word not in _STOP_WORDS}


def _same_location(left: dict[str, Any], right: dict[str, Any]) -> bool:
    return (left["path"] == right["path"] and isinstance(left["line"], int) and isinstance(right["line"], int)
            and abs(left["line"] - right["line"]) <= MATCH_LINE_WINDOW
            and left.get("severity") == right.get("severity"))


def _same_claim(left: dict[str, Any], right: dict[str, Any]) -> bool:
    """Identity needs the same title. Similar titles can name different operations, for example uploads and downloads."""
    def normalized(item: dict[str, Any]) -> str:
        return " ".join(str(item.get("title", "")).lower().split())

    return _same_location(left, right) and bool(normalized(left)) and normalized(left) == normalized(right)


def _similar_claim(left: dict[str, Any], right: dict[str, Any]) -> bool:
    left_words, right_words = _claim_words(left.get("title")), _claim_words(right.get("title"))
    return (_same_location(left, right) and bool(left_words) and bool(right_words)
            and len(left_words & right_words) / len(left_words | right_words) >= SIMILAR_TITLE_OVERLAP)


def pair_findings(
    left: list[dict[str, Any]], right: list[dict[str, Any]]
) -> tuple[list[tuple[int, int]], set[int], set[int]]:
    """One-to-one pairs of the same claim, and the items that only a maintainer can pair.

    A pair needs the same file, severity, and title at a nearby line, with no competing candidate. An item is
    ambiguous when it has several such candidates, or when it stays unpaired next to a similar claim on the other
    side. An ambiguous item is neither paired nor reported as missing or as a difference.
    """
    left_candidates = {index: [other for other, item in enumerate(right) if _same_claim(left[index], item)]
                       for index in range(len(left))}
    right_candidates = {index: [other for other, item in enumerate(left) if _same_claim(item, right[index])]
                        for index in range(len(right))}
    pairs = [(index, candidates[0]) for index, candidates in left_candidates.items()
             if len(candidates) == 1 and right_candidates[candidates[0]] == [index]]
    paired_left = {index for index, _ in pairs}
    paired_right = {index for _, index in pairs}
    ambiguous_left = {index for index in range(len(left)) if index not in paired_left and (
        left_candidates[index] or any(_similar_claim(left[index], item) for item in right))}
    ambiguous_right = {index for index in range(len(right)) if index not in paired_right and (
        right_candidates[index] or any(_similar_claim(item, right[index]) for item in left))}
    return pairs, ambiguous_left, ambiguous_right


def classify(
    findings: list[dict[str, Any]], adjudicated: list[dict[str, Any]], *, complete: bool
) -> dict[str, list[dict[str, Any]]]:
    """Compare one variant's findings with the maintainer's verdicts for the same snapshot.

    A missing finding counts only when the variant reviewed everything; otherwise it is inconclusive.
    """
    pairs, ambiguous_adjudications, ambiguous_findings = pair_findings(adjudicated, findings)
    paired_adjudications = {left for left, _ in pairs}
    paired_findings = {right for _, right in pairs}
    result: dict[str, list[dict[str, Any]]] = {
        "true_found": [], "true_missed": [], "false_reproduced": [], "false_avoided": [], "inconclusive": [],
        "ambiguous": [], "unadjudicated": [],
    }
    for index, item in enumerate(adjudicated):
        if index in ambiguous_adjudications:
            result["ambiguous"].append(item)
        elif index in paired_adjudications:
            result["true_found" if item["verdict"] == "true_finding" else "false_reproduced"].append(item)
        elif complete:
            result["true_missed" if item["verdict"] == "true_finding" else "false_avoided"].append(item)
        else:
            result["inconclusive"].append(item)
    result["unadjudicated"] = [
        finding for index, finding in enumerate(findings)
        if index not in paired_findings and index not in ambiguous_findings
    ]
    result["ambiguous"] += [finding for index, finding in enumerate(findings) if index in ambiguous_findings]
    return result


def variant_delta(
    baseline: list[dict[str, Any]], rules: list[dict[str, Any]], *, baseline_complete: bool, rules_complete: bool
) -> dict[str, Any]:
    """Findings that only one variant reports. A side's absence counts only when that side reviewed everything."""
    pairs, ambiguous_baseline, ambiguous_rules = pair_findings(baseline, rules)
    paired_baseline = {left for left, _ in pairs}
    paired_rules = {right for _, right in pairs}
    only_rules = [item for index, item in enumerate(rules)
                  if index not in paired_rules and index not in ambiguous_rules]
    only_baseline = [item for index, item in enumerate(baseline)
                     if index not in paired_baseline and index not in ambiguous_baseline]
    return {
        "only_with_rules": only_rules if baseline_complete else None,
        "only_without_rules": only_baseline if rules_complete else None,
        "inconclusive": ([] if baseline_complete else only_rules) + ([] if rules_complete else only_baseline),
        "ambiguous": [baseline[index] for index in sorted(ambiguous_baseline)]
        + [rules[index] for index in sorted(ambiguous_rules)],
    }


def _finding_line(finding: dict[str, Any]) -> str:
    title = str(finding.get("title", "")).replace("|", "\\|").replace("\n", " ")[:160]
    return f"`{finding['path']}:{finding['line']}` **{str(finding.get('severity', '')).upper()}** {title}"


def render_report(results: list[dict[str, Any]]) -> str:
    lines = ["# Automated review replay", "",
             "Nothing was published. Adjudicate new findings in `.github/review-replay/cases.json`.",
             "A variant that did not review everything cannot show that a finding is absent.", "",
             "| PR | Variant | Complete | Findings | True found | True missed | False reproduced | Unadjudicated |",
             "|---|---|---|---|---|---|---|---|"]
    for result in results:
        for variant in VARIANTS:
            outcome = result["variants"].get(variant, {})
            if "classification" not in outcome:
                reason = outcome.get("error") or f"skipped: {outcome.get('skipped', 'not run')}"
                lines.append(f"| #{result['pull_request']} | {variant} | no ({reason}) | | | | | |")
                continue
            summary = outcome["classification"]
            lines.append(
                f"| #{result['pull_request']} | {variant} | {'yes' if outcome['limits']['complete'] else 'no'} "
                f"| {len(outcome['findings'])} | {len(summary['true_found'])} | {len(summary['true_missed'])} "
                f"| {len(summary['false_reproduced'])} | {len(summary['unadjudicated'])} |")
    for result in results:
        sections = []
        # Every finding and verdict that needs a maintainer stays visible, whatever the other variant did.
        for variant in VARIANTS:
            summary = result["variants"].get(variant, {}).get("classification")
            if not summary:
                continue
            for key, heading in (("unadjudicated", "unadjudicated findings"),
                                 ("ambiguous", "ambiguous findings and verdicts (similar claims nearby)"),
                                 ("inconclusive", "inconclusive verdicts (the variant did not review everything)")):
                if summary[key]:
                    sections += ["", f"{variant}, {heading}:"] + [f"- {_finding_line(item)}" for item in summary[key]]
        delta = result.get("delta")
        if delta:
            for key, heading in (("only_with_rules", "Only with the repository rules"),
                                 ("only_without_rules", "Only without the repository rules"),
                                 ("inconclusive", "Inconclusive (the other variant did not review everything)"),
                                 ("ambiguous", "Ambiguous differences (similar claims nearby)")):
                if delta[key] is None:
                    sections += ["", f"{heading}: not measurable."]
                elif delta[key]:
                    sections += ["", f"{heading}:"] + [f"- {_finding_line(item)}" for item in delta[key]]
        if sections:
            lines += ["", f"## #{result['pull_request']}"] + sections
    return "\n".join(lines) + "\n"


def replay_case(case: dict[str, Any], repo: str, *, github_token: str, api_url: str, llm_token: str,
                rules: str | None, has_time: Callable[[], bool] = lambda: True) -> dict[str, Any]:
    number = case["pull_request"]
    if not has_time():
        return {"pull_request": number, "variants": {name: {"skipped": "time budget"} for name in VARIANTS}}
    pull_request = fetch_pull_request(repo, number, token=github_token, api_url=api_url)
    comparison = github_request(
        "GET", f"/repos/{repo}/compare/{case['base_sha']}...{case['head_sha']}", token=github_token, api_url=api_url)
    files = comparison.get("files") if isinstance(comparison, dict) else None
    if not isinstance(files, list):
        raise RuntimeError("GitHub returned no file list for the recorded snapshot")
    if len(files) >= COMPARE_FILE_LIMIT:
        raise TruncatedComparisonError("The comparison may omit changed files")
    # Review the recorded snapshot, not the pull request's current state.
    pull_request = dict(pull_request, head=dict(pull_request.get("head") or {}, sha=case["head_sha"]),
                        changed_files=len(files))
    snapshot = PullRequestSnapshot(
        number, case["head_sha"], str((pull_request.get("base") or {}).get("ref", "")), case["base_sha"], False, "open")
    llm_api_url, model, reasoning_effort = llm_configuration()
    idle_seconds = review_idle_seconds()
    result: dict[str, Any] = {"pull_request": number, "variants": {}}
    for variant in VARIANTS:
        if not has_time():
            result["variants"][variant] = {"skipped": "time budget"}
            continue
        try:
            outcome = review_pull_request_files(
                pull_request, files, snapshot, repo, github_token=github_token, api_url=api_url,
                llm_token=llm_token, llm_api_url=llm_api_url, model=model, reasoning_effort=reasoning_effort,
                repository_rules=rules if variant == "repository_rules" else None,
                deadline=time.monotonic() + REVIEW_LLM_TOTAL_SECONDS, idle_seconds=idle_seconds,
                is_current=lambda: True)
            if outcome is None:
                raise RuntimeError("The review returned no outcome")
            limits = completeness(outcome)
            findings = finding_records(outcome.review, files)
            result["variants"][variant] = {
                "findings": findings,
                "limits": limits,
                "classification": classify(findings, case["adjudicated"], complete=limits["complete"]),
            }
        except Exception as error:  # One unavailable variant must not hide the other results.
            # Record the error type only; provider content and request details stay out of the report.
            result["variants"][variant] = {"error": type(error).__name__}
    baseline, with_rules = (result["variants"][name] for name in VARIANTS)
    if "findings" in baseline and "findings" in with_rules:
        result["delta"] = variant_delta(
            baseline["findings"], with_rules["findings"],
            baseline_complete=baseline["limits"]["complete"], rules_complete=with_rules["limits"]["complete"])
    return result


def write_results(output: pathlib.Path, results: list[dict[str, Any]]) -> str:
    (output / "results.json").write_text(json.dumps(results, indent=2) + "\n", encoding="utf-8")
    report = render_report(results)
    (output / "report.md").write_text(report, encoding="utf-8")
    return report


def main() -> int:
    github_token = os.environ.get("GH_TOKEN", "")
    llm_token = os.environ.get("LLM_API_KEY", "")
    repo = os.environ.get("GITHUB_REPOSITORY", "")
    api_url = os.environ.get("GITHUB_API_URL", "https://api.github.com")
    if not github_token or not repo or not llm_token:
        raise RuntimeError("GH_TOKEN, GITHUB_REPOSITORY and LLM_API_KEY are required")
    rules = load_repository_rules()
    if rules is None:
        raise RuntimeError("The repository rules could not be loaded")
    cases = select_cases(load_cases(), os.environ.get("REPLAY_CASES", ""))
    output = pathlib.Path(os.environ.get("REPLAY_OUTPUT", "review-replay-output"))
    output.mkdir(parents=True, exist_ok=True)
    stop_at = time.monotonic() + float(os.environ.get("REPLAY_BUDGET_SECONDS") or DEFAULT_BUDGET_SECONDS)

    def has_time() -> bool:
        # A review can use its whole analysis budget plus slow source reads, so start one only when it can finish.
        return time.monotonic() + REVIEW_LLM_TOTAL_SECONDS + SOURCE_READ_RESERVE_SECONDS <= stop_at

    results: list[dict[str, Any]] = []
    report = write_results(output, results)
    for case in cases:
        print(f"Replaying pull request #{case['pull_request']}", flush=True)
        try:
            results.append(replay_case(case, repo, github_token=github_token, api_url=api_url,
                                       llm_token=llm_token, rules=rules, has_time=has_time))
        except Exception as error:
            results.append({"pull_request": case["pull_request"],
                            "variants": {name: {"error": type(error).__name__} for name in VARIANTS}})
        # Keep every finished case, so a stopped job still leaves its results.
        report = write_results(output, results)
    summary_path = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary_path:
        with open(summary_path, "a", encoding="utf-8") as summary:
            summary.write(report)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
