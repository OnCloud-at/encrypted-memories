#!/usr/bin/env python3
"""Create an iPhone Duo simulator for the iOS 27.1 runtime of the pinned Xcode and print its UDID.

Usage: create_duo_simulator.py --name <simulator name>

The script prints nothing and exits 0 when the runner has no available iOS 27.1 runtime that supports the iPhone Duo
device type. The caller decides whether that is a failure: the pull-request Duo job gives advice and skips, the nightly
job fails. A failed `simctl` call exits non-zero. A newer runtime comes with a new Xcode pin and a new constant here.
Both Duo workflows call this script, so the runtime choice exists once.
"""
import argparse
import json
import re
import subprocess
import sys

DEVICE_TYPE = "iPhone Duo"
RUNTIME_VERSION = "27.1"


def simctl(*args):
    return subprocess.run(["xcrun", "simctl", *args], check=True, capture_output=True, text=True).stdout


def version_matches(version):
    """27.1 and 27.1.x match; 27.10 does not."""
    return version == RUNTIME_VERSION or version.startswith(RUNTIME_VERSION + ".")


def build_key(build):
    """Compare build versions by their number and letter groups, so 24B10 sorts above 24B5."""
    return tuple((0, int(part)) if part.isdigit() else (1, part) for part in re.findall(r"\d+|[A-Za-z]+", build))


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--name", required=True)
    arguments = parser.parse_args(argv)

    types = [t for t in json.loads(simctl("list", "devicetypes", "-j"))["devicetypes"] if t["name"] == DEVICE_TYPE]
    runtimes = [
        r
        for r in json.loads(simctl("list", "runtimes", "-j"))["runtimes"]
        if r.get("isAvailable")
        and r.get("platform") == "iOS"
        and version_matches(r["version"])
        and any(t["name"] == DEVICE_TYPE for t in r.get("supportedDeviceTypes", []))
    ]
    if not types or not runtimes:
        return 0
    runtime = max(runtimes, key=lambda r: build_key(r["buildversion"]))
    sys.stderr.write("runtime " + runtime["identifier"] + " build " + runtime["buildversion"] + "\n")
    print(simctl("create", arguments.name, types[0]["identifier"], runtime["identifier"]).strip())
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
