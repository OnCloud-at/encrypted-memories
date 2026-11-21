#!/usr/bin/env python3
"""Refuse a release unless the nightly UI run of its exact commit is green (#1166, evidence of #1134).

Usage: release_nightly_gate.py --repository=<owner/name> --commit=<sha> --tag=<tag>
           [--overridden=true|false] [--override-reason=<text>]

The rule. A run for another commit never counts. Of the runs of `nightly-ui-tests.yml` whose head commit equals the
release commit, a run that is still open (any status other than completed, events `schedule` and `workflow_dispatch`)
refuses the release and is named, because its result is not known yet and an older green run must not hide it. Of the
completed runs the newest one decides, ranked by the start of its latest attempt and then by id, so a newer red run is
not hidden by an older green one and a re-run of an older run counts as the newer run. The deciding run passes only
when all of these hold:
  1. The event of the run is `schedule` or `workflow_dispatch`. The nightly workflow has no other trigger, so a run of
     another event is not a run of its contract.
  2. The run concluded `success`.
  3. Each of the two jobs exists exactly once in the latest attempt, concluded `success` and ran in the attempt of the run.
  4. Each job has exactly one evidence artifact that did not expire and belongs to the release commit.
  5. The evidence file (schema 1, written by nightly_ui_evidence.py) names that job, run, attempt and commit, has whole
     counts that add up, at least one passed test and no failed test, and says `ok`. The gate derives the verdict from the
     counts again and does not trust `ok` alone, because `ok` judges the result bundle only (see nightly_ui_evidence.py).
     Numbers must be real integers: a boolean or a float is no number.
The refusal lists every failed condition that the data shows, not only the first. The age of the run is not limited: a run
for the release commit is current by definition. The refusal names a run that is older than 14 days. The simulator name is
not checked, because the iPhone Duo job names its own simulator.

The read ends in a refusal, never in a job timeout: each `gh` call is repeated up to 4 times and the whole read has one
time budget (BUDGET_SECONDS), which stays below the timeout of the workflow step.

A deliberate override of the release gates (--overridden=true) skips the read and records the reason in the job summary.
GitHub offers no input for `workflow_dispatch` here: the nightly run tests the head of the chosen ref, so the remedy is
`gh workflow run nightly-ui-tests.yml --ref <tag>`.
"""
import argparse
import datetime
import html
import io
import json
import os
import re
import subprocess
import sys
import time
import zipfile
import zlib

WORKFLOW = "nightly-ui-tests.yml"
EVENTS = ("schedule", "workflow_dispatch")
JOBS = (("default-simulator", "Nightly iOS UI tests (default simulator)"),
        ("iphone-duo", "Nightly iOS UI tests (iPhone Duo)"))
OLD_RUN = datetime.timedelta(days=14)
EVIDENCE_FILE = "ui-evidence.json"
EVIDENCE_LIMIT = 65536
COUNTS = ("executed", "passed", "failed", "skipped", "expected_failures")
SHA = re.compile(r"[0-9a-f]{40}")
REPOSITORY = re.compile(r"(?!\.+/)[A-Za-z0-9_.-]+/(?!\.+$)[A-Za-z0-9_.-]+")
# The same four tries as retry_command in the release workflow. The step of the workflow stops at STEP_MINUTES, so the
# budget of the whole read ends first and the refusal text is written.
ATTEMPTS = 4
CALL_SECONDS = 60
BUDGET_SECONDS = 240
STEP_MINUTES = 5


class Refusal(Exception):
    """The nightly run does not allow the release."""


class Unreadable(Exception):
    """An evidence artifact is not one valid evidence file."""


class GitHubError(Exception):
    """GitHub could not be read, so the gate cannot decide."""


class GitHubApi:
    """The reads of the gate through the `gh` CLI: up to `attempts` tries per call, one time budget for all calls."""

    def __init__(self, repository, attempts=ATTEMPTS, delay=5, budget=BUDGET_SECONDS, call_seconds=CALL_SECONDS):
        self.repository = repository
        self.attempts = attempts
        self.delay = delay
        self.call_seconds = call_seconds
        self.budget = budget
        self.deadline = time.monotonic() + budget

    def _read(self, arguments, path):
        last = ""
        for attempt in range(1, self.attempts + 1):
            remaining = self.deadline - time.monotonic()
            if remaining <= 0:
                raise GitHubError(f"The time budget of {self.budget} seconds for reading GitHub ran out at {path}"
                                  f"{': ' + last if last else ''}")
            timeout = min(self.call_seconds, remaining)
            try:
                completed = subprocess.run(["gh", "api", *arguments, path], capture_output=True, timeout=timeout)
            except subprocess.TimeoutExpired:
                last = f"no answer within {timeout:.0f} seconds"
            except OSError as error:
                last = str(error)
            else:
                if completed.returncode == 0:
                    return completed.stdout
                last = completed.stderr.decode(errors="replace").strip()[-300:]
            if attempt < self.attempts:
                time.sleep(min(self.delay * attempt, max(0.0, self.deadline - time.monotonic())))
        raise GitHubError(f"The request {path} failed {self.attempts} times: {last}")

    def _pages(self, path, key):
        try:
            pages = json.loads(self._read(["--paginate", "--slurp"], path))
            return [entry for page in pages for entry in page[key]]
        except (ValueError, KeyError, TypeError):
            raise GitHubError(f"The answer to {path} has no list of {key}.") from None

    def runs(self, commit):
        return self._pages(f"repos/{self.repository}/actions/workflows/{WORKFLOW}/runs?head_sha={commit}&per_page=100", "workflow_runs")

    def jobs(self, run_id):
        return self._pages(f"repos/{self.repository}/actions/runs/{run_id}/jobs?filter=latest&per_page=100", "jobs")

    def artifacts(self, run_id):
        return self._pages(f"repos/{self.repository}/actions/runs/{run_id}/artifacts?per_page=100", "artifacts")

    def evidence(self, artifact_id):
        raw = self._read([], f"repos/{self.repository}/actions/artifacts/{artifact_id}/zip")
        try:
            archive = zipfile.ZipFile(io.BytesIO(raw))
        except zipfile.BadZipFile:
            raise Unreadable("The artifact is not a zip file.") from None
        names = archive.namelist()
        if names != [EVIDENCE_FILE]:
            raise Unreadable(f"The artifact must hold exactly one file, {EVIDENCE_FILE}, but holds {len(names)}.")
        try:
            with archive.open(EVIDENCE_FILE) as handle:
                content = handle.read(EVIDENCE_LIMIT + 1)
        except (RuntimeError, NotImplementedError, zipfile.BadZipFile, zlib.error, EOFError):
            raise Unreadable(f"{EVIDENCE_FILE} is encrypted, corrupt or uses an unsupported compression.") from None
        if len(content) > EVIDENCE_LIMIT:
            raise Unreadable(f"{EVIDENCE_FILE} is larger than {EVIDENCE_LIMIT} bytes.")
        try:
            return json.loads(content)
        except (ValueError, RecursionError):
            # Deeply nested JSON exhausts the recursion limit of the parser; it is no valid evidence either.
            raise Unreadable(f"{EVIDENCE_FILE} is not valid JSON.") from None


def whole(value):
    return type(value) is int and value >= 0


def same_number(value, expected):
    return type(value) is int and value == expected


def evidence_problems(key, data, run, commit):
    """Everything that makes an evidence file unusable for this run, job and commit."""
    if not isinstance(data, dict):
        return ["the evidence is not a JSON object"]
    problems = []
    if not same_number(data.get("schema"), 1):
        problems.append(f"the evidence has schema {data.get('schema')!r}, expected 1")
    if data.get("job") != key:
        problems.append(f"the evidence is for job {data.get('job')!r}, expected {key}")
    if not same_number(data.get("run_id"), run["id"]):
        problems.append(f"the evidence is for run id {data.get('run_id')!r}, expected {run['id']}")
    if not same_number(data.get("run_attempt"), run["run_attempt"]):
        problems.append(f"the evidence is for attempt {data.get('run_attempt')!r}, the run is at attempt {run['run_attempt']}")
    if data.get("commit") != commit:
        problems.append(f"the evidence is for commit {data.get('commit')!r}, expected {commit}")
    for name in COUNTS:
        if not whole(data.get(name)):
            problems.append(f"the count {name} is not a whole number")
    if all(whole(data.get(name)) for name in COUNTS):
        executed, passed, failed, skipped, expected = (data[name] for name in COUNTS)
        if executed != passed + failed + skipped + expected:
            problems.append("the counts do not add up to the executed tests")
    if whole(data.get("failed")) and data["failed"]:
        problems.append(f"the evidence reports {data['failed']} failed tests")
    if whole(data.get("passed")) and data["passed"] == 0:
        problems.append("no test passed")
    if data.get("ok") is not True:
        problems.append("the evidence says ok is false")
    return problems


def job_problems(key, name, run, commit, jobs, artifacts, github):
    """The problems of one nightly job: its conclusion, its attempt, its artifact and its evidence.

    `jobs` and `artifacts` are the lists of the whole run, read once."""
    problems = []
    found = [entry for entry in jobs if entry.get("name") == name]
    if not found:
        problems.append("the latest attempt has no such job")
    elif len(found) > 1:
        problems.append(f"{len(found)} jobs have this name in the latest attempt")
    else:
        if found[0].get("conclusion") != "success":
            problems.append(f"the job conclusion is {found[0].get('conclusion')}")
        if not same_number(found[0].get("run_attempt"), run["run_attempt"]):
            problems.append(f"the job ran in attempt {found[0].get('run_attempt')}, the run is at attempt {run['run_attempt']}; re-run all jobs of the run")
    artifact_name = f"nightly-ui-evidence-{key}"
    matching = [entry for entry in artifacts if entry.get("name") == artifact_name]
    if not matching:
        problems.append(f"the run has no evidence artifact {artifact_name}")
    elif len(matching) > 1:
        problems.append(f"the run has {len(matching)} artifacts named {artifact_name}")
    else:
        artifact = matching[0]
        if artifact.get("expired") is not False:
            problems.append(f"the evidence artifact {artifact_name} expired")
        if (artifact.get("workflow_run") or {}).get("head_sha") != commit:
            problems.append(f"the evidence artifact {artifact_name} belongs to another commit")
        if artifact.get("expired") is False:
            try:
                problems += evidence_problems(key, github.evidence(artifact["id"]), run, commit)
            except Unreadable as error:
                problems.append(str(error))
    return [f"{name}: {problem}" for problem in problems]


def moment(run):
    """The start of the latest attempt of a run, else its creation."""
    for key in ("run_started_at", "created_at"):
        try:
            return datetime.datetime.fromisoformat(run[key].replace("Z", "+00:00"))
        except (KeyError, AttributeError, ValueError):
            continue
    raise Refusal(f"Run {run.get('id')} has no readable start time.")


def describe(run, now):
    text = f"run {run['id']} ({run.get('html_url')})"
    return text + (", which is older than 14 days" if now - moment(run) > OLD_RUN else "")


def decide(commit, github, now):
    """The summary lines of a green run, or a Refusal that names the run and every failed condition."""
    try:
        return decide_run(commit, github, now)
    except (KeyError, TypeError, AttributeError) as error:
        raise Refusal(f"GitHub answered with data that the gate cannot read ({error!r}).") from None


def decide_run(commit, github, now):
    runs = [entry for entry in github.runs(commit) if entry.get("head_sha") == commit]
    if not runs:
        raise Refusal(f"There is no nightly UI run for commit {commit}.")
    problems = []
    for entry in runs:
        if entry.get("event") in EVENTS and entry.get("status") != "completed":
            problems.append(f"run {entry['id']} ({entry.get('html_url')}) is still in progress, status {entry.get('status')}; "
                            "an older run does not count while another run is open")
    completed = [entry for entry in runs if entry.get("status") == "completed"]
    run = None
    if completed:
        run = max(completed, key=lambda entry: (moment(entry), entry["id"]))
        detail = []
        if run.get("event") not in EVENTS:
            detail.append(f"its event is {run.get('event')}, but only schedule and workflow_dispatch runs count")
        if run.get("conclusion") != "success":
            detail.append(f"the run conclusion is {run.get('conclusion')}")
        jobs, artifacts = github.jobs(run["id"]), github.artifacts(run["id"])
        for key, name in JOBS:
            detail += job_problems(key, name, run, commit, jobs, artifacts, github)
        if detail:
            problems.append(f"the newest completed run, {describe(run, now)}, does not qualify: " + "; ".join(detail))
    if problems:
        raise Refusal(f"The nightly UI gate refuses commit {commit}: " + "; ".join(problems) + ".")
    return [f"Nightly UI run {run['id']} ({run.get('html_url')}) for commit {commit} is green: event {run['event']}, "
            f"attempt {run['run_attempt']}, both UI jobs succeeded with passing evidence."]


def escape(value):
    return value.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")


def report(message):
    print(message, flush=True)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as summary:
            summary.write(message + "\n\n")


def refuse(cause, remedy):
    print(f"::error title=Apple release failed (nightly UI gate)::{escape(cause)} Remediation: {escape(remedy)}",
          file=sys.stderr)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as summary:
            summary.write(f"### Nightly UI gate: release refused\n\n{cause}\n\n{remedy}\n\n")
    return 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--overridden", choices=("true", "false"), default="false")
    parser.add_argument("--override-reason", default="")
    args = parser.parse_args()
    if not REPOSITORY.fullmatch(args.repository) or not SHA.fullmatch(args.commit):
        parser.error("The repository must be owner/name and the commit a full lowercase SHA-1 value.")
    if args.overridden == "true":
        report("**The nightly UI gate was skipped by the deliberate override of this release:** "
               + html.escape(args.override_reason))
        return 0
    try:
        lines = decide(args.commit, GitHubApi(args.repository), datetime.datetime.now(datetime.timezone.utc))
    except Refusal as error:
        return refuse(str(error), f"Start a nightly run for this commit with `gh workflow run {WORKFLOW} --ref {args.tag}`, "
                                  f"wait until both UI jobs are green, then re-run this release. The ref must contain .github/workflows/{WORKFLOW}.")
    except GitHubError as error:
        return refuse(f"The release gate could not read the nightly UI run from GitHub: {error}",
                      "Re-run the release workflow later.")
    for line in lines:
        report(line)
    return 0


if __name__ == "__main__":
    sys.exit(main())
