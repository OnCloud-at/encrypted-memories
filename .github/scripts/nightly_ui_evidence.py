#!/usr/bin/env python3
"""Write the evidence file of a nightly UI test job and fail unless UI tests really ran (#1134, read by #1166).

Usage: nightly_ui_evidence.py --job <job> --result <bundle> --run-id <id> --run-attempt <n>
           --commit <sha> --checkout-head <sha> --out <file>

The script reads the summary of the result bundle with `xcrun xcresulttool get test-results summary`
(schema 0.5.0). The evidence file is schema 1:
  {"schema": 1, "job": "default-simulator" | "iphone-duo", "run_id": N, "run_attempt": N, "commit": "<40 hex>",
   "simulator": {"name": "<device name>", "os": "<OS version>"},
   "executed": N, "passed": N, "failed": N, "skipped": N, "expected_failures": N, "ok": true | false}

Counts. `executed` is the number of tests that the result bundle reports, skipped tests included. The invariant
  executed = passed + failed + skipped + expected_failures
must hold; the script fails and writes no evidence when it does not. An expected failure is no pass.
`ok` is true only when passed > 0 and failed == 0; passed > 0 already means executed > 0 under the invariant.
The exit status is 0 only when `ok` is true. `executed` does not mean that tests ran: it counts skipped tests too, so a
reader checks `passed`.

Limit of `ok`. It judges the result bundle only. A job can still fail after a clean bundle, for example when the test
script exits non-zero after the last test or when a later step fails. A reader such as the release gate (#1166) must
require `ok` together with the conclusion `success` of the same job, run id and attempt.

Identity. `run_id` and `run_attempt` are GITHUB_RUN_ID and GITHUB_RUN_ATTEMPT (positive whole numbers, no leading
zero). A rerun keeps `run_id`, raises `run_attempt` and keeps `commit`. The artifact API has no attempt field, so the
attempt exists only in this file; a reader compares it with the attempt that it judges.
No evidence file exists after a run that could not establish the commit, exactly one simulator or consistent counts;
an old file at the output path is removed first.
"""
import argparse
import json
import os
import pathlib
import re
import subprocess
import sys

JOBS = ("default-simulator", "iphone-duo")
COUNTS = ("totalTestCount", "passedTests", "failedTests", "skippedTests", "expectedFailures")
SHA = re.compile(r"[0-9a-f]{40}")
NUMBER = re.compile(r"[1-9][0-9]*")


class EvidenceError(Exception):
    pass


def read_summary(result):
    """The summary JSON of a result bundle. A missing bundle means that no test started."""
    if not result.is_dir():
        raise EvidenceError("There is no UI test result bundle, so no UI test ran.")
    command = ["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(result)]
    try:
        completed = subprocess.run(command, capture_output=True, text=True, timeout=300)
    except (OSError, subprocess.TimeoutExpired):
        raise EvidenceError("xcresulttool could not be run.") from None
    if completed.returncode != 0:
        raise EvidenceError("xcresulttool could not read the result bundle.")
    try:
        return json.loads(completed.stdout)
    except ValueError:
        raise EvidenceError("The test summary is not valid JSON.") from None


def count(summary, key):
    value = summary.get(key)
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise EvidenceError(f"The test summary has no valid {key}.")
    return value


def number(text, name):
    if not NUMBER.fullmatch(text):
        raise EvidenceError(f"{name} must be a positive whole number without a leading zero.")
    return int(text)


def simulator(summary):
    """The one simulator that ran the tests. Configurations of one test plan may list it more than once."""
    configurations = summary.get("devicesAndConfigurations")
    found = set()
    for configuration in configurations if isinstance(configurations, list) else []:
        entry = configuration.get("device") if isinstance(configuration, dict) else None
        name = entry.get("deviceName") if isinstance(entry, dict) else None
        version = entry.get("osVersion") if isinstance(entry, dict) else None
        if not (isinstance(name, str) and name and isinstance(version, str) and version):
            raise EvidenceError("A device of the test summary has no name or OS version.")
        found.add((name, version))
    if len(found) != 1:
        raise EvidenceError(f"The test summary must name exactly one simulator, but names {len(found)}.")
    return found.pop()


def build(arguments, summary):
    run_id = number(arguments.run_id, "The run id")
    run_attempt = number(arguments.run_attempt, "The run attempt")
    commit, head = arguments.commit, arguments.checkout_head
    if not (SHA.fullmatch(commit) and SHA.fullmatch(head)):
        raise EvidenceError("The commit of the run and of the checkout must be full lowercase SHA-1 values.")
    if commit != head:
        raise EvidenceError(f"The checked-out commit {head} is not the commit of the run {commit}.")
    if not isinstance(summary, dict):
        raise EvidenceError("The test summary is not a JSON object.")
    executed, passed, failed, skipped, expected_failures = (count(summary, key) for key in COUNTS)
    if executed != passed + failed + skipped + expected_failures:
        raise EvidenceError("The counts do not satisfy executed = passed + failed + skipped + expected_failures.")
    name, version = simulator(summary)
    return {
        "schema": 1, "job": arguments.job, "run_id": run_id, "run_attempt": run_attempt, "commit": commit,
        "simulator": {"name": name, "os": version},
        "executed": executed, "passed": passed, "failed": failed, "skipped": skipped,
        "expected_failures": expected_failures,
        "ok": passed > 0 and failed == 0,
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--job", required=True, choices=JOBS)
    parser.add_argument("--result", required=True, type=pathlib.Path)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--run-attempt", required=True)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--checkout-head", required=True)
    parser.add_argument("--out", required=True, type=pathlib.Path)
    arguments = parser.parse_args()
    arguments.out.unlink(missing_ok=True)
    try:
        evidence = build(arguments, read_summary(arguments.result))
    except EvidenceError as error:
        print(f"::error::{error} The nightly run has no evidence for {arguments.job}.", file=sys.stderr)
        return 1
    arguments.out.parent.mkdir(parents=True, exist_ok=True)
    arguments.out.write_text(json.dumps(evidence, indent=2) + "\n")
    line = (f"UI tests of {evidence['job']} on {evidence['simulator']['name']} (OS {evidence['simulator']['os']}), "
            f"run {evidence['run_id']} attempt {evidence['run_attempt']}: executed {evidence['executed']}, "
            f"passed {evidence['passed']}, failed {evidence['failed']}, skipped {evidence['skipped']}, "
            f"expected failures {evidence['expected_failures']}")
    print(line)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as handle:
            handle.write(line + "\n\n")
    if evidence["executed"] == 0:
        print(f"::error::no UI test ran in {evidence['job']}: the result bundle holds no test.", file=sys.stderr)
    elif evidence["passed"] == 0:
        print(f"::error::no UI test passed in {evidence['job']}: every test was skipped, failed or an expected failure.",
              file=sys.stderr)
    if evidence["failed"]:
        noun = "UI test" if evidence["failed"] == 1 else "UI tests"
        print(f"::error::{evidence['failed']} {noun} failed in {evidence['job']}.", file=sys.stderr)
    return 0 if evidence["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
