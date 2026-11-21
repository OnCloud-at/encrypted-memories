"""Tests for release_nightly_gate.py, the release gate on the nightly UI run (#1166, reads the evidence of #1134)."""
import base64
import datetime
import io
import json
import os
import pathlib
import stat
import subprocess
import sys
import tempfile
import time
import tracemalloc
import unittest
import unittest.mock
import zipfile

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import release_nightly_gate as gate  # noqa: E402

SCRIPT = pathlib.Path(__file__).resolve().parent / "release_nightly_gate.py"
RECORDED = pathlib.Path(__file__).resolve().parent / "fixtures" / "nightly_run_44888356731.json"
COMMIT = "0123456789abcdef0123456789abcdef01234567"
OLDER = "fedcba9876543210fedcba9876543210fedcba98"
NOW = datetime.datetime(2026, 11, 22, 12, 0, tzinfo=datetime.timezone.utc)
JOB_NAMES = {"default-simulator": "Nightly iOS UI tests (default simulator)",
             "iphone-duo": "Nightly iOS UI tests (iPhone Duo)"}
KEYS = tuple(JOB_NAMES)


def run(run_id=100, status="completed", conclusion="success", event="schedule", sha=COMMIT, attempt=1,
        created="2026-11-22T02:31:00Z", started=None):
    return {"id": run_id, "status": status, "conclusion": conclusion, "event": event, "head_sha": sha,
            "run_attempt": attempt, "created_at": created, "run_started_at": started or created,
            "html_url": f"https://github.com/example/repository/actions/runs/{run_id}"}


def job(key, conclusion="success", attempt=1, name=None):
    return {"id": 5000 + KEYS.index(key), "name": name or JOB_NAMES[key], "status": "completed",
            "conclusion": conclusion, "run_attempt": attempt}


def artifact(key, expired=False, sha=COMMIT, run_id=100, name=None):
    return {"id": 9000 + KEYS.index(key), "name": name or f"nightly-ui-evidence-{key}", "expired": expired,
            "workflow_run": {"id": run_id, "head_sha": sha}}


def evidence(key, run_id=100, attempt=1, commit=COMMIT, passed=118, failed=0, skipped=7, expected=0, ok=True,
             schema=1, executed=None):
    return {"schema": schema, "job": key, "run_id": run_id, "run_attempt": attempt, "commit": commit,
            "simulator": {"name": "iPhone 17", "os": "27.2"},
            "executed": passed + failed + skipped + expected if executed is None else executed,
            "passed": passed, "failed": failed, "skipped": skipped, "expected_failures": expected, "ok": ok}


class FakeGitHub:
    """The four reads of the gate, served from memory. It returns every run that it holds; the real API filters."""

    def __init__(self):
        self.run_list = [run()]
        self.job_lists = {100: [job(key) for key in KEYS]}
        self.artifact_lists = {100: [artifact(key) for key in KEYS]}
        self.evidence_by_id = {9000 + index: evidence(key) for index, key in enumerate(KEYS)}
        self.reads = {"jobs": 0, "artifacts": 0}

    def runs(self, commit):
        return self.run_list

    def jobs(self, run_id):
        self.reads["jobs"] += 1
        return self.job_lists.get(run_id, [])

    def artifacts(self, run_id):
        self.reads["artifacts"] += 1
        return self.artifact_lists.get(run_id, [])

    def evidence(self, artifact_id):
        value = self.evidence_by_id[artifact_id]
        if isinstance(value, Exception):
            raise value
        return value


class DecisionTests(unittest.TestCase):
    def refusal(self, world, now=NOW):
        with self.assertRaises(gate.Refusal) as caught:
            gate.decide(COMMIT, world, now)
        return str(caught.exception)

    def test_a_green_scheduled_run_for_the_commit_passes(self):
        lines = gate.decide(COMMIT, FakeGitHub(), NOW)
        self.assertIn("100", " ".join(lines))
        self.assertIn(COMMIT, " ".join(lines))

    def test_a_manual_run_for_the_commit_passes(self):
        world = FakeGitHub()
        world.run_list = [run(event="workflow_dispatch")]
        self.assertIn("workflow_dispatch", " ".join(gate.decide(COMMIT, world, NOW)))

    def test_without_a_run_the_release_is_refused(self):
        world = FakeGitHub()
        world.run_list = []
        message = self.refusal(world)
        self.assertIn(COMMIT, message)
        self.assertIn("no nightly UI run", message)

    def test_a_run_for_an_older_commit_does_not_count(self):
        world = FakeGitHub()
        world.run_list = [run(sha=OLDER)]
        self.assertIn("no nightly UI run", self.refusal(world))

    def test_a_newer_run_of_another_commit_does_not_hide_the_green_run(self):
        world = FakeGitHub()
        world.run_list = [run(run_id=101, sha=OLDER, conclusion="failure"), run()]
        gate.decide(COMMIT, world, NOW)

    def test_the_newest_run_decides_and_a_later_red_run_beats_an_older_green_one(self):
        world = FakeGitHub()
        world.run_list = [run(run_id=100), run(run_id=101, conclusion="failure")]
        world.job_lists[101] = [job("default-simulator"), job("iphone-duo", conclusion="failure")]
        world.artifact_lists[101] = [artifact(key, run_id=101) for key in KEYS]
        world.evidence_by_id = {9000: evidence("default-simulator", run_id=101),
                                9001: evidence("iphone-duo", run_id=101, failed=4, ok=False)}
        message = self.refusal(world)
        self.assertIn("101", message)
        self.assertIn("iPhone Duo", message)
        self.assertNotIn("run 100", message)

    def test_the_newest_run_decides_whatever_the_order_of_the_list(self):
        world = FakeGitHub()
        world.run_list = [run(run_id=101, conclusion="failure"), run(run_id=100)]
        world.job_lists[101] = [job("default-simulator", conclusion="failure"), job("iphone-duo")]
        world.artifact_lists[101] = [artifact(key, run_id=101) for key in KEYS]
        world.evidence_by_id = {9000: evidence("default-simulator", run_id=101, failed=1, ok=False),
                                9001: evidence("iphone-duo", run_id=101)}
        self.assertIn("101", self.refusal(world))

    def test_a_newest_run_in_progress_is_refused_and_named_although_an_older_run_is_green(self):
        for status in ("in_progress", "queued", "waiting", "requested", "pending"):
            with self.subTest(status=status):
                world = FakeGitHub()
                world.run_list = [run(run_id=100), run(run_id=101, status=status, conclusion=None)]
                message = self.refusal(world)
                self.assertIn("in progress", message)
                self.assertIn("101", message)
                self.assertIn("https://github.com/example/repository/actions/runs/101", message)

    def test_only_scheduled_and_manual_runs_count(self):
        for event in ("push", "pull_request", "release", "repository_dispatch", "workflow_run", "merge_group"):
            with self.subTest(event=event):
                world = FakeGitHub()
                world.run_list = [run(event=event)]
                message = self.refusal(world)
                self.assertIn(event, message)
                self.assertIn("schedule", message)

    def test_a_run_that_did_not_succeed_is_refused_although_both_jobs_look_green(self):
        for conclusion in ("failure", "cancelled", "timed_out", "neutral", None):
            with self.subTest(conclusion=conclusion):
                world = FakeGitHub()
                world.run_list = [run(conclusion=conclusion)]
                self.assertIn("100", self.refusal(world))

    def test_a_job_with_a_clean_evidence_file_but_a_failed_conclusion_is_refused(self):
        world = FakeGitHub()
        world.job_lists[100] = [job("default-simulator"), job("iphone-duo", conclusion="failure")]
        message = self.refusal(world)
        self.assertIn("iPhone Duo", message)
        self.assertIn("failure", message)
        self.assertNotIn("(default simulator)", message)

    def test_a_job_that_did_not_succeed_in_any_way_is_refused(self):
        for conclusion in ("failure", "cancelled", "skipped", "timed_out", None):
            with self.subTest(conclusion=conclusion):
                world = FakeGitHub()
                world.job_lists[100] = [job("default-simulator", conclusion=conclusion), job("iphone-duo")]
                self.assertIn("default simulator", self.refusal(world))

    def test_a_missing_or_duplicate_job_is_refused(self):
        world = FakeGitHub()
        world.job_lists[100] = [job("default-simulator")]
        self.assertIn("iPhone Duo", self.refusal(world))
        world.job_lists[100] = [job("default-simulator"), job("iphone-duo"), job("iphone-duo")]
        message = self.refusal(world)
        self.assertIn("iPhone Duo", message)
        self.assertIn("2 jobs", message)

    def test_a_job_of_another_attempt_than_the_run_is_refused(self):
        world = FakeGitHub()
        world.run_list = [run(attempt=2)]
        world.job_lists[100] = [job("default-simulator", attempt=2), job("iphone-duo", attempt=1)]
        world.evidence_by_id[9000] = evidence("default-simulator", attempt=2)
        message = self.refusal(world)
        self.assertIn("iPhone Duo", message)
        self.assertIn("attempt", message)

    def test_a_job_of_an_older_attempt_is_refused_although_its_evidence_matches_the_run(self):
        world = FakeGitHub()
        world.run_list = [run(attempt=2)]
        world.job_lists[100] = [job("default-simulator", attempt=2), job("iphone-duo", attempt=1)]
        world.evidence_by_id = {9000 + index: evidence(key, attempt=2) for index, key in enumerate(KEYS)}
        message = self.refusal(world)
        self.assertIn("iPhone Duo", message)
        self.assertIn("ran in attempt 1", message)
        self.assertIn("re-run all jobs", message)

    def test_a_missing_artifact_is_refused(self):
        world = FakeGitHub()
        world.artifact_lists[100] = [artifact("default-simulator")]
        message = self.refusal(world)
        self.assertIn("nightly-ui-evidence-iphone-duo", message)
        self.assertIn("no evidence artifact", message)

    def test_a_duplicate_artifact_is_refused(self):
        world = FakeGitHub()
        second = artifact("iphone-duo")
        second["id"] = 9100
        world.artifact_lists[100].append(second)
        world.evidence_by_id[9100] = evidence("iphone-duo")
        self.assertIn("2 artifacts", self.refusal(world))

    def test_an_expired_artifact_is_refused(self):
        world = FakeGitHub()
        world.artifact_lists[100] = [artifact("default-simulator"), artifact("iphone-duo", expired=True)]
        del world.evidence_by_id[9001]  # an expired artifact has no download: the gate must not ask for it
        message = self.refusal(world)
        self.assertIn("expired", message)
        self.assertNotIn("cannot read", message)

    def test_an_artifact_of_another_commit_is_refused(self):
        world = FakeGitHub()
        world.artifact_lists[100] = [artifact("default-simulator", sha=OLDER), artifact("iphone-duo")]
        self.assertIn("another commit", self.refusal(world))

    def test_evidence_that_does_not_belong_to_this_run_job_and_commit_is_refused(self):
        cases = {
            "schema": evidence("default-simulator", schema=2),
            "job": evidence("iphone-duo"),
            "run id": evidence("default-simulator", run_id=99),
            "commit": evidence("default-simulator", commit=OLDER),
        }
        for name, bad in cases.items():
            with self.subTest(name=name):
                world = FakeGitHub()
                world.evidence_by_id[9000] = bad
                message = self.refusal(world)
                self.assertIn("default simulator", message)
                self.assertIn(name, message)

    def test_evidence_of_an_old_attempt_is_refused_after_a_rerun(self):
        world = FakeGitHub()
        world.run_list = [run(attempt=2)]
        world.job_lists[100] = [job(key, attempt=2) for key in KEYS]
        world.evidence_by_id[9001] = evidence("iphone-duo", attempt=1)
        message = self.refusal(world)
        self.assertIn("iPhone Duo", message)
        self.assertIn("attempt 1", message)

    def test_evidence_of_the_current_attempt_passes_after_a_rerun(self):
        world = FakeGitHub()
        world.run_list = [run(attempt=2)]
        world.job_lists[100] = [job(key, attempt=2) for key in KEYS]
        world.evidence_by_id = {9000 + index: evidence(key, attempt=2) for index, key in enumerate(KEYS)}
        gate.decide(COMMIT, world, NOW)

    def test_the_gate_re_derives_the_verdict_and_never_trusts_ok_alone(self):
        cases = {
            "failed tests": evidence("iphone-duo", failed=4, ok=True),
            "no passed test": evidence("iphone-duo", passed=0, skipped=125, ok=True),
            "ok false": evidence("iphone-duo", ok=False),
            "counts": evidence("iphone-duo", executed=999, ok=True),
        }
        for bad_value in ("118", None, True, -1, 1.5):
            broken = evidence("iphone-duo")
            broken["passed"] = bad_value
            cases[f"passed={bad_value!r}"] = broken
        for name, bad in cases.items():
            with self.subTest(name=name):
                world = FakeGitHub()
                world.evidence_by_id[9001] = bad
                message = self.refusal(world)
                self.assertIn("iPhone Duo", message)

    def test_skipped_tests_alone_never_make_a_green_run(self):
        world = FakeGitHub()
        world.evidence_by_id[9000] = evidence("default-simulator", passed=0, skipped=125, ok=True)
        self.assertIn("passed", self.refusal(world))

    def test_unreadable_evidence_is_refused(self):
        world = FakeGitHub()
        world.evidence_by_id[9001] = gate.Unreadable("The artifact holds no ui-evidence.json.")
        message = self.refusal(world)
        self.assertIn("iPhone Duo", message)
        self.assertIn("ui-evidence.json", message)

    def test_every_failing_condition_of_both_jobs_is_listed(self):
        world = FakeGitHub()
        world.job_lists[100] = [job("default-simulator", conclusion="failure"), job("iphone-duo", conclusion="failure")]
        message = self.refusal(world)
        self.assertIn("default simulator", message)
        self.assertIn("iPhone Duo", message)

    def test_any_open_run_refuses_even_a_re_run_of_an_older_run_next_to_a_newer_green_run(self):
        world = FakeGitHub()
        world.run_list = [run(run_id=100, attempt=2, status="in_progress", conclusion=None, started="2026-11-22T05:00:00Z"),
                          run(run_id=101, started="2026-11-22T03:00:00Z")]
        world.job_lists[101] = [job(key) for key in KEYS]
        world.artifact_lists[101] = [artifact(key, run_id=101) for key in KEYS]
        world.evidence_by_id = {9000 + index: evidence(key, run_id=101) for index, key in enumerate(KEYS)}
        message = self.refusal(world)
        self.assertIn("run 100", message)
        self.assertIn("in progress", message)

    def test_every_open_run_is_named(self):
        world = FakeGitHub()
        world.run_list = [run(run_id=100), run(run_id=101, status="queued", conclusion=None),
                          run(run_id=102, status="in_progress", conclusion=None, event="workflow_dispatch")]
        message = self.refusal(world)
        self.assertIn("run 101", message)
        self.assertIn("run 102", message)

    def test_an_open_run_of_another_event_is_not_a_nightly_run_and_blocks_nothing(self):
        world = FakeGitHub()
        world.run_list = [run(run_id=100), run(run_id=101, status="in_progress", conclusion=None, event="push")]
        gate.decide(COMMIT, world, NOW)

    def test_a_re_run_of_an_older_run_is_the_newest_run_by_its_start_not_by_its_id(self):
        world = FakeGitHub()
        world.run_list = [run(run_id=100, attempt=2, conclusion="failure", started="2026-11-22T06:00:00Z"),
                          run(run_id=101, started="2026-11-22T03:00:00Z")]
        world.job_lists[101] = [job(key) for key in KEYS]
        world.artifact_lists[101] = [artifact(key, run_id=101) for key in KEYS]
        world.evidence_by_id = {9000 + index: evidence(key, run_id=101) for index, key in enumerate(KEYS)}
        message = self.refusal(world)
        self.assertIn("run 100", message)
        self.assertNotIn("run 101", message)

    def test_runs_that_started_together_are_ranked_by_id(self):
        world = FakeGitHub()
        world.run_list = [run(run_id=100), run(run_id=101, conclusion="failure")]
        world.job_lists[101] = [job(key, conclusion="failure") for key in KEYS]
        self.assertIn("run 101", self.refusal(world))

    def test_a_run_without_a_start_falls_back_to_its_creation_and_without_both_it_is_refused(self):
        world = FakeGitHub()
        without_start = run()
        del without_start["run_started_at"]
        world.run_list = [without_start]
        gate.decide(COMMIT, world, NOW)
        del without_start["created_at"]
        self.assertIn("no readable start time", self.refusal(world))
        without_start["created_at"] = "yesterday"
        self.assertIn("no readable start time", self.refusal(world))

    def test_the_conditions_of_the_run_and_of_both_jobs_are_listed_together(self):
        world = FakeGitHub()
        world.run_list = [run(event="push", conclusion="failure")]
        world.job_lists[100] = [job("default-simulator", conclusion="failure"), job("iphone-duo", attempt=2)]
        message = self.refusal(world)
        for text in ("event is push", "run conclusion is failure", "(default simulator): the job conclusion is failure",
                     "(iPhone Duo): the job ran in attempt 2"):
            self.assertIn(text, message)

    def test_an_expired_artifact_of_another_commit_gets_both_problems_and_every_other_artifact_is_still_checked(self):
        world = FakeGitHub()
        world.artifact_lists[100] = [artifact("default-simulator", expired=True, sha=OLDER), artifact("iphone-duo")]
        world.evidence_by_id[9001] = evidence("iphone-duo", failed=2, ok=False)
        message = self.refusal(world)
        self.assertIn("expired", message)
        self.assertIn("another commit", message)
        self.assertIn("2 failed", message)

    def test_a_foreign_artifact_still_has_its_evidence_checked(self):
        world = FakeGitHub()
        world.artifact_lists[100] = [artifact("default-simulator", sha=OLDER), artifact("iphone-duo")]
        world.evidence_by_id[9000] = evidence("default-simulator", commit=OLDER)
        message = self.refusal(world)
        self.assertIn("another commit", message)
        self.assertIn("for commit", message)

    def test_bad_counts_do_not_hide_the_failed_tests_the_missing_pass_or_ok(self):
        world = FakeGitHub()
        bad = evidence("iphone-duo", failed=3, ok=False)
        bad["executed"] = "many"
        world.evidence_by_id[9001] = bad
        message = self.refusal(world)
        self.assertIn("count executed is not a whole number", message)
        self.assertIn("3 failed", message)
        self.assertIn("ok is false", message)
        worse = evidence("iphone-duo", ok=False)
        worse["passed"] = "x"
        world.evidence_by_id[9001] = worse
        self.assertIn("count passed is not a whole number", self.refusal(world))
        self.assertIn("ok is false", self.refusal(world))

    def test_numbers_must_be_real_integers(self):
        cases = {
            "schema true": evidence("iphone-duo", schema=True),
            "schema float": evidence("iphone-duo", schema=1.0),
            "run id float": evidence("iphone-duo", run_id=100.0),
            "attempt float": evidence("iphone-duo", attempt=1.0),
            "passed true with a matching executed": evidence("iphone-duo", passed=True, skipped=0),
            "ok one": evidence("iphone-duo", ok=1),
            "ok text": evidence("iphone-duo", ok="true"),
        }
        for name, bad in cases.items():
            with self.subTest(name=name):
                world = FakeGitHub()
                world.evidence_by_id[9001] = bad
                self.assertIn("iPhone Duo", self.refusal(world))

    def test_the_run_and_job_attempts_must_be_real_integers(self):
        world = FakeGitHub()
        world.job_lists[100] = [job("default-simulator", attempt=1.0), job("iphone-duo")]
        self.assertIn("(default simulator): the job ran in attempt 1.0", self.refusal(world))
        world = FakeGitHub()
        world.job_lists[100] = [job("default-simulator", attempt=True), job("iphone-duo")]
        self.assertIn("the job ran in attempt True", self.refusal(world))

    def test_an_artifact_without_the_expired_flag_is_refused(self):
        world = FakeGitHub()
        del world.artifact_lists[100][1]["expired"]
        self.assertIn("expired", self.refusal(world))

    def test_jobs_and_artifacts_of_the_run_are_read_once(self):
        world = FakeGitHub()
        gate.decide(COMMIT, world, NOW)
        self.assertEqual({"jobs": 1, "artifacts": 1}, world.reads)
        world = FakeGitHub()
        world.job_lists[100] = [job("default-simulator", conclusion="failure"), job("iphone-duo", conclusion="failure")]
        self.refusal(world)
        self.assertEqual({"jobs": 1, "artifacts": 1}, world.reads)

    def test_data_that_lacks_a_field_ends_in_a_refusal_and_never_in_a_traceback(self):
        def without(entry, key):
            return {name: value for name, value in entry.items() if name != key}
        cases = {
            "run without id": lambda world: setattr(world, "run_list", [without(run(), "id")]),
            "run without attempt": lambda world: setattr(world, "run_list", [without(run(), "run_attempt")]),
            "artifact without id": lambda world: world.artifact_lists.update({100: [artifact("default-simulator"), without(artifact("iphone-duo"), "id")]}),
            "run is no object": lambda world: setattr(world, "run_list", [None]),
            "job is no object": lambda world: world.job_lists.update({100: [None]}),
        }
        for name, change in cases.items():
            with self.subTest(name=name):
                world = FakeGitHub()
                change(world)
                self.assertIn("cannot read", self.refusal(world))

    def test_the_recorded_run_with_a_red_duo_job_is_refused(self):
        recorded = json.loads(RECORDED.read_text())
        world = FakeGitHub()
        world.run_list = recorded["runs"]
        run_id = recorded["runs"][0]["id"]
        world.job_lists = {run_id: recorded["jobs"]}
        world.artifact_lists = {run_id: recorded["artifacts"]}
        world.evidence_by_id = {int(key): value for key, value in recorded["evidence"].items()}
        commit = recorded["runs"][0]["head_sha"]
        with self.assertRaises(gate.Refusal) as caught:
            gate.decide(commit, world, NOW)
        message = str(caught.exception)
        self.assertIn("44888356731", message)
        self.assertIn("iPhone Duo", message)
        self.assertIn("failure", message)
        self.assertIn("4 failed", message)
        self.assertNotIn("(default simulator)", message)

    def test_a_refusal_names_an_old_run_but_an_old_green_run_still_passes(self):
        old = "2026-10-01T02:31:00Z"
        world = FakeGitHub()
        world.run_list = [run(created=old)]
        gate.decide(COMMIT, world, NOW)
        world.job_lists[100] = [job("default-simulator", conclusion="failure"), job("iphone-duo")]
        self.assertIn("older than 14 days", self.refusal(world))
        world.run_list = [run(created="2026-11-20T02:31:00Z")]
        self.assertNotIn("older than 14 days", self.refusal(world))


def fake_gh(directory):
    """A `gh` that serves the four API reads of the gate from a world file and logs every call."""
    path = pathlib.Path(directory) / "gh"
    path.write_text('''#!/usr/bin/env python3
import base64, io, json, os, sys, urllib.parse, zipfile
args = sys.argv[1:]
with open(os.environ["FAKE_GH_LOG"], "a") as log:
    log.write(json.dumps(args) + "\\n")
if os.environ.get("FAKE_GH_HANG"):
    import time
    time.sleep(float(os.environ["FAKE_GH_HANG"]))
if os.environ.get("FAKE_GH_FAIL"):
    sys.stderr.write("HTTP 502\\n")
    sys.exit(1)
world = json.load(open(os.environ["FAKE_GH_WORLD"]))
assert args[0] == "api"
target = [a for a in args[1:] if not a.startswith("--")][0]
parsed = urllib.parse.urlparse(target)
query = urllib.parse.parse_qs(parsed.query)
segments = parsed.path.strip("/").split("/")
def pages(page):
    # gh prints one list of pages only with --paginate and --slurp together
    print(json.dumps([page] if "--paginate" in args and "--slurp" in args else page))
if segments[-1] == "runs" and segments[-2] == "nightly-ui-tests.yml":
    runs = [r for r in world["runs"] if r["head_sha"] == query["head_sha"][0]]
    pages({"total_count": len(runs), "workflow_runs": runs})
elif segments[-1] == "jobs":
    assert query["filter"] == ["latest"]
    jobs = world["jobs"][segments[-2]]
    pages({"total_count": len(jobs), "jobs": jobs})
elif segments[-1] == "artifacts" and segments[-3] == "runs":
    artifacts = world["artifacts"][segments[-2]]
    pages({"total_count": len(artifacts), "artifacts": artifacts})
elif segments[-1] == "zip" and segments[-3] == "artifacts":
    entry = world["evidence"][segments[-2]]
    if isinstance(entry, dict) and "raw_zip_base64" in entry:
        sys.stdout.buffer.write(base64.b64decode(entry["raw_zip_base64"]))
    else:
        buffer = io.BytesIO()
        with zipfile.ZipFile(buffer, "w") as archive:
            archive.writestr("ui-evidence.json", json.dumps(entry))
        sys.stdout.buffer.write(buffer.getvalue())
else:
    sys.stderr.write("unexpected call " + target + "\\n")
    sys.exit(2)
''')
    path.chmod(path.stat().st_mode | stat.S_IXUSR)
    return path


def archive(members):
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w") as handle:
        for name, content in members:
            handle.writestr(name, content)
    return base64.b64encode(buffer.getvalue()).decode()


class CliTests(unittest.TestCase):
    def setUp(self):
        self.directory = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(__import__("shutil").rmtree, self.directory, True)
        fake_gh(self.directory)
        recorded = json.loads(RECORDED.read_text())
        self.recorded_commit = recorded["runs"][0]["head_sha"]
        run_key = str(recorded["runs"][0]["id"])
        self.world = {"runs": recorded["runs"], "jobs": {run_key: recorded["jobs"]},
                      "artifacts": {run_key: recorded["artifacts"]}, "evidence": recorded["evidence"]}

    def execute(self, *arguments, commit=None, repository="example/repository", environment=None):
        world_file = self.directory / "world.json"
        world_file.write_text(json.dumps(self.world))
        summary = self.directory / "summary.md"
        summary.write_text("")
        log = self.directory / "calls.log"
        log.write_text("")
        env = {**os.environ, "PATH": f"{self.directory}{os.pathsep}{os.environ['PATH']}",
               "FAKE_GH_WORLD": str(world_file), "FAKE_GH_LOG": str(log), "GITHUB_STEP_SUMMARY": str(summary),
               **(environment or {})}
        completed = subprocess.run(
            [sys.executable, "-I", str(SCRIPT), f"--repository={repository}",
             f"--commit={commit or self.recorded_commit}", "--tag=v9.9.9", *arguments],
            capture_output=True, text=True, env=env, timeout=60)
        return completed, summary.read_text(), log.read_text()

    def make_green(self):
        for job_entry in next(iter(self.world["jobs"].values())):
            job_entry["conclusion"] = "success"
        for key, entry in self.world["evidence"].items():
            entry.update(failed=0, skipped=7, ok=True)
            entry["executed"] = entry["passed"] + entry["failed"] + entry["skipped"] + entry["expected_failures"]
        for run_entry in self.world["runs"]:
            run_entry["conclusion"] = "success"

    def test_the_recorded_red_run_is_refused_with_the_run_the_job_and_the_start_command(self):
        completed, summary, log = self.execute()
        self.assertEqual(1, completed.returncode, completed.stderr)
        for text in (completed.stderr, summary):
            self.assertIn("44888356731", text)
            self.assertIn("iPhone Duo", text)
            self.assertIn("gh workflow run nightly-ui-tests.yml --ref v9.9.9", text)
        self.assertIn(f"head_sha={self.recorded_commit}", log)

    def test_a_green_run_passes_and_is_recorded_in_the_summary(self):
        self.make_green()
        completed, summary, _ = self.execute()
        self.assertEqual(0, completed.returncode, completed.stderr)
        self.assertIn("44888356731", summary)
        self.assertIn("is green", summary)

    def test_a_commit_without_a_run_is_refused(self):
        completed, summary, _ = self.execute(commit=OLDER)
        self.assertEqual(1, completed.returncode)
        self.assertIn("no nightly UI run", summary)

    def test_a_malformed_commit_or_repository_is_rejected_before_any_read(self):
        for kwargs in ({"commit": "main"}, {"commit": self.recorded_commit.upper()}, {"repository": "a/b/c"},
                       {"repository": "../x"}, {"repository": "x/.."}):
            with self.subTest(**kwargs):
                completed, _, log = self.execute(**kwargs)
                self.assertEqual(2, completed.returncode)
                self.assertEqual("", log)

    def test_the_override_skips_the_read_records_the_reason_and_never_calls_github(self):
        completed, summary, log = self.execute("--overridden=true", "--override-reason=Hosted runners are down")
        self.assertEqual(0, completed.returncode, completed.stderr)
        self.assertIn("deliberate override", summary)
        self.assertIn("Hosted runners are down", summary)
        self.assertEqual("", log)

    def test_no_override_reads_the_run_even_when_a_reason_is_present(self):
        completed, _, log = self.execute("--overridden=false", "--override-reason=left over")
        self.assertEqual(1, completed.returncode)
        self.assertNotEqual("", log)

    def test_a_reason_that_starts_with_a_dash_is_recorded(self):
        completed, summary, log = self.execute("--overridden=true", "--override-reason=-urgent")
        self.assertEqual(0, completed.returncode, completed.stderr)
        self.assertIn("-urgent", summary)
        self.assertEqual("", log)

    def test_a_failing_github_read_refuses_the_release_with_the_error_text_and_four_calls(self):
        # In this process the retry delay is zero; the real delay would only make the test slow.
        real = gate.GitHubApi
        world_file = self.directory / "world.json"
        world_file.write_text(json.dumps(self.world))
        summary = self.directory / "summary.md"
        summary.write_text("")
        log = self.directory / "calls.log"
        log.write_text("")
        environment = {"PATH": f"{self.directory}{os.pathsep}{os.environ['PATH']}", "FAKE_GH_WORLD": str(world_file),
                       "FAKE_GH_LOG": str(log), "GITHUB_STEP_SUMMARY": str(summary), "FAKE_GH_FAIL": "1"}
        arguments = ["release_nightly_gate.py", "--repository=example/repository", f"--commit={self.recorded_commit}", "--tag=v9.9.9"]
        errors = io.StringIO()
        with unittest.mock.patch.dict(os.environ, environment), unittest.mock.patch.object(sys, "argv", arguments), \
                unittest.mock.patch.object(gate, "GitHubApi", lambda repository: real(repository, delay=0)), \
                unittest.mock.patch.object(sys, "stderr", errors), unittest.mock.patch.object(sys, "stdout", io.StringIO()):
            status = gate.main()
        self.assertEqual(1, status)
        self.assertIn("::error", errors.getvalue())
        self.assertIn("could not read", summary.read_text())
        self.assertIn("HTTP 502", summary.read_text())
        self.assertEqual(4, len(log.read_text().splitlines()))

    def test_an_artifact_that_is_not_one_evidence_file_is_refused(self):
        self.make_green()
        duo = next(key for key, value in self.world["evidence"].items() if value["job"] == "iphone-duo")
        good = json.dumps(self.world["evidence"][duo])
        cases = {
            "two files": archive([("ui-evidence.json", good), ("extra.json", "{}")]),
            "other name": archive([("other.json", good)]),
            "not json": archive([("ui-evidence.json", "not json")]),
            "not an object": archive([("ui-evidence.json", "[1]")]),
            "too large": archive([("ui-evidence.json", good + " " * 70000)]),
            "not a zip": base64.b64encode(b"plain").decode(),
        }
        for name, raw in cases.items():
            with self.subTest(name=name):
                self.world["evidence"][duo] = {"raw_zip_base64": raw}
                completed, summary, _ = self.execute()
                self.assertEqual(1, completed.returncode, summary)
                self.assertIn("iPhone Duo", summary)


class ApiTests(unittest.TestCase):
    def setUp(self):
        self.directory = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(__import__("shutil").rmtree, self.directory, True)
        fake_gh(self.directory)
        self.log = self.directory / "calls.log"
        self.log.write_text("")
        patcher = unittest.mock.patch.dict(os.environ, {
            "PATH": f"{self.directory}{os.pathsep}{os.environ['PATH']}", "FAKE_GH_LOG": str(self.log),
            "FAKE_GH_WORLD": str(self.directory / "world.json")})
        patcher.start()
        self.addCleanup(patcher.stop)

    def serve(self, raw):
        (self.directory / "world.json").write_text(json.dumps({"evidence": {"7": {"raw_zip_base64": base64.b64encode(raw).decode()}}}))

    def test_a_gh_failure_is_tried_four_times_like_the_release_workflow_and_then_reported(self):
        os.environ["FAKE_GH_FAIL"] = "1"
        api = gate.GitHubApi("example/repository", delay=0)
        with self.assertRaises(gate.GitHubError) as caught:
            api.runs(COMMIT)
        self.assertIn("HTTP 502", str(caught.exception))
        self.assertIn("failed 4 times", str(caught.exception))
        self.assertEqual(4, len(self.log.read_text().splitlines()))

    def test_a_call_that_hangs_is_cut_and_the_whole_read_ends_inside_its_time_budget(self):
        os.environ["FAKE_GH_HANG"] = "12"
        api = gate.GitHubApi("example/repository", delay=0, budget=2, call_seconds=1)
        started = time.monotonic()
        with self.assertRaises(gate.GitHubError) as caught:
            api.runs(COMMIT)
        self.assertLess(time.monotonic() - started, 8)
        self.assertIn("time budget of 2 seconds", str(caught.exception))
        self.assertLess(len(self.log.read_text().splitlines()), 4)

    def test_the_pause_between_tries_never_outlasts_the_budget(self):
        os.environ["FAKE_GH_FAIL"] = "1"
        api = gate.GitHubApi("example/repository", delay=20, budget=1)
        started = time.monotonic()
        with self.assertRaises(gate.GitHubError) as caught:
            api.runs(COMMIT)
        self.assertLess(time.monotonic() - started, 6)
        self.assertIn("time budget of 1 seconds", str(caught.exception))
        self.assertIn("HTTP 502", str(caught.exception))

    def test_the_budget_is_shared_by_all_calls(self):
        os.environ["FAKE_GH_FAIL"] = "1"
        api = gate.GitHubApi("example/repository", delay=0, budget=0)
        with self.assertRaises(gate.GitHubError) as caught:
            api.runs(COMMIT)
        self.assertIn("time budget", str(caught.exception))
        self.assertEqual("", self.log.read_text())

    def test_the_budget_ends_before_the_step_of_the_workflow(self):
        # Each call is cut at the time that is left, so the read never outlasts its budget; 30 seconds remain for the
        # start of the script and for the refusal text.
        self.assertLessEqual(gate.BUDGET_SECONDS + 30, gate.STEP_MINUTES * 60)
        self.assertGreaterEqual(gate.BUDGET_SECONDS, gate.CALL_SECONDS)

    def good(self):
        return json.dumps(evidence("iphone-duo")).encode()

    def zip_of(self, content, method=zipfile.ZIP_STORED):
        buffer = io.BytesIO()
        with zipfile.ZipFile(buffer, "w", method) as handle:
            handle.writestr("ui-evidence.json", content)
        return buffer.getvalue()

    def test_a_valid_archive_gives_the_evidence(self):
        self.serve(self.zip_of(self.good()))
        self.assertEqual("iphone-duo", gate.GitHubApi("example/repository", delay=0).evidence(7)["job"])

    def test_an_encrypted_corrupt_or_unsupported_entry_is_unreadable_and_never_a_traceback(self):
        plain = self.zip_of(self.good() * 20, zipfile.ZIP_DEFLATED)
        encrypted = bytearray(plain)
        encrypted[plain.index(b"PK\x03\x04") + 6] |= 1
        encrypted[plain.index(b"PK\x01\x02") + 8] |= 1
        corrupt = bytearray(plain)
        corrupt[plain.index(b"PK\x03\x04") + 30 + len("ui-evidence.json") + 2] ^= 0xFF
        unsupported = bytearray(plain)
        unsupported[plain.index(b"PK\x03\x04") + 8] = 99
        unsupported[plain.index(b"PK\x01\x02") + 10] = 99
        for name, raw in (("encrypted", encrypted), ("corrupt", corrupt), ("unsupported", unsupported)):
            with self.subTest(name=name):
                self.serve(bytes(raw))
                with self.assertRaises(gate.Unreadable):
                    gate.GitHubApi("example/repository", delay=0).evidence(7)

    def test_deeply_nested_json_is_unreadable_and_never_a_traceback(self):
        nested = b"[" * 5000 + b"]" * 5000
        self.assertLess(len(nested), gate.EVIDENCE_LIMIT)
        self.serve(self.zip_of(nested))
        api = gate.GitHubApi("example/repository", delay=0)
        # Python 3.12 of the hosted runner raises RecursionError for this file; newer parsers read it. Either way the
        # file is no evidence and the gate never ends in a traceback.
        try:
            api.evidence(7)
        except gate.Unreadable:
            pass
        # The same file with a parser that exhausts the recursion limit, on any Python.
        with unittest.mock.patch.object(gate.json, "loads", side_effect=RecursionError):
            with self.assertRaises(gate.Unreadable) as caught:
                api.evidence(7)
        self.assertIn("not valid JSON", str(caught.exception))

    def test_the_runs_are_asked_for_by_the_release_commit(self):
        (self.directory / "world.json").write_text(json.dumps({"runs": [{"head_sha": COMMIT, "id": 1}]}))
        self.assertEqual([{"head_sha": COMMIT, "id": 1}], gate.GitHubApi("example/repository", delay=0).runs(COMMIT))
        self.assertIn(f"head_sha={COMMIT}", self.log.read_text())
        self.assertEqual([], gate.GitHubApi("example/repository", delay=0).runs(OLDER))

    def test_a_member_that_expands_far_beyond_the_limit_is_read_in_a_bounded_way(self):
        bomb = self.zip_of(b" " * (100 * 1024 * 1024), zipfile.ZIP_DEFLATED)
        self.assertLess(len(bomb), 1024 * 1024)
        self.serve(bomb)
        api = gate.GitHubApi("example/repository", delay=0)
        tracemalloc.start()
        try:
            with self.assertRaises(gate.Unreadable):
                api.evidence(7)
            peak = tracemalloc.get_traced_memory()[1]
        finally:
            tracemalloc.stop()
        self.assertLess(peak, 8 * 1024 * 1024)


if __name__ == "__main__":
    unittest.main()
