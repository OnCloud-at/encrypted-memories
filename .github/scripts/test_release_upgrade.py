#!/usr/bin/env python3
"""Behavior checks for release upgrade selection and the explicit override."""

import unittest
from unittest.mock import patch
import json
from pathlib import Path
import subprocess
import sys
import tempfile
from collections import Counter

import release_upgrade
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts/upgrade-test"))
from journey import run_cases
from release_upgrade import (
    UpgradeError, JOB_BUDGET_MINUTES, job_minutes, journey_points, select_sources, select_plan,
    upgrade_matrix, plan_matrix, unbudgeted_matrix, validate_override, MAX_MATRIX_JOBS, MIN_IOS_JOBS, shard_count,
)

REQUIRED_POINTS = {
    "backup.claimed", "backup.remoteReceipt", "backup.localRecord",
    "model.partial", "model.installRecord", "model.promoted",
    "index.embed", "index.beforeCommit", "index.afterCommit",
    "thumbnail.beforeLoad", "thumbnail.afterLoad", "thumbnail.stored",
}

def release(tag, published="2026-10-01T12:00:00Z", **changes):
    result = {
        "tag_name": tag,
        "draft": False,
        "prerelease": "-" in tag,
        "published_at": published,
    }
    result.update(changes)
    return result


def synthetic_capacity():
    return [{"platform": platform, "os": os_version, "device": device,
             "provision_minutes": 4, "available_gib": 100, "peak_gib": 20, "case_gib": 0.5,
             "evidence": "synthetic test input"}
            for platform, os_version, device in release_upgrade.CONFIGURATIONS]


def script_with_config(root, change=lambda config: None):
    """A copy of the planner next to a changed copy of its checked-in configuration."""
    source = Path(__file__).with_name("release_upgrade.py")
    script = root / "release_upgrade.py"
    script.write_text(source.read_text())
    config = json.loads(source.with_name("release_upgrade_config.json").read_text())
    change(config)
    (root / "release_upgrade_config.json").write_text(json.dumps(config))
    return script


class ReleaseUpgradeTests(unittest.TestCase):
    def test_capacity_cannot_override_checked_in_runtime_pins(self):
        capacity = synthetic_capacity()
        capacity[0]["runtime_version"] = "26.4"
        capacity[0]["runtime_id"] = "com.apple.CoreSimulator.SimRuntime.iOS-26-4"
        with self.assertRaisesRegex(UpgradeError, "pin"):
            release_upgrade.validate_provisioning(capacity)

    def test_the_gate_has_three_configurations_and_rejects_ipad_and_macos_26(self):
        self.assertEqual(set(release_upgrade.CONFIGURATIONS), {
            ("iOS", "26", "iPhone"), ("iOS", "27", "iPhone"), ("macOS", "27", None),
        })
        invalid = dict(synthetic_capacity()[0], device="iPad")
        with self.assertRaises(UpgradeError):
            release_upgrade.validate_configuration(invalid)
        macos_26 = dict(synthetic_capacity()[-1], os="26")
        with self.assertRaisesRegex(UpgradeError, "Unknown provisioning configuration"):
            release_upgrade.validate_configuration(macos_26)
        # A macOS 26 entry next to the three valid ones must fail the whole plan, not be ignored.
        with self.assertRaisesRegex(UpgradeError, "Unknown provisioning configuration"):
            plan_matrix(["a"], ["point.a"], overridden=False, provisioning=synthetic_capacity() + [macos_26])

    def test_three_sources_plan_all_three_configurations(self):
        points = [f"point.{index}" for index in range(12)]
        jobs = upgrade_matrix(["v1.0.5", "v1.1.0", "v1.1.0-beta.3"], points, synthetic_capacity())["include"]
        self.assertEqual(len(jobs), 7, "Two iPhone configurations of three jobs and one macOS job")
        expected = {("iOS", "26", "iPhone"), ("iOS", "27", "iPhone"), ("macOS", "27", None)}
        configurations = {(job["platform"], job["os"], job.get("device")) for job in jobs}
        self.assertEqual(configurations, expected)
        for configuration in expected:
            matching = [job for job in jobs if (job["platform"], job["os"], job.get("device")) == configuration]
            covered = [point for job in matching for point in job["points"].split()]
            self.assertEqual(Counter(covered), Counter(points), configuration)
            for job in matching:
                self.assertLessEqual(job_minutes(job["platform"], 3, len(job["points"].split())), JOB_BUDGET_MINUTES)

    def test_expanded_matrix_limit_counts_all_configurations(self):
        points = [f"point.{index}" for index in range(12)]
        with patch.object(release_upgrade, "MAX_MATRIX_JOBS", 6):
            with self.assertRaisesRegex(UpgradeError, "7 jobs.*6"):
                upgrade_matrix(["a", "b", "c"], points, synthetic_capacity())
            with self.assertRaisesRegex(UpgradeError, "7 jobs.*6"):
                plan_matrix(["a", "b", "c"], points, overridden=False, provisioning=synthetic_capacity())

    def test_checked_in_capacity_plans_without_a_variable(self):
        points = [f"point.{i}" for i in range(12)]
        jobs = plan_matrix(["a", "b", "c"], points, overridden=False)[0]["include"]
        # iOS 26 needs four jobs of three points: 20 + 1.1 x 12 GiB would not fit 32 GiB.
        self.assertEqual(len(jobs), 8)
        self.assertEqual(max(job["planned_minutes"] for job in jobs), 136)
        self.assertEqual(sum(job["planned_minutes"] for job in jobs), 958)
        for job in jobs:
            self.assertIn(release_upgrade.PINNED_SOURCE, job["capacity_source"])
            self.assertLessEqual(job["planned_peak_gib"], job["available_gib"])
        ios_26 = next(job for job in jobs if (job["platform"], job["os"]) == ("iOS", "26"))
        self.assertIn("provision_minutes measured", ios_26["capacity_source"])
        self.assertIn("case_gib estimated", ios_26["capacity_source"])
        self.assertAlmostEqual(ios_26["planned_peak_gib"], 20 + 1.1 * 3 * 3)

    def test_every_pinned_number_states_whether_it_is_measured_or_estimated(self):
        for key in release_upgrade.CONFIGURATIONS:
            capacity = release_upgrade.pinned_capacity(key)
            for field in release_upgrade.CAPACITY_FIELDS:
                self.assertRegex(capacity["source"], f"{field} (measured|estimated)")
            self.assertTrue(capacity["evidence"].strip())

    def test_a_configuration_without_checked_in_capacity_fails_closed(self):
        pins = {key: dict(value) for key, value in release_upgrade.PINS.items()}
        del pins[("iOS", "27", "iPhone")]["capacity"]
        with patch.object(release_upgrade, "PINS", pins):
            with self.assertRaisesRegex(UpgradeError, "capacity is required"):
                upgrade_matrix(["a"], ["point.a"])
            self.assertEqual(plan_matrix(["a"], ["point.a"], overridden=True)[0],
                             unbudgeted_matrix(["point.a"]))
            # The override of the missing configuration closes the gap; its numbers come from the variable.
            override = [item for item in synthetic_capacity() if (item["platform"], item["os"]) == ("iOS", "27")]
            jobs = upgrade_matrix(["a"], ["point.a"], override)["include"]
            self.assertTrue(all(job["capacity_source"].startswith(release_upgrade.OVERRIDE_SOURCE)
                                for job in jobs if (job["platform"], job["os"]) == ("iOS", "27")))
        incomplete = {key: dict(value) for key, value in release_upgrade.PINS.items()}
        capacity = dict(incomplete[("macOS", "27", None)]["capacity"])
        capacity["basis"] = {field: "measured" for field in release_upgrade.CAPACITY_FIELDS[1:]}
        incomplete[("macOS", "27", None)]["capacity"] = capacity
        with patch.object(release_upgrade, "PINS", incomplete), self.assertRaisesRegex(UpgradeError, "capacity is required"):
            upgrade_matrix(["a"], ["point.a"])
        broken = {key: dict(value) for key, value in release_upgrade.PINS.items()}
        broken[("macOS", "27", None)]["capacity"] = dict(broken[("macOS", "27", None)]["capacity"], basis={"case_gib": "guessed"})
        with patch.object(release_upgrade, "PINS", broken), self.assertRaisesRegex(UpgradeError, "capacity is required"):
            upgrade_matrix(["a"], ["point.a"])

    def test_a_basis_outside_the_known_words_fails_closed_even_when_every_key_is_present(self):
        pins = {key: dict(value) for key, value in release_upgrade.PINS.items()}
        key = ("macOS", "27", None)
        for word in ("guessed", "", None, "Measured"):
            capacity = dict(pins[key]["capacity"])
            capacity["basis"] = dict(capacity["basis"], case_gib=word)
            pins[key] = dict(pins[key], capacity=capacity)
            with self.subTest(word=word), patch.object(release_upgrade, "PINS", pins), \
                    self.assertRaisesRegex(UpgradeError, "capacity is required"):
                upgrade_matrix(["a"], ["point.a"])
        for word in release_upgrade.BASES:
            capacity = dict(pins[key]["capacity"])
            capacity["basis"] = dict(capacity["basis"], case_gib=word)
            pins[key] = dict(pins[key], capacity=capacity)
            with self.subTest(word=word), patch.object(release_upgrade, "PINS", pins):
                self.assertTrue(upgrade_matrix(["a"], ["point.a"])["include"])

    def test_zero_is_not_a_capacity_and_the_input_rules_name_the_field(self):
        for field in release_upgrade.CAPACITY_FIELDS:
            for value in (0, 0.0):
                with self.subTest(field=field, value=value), self.assertRaisesRegex(UpgradeError, field):
                    release_upgrade.validate_configuration(dict(synthetic_capacity()[1], **{field: value}))
        ios, macos = synthetic_capacity()[1], synthetic_capacity()[2]
        rules = [(dict(ios, os=27), "field os must be a JSON string"), (dict(ios, os=None), "field os must be a JSON string"),
                 (dict(macos, device="iPhone"), "field device must be null for macOS"),
                 (dict(ios, device=None), "field device must be null for macOS and a device name for iOS"),
                 (dict(ios, platform="tvOS"), "field platform"), (dict(ios, platform=None), "field platform")]
        for item, message in rules:
            with self.subTest(item=item), self.assertRaisesRegex(UpgradeError, message):
                release_upgrade.validate_configuration(item)
        # An unknown but well-formed configuration keeps its own message.
        with self.assertRaisesRegex(UpgradeError, "Unknown provisioning configuration"):
            release_upgrade.validate_configuration(dict(ios, os="25"))

    def test_every_ios_configuration_must_state_newest_runtime_and_exactly_one_sets_it(self):
        pins = {key: dict(value) for key, value in release_upgrade.PINS.items()}
        release_upgrade.validate_pins(pins)
        missing = {key: dict(value) for key, value in pins.items()}
        del missing[("iOS", "26", "iPhone")]["newest_runtime"]
        with self.assertRaisesRegex(UpgradeError, "newest_runtime must be true or false"):
            release_upgrade.validate_pins(missing)
        wrong_type = {key: dict(value) for key, value in pins.items()}
        wrong_type[("iOS", "26", "iPhone")]["newest_runtime"] = "no"
        with self.assertRaisesRegex(UpgradeError, "newest_runtime must be true or false"):
            release_upgrade.validate_pins(wrong_type)
        for value in (False, True):
            both = {key: dict(item) for key, item in pins.items()}
            for key in both:
                if key[0] == "iOS":
                    both[key]["newest_runtime"] = value
            with self.assertRaisesRegex(UpgradeError, "Exactly one iOS configuration"):
                release_upgrade.validate_pins(both)

    def test_an_override_replaces_only_the_configurations_it_names(self):
        override = [dict(synthetic_capacity()[1], case_gib=0.2)]
        jobs = upgrade_matrix(["a"], ["point.a", "point.b"], override)["include"]
        by_config = {(job["platform"], job["os"]): job["capacity_source"] for job in jobs}
        self.assertTrue(by_config[("iOS", "27")].startswith(release_upgrade.OVERRIDE_SOURCE))
        self.assertTrue(by_config[("iOS", "26")].startswith(release_upgrade.PINNED_SOURCE))
        self.assertTrue(by_config[("macOS", "27")].startswith(release_upgrade.PINNED_SOURCE))
        with self.assertRaisesRegex(UpgradeError, "own source"):
            upgrade_matrix(["a"], ["point.a"], [dict(synthetic_capacity()[0], source="release_upgrade_config.json")])
        with self.assertRaisesRegex(UpgradeError, "JSON array"):
            upgrade_matrix(["a"], ["point.a"], {"platform": "iOS"})

    def test_shard_count_rejects_capacity_of_another_platform(self):
        ios = release_upgrade.validate_provisioning()[("iOS", "27", "iPhone")]
        with self.assertRaisesRegex(UpgradeError, "platform"):
            shard_count("macOS", 1, 1, ios)
        self.assertEqual(shard_count("iOS", 1, 1, ios), 1)

    def test_shard_count_needs_capacity(self):
        with self.assertRaisesRegex(UpgradeError, "capacity.*required"):
            shard_count("iOS", 1, 1, None)

    def test_direct_shard_count_rejects_invalid_provisioning(self):
        for changes in ({"provision_minutes": 0}, {"provision_minutes": -100},
                        {"available_gib": float("inf")}, {"runtime_build": ""},
                        {"runner": "paid"}, {"evidence": ""}):
            config = dict(synthetic_capacity()[0], **changes)
            with self.subTest(changes=changes), self.assertRaises(UpgradeError):
                shard_count("iOS", 1, 1, config)
        with self.assertRaises(UpgradeError):
            shard_count("iOS", 1, 1, {"provision_minutes": 1, "available_gib": 100,
                                       "peak_gib": 20, "case_gib": 0.5})
        for sources, points in [(0, 1), (-1, 1), (True, 1), (1, 0), (1, 1.5)]:
            with self.subTest(sources=sources, points=points), self.assertRaises(UpgradeError):
                shard_count("iOS", sources, points, synthetic_capacity()[0])
        config = dict(synthetic_capacity()[0], available_gib=10 ** 400)
        try:
            shard_count("iOS", 1, 1, config)
        except UpgradeError:
            pass
        except Exception as error:
            self.fail(f"Oversized capacity must produce UpgradeError, got {type(error).__name__}")
        else:
            self.fail("Oversized capacity must be rejected")

    def test_direct_matrix_rejects_duplicate_or_blank_inputs(self):
        cases = [(["v1.0.5"], ["index.embed", "index.embed"]),
                 (["v1.0.5", "v1.0.5"], ["index.embed"]),
                 (["v1.0.5"], [" "]), ([""], ["index.embed"])]
        for sources, points in cases:
            with self.subTest(sources=sources, points=points), self.assertRaises(UpgradeError):
                upgrade_matrix(sources, points, synthetic_capacity())

    def test_ios_26_capacity_includes_measured_cold_provisioning(self):
        for field, value in (("provision_minutes", 3.9), ("peak_gib", 8.0)):
            capacity = synthetic_capacity()
            capacity[0][field] = value
            with self.subTest(field=field), self.assertRaisesRegex(UpgradeError, "measured"):
                upgrade_matrix(["a", "b", "c"], [f"point.{i}" for i in range(12)], capacity)

    def test_provisioning_and_disk_are_charged_per_expanded_job(self):
        capacity = synthetic_capacity()
        capacity[0]["provision_minutes"] = 40
        points = [f"point.{i}" for i in range(12)]
        matrix, _ = plan_matrix(["a", "b", "c"], points, overridden=False, provisioning=capacity)
        first = [j for j in matrix["include"] if (j["platform"], j["os"], j["device"]) == ("iOS", "26", "iPhone")]
        self.assertEqual(len(first), 4)
        self.assertTrue(all(job_minutes("iOS", 3, len(j["points"].split())) + 40 <= 165 for j in first))
        self.assertEqual(sorted(p for j in first for p in j["points"].split()), sorted(points))
        capacity[0]["available_gib"] = 20
        with self.assertRaisesRegex(UpgradeError, "disk"):
            plan_matrix(["a", "b", "c"], points, overridden=False, provisioning=capacity)

    def test_invalid_or_incomplete_capacity_fails_closed(self):
        for field, value in [("provision_minutes", None), ("available_gib", 0), ("case_gib", -1),
                             ("peak_gib", float("nan")), ("evidence", ""), ("runner", "paid"),
                             ("runtime_version", "27.0"), ("runtime_id", "not-a-runtime")]:
            with self.subTest(field=field):
                capacity = synthetic_capacity()
                capacity[0][field] = value
                with self.assertRaises(UpgradeError):
                    plan_matrix(["a"], ["point.a"], overridden=False, provisioning=capacity)
        with self.assertRaises(UpgradeError):
            plan_matrix(["a"], ["point.a"], overridden=False, provisioning=synthetic_capacity() + [synthetic_capacity()[0]])

    def test_runtime_disk_check_accepts_available_and_rejects_missing_or_insufficient_input(self):
        script = str(Path(__file__).with_name("release_upgrade.py"))
        with tempfile.TemporaryDirectory() as root:
            good = subprocess.run([sys.executable, script, "--check-free-disk", root, "0.001"], capture_output=True)
            self.assertEqual(good.returncode, 0, good.stderr)
            for value in ("", "nan", "-1", "1000000000"):
                result = subprocess.run([sys.executable, script, "--check-free-disk", root, value], capture_output=True)
                self.assertNotEqual(result.returncode, 0, value)

    def test_five_new_points_are_accepted_by_the_journey_list_contract(self):
        journey = Path(__file__).resolve().parents[2] / "scripts/upgrade-test/run_journey.py"
        points = journey_points(journey) + [f"extra.{index}" for index in range(5)]
        case = type(self)("test_the_journey_lists_its_points_once_for_the_matrix")
        result = unittest.TestResult()
        with patch(__name__ + ".journey_points", return_value=points):
            case.run(result)
        self.assertTrue(result.wasSuccessful(), result.failures or result.errors)

        sources = ["v1.0.5", "v1.1.0", "v1.2.0"]
        jobs = upgrade_matrix(sources, points, synthetic_capacity())["include"]
        for platform, os_version, device in release_upgrade.CONFIGURATIONS:
            calls = []
            for job in jobs:
                if (job["platform"], job["os"], job["device"]) == (platform, os_version, device):
                    run_cases(sources, job["points"].split(), lambda source, point: calls.append((source, point)))
            expected = Counter((source, point) for source in sources for point in points)
            self.assertEqual(Counter(calls), expected, platform)
            self.assertNotEqual(Counter(calls[:-1]), expected, "an omitted case must fail coverage")
            self.assertNotEqual(Counter(calls + [calls[0]]), expected, "a repeated case must fail coverage")

    def test_journey_contract_rejects_a_missing_or_duplicated_required_point(self):
        journey = Path(__file__).resolve().parents[2] / "scripts/upgrade-test/run_journey.py"
        points = journey_points(journey)
        for broken in ([point for point in points if point != required] for required in REQUIRED_POINTS):
            case = type(self)("test_the_journey_lists_its_points_once_for_the_matrix")
            result = unittest.TestResult()
            with patch(__name__ + ".journey_points", return_value=broken):
                case.run(result)
            self.assertFalse(result.wasSuccessful())
        for broken in (points + [point] for point in points):
            case = type(self)("test_the_journey_lists_its_points_once_for_the_matrix")
            result = unittest.TestResult()
            with patch(__name__ + ".journey_points", return_value=broken):
                case.run(result)
            self.assertFalse(result.wasSuccessful())

    def test_stable_checks_every_supported_published_stable_predecessor(self):
        target = release("v1.1.0", "2026-10-08T12:00:00Z")
        history = [release("v1.0.5"), release("v1.0.3"), release("v1.0.4"), target]
        self.assertEqual(select_sources(target, history), ["v1.0.5"])

    def test_new_stable_releases_join_without_an_allowlist(self):
        target = release("v1.3.0", "2026-10-08T12:00:00Z")
        self.assertEqual(select_sources(target, [release("v1.0.4"), release("v1.0.5"),
                                                release("v1.1.0"), release("v1.2.0"), target]),
                         ["v1.0.5", "v1.1.0", "v1.2.0"])

    def test_beta_three_reports_the_exact_previous_beta_exception(self):
        target = release("v1.1.0-beta.3", "2026-10-08T12:00:00Z")
        plan = select_plan(target, [release("v1.0.5"), release("v1.1.0-beta.2"), target])
        self.assertEqual(plan["sources"], ["v1.0.5"])
        self.assertEqual(plan["untested"], ["v1.1.0-beta.2"])

    def test_later_beta_with_entry_is_not_excepted(self):
        target = release("v1.1.0-beta.4", "2026-10-08T12:00:00Z")
        plan = select_plan(target, [release("v1.0.5"), release("v1.1.0-beta.3"), target])
        self.assertEqual(plan, {"sources": ["v1.0.5", "v1.1.0-beta.3"], "untested": []})

    def test_stable_one_one_does_not_select_or_except_a_beta(self):
        target = release("v1.1.0", "2026-10-08T12:00:00Z")
        self.assertEqual(select_plan(target, [release("v1.0.5"), release("v1.1.0-beta.2"), target]),
                         {"sources": ["v1.0.5"], "untested": []})

    def test_beta_adds_the_previous_published_beta(self):
        target = release("v1.1.0-beta.2", "2026-10-08T12:00:00Z")
        history = [release("v1.0.5"), release("v1.1.0-beta.1"), release("v1.0.5-beta.3"), target]
        self.assertEqual(select_sources(target, history), ["v1.0.5", "v1.1.0-beta.1"])

    def test_previous_beta_uses_publication_time_not_response_order(self):
        target = release("v1.1.0-beta.11", "2026-10-08T12:00:00Z")
        history = [release("v1.1.0-beta.10", "2026-10-07T12:00:00Z"),
                   release("v1.1.0-beta.9", "2026-10-06T12:00:00Z"), target]
        self.assertEqual(select_sources(target, history), ["v1.1.0-beta.10"])

    def test_ignores_drafts_unpublished_and_future_releases(self):
        target = release("v1.1.0", "2026-10-08T12:00:00Z")
        history = [release("v1.0.3", draft=True), release("v1.0.4", published_at=None),
                   release("v1.0.5"), release("v1.2.0"),
                   release("v1.0.6", "2026-10-09T12:00:00Z"), target]
        self.assertEqual(select_sources(target, history), ["v1.0.5"])

    def test_semantic_versions_sort_numerically(self):
        target = release("v1.11.0", "2026-10-08T12:00:00Z")
        history = [release("v1.10.0"), release("v1.9.0"), target]
        self.assertEqual(select_sources(target, history), ["v1.9.0", "v1.10.0"])

    def test_beta_does_not_select_the_stable_of_the_same_version(self):
        target = release("v1.1.0-beta.2", "2026-10-08T12:00:00Z")
        self.assertEqual(select_sources(target, [release("v1.1.0"), target]), [])

    def test_rejects_ambiguous_duplicate_published_tags(self):
        target = release("v1.1.0")
        with self.assertRaises(UpgradeError):
            select_sources(target, [target, release("v1.0.5"), release("v1.0.5")])

    def test_rejects_missing_target_from_paginated_history(self):
        with self.assertRaises(UpgradeError):
            select_sources(release("v1.1.0"), [release("v1.0.5")])

    def test_rejects_prerelease_flag_that_disagrees_with_tag(self):
        target = release("v1.1.0")
        with self.assertRaises(UpgradeError):
            select_sources(target, [target, release("v1.0.5", prerelease=True)])

    def test_stable_sources_cannot_be_excepted_even_if_the_list_changes(self):
        target = release("v1.1.0")
        with patch("release_upgrade.PREVIOUS_BETA_WITHOUT_ENTRY", frozenset({"v1.0.5"})):
            self.assertEqual(select_plan(target, [release("v1.0.5"), target]),
                             {"sources": ["v1.0.5"], "untested": []})

    def test_cli_reports_the_previous_beta_exception_and_exports_selection(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target = release("v1.1.0-beta.3", "2026-10-08T12:00:00Z")
            (root / "release.json").write_text(json.dumps(target))
            (root / "history.json").write_text(json.dumps([release("v1.0.5"), release("v1.1.0-beta.2"), target]))
            subprocess.run([sys.executable, str(script_with_config(root)), "--journey", str(Path(__file__).resolve().parents[2] / "scripts/upgrade-test/run_journey.py"),
                            "--release", str(root / "release.json"), "--history", str(root / "history.json"),
                            "--output", str(root / "plan.json")], check=True, capture_output=True,
                           env={"GITHUB_OUTPUT": str(root / "output"), "GITHUB_STEP_SUMMARY": str(root / "summary"),
                                "UPGRADE_PROVISIONING": json.dumps(synthetic_capacity())})
            self.assertTrue((root / "summary").exists(), "The excluded beta is absent from the job summary")
            self.assertIn("nicht getestet: v1.1.0-beta.2 (kein Prüfeinstieg)", (root / "summary").read_text())
            self.assertIn('upgrade_sources=["v1.0.5"]', (root / "output").read_text())
            self.assertIn("upgrade_overridden=false", (root / "output").read_text())

    def test_cli_plans_from_the_checked_in_capacity_and_names_the_source_of_each_number(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target = release("v1.1.0", "2026-10-08T12:00:00Z")
            (root / "release.json").write_text(json.dumps(target))
            (root / "history.json").write_text(json.dumps([release("v1.0.5"), target]))
            journey = str(Path(__file__).resolve().parents[2] / "scripts/upgrade-test/run_journey.py")
            command = [sys.executable, str(script_with_config(root)), "--journey", journey,
                       "--release", str(root / "release.json"), "--history", str(root / "history.json"),
                       "--output", str(root / "plan.json")]
            environment = {"GITHUB_OUTPUT": str(root / "output"), "GITHUB_STEP_SUMMARY": str(root / "summary")}
            result = subprocess.run(command, capture_output=True, text=True, env=environment)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            summary = (root / "summary").read_text()
            self.assertIn("release_upgrade_config.json (provision_minutes measured", summary)
            self.assertNotIn(release_upgrade.OVERRIDE_SOURCE, summary)
            # The optional variable replaces the named configuration and the summary says so.
            override = [dict(synthetic_capacity()[0], evidence="rehearsal numbers")]
            subprocess.run(command, check=True, capture_output=True, text=True,
                           env=dict(environment, UPGRADE_PROVISIONING=json.dumps(override)))
            self.assertIn("RELEASE_UPGRADE_PROVISIONING (all numbers supplied)", (root / "summary").read_text())
            # A malformed variable is never ignored for a normal release.
            broken = subprocess.run(command, capture_output=True, text=True, env=dict(environment, UPGRADE_PROVISIONING="{"))
            self.assertNotEqual(broken.returncode, 0)
            self.assertIn("Invalid provisioning JSON", (root / "summary").read_text())
            # A configuration without checked-in capacity fails the plan.
            def drop(config):
                del config["configurations"][0]["capacity"]
            (root / "plan.json").unlink()
            missing = subprocess.run([sys.executable, str(script_with_config(root, drop))] + command[2:],
                                     capture_output=True, text=True, env=environment)
            self.assertNotEqual(missing.returncode, 0)
            self.assertFalse((root / "plan.json").exists())

    def test_cli_failure_records_the_cause_in_the_job_summary(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "release.json").write_text(json.dumps(release("v1.1.0")))
            (root / "history.json").write_text("[]")
            result = subprocess.run([sys.executable, str(Path(__file__).with_name("release_upgrade.py")),
                                     "--release", str(root / "release.json"), "--history", str(root / "history.json"),
                                     "--output", str(root / "plan.json")], capture_output=True,
                                    env={"GITHUB_STEP_SUMMARY": str(root / "summary")})
            self.assertNotEqual(result.returncode, 0)
            self.assertTrue((root / "summary").exists(), "The failure cause is absent from the job summary")
            self.assertIn("Target release is absent", (root / "summary").read_text())

    def test_the_journey_lists_its_points_once_for_the_matrix(self):
        journey = Path(__file__).resolve().parents[2] / "scripts/upgrade-test/run_journey.py"
        points = journey_points(journey)
        self.assertTrue(REQUIRED_POINTS.issubset(points), REQUIRED_POINTS.difference(points))
        self.assertEqual(len(set(points)), len(points))
        self.assertEqual(points[0], "backup.claimed")

    def test_the_matrix_covers_every_point_once_per_platform_and_fits_the_job_budget(self):
        points = [f"point.{index}" for index in range(12)]
        for source_count in range(0, 9):
            matrix = upgrade_matrix([f"v1.0.{index}" for index in range(source_count)], points, synthetic_capacity())
            for platform, os_version, device in release_upgrade.CONFIGURATIONS:
                jobs = [job for job in matrix["include"] if (job["platform"], job["os"], job["device"]) == (platform, os_version, device)]
                with self.subTest(platform=platform, os=os_version, device=device, sources=source_count):
                    covered = [point for job in jobs for point in job["points"].split()]
                    self.assertEqual(sorted(covered), sorted(points))
                    self.assertEqual(len({job["shard"] for job in jobs}), len(jobs))
                    for job in jobs:
                        minutes = job_minutes(platform, max(1, source_count), len(job["points"].split()))
                        self.assertLessEqual(minutes, JOB_BUDGET_MINUTES)

    def test_more_sources_never_need_fewer_ios_jobs_and_a_new_point_needs_no_edit(self):
        points = [f"point.{index}" for index in range(12)]
        ios = lambda sources, points: [job for job in upgrade_matrix(sources, points, synthetic_capacity())["include"]
                                       if (job["platform"], job["os"], job["device"]) == ("iOS", "26", "iPhone")]
        counts = [len(ios([f"v{index}" for index in range(sources)], points)) for sources in range(1, 9)]
        self.assertEqual(counts, sorted(counts))
        self.assertGreater(counts[3], counts[0])
        more = points + ["point.new"]
        covered = [point for job in ios(["a", "b", "c"], more) for point in job["points"].split()]
        self.assertEqual(sorted(covered), sorted(more))

    def test_one_source_runs_the_ios_gate_in_two_jobs_and_never_more_jobs_than_points(self):
        points = [f"point.{index}" for index in range(12)]
        shape = lambda sources, points, platform: [
            len(job["points"].split()) for job in upgrade_matrix(sources, points, synthetic_capacity())["include"]
            if job["platform"] == platform and job["os"] == ("26" if platform == "iOS" else "27")]
        # One source fits one iOS job, but the minimum plans two of six points. macOS keeps one job.
        self.assertLessEqual(job_minutes("iOS", 1, 12), JOB_BUDGET_MINUTES)
        self.assertEqual(MIN_IOS_JOBS, 2)
        self.assertEqual(shape(["v1.0.5"], points, "iOS"), [6, 6])
        self.assertEqual(shape(["v1.0.5"], points, "macOS"), [12])
        self.assertEqual(shape([], points, "iOS"), [6, 6])
        # Three sources need three iOS jobs anyway.
        self.assertEqual(shape(["a", "b", "c"], points, "iOS"), [4, 4, 4])
        # The minimum never leaves a job without a point: one point is one job, two points are two jobs.
        self.assertEqual(shape(["v1.0.5"], ["point.a"], "iOS"), [1])
        self.assertEqual(shape(["v1.0.5"], ["point.a", "point.b"], "iOS"), [1, 1])
        # The minimum never breaks the budget rule and never plans an empty job.
        for sources in range(1, 9):
            for count in (1, 2, 5, 12):
                with self.subTest(sources=sources, points=count):
                    jobs = [len(job["points"].split()) for job in upgrade_matrix(
                        [f"v{index}" for index in range(sources)], points[:count], synthetic_capacity())["include"]
                        if (job["platform"], job["os"], job["device"]) == ("iOS", "26", "iPhone")]
                    self.assertGreaterEqual(len(jobs), min(MIN_IOS_JOBS, count))
                    self.assertTrue(all(size >= 1 for size in jobs))
                    self.assertEqual(sum(jobs), count)
                    self.assertLessEqual(job_minutes("iOS", sources, max(jobs)), JOB_BUDGET_MINUTES)

    def test_shard_count_without_points_fails_with_an_upgrade_error_for_every_platform(self):
        for platform in {key[0] for key in release_upgrade.CONFIGURATIONS}:
            with self.subTest(platform=platform):
                with self.assertRaises(UpgradeError):
                    shard_count(platform, 1, 0, synthetic_capacity()[0])

    def test_a_point_that_no_job_can_hold_fails_with_its_cost(self):
        with self.assertRaisesRegex(UpgradeError, "more than the 165 minutes"):
            upgrade_matrix([f"v1.0.{index}" for index in range(40)], ["point.a", "point.b"], synthetic_capacity())

    def test_a_plan_of_more_jobs_than_github_accepts_fails_before_it_is_exported(self):
        points = [f"point.{index}" for index in range(250)]
        sources = [f"v1.0.{index}" for index in range(8)]
        with self.assertRaisesRegex(UpgradeError, f"more than the {MAX_MATRIX_JOBS} that GitHub accepts"):
            upgrade_matrix(sources, points, synthetic_capacity())

    def test_a_deliberate_override_falls_back_to_one_job_per_platform_when_no_plan_fits(self):
        points = [f"point.{index}" for index in range(12)]
        sources = [f"v1.0.{index}" for index in range(40)]
        with self.assertRaises(UpgradeError):
            plan_matrix(sources, points, overridden=False, provisioning=synthetic_capacity())
        matrix, note = plan_matrix(sources, points, overridden=True, provisioning=synthetic_capacity())
        self.assertEqual(matrix, unbudgeted_matrix(points))
        self.assertEqual([(job["platform"], len(job["points"].split())) for job in matrix["include"]],
                         [(platform, 12) for platform, _, _ in release_upgrade.CONFIGURATIONS])
        self.assertIn("more than the 165 minutes", note)
        self.assertIsNone(plan_matrix(["v1.0.5"], points, overridden=True, provisioning=synthetic_capacity())[1])

    def test_cli_keeps_the_override_escape_path_with_more_sources_than_a_job_can_plan(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target = release("v1.2.0", "2026-11-01T12:00:00Z")
            history = [release(f"v1.0.{index}") for index in range(5, 25)] + [target]
            (root / "release.json").write_text(json.dumps(target))
            (root / "history.json").write_text(json.dumps(history))
            command = [sys.executable, str(Path(__file__).with_name("release_upgrade.py")),
                       "--release", str(root / "release.json"), "--history", str(root / "history.json"),
                       "--output", str(root / "plan.json")]
            environment = {"GITHUB_OUTPUT": str(root / "output"), "GITHUB_STEP_SUMMARY": str(root / "summary"),
                           "UPGRADE_PROVISIONING": json.dumps(synthetic_capacity())}
            failed = subprocess.run(command, capture_output=True, env=environment)
            self.assertNotEqual(failed.returncode, 0)
            self.assertIn("more than the 165 minutes", (root / "summary").read_text())
            (root / "summary").unlink()
            (root / "output").unlink(missing_ok=True)
            overridden = subprocess.run(
                command + ["--event", "workflow_dispatch", "--ref", "refs/heads/main", "--override-tag", "v1.2.0",
                           "--override-reason", "Infrastructure failure"],
                capture_output=True, env=environment)
            self.assertEqual(overridden.returncode, 0, overridden.stderr)
            output = (root / "output").read_text()
            self.assertIn("upgrade_overridden=true", output)
            plan = json.loads((root / "plan.json").read_text())
            self.assertTrue(plan["overridden"])
            self.assertEqual([job["shard"] for job in plan["matrix"]["include"]], ["1-of-1"] * 3)
            self.assertIn("the journey steps are skipped by the override, so the jobs only acknowledge it",
                          (root / "summary").read_text())
            # The fresh summary of the override run states that the gate is off; nothing is left from the failed run.
            self.assertIn("The upgrade gate is off for this release", (root / "summary").read_text())

    def test_override_survives_malformed_provisioning_without_hiding_it(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target = release("v1.1.0", "2026-10-08T12:00:00Z")
            (root / "release.json").write_text(json.dumps(target))
            (root / "history.json").write_text(json.dumps([release("v1.0.5"), target]))
            command = [sys.executable, str(Path(__file__).with_name("release_upgrade.py")),
                       "--release", str(root / "release.json"), "--history", str(root / "history.json"),
                       "--output", str(root / "plan.json"), "--event", "workflow_dispatch", "--ref", "refs/heads/main",
                       "--override-tag", "v1.1.0", "--override-reason", "Infrastructure failure"]
            result = subprocess.run(command, capture_output=True, text=True, env={"UPGRADE_PROVISIONING": "{"})
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("provisioning", result.stdout.lower())
            self.assertTrue(json.loads((root / "plan.json").read_text())["overridden"])

    def test_an_empty_point_listing_reports_the_listing_failure_and_invents_no_cost(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target = release("v1.1.0-beta.3", "2026-10-08T12:00:00Z")
            (root / "release.json").write_text(json.dumps(target))
            (root / "history.json").write_text(json.dumps([release("v1.0.5"), target]))
            (root / "empty.py").write_text("pass\n")
            command = [sys.executable, str(Path(__file__).with_name("release_upgrade.py")),
                       "--release", str(root / "release.json"), "--history", str(root / "history.json"),
                       "--output", str(root / "plan.json"), "--journey", str(root / "empty.py")]
            environment = {"GITHUB_OUTPUT": str(root / "output"), "GITHUB_STEP_SUMMARY": str(root / "summary")}
            self.assertNotEqual(subprocess.run(command, capture_output=True, env=environment).returncode, 0)
            overridden = subprocess.run(
                command + ["--event", "workflow_dispatch", "--ref", "refs/heads/main",
                           "--override-tag", "v1.1.0-beta.3", "--override-reason", "Infrastructure failure"],
                capture_output=True, env=environment)
            self.assertEqual(overridden.returncode, 0, overridden.stderr)
            summary = (root / "summary").read_text()
            self.assertIn("lists no usable interruption points", summary)
            self.assertNotIn("minutes", summary)
        with self.assertRaisesRegex(UpgradeError, "no interruption point to plan"):
            upgrade_matrix(["v1.0.5"], [])

    def test_listing_the_points_has_a_deadline_and_keeps_the_end_of_the_error_text(self):
        with tempfile.TemporaryDirectory() as directory:
            hang = Path(directory) / "hang.py"
            hang.write_text("import time\ntime.sleep(60)\n")
            with patch.object(release_upgrade, "LIST_POINTS_TIMEOUT_SECONDS", 1):
                with self.assertRaisesRegex(UpgradeError, "did not list its interruption points within 1 seconds"):
                    journey_points(hang)
            failing = Path(directory) / "failing.py"
            failing.write_text("import sys\nsys.stderr.write('A' * 300 + 'THE-CAUSE')\nsys.exit(3)\n")
            with self.assertRaises(UpgradeError) as raised:
                journey_points(failing)
            self.assertIn("THE-CAUSE", str(raised.exception))
            self.assertNotIn("A" * 201, str(raised.exception))

    def test_cli_exports_the_matrix_of_the_selected_sources(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target = release("v1.1.0-beta.3", "2026-10-08T12:00:00Z")
            (root / "release.json").write_text(json.dumps(target))
            (root / "history.json").write_text(json.dumps([release("v1.0.5"), release("v1.1.0-beta.2"), target]))
            subprocess.run([sys.executable, str(script_with_config(root)), "--journey", str(Path(__file__).resolve().parents[2] / "scripts/upgrade-test/run_journey.py"),
                            "--release", str(root / "release.json"), "--history", str(root / "history.json"),
                            "--output", str(root / "plan.json")], check=True, capture_output=True,
                           env={"GITHUB_OUTPUT": str(root / "output"), "GITHUB_STEP_SUMMARY": str(root / "summary"),
                                "UPGRADE_PROVISIONING": json.dumps(synthetic_capacity())})
            line = next(line for line in (root / "output").read_text().splitlines()
                        if line.startswith("upgrade_matrix="))
            matrix = json.loads(line.removeprefix("upgrade_matrix="))
            self.assertEqual({job["platform"] for job in matrix["include"]}, {key[0] for key in release_upgrade.CONFIGURATIONS})
            summary = (root / "summary").read_text()
            self.assertIn("iOS 26 iPhone 1-of-2 (6 points)", summary)
            self.assertIn("iOS 27 iPhone 2-of-2 (6 points)", summary)
            self.assertIn("macOS 27 host 1-of-1 (12 points)", summary)
            self.assertEqual(json.loads((root / "plan.json").read_text())["matrix"], matrix)

    def test_no_override_needs_no_reason(self):
        self.assertFalse(validate_override("release", "refs/tags/v1.1.0", "v1.1.0", "", ""))

    def test_explicit_main_dispatch_override_requires_tag_and_reason(self):
        self.assertTrue(validate_override("workflow_dispatch", "refs/heads/main", "v1.1.0",
                                          "v1.1.0", "Confirmed infrastructure failure"))

    def test_rejects_automatic_wrong_ref_wrong_tag_and_empty_reason_overrides(self):
        cases = [("release", "refs/heads/main", "v1.1.0", "Reason"),
                 ("workflow_dispatch", "refs/heads/work/test", "v1.1.0", "Reason"),
                 ("workflow_dispatch", "refs/heads/main", "v1.0.5", "Reason"),
                 ("workflow_dispatch", "refs/heads/main", "v1.1.0", "   ")]
        for event, ref, confirmation, reason in cases:
            with self.subTest(event=event, ref=ref, confirmation=confirmation):
                with self.assertRaises(UpgradeError):
                    validate_override(event, ref, "v1.1.0", confirmation, reason)


RECORDED_JOBS = Path(__file__).resolve().parent / "fixtures" / "upgrade_jobs_run_41064872152.json"
# Real job records with their check-run annotations: a lost runner (run 38193953552) and a full runner disk (run 38181793360).
RECORDED_ANNOTATIONS = Path(__file__).resolve().parent / "fixtures" / "upgrade_annotations_runs_38193953552_38181793360.json"
UPGRADE_JOB = "Test installed upgrades on iOS 27 iPhone (1-of-3)"
# Synthetic annotation texts, shaped like the real ones.
LOST_NOTE = {"annotation_level": "failure", "message": "The hosted runner lost communication with the server. (synthetic)"}
DISK_NOTE = {"annotation_level": "failure", "message": "System.IO.IOException: No space left on device : 'x' (synthetic)"}
# The warning of the runner itself, shaped like its source text (not a record of a run): it appears at the warning level.
LOW_DISK_NOTE = {"annotation_level": "warning", "message": "You are running out of disk space. The runner will stop working "
                 "when the machine runs out of disk space. Free space left: 80 MB (synthetic)"}


def synthetic_job(name=UPGRADE_JOB, conclusion="failure", status="completed", minutes=40, steps=None, attempt=1, job_id=1001):
    """A job in the shape of the GitHub jobs API. The steps of a lost runner stop without a failed step."""
    if steps is None:
        steps = [("Check out trusted upgrade automation", "success"), ("Test installed upgrades", "cancelled"),
                 ("Retain upgrade evidence", "skipped")]
    return {"id": job_id, "name": name, "status": status, "conclusion": conclusion, "run_attempt": attempt,
            "started_at": "2026-11-21T10:00:00Z",
            "completed_at": f"2026-11-21T{10 + minutes // 60:02d}:{minutes % 60:02d}:00Z",
            "steps": [{"name": step, "status": "completed", "conclusion": result, "number": number}
                      for number, (step, result) in enumerate(steps, 1)]}


def passed_job(name="Build iOS"):
    return synthetic_job(name=name, conclusion="success", steps=[("Build", "success")], job_id=2002)


def annotations_of(notes_by_id):
    """A reader of annotations for the classifier: the notes of the job id, or a failed read for an id without notes."""
    def read(job_id):
        notes = notes_by_id[job_id]
        if isinstance(notes, Exception):
            raise notes
        return notes
    return read


def never_read(job_id):
    raise AssertionError(f"the annotations of job {job_id} must not be read")


def real(key):
    record = json.loads(RECORDED_ANNOTATIONS.read_text())[key]
    return record["job"], record["annotations"]


class LostRunnerTests(unittest.TestCase):
    """The classifier of a failed upgrade gate (#1016). Its input is the jobs answer of the GitHub API and, for a job that
    ended without a failed step, the check-run annotations of the job."""

    def kinds(self, jobs, notes_by_id=None):
        reader = annotations_of(notes_by_id) if notes_by_id is not None else never_read
        return {name: kind for name, kind in release_upgrade.classify_failed_jobs(jobs, reader)}

    def decide(self, jobs, attempt, notes_by_id=None):
        reader = annotations_of(notes_by_id) if notes_by_id is not None else never_read
        return release_upgrade.retry_decision(release_upgrade.classify_failed_jobs(jobs, reader), attempt)

    def test_the_four_jobs_of_the_recorded_failed_run_failed_in_their_own_step_and_are_not_retried(self):
        jobs = json.loads(RECORDED_JOBS.read_text())["jobs"]
        failed = self.kinds(jobs)
        self.assertEqual(4, len(failed))
        self.assertEqual({"step-failed"}, set(failed.values()))
        retry, reason = self.decide(jobs, 1)
        self.assertFalse(retry)
        self.assertIn("step failed", reason)

    def test_the_real_lost_runner_is_retried_once(self):
        job, notes = real("lost_runner")
        self.assertEqual([], job["steps"])
        self.assertEqual({job["name"]: "lost-runner"}, self.kinds([job], {job["id"]: notes}))
        retry, reason = self.decide([job], 1, {job["id"]: notes})
        self.assertTrue(retry)
        self.assertIn("lost its runner", reason)

    def test_the_real_job_with_a_full_runner_disk_is_not_a_lost_runner_and_is_never_retried(self):
        job, notes = real("disk_full")
        self.assertEqual([], job["steps"])
        self.assertEqual({job["name"]: "disk-full"}, self.kinds([job], {job["id"]: notes}))
        retry, reason = self.decide([job], 1, {job["id"]: notes})
        self.assertFalse(retry)
        self.assertIn("runner disk", reason)
        self.assertIn(job["name"], reason)

    def test_a_full_disk_next_to_a_lost_runner_prevents_the_retry(self):
        lost, lost_notes = real("lost_runner")
        full, full_notes = real("disk_full")
        retry, reason = self.decide([lost, full], 1, {lost["id"]: lost_notes, full["id"]: full_notes})
        self.assertFalse(retry)
        self.assertIn(full["name"], reason)

    def test_synthetic_job_without_a_failed_step_and_with_a_lost_runner_annotation_is_retried_once(self):
        jobs = [passed_job(), synthetic_job()]
        self.assertEqual({UPGRADE_JOB: "lost-runner"}, self.kinds(jobs, {1001: [LOST_NOTE]}))
        self.assertTrue(self.decide(jobs, 1, {1001: [LOST_NOTE]})[0])

    def test_synthetic_job_that_never_started_a_step_is_a_lost_runner_when_its_annotation_says_so(self):
        jobs = [synthetic_job(steps=[], minutes=3)]
        self.assertEqual({UPGRADE_JOB: "lost-runner"}, self.kinds(jobs, {1001: [LOST_NOTE]}))

    def test_a_job_that_did_not_conclude_with_a_failure_is_never_a_lost_runner(self):
        for conclusion in ("cancelled", "timed_out", "action_required", "stale", None):
            with self.subTest(conclusion=conclusion):
                jobs = [synthetic_job(conclusion=conclusion, minutes=40)]
                self.assertEqual({UPGRADE_JOB: "not-failure"}, self.kinds(jobs))
                retry, reason = self.decide(jobs, 1)
                self.assertFalse(retry)
                self.assertIn("did not conclude with a failure", reason)

    def test_a_job_that_ended_before_it_started_is_unreadable(self):
        job = {**synthetic_job(), "started_at": "2026-11-21T11:00:00Z", "completed_at": "2026-11-21T10:00:00Z"}
        self.assertEqual({UPGRADE_JOB: "unreadable"}, self.kinds([job]))
        self.assertFalse(self.decide([job], 1)[0])

    def test_the_low_disk_warning_of_the_runner_next_to_the_lost_runner_text_is_a_full_disk(self):
        job, notes = real("lost_runner")
        self.assertEqual({job["name"]: "disk-full"}, self.kinds([job], {job["id"]: [*notes, LOW_DISK_NOTE]}))
        self.assertEqual({job["name"]: "disk-full"}, self.kinds([job], {job["id"]: [LOW_DISK_NOTE, *notes]}))
        retry, reason = self.decide([job], 1, {job["id"]: [*notes, LOW_DISK_NOTE]})
        self.assertFalse(retry)
        self.assertIn("runner disk", reason)
        self.assertEqual({UPGRADE_JOB: "disk-full"}, self.kinds([synthetic_job()], {1001: [LOW_DISK_NOTE]}))

    def test_synthetic_other_annotations_next_to_the_lost_runner_text_do_not_hide_it(self):
        other = {"annotation_level": "warning", "message": "Node.js 20 actions are deprecated. (synthetic)"}
        self.assertEqual({UPGRADE_JOB: "lost-runner"}, self.kinds([synthetic_job()], {1001: [other, LOST_NOTE]}))

    def test_synthetic_the_text_of_a_full_disk_wins_over_the_text_of_a_lost_runner(self):
        self.assertEqual({UPGRADE_JOB: "disk-full"}, self.kinds([synthetic_job()], {1001: [LOST_NOTE, DISK_NOTE]}))
        self.assertEqual({UPGRADE_JOB: "disk-full"}, self.kinds([synthetic_job()], {1001: [DISK_NOTE, LOST_NOTE]}))

    def test_synthetic_a_full_disk_counts_at_every_annotation_level(self):
        warning = {"annotation_level": "warning", "message": "No space left on device (synthetic)"}
        self.assertEqual({UPGRADE_JOB: "disk-full"}, self.kinds([synthetic_job()], {1001: [warning]}))

    def test_synthetic_the_lost_runner_text_counts_only_in_a_failure_annotation(self):
        for level in ("warning", "notice", None):
            with self.subTest(level=level):
                note = {"annotation_level": level, "message": LOST_NOTE["message"]}
                self.assertEqual({UPGRADE_JOB: "unknown"}, self.kinds([synthetic_job()], {1001: [note]}))

    def test_any_other_or_unreadable_annotation_is_unknown_and_never_retried(self):
        job = synthetic_job()
        cases = {"other text": [{"annotation_level": "failure", "message": "Process completed with exit code 1."}],
                 "no annotation": [], "not a list": "lost communication with the server", "none": None,
                 "note is not an object": ["lost communication with the server"],
                 "text is no string": [{"annotation_level": "failure", "message": 5}],
                 "no text": [{"annotation_level": "failure"}],
                 "one note unreadable": [LOST_NOTE, 7],
                 "read failed": release_upgrade.UpgradeError("no access"), "no network": OSError("offline"),
                 "answer is no json": ValueError("not json"), "read timed out": subprocess.TimeoutExpired("gh", 60)}
        for name, notes in cases.items():
            with self.subTest(name=name):
                self.assertEqual({UPGRADE_JOB: "unknown"}, self.kinds([job], {1001: notes}))
                retry, reason = self.decide([job], 1, {1001: notes})
                self.assertFalse(retry)
                self.assertIn("do not name a lost runner", reason)

    def test_the_annotation_text_is_judged_without_help_from_the_caller(self):
        self.assertEqual("lost-runner", release_upgrade.annotation_kind([LOST_NOTE]))
        self.assertEqual("disk-full", release_upgrade.annotation_kind([DISK_NOTE]))
        self.assertEqual("disk-full", release_upgrade.annotation_kind([LOW_DISK_NOTE]))
        for notes in (None, "lost communication with the server", {"message": "x"}, [], ["x"], [LOST_NOTE, 7],
                      [{"annotation_level": "failure", "message": None}], [{"annotation_level": "failure"}]):
            with self.subTest(notes=notes):
                self.assertEqual("unknown", release_upgrade.annotation_kind(notes))

    def test_a_job_without_a_usable_id_is_unknown_and_its_annotations_are_not_read(self):
        for job_id in (None, "1001", True, 1.0):
            with self.subTest(job_id=job_id):
                job = {**synthetic_job(), "id": job_id}
                self.assertEqual({UPGRADE_JOB: "unknown"}, self.kinds([job]))
        job = {key: value for key, value in synthetic_job().items() if key != "id"}
        self.assertEqual({UPGRADE_JOB: "unknown"}, self.kinds([job]))

    def test_the_annotations_of_a_job_that_the_record_decides_are_not_read(self):
        other = synthetic_job(name="Build iOS", steps=[("Build", "cancelled")], job_id=2002)
        failed_step = synthetic_job(steps=[("Test installed upgrades", "failure")], job_id=2003)
        slow = synthetic_job(minutes=176, job_id=2004)
        broken = {**synthetic_job(job_id=2005), "completed_at": None}
        self.assertEqual({"Build iOS": "other-job", UPGRADE_JOB: "unreadable"}, self.kinds([other, broken]))
        self.assertEqual({UPGRADE_JOB: "step-failed"}, self.kinds([failed_step]))
        self.assertEqual({UPGRADE_JOB: "timeout"}, self.kinds([slow]))

    def test_the_annotations_of_a_job_are_read_once_for_the_report_and_the_decision(self):
        calls = []

        def read(job_id):
            calls.append(job_id)
            return [LOST_NOTE]
        with patch.object(release_upgrade, "report"), patch.dict("os.environ", {"GITHUB_OUTPUT": "/dev/null"}):
            release_upgrade.report_classification([synthetic_job()], 1, read)
        self.assertEqual([1001], calls)

    def test_a_second_attempt_is_never_retried(self):
        retry, reason = self.decide([synthetic_job(attempt=2)], 2, {1001: [LOST_NOTE]})
        self.assertFalse(retry)
        self.assertIn("attempt 2", reason)

    def test_one_genuinely_failed_job_prevents_the_retry_of_a_lost_one(self):
        genuine = synthetic_job(name="Test installed upgrades on macOS 27 host (1-of-1)", job_id=3003,
                                steps=[("Test installed upgrades", "failure")])
        retry, reason = self.decide([synthetic_job(), genuine], 1, {1001: [LOST_NOTE]})
        self.assertFalse(retry)
        self.assertIn("macOS 27 host", reason)

    def test_a_failed_job_outside_the_upgrade_gate_prevents_the_retry(self):
        build = synthetic_job(name="Build iOS", steps=[("Build", "cancelled")], job_id=2002)
        self.assertEqual("other-job", self.kinds([build])["Build iOS"])
        retry, reason = self.decide([synthetic_job(), build], 1, {1001: [LOST_NOTE]})
        self.assertFalse(retry)
        self.assertIn("Build iOS", reason)

    def test_a_job_that_ran_into_its_timeout_is_not_a_lost_runner(self):
        for minutes in (175, 180):
            with self.subTest(minutes=minutes):
                jobs = [synthetic_job(minutes=minutes, conclusion="cancelled")]
                self.assertEqual({UPGRADE_JOB: "timeout"}, self.kinds(jobs))
                self.assertFalse(self.decide(jobs, 1)[0])
        self.assertEqual({UPGRADE_JOB: "lost-runner"}, self.kinds([synthetic_job(minutes=174)], {1001: [LOST_NOTE]}))

    def test_unreadable_job_data_is_never_retried(self):
        broken = {"missing steps": {k: v for k, v in synthetic_job().items() if k != "steps"},
                  "missing end": {**synthetic_job(), "completed_at": None},
                  "bad time": {**synthetic_job(), "started_at": "yesterday"}}
        for name, job in broken.items():
            with self.subTest(name=name):
                self.assertEqual({UPGRADE_JOB: "unreadable"}, self.kinds([job]))
                self.assertFalse(self.decide([job], 1)[0])

    def test_jobs_that_succeeded_were_skipped_or_still_run_are_no_failures(self):
        jobs = [passed_job(), synthetic_job(conclusion="skipped"), synthetic_job(conclusion="neutral"),
                synthetic_job(conclusion=None, status="in_progress")]
        self.assertEqual({}, self.kinds(jobs))
        retry, reason = self.decide(jobs, 1)
        self.assertFalse(retry)
        self.assertIn("no failed job", reason)

    def test_a_job_that_is_still_running_does_not_hide_a_lost_runner(self):
        jobs = [synthetic_job(), synthetic_job(name="Classify the upgrade failure", conclusion=None, status="in_progress", job_id=4004)]
        self.assertTrue(self.decide(jobs, 1, {1001: [LOST_NOTE]})[0])


class AnnotationReadTests(unittest.TestCase):
    """`read_annotations` and the command line: the read goes through `gh` and fails closed."""

    def run_gh(self, answer, **extra):
        class Done:
            returncode = extra.get("returncode", 0)
            stdout = json.dumps(answer)
        with patch.dict("os.environ", {"GITHUB_REPOSITORY": "example/repository"}), \
                patch.object(release_upgrade.subprocess, "run", return_value=Done) as run:
            return release_upgrade.read_annotations(1001), run

    def test_the_annotations_come_from_the_check_run_of_the_job_and_all_pages_are_joined(self):
        notes, run = self.run_gh([[LOST_NOTE], [DISK_NOTE]])
        self.assertEqual([LOST_NOTE, DISK_NOTE], notes)
        command = run.call_args.args[0]
        self.assertEqual(["gh", "api", "--paginate", "--slurp"], command[:4])
        self.assertEqual("repos/example/repository/check-runs/1001/annotations?per_page=100", command[4])
        self.assertEqual(release_upgrade.ANNOTATION_READ_SECONDS, run.call_args.kwargs["timeout"])

    def test_a_failed_read_raises(self):
        with self.assertRaises(release_upgrade.UpgradeError):
            self.run_gh([], returncode=1)

    def fake_gh(self, root, answers):
        """A `gh` that answers with the annotations of the job id in its last argument and fails for an id without an answer."""
        (root / "bin").mkdir()
        script = root / "bin" / "gh"
        script.write_text('#!/usr/bin/env bash\nfor last; do :; done\nid=${last#*check-runs/}\nid=${id%%/*}\n'
                          '[[ -f "$FAKE_ANSWERS/$id.json" ]] || exit 1\ncat "$FAKE_ANSWERS/$id.json"\n')
        script.chmod(0o755)
        (root / "answers").mkdir()
        for job_id, notes in answers.items():
            (root / "answers" / f"{job_id}.json").write_text(json.dumps([notes]))
        return {"PATH": f"{root / 'bin'}:/usr/bin:/bin", "FAKE_ANSWERS": str(root / "answers"),
                "GITHUB_REPOSITORY": "example/repository", "GITHUB_OUTPUT": str(root / "output"),
                "GITHUB_STEP_SUMMARY": str(root / "summary")}

    def classify(self, jobs, answers, attempt="1"):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            env = self.fake_gh(root, answers)
            (root / "jobs.json").write_text(json.dumps([{"total_count": len(jobs), "jobs": jobs}]))
            completed = subprocess.run([sys.executable, str(Path(release_upgrade.__file__)), "--classify-jobs",
                                        str(root / "jobs.json"), attempt], capture_output=True, text=True, env=env)
            self.assertEqual(0, completed.returncode, completed.stderr)
            return (root / "output").read_text().splitlines(), (root / "summary").read_text()

    def test_cli_retries_the_real_lost_runner_and_names_it(self):
        job, notes = real("lost_runner")
        output, summary = self.classify([job], {job["id"]: notes})
        self.assertIn("retry=true", output)
        self.assertIn("lost its runner", summary)

    def test_cli_names_the_full_disk_of_the_real_job_and_does_not_retry(self):
        job, notes = real("disk_full")
        output, summary = self.classify([job], {job["id"]: notes})
        self.assertIn("retry=false", output)
        self.assertIn("runner disk", summary)
        self.assertNotIn("lost its runner", summary)

    def test_cli_does_not_retry_when_the_annotation_read_fails(self):
        job, _ = real("lost_runner")
        output, summary = self.classify([job], {})
        self.assertIn("retry=false", output)
        self.assertIn("do not name a lost runner", summary)

    def test_cli_reports_the_class_of_each_failed_job_and_the_decision(self):
        for jobs, answers, retry, text in (([passed_job(), synthetic_job()], {1001: [LOST_NOTE]}, "true", "lost its runner"),
                                           (json.loads(RECORDED_JOBS.read_text())["jobs"], {}, "false", "step failed")):
            with self.subTest(retry=retry):
                output, summary = self.classify(jobs, answers)
                self.assertIn(f"retry={retry}", output)
                self.assertIn(text, summary)

    def test_cli_refuses_jobs_that_cannot_be_read(self):
        script = Path(release_upgrade.__file__)
        for name, content, attempt in (("not json", "nope", "1"), ("no jobs key", "[{}]", "1"), ("not a list", "{}", "1"), ("job is not an object", '[{"jobs": ["x"]}]', "1"),
                                       ("attempt", "[]", "first")):
            with self.subTest(name=name), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                (root / "jobs.json").write_text(content)
                completed = subprocess.run([sys.executable, str(script), "--classify-jobs", str(root / "jobs.json"), attempt],
                                           capture_output=True, text=True,
                                           env={"GITHUB_OUTPUT": str(root / "output"), "GITHUB_STEP_SUMMARY": str(root / "summary")})
                self.assertEqual(1, completed.returncode)
                self.assertIn("could not be read", (root / "summary").read_text())
                self.assertFalse((root / "output").exists())


if __name__ == "__main__":
    unittest.main()
