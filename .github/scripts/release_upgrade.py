#!/usr/bin/env python3
"""Select published upgrade sources and validate a deliberate release override."""

import argparse
from datetime import datetime
import json
import html
import math
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys


class UpgradeError(ValueError):
    """Release metadata or upgrade evidence cannot authorize an upload."""


# v1.0.5 was the first public App Store version. Earlier releases were admission tests.
OLDEST_SUPPORTED_STABLE = "v1.0.5"
# Beta 2 had only testers and predates the test entry. Stable sources cannot use this exception.
PREVIOUS_BETA_WITHOUT_ENTRY = frozenset({"v1.1.0-beta.2"})

# A hosted job stops after 180 minutes. A job may plan at most this long, which keeps a margin for a slow runner.
JOB_BUDGET_MINUTES = 165
# One hosted cold export/import sample, run 43908282083. These are floors, not variance margins.
IOS_26_PROVISION_MINUTES = 236 / 60
IOS_26_PROVISION_GIB = 8573672 / 1048576
CONFIG = json.loads(Path(__file__).with_name("release_upgrade_config.json").read_text())
PINS = {(item["platform"], item["os"], item["device"]): item for item in CONFIG["configurations"]}


def validate_pins(pins):
    """Every iOS configuration states `newest_runtime`; exactly one sets it. That one is the local default pin and the
    only job that must run on the newest runtime of its major version. A new configuration without the field fails
    when this module loads."""
    ios = [key for key in pins if key[0] == "iOS"]
    for key in ios:
        if not isinstance(pins[key].get("newest_runtime"), bool):
            raise UpgradeError(f"newest_runtime must be true or false for {key} in release_upgrade_config.json")
    if sum(pins[key]["newest_runtime"] for key in ios) != 1:
        raise UpgradeError("Exactly one iOS configuration must set newest_runtime in release_upgrade_config.json")


validate_pins(PINS)
CONFIGURATIONS = tuple(PINS)
DEVICE_NAMES = CONFIG["devices"]
# A job needs: builds + cases = BUILD_MINUTES_PER_SOURCE x sources + CASE_MINUTES x sources x points of the job.
# Measured on the hosted runner (v1.1.0-rc.1, run 38202469938, two sources, and v1.1.0, run 38307297868, one source):
#   iOS case: mean 6.6 to 7.6 minutes per job (slowest job mean 454 s), slowest single case 653 s (10.9 minutes).
#   iOS builds and set-up: 9.6 minutes for one source, 18.5 and 25.6 minutes for two sources (9 to 13 per source).
#   macOS case: mean 48 to 59 seconds (slowest single case 115 s); builds and set-up: 8.0 minutes for one source,
#   about 25 minutes for two sources (up to 13 per source).
# The constants are estimates from the job means of these two releases (cache-miss builds in the two-source run): iOS case
# 8.0, macOS case 1.5, builds 12.0 minutes per source. The measured maxima are higher: a build and set-up residual of up to
# 12.8 (iOS) and 12.4 (macOS) minutes per source, a slowest point mean of 9.2 minutes per iOS case (model.installRecord:
# 653 and 455 seconds), and a slowest single case of 10.9 minutes. The check at 165 minutes keeps a margin against the
# estimate only; a job that concentrates slow points, or a slower runner, can use more of its 180-minute timeout.
# The disk bounds a job below the time budget. Each case ends with `simctl delete` of its simulator, and macOS moves that
# device's data into `Deleting-<uuid>` directories of TMPDIR that a system process empties asynchronously (#1008). The
# journey keeps nothing in TMPDIR. A hosted runner under load emptied them too slowly: in run 41098205915 a shard grew
# TMPDIR from 0 to 8.6 GiB and lost 10.9 GiB of free disk over its 24 cases (about 0.5 GiB per case; #498 measured up to
# 0.9 GiB per case), starting from 26.0 to 26.5 GiB free after the builds. About 28 cases therefore fill the disk, and
# the time budget plans fewer: at most 19, 16, 15 or 12 cases per job for one to four sources.
BUILD_MINUTES_PER_SOURCE = {"iOS": 12.0, "macOS": 12.0}
CASE_MINUTES = {"iOS": 8.0, "macOS": 1.5}
# A release with one source would fit one iOS job (about 108 planned minutes). Two jobs halve the wall-clock time of the
# gate for about one more build of runner time.
MIN_IOS_JOBS = 2
# GitHub accepts at most 256 jobs from one matrix.
MAX_MATRIX_JOBS = 256
# The journey prints its points at once; a longer run is a hang, not a slow list.
LIST_POINTS_TIMEOUT_SECONDS = 30

TAG = re.compile(r"v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-(beta|rc)\.([1-9][0-9]*))?\Z")


def published_release(payload):
    tag = payload.get("tag_name", "")
    match = TAG.fullmatch(tag)
    if not match:
        raise UpgradeError("Invalid app release tag")
    prerelease = payload.get("prerelease")
    if type(prerelease) is not bool or prerelease != (match[4] is not None):
        raise UpgradeError(f"Prerelease flag disagrees with {tag}")
    if payload.get("draft") is not False or not payload.get("published_at"):
        raise UpgradeError(f"Release {tag} is not published")
    try:
        timestamp = datetime.fromisoformat(payload["published_at"].replace("Z", "+00:00"))
        if timestamp.tzinfo is None:
            raise ValueError("Timestamp has no time zone")
    except (TypeError, ValueError) as error:
        raise UpgradeError(f"Invalid publication time for {tag}") from error
    version = tuple(int(match[i]) for i in (1, 2, 3))
    # A stable release follows every beta and release candidate of its version.
    order = (*version, {"beta": 0, "rc": 1, None: 2}[match[4]], int(match[5] or 0))
    return tag, version, match[4], order, timestamp


def select_sources(target, history):
    target_tag, _, target_channel, target_order, target_time = published_release(target)
    if not isinstance(history, list):
        raise UpgradeError("Release history must contain every API page")
    releases = {}
    for payload in history:
        if payload.get("draft") is True or not payload.get("published_at"):
            continue
        # Model releases in this repository are not app upgrade sources.
        if not payload.get("tag_name", "").startswith("v"):
            continue
        parsed = published_release(payload)
        if parsed[0] in releases:
            raise UpgradeError(f"Duplicate published release tag {parsed[0]}")
        releases[parsed[0]] = parsed
    if releases.get(target_tag) != published_release(target):
        raise UpgradeError("Target release is absent or differs from the complete release history")
    predecessors = [r for r in releases.values() if r[3] < target_order and r[4] <= target_time]
    floor = tuple(map(int, OLDEST_SUPPORTED_STABLE[1:].split(".")))
    stable = sorted((r for r in predecessors if r[2] is None and r[1] >= floor), key=lambda r: r[3])
    result = [r[0] for r in stable]
    if target_channel is not None:
        betas = [r for r in predecessors if r[2] == "beta" and r[1] >= floor]
        if betas:
            result.append(max(betas, key=lambda r: (r[4], r[3]))[0])
    return result


def select_plan(target, history):
    selected = select_sources(target, history)
    untested = [tag for tag in selected if TAG.fullmatch(tag)[4] == "beta" and tag in PREVIOUS_BETA_WITHOUT_ENTRY]
    return {"sources": [tag for tag in selected if tag not in untested], "untested": untested}


def journey_points(journey):
    """The interruption points of the journey: its one list."""
    try:
        result = subprocess.run([sys.executable, str(journey), "--list-points"], capture_output=True, text=True,
                                timeout=LIST_POINTS_TIMEOUT_SECONDS)
    except subprocess.TimeoutExpired as error:
        raise UpgradeError(
            f"The journey did not list its interruption points within {LIST_POINTS_TIMEOUT_SECONDS} seconds") from error
    except OSError as error:
        raise UpgradeError(f"The journey could not be started: {error}") from error
    points = result.stdout.split()
    if result.returncode or not points or len(set(points)) != len(points):
        raise UpgradeError(f"The journey lists no usable interruption points: {result.stderr.strip()[-200:]}")
    return points


def job_minutes(platform, source_count, point_count):
    return BUILD_MINUTES_PER_SOURCE[platform] * source_count + CASE_MINUTES[platform] * source_count * point_count


def shard_count(platform, source_count, point_count, provisioning):
    """The fewest jobs of one configuration so that each job, with every source, fits the time budget and the disk limit.

    The iOS gate never runs in fewer than MIN_IOS_JOBS jobs, but never in more jobs than points, so every job holds at
    least one point: with one point a single job is planned."""
    if not provisioning:
        raise UpgradeError("Provisioning capacity is required for each job")
    if any(isinstance(value, bool) or not isinstance(value, int) or value < 1
           for value in (source_count, point_count)):
        raise UpgradeError("Source and interruption point counts must be positive integers")
    key = validate_configuration(provisioning)
    if key[0] != platform:
        raise UpgradeError("Provisioning platform does not match the requested platform")
    minimum = max(1, min(MIN_IOS_JOBS, point_count)) if platform == "iOS" else 1
    for count in range(minimum, point_count + 1):
        largest = math.ceil(point_count / count)
        minutes = job_minutes(platform, source_count, largest) + provisioning["provision_minutes"]
        disk_fits = (provisioning["peak_gib"] + provisioning["case_gib"] * source_count * largest
                     <= provisioning["available_gib"])
        if minutes <= JOB_BUDGET_MINUTES and disk_fits:
            return count
    minimum_minutes = job_minutes(platform, source_count, 1) + provisioning["provision_minutes"]
    if minimum_minutes > JOB_BUDGET_MINUTES:
        raise UpgradeError(f"One interruption point of {source_count} sources needs {minimum_minutes:.0f} minutes on {platform}, more than the {JOB_BUDGET_MINUTES} minutes that a job may plan")
    raise UpgradeError(f"One interruption point of {source_count} sources exceeds the disk budget on {platform}")


def upgrade_matrix(sources, points, override=None):
    """Each device and OS configuration tests every source and covers every point once.

    The capacity of each configuration comes from release_upgrade_config.json; `override` is the optional list of
    RELEASE_UPGRADE_PROVISIONING objects that replace it for the configurations they name."""
    if not points:
        raise UpgradeError("There is no interruption point to plan")
    for name, values in (("source", sources), ("interruption point", points)):
        if (not isinstance(values, (list, tuple)) or
                any(not isinstance(value, str) or not value.strip() or value != value.strip() or
                    any(character.isspace() for character in value) for value in values) or
                len(set(values)) != len(values)):
            raise UpgradeError(f"Invalid or duplicate {name}")
    provisioning = validate_provisioning(override)
    include = []
    for platform, os_version, device in CONFIGURATIONS:
        config = provisioning[(platform, os_version, device)]
        count = shard_count(platform, max(1, len(sources)), len(points), config)
        size, extra = divmod(len(points), count)
        start = 0
        for index in range(count):
            end = start + size + (1 if index < extra else 0)
            job = {"platform": platform, "os": os_version, "device": device,
                   "shard": f"{index + 1}-of-{count}", "points": " ".join(points[start:end])}
            pin = PINS[(platform, os_version, device)]
            job.update({key: pin.get(key, "") for key in ("runner", "runtime_version", "runtime_build")})
            job["runtime_id"] = ("com.apple.CoreSimulator.SimRuntime.iOS-" + pin["runtime_version"].replace(".", "-")) if platform == "iOS" else ""
            job["available_gib"] = config["available_gib"]
            cases = max(1, len(sources)) * (end - start)
            job["planned_minutes"] = job_minutes(platform, max(1, len(sources)), end - start) + config["provision_minutes"]
            job["planned_peak_gib"] = config["peak_gib"] + config["case_gib"] * cases
            job["capacity_evidence"] = config["evidence"]
            job["capacity_source"] = config["source"]
            include.append(job)
            start = end
    if len(include) > MAX_MATRIX_JOBS:
        raise UpgradeError(f"The plan needs {len(include)} jobs, more than the {MAX_MATRIX_JOBS} that GitHub accepts")
    return {"include": include}


def unbudgeted_matrix(points):
    """One job per configuration when a deliberate override cannot plan the journey."""
    return {"include": [{"platform": platform, "os": os_version, "device": device, "runner": PINS[(platform, os_version, device)]["runner"],
                         "shard": "1-of-1", "points": " ".join(points)}
                        for platform, os_version, device in CONFIGURATIONS]}


def validate_configuration(item):
    if not isinstance(item, dict):
        raise UpgradeError("Invalid provisioning configuration")
    if item.get("platform") not in ("iOS", "macOS"):
        raise UpgradeError("The provisioning field platform must be \"iOS\" or \"macOS\"")
    if not isinstance(item.get("os"), str):
        raise UpgradeError("The provisioning field os must be a JSON string, for example \"26\"")
    if (item["platform"] == "macOS") != (item.get("device") is None):
        raise UpgradeError("The provisioning field device must be null for macOS and a device name for iOS")
    key = (item["platform"], item["os"], item["device"])
    if key not in CONFIGURATIONS:
        raise UpgradeError("Unknown provisioning configuration")
    for field in ("provision_minutes", "available_gib", "peak_gib", "case_gib"):
        value = item.get(field)
        try:
            valid = not isinstance(value, bool) and isinstance(value, (int, float)) and math.isfinite(value) and value > 0
        except OverflowError:
            valid = False
        if not valid:
            raise UpgradeError(f"Invalid or unknown provisioning {field} for {key}")
    if key[0:2] == ("iOS", "26") and (item["provision_minutes"] < IOS_26_PROVISION_MINUTES or
                                       item["peak_gib"] < IOS_26_PROVISION_GIB):
        raise UpgradeError(f"Provisioning capacity for {key} is below the measured iOS 26 sample")
    permitted = {"platform", "os", "device", "provision_minutes", "available_gib", "peak_gib", "case_gib", "evidence",
                 "source"}
    if set(item) - permitted:
        raise UpgradeError(f"Capacity inputs cannot override a checked-in pin for {key}")
    if not isinstance(item.get("evidence"), str) or not item["evidence"].strip():
        raise UpgradeError(f"Invalid or unknown provisioning evidence for {key}")
    return key


CAPACITY_FIELDS = ("provision_minutes", "available_gib", "peak_gib", "case_gib")
# "measured": measured on this configuration. "measured on another runtime": measured on a runtime that the pin replaced.
BASES = frozenset({"measured", "measured on another runtime", "estimated"})
PINNED_SOURCE = "release_upgrade_config.json"
OVERRIDE_SOURCE = "RELEASE_UPGRADE_PROVISIONING"


def pinned_capacity(key):
    """The checked-in capacity of one configuration, with the basis of each number (see BASES)."""
    capacity = PINS[key].get("capacity")
    if (not isinstance(capacity, dict) or not isinstance(capacity.get("basis"), dict) or
            set(capacity["basis"]) != set(CAPACITY_FIELDS) or
            not set(capacity["basis"].values()) <= BASES):
        raise UpgradeError(f"Provisioning capacity is required for {key} in release_upgrade_config.json")
    item = {"platform": key[0], "os": key[1], "device": key[2], "evidence": capacity.get("evidence")}
    item.update({field: capacity.get(field) for field in CAPACITY_FIELDS})
    validate_configuration(item)
    item["source"] = PINNED_SOURCE + " (" + ", ".join(f"{field} {capacity['basis'][field]}" for field in CAPACITY_FIELDS) + ")"
    return item


def validate_provisioning(override=None):
    """The capacity of every configuration: the checked-in values, replaced by the optional override objects."""
    if override is not None and not isinstance(override, list):
        raise UpgradeError("The provisioning override must be a JSON array")
    supplied = {}
    for item in override or []:
        if isinstance(item, dict) and "source" in item:
            raise UpgradeError("The provisioning override cannot set its own source")
        key = validate_configuration(item)
        if key in supplied:
            raise UpgradeError("Duplicate provisioning configuration")
        supplied[key] = dict(item, source=OVERRIDE_SOURCE + " (all numbers supplied)")
    return {key: supplied.get(key) or pinned_capacity(key) for key in CONFIGURATIONS}


def plan_matrix(sources, points, overridden, provisioning=None):
    # `provisioning` is the optional RELEASE_UPGRADE_PROVISIONING override; None uses the checked-in capacity.
    """The matrix and a note. A deliberate override keeps its escape path: a plan that does not fit falls back."""
    try:
        return upgrade_matrix(sources, points, provisioning), None
    except UpgradeError as error:
        if not overridden:
            raise
        return unbudgeted_matrix(points), (
            f"Override: {error}. The plan falls back to one job per configuration with every point; the journey steps "
            "are skipped by the override, so the jobs only acknowledge it.")


def validate_override(event, ref, tag, confirmation, reason):
    if not confirmation and not reason:
        return False
    if event != "workflow_dispatch" or ref != "refs/heads/main":
        raise UpgradeError("Only a manual run from main can override the upgrade check")
    if confirmation != tag or not reason.strip():
        raise UpgradeError("An override requires the exact release tag and a nonempty reason")
    if len(reason) > 500 or any(ord(c) < 32 for c in reason):
        raise UpgradeError("The override reason must be one printable line of at most 500 characters")
    return True


def report(message):
    print(message, flush=True)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as summary:
            summary.write(message + "\n\n")


def main():
    if len(sys.argv) == 4 and sys.argv[1] == "--check-free-disk":
        try:
            minimum = float(sys.argv[3])
        except ValueError as error:
            raise UpgradeError("The free-disk minimum must be a positive number") from error
        if not math.isfinite(minimum) or minimum <= 0:
            raise UpgradeError("The free-disk minimum must be a positive number")
        available = shutil.disk_usage(sys.argv[2]).free / (1024 ** 3)
        if available < minimum:
            raise UpgradeError(f"Insufficient free disk: {available:.1f} GiB available, {minimum:.1f} GiB required")
        report(f"Free disk: {available:.1f} GiB; required minimum {minimum:.1f} GiB")
        return
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--release", type=Path, required=True)
    parser.add_argument("--history", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--event", default="release")
    parser.add_argument("--ref", default="")
    parser.add_argument("--override-tag", default="")
    parser.add_argument("--override-reason", default="")
    parser.add_argument("--journey", type=Path,
                        default=Path(__file__).resolve().parents[2] / "scripts/upgrade-test/run_journey.py")
    args = parser.parse_args()
    target = json.loads(args.release.read_text())
    selection = select_plan(target, json.loads(args.history.read_text()))
    overridden = validate_override(args.event, args.ref, target["tag_name"],
                                   args.override_tag, args.override_reason)
    try:
        points = journey_points(args.journey)
    except UpgradeError as error:
        if not overridden:
            raise
        # The journey steps are skipped by the override; the matrix only has to exist, so no cost is planned.
        report(f"Override: {error}. The journey steps are skipped by the override, so the jobs only acknowledge it.")
        matrix, note = unbudgeted_matrix([]), None
    else:
        raw_provisioning = os.environ.get("UPGRADE_PROVISIONING")
        try:
            provisioning = json.loads(raw_provisioning) if raw_provisioning else None
        except json.JSONDecodeError as error:
            if not overridden:
                raise UpgradeError(f"Invalid provisioning JSON: {error}") from error
            report(f"Override: invalid provisioning JSON: {error}")
            provisioning = None
        matrix, note = plan_matrix(selection["sources"], points, overridden, provisioning)
    plan = {"target": target["tag_name"], **selection, "matrix": matrix,
            "overridden": overridden, "override_reason": args.override_reason}
    args.output.write_text(json.dumps(plan, indent=2) + "\n")
    if os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a") as output:
            output.write("upgrade_sources=" + json.dumps(selection["sources"]) + "\n")
            output.write("upgrade_overridden=" + str(overridden).lower() + "\n")
            output.write("upgrade_matrix=" + json.dumps(matrix, separators=(",", ":")) + "\n")
    report("Upgrade sources: " + ", ".join(selection["sources"]))
    if note:
        report(note)
    report("Upgrade jobs: " + ", ".join(f"{job['platform']} {job['os']} {job['device'] or 'host'} {job['shard']} ({len(job['points'].split())} points)"
                                         for job in matrix["include"]))
    for job in matrix["include"]:
        if "planned_minutes" in job:
            report(f"Estimated {job['platform']} {job['os']} {job['device'] or 'host'} {job['shard']}: "
                   f"{job['planned_minutes']:.1f} minutes, {job['planned_peak_gib']:.1f} GiB peak, "
                   f"{job['available_gib']:.1f} GiB minimum free. Capacity source: {html.escape(job['capacity_source'])}. "
                   f"Evidence: {html.escape(job['capacity_evidence'])}")
    for tag in selection["untested"]:
        report(f"nicht getestet: {tag} (kein Prüfeinstieg)")
    if overridden:
        report("**Upgrade check deliberately overridden for " + target["tag_name"] + ":** "
               + html.escape(args.override_reason))
        report("**The upgrade gate is off for this release:** no installed-upgrade journey runs, and the upgrade jobs "
               "only acknowledge the override.")


if __name__ == "__main__":
    try:
        main()
    except (UpgradeError, OSError, json.JSONDecodeError) as error:
        report(f"Release upgrade check failed: {error}")
        raise SystemExit(1)
