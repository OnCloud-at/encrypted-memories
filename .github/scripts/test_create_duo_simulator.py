#!/usr/bin/env python3
"""Tests for create_duo_simulator.py with a stub `xcrun` that answers the three simctl calls."""
import json
import os
import pathlib
import stat
import subprocess
import sys
import tempfile
import unittest

SCRIPT = pathlib.Path(__file__).with_name("create_duo_simulator.py")
UDID = "11111111-2222-3333-4444-555555555555"
DUO_TYPE = {"name": "iPhone Duo", "identifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-Duo"}


def runtime(version="27.1", build="24B1", available=True, platform="iOS", types=("iPhone Duo",)):
    return {
        "isAvailable": available,
        "platform": platform,
        "version": version,
        "buildversion": build,
        "identifier": "com.apple.CoreSimulator.SimRuntime.iOS-" + build,
        "supportedDeviceTypes": [{"name": name} for name in types],
    }


class CreateDuoSimulatorTests(unittest.TestCase):
    def run_script(self, types, runtimes, create_fails=False):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            (root / "types.json").write_text(json.dumps({"devicetypes": types}))
            (root / "runtimes.json").write_text(json.dumps({"runtimes": runtimes}))
            stub = root / "xcrun"
            stub.write_text(
                "#!/usr/bin/env bash\n"
                'case "$*" in\n'
                '  "simctl list devicetypes -j") cat "$STUB_DIR/types.json" ;;\n'
                '  "simctl list runtimes -j") cat "$STUB_DIR/runtimes.json" ;;\n'
                '  simctl\\ create*) [[ -n "$STUB_FAIL" ]] && exit 1; echo "$*" > "$STUB_DIR/create.txt"; echo ' + UDID + " ;;\n"
                "  *) exit 2 ;;\n"
                "esac\n"
            )
            stub.chmod(stub.stat().st_mode | stat.S_IXUSR)
            env = dict(os.environ, PATH=f"{directory}:{os.environ['PATH']}", STUB_DIR=directory)
            if create_fails:
                env["STUB_FAIL"] = "1"
            result = subprocess.run(
                [sys.executable, "-B", str(SCRIPT), "--name", "Test Duo"], env=env, capture_output=True, text=True
            )
            created = (root / "create.txt").read_text().strip() if (root / "create.txt").exists() else None
            return result, created

    def test_creates_the_simulator_on_the_newest_matching_runtime_and_prints_its_udid(self):
        result, created = self.run_script([DUO_TYPE], [runtime(build="24B5"), runtime(build="24B10")])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), UDID)
        # 24B10 is newer than 24B5; a plain string comparison would pick 24B5.
        self.assertIn("iOS-24B10", created)
        self.assertIn("Test Duo", created)
        self.assertIn(DUO_TYPE["identifier"], created)

    def test_a_runner_without_a_usable_duo_simulator_prints_nothing_and_exits_zero(self):
        cases = {
            "no Duo device type": ([], [runtime()]),
            "no runtime": ([DUO_TYPE], []),
            "another major version": ([DUO_TYPE], [runtime(version="26.4")]),
            "27.10 is not 27.1": ([DUO_TYPE], [runtime(version="27.10")]),
            "runtime not available": ([DUO_TYPE], [runtime(available=False)]),
            "another platform": ([DUO_TYPE], [runtime(platform="watchOS")]),
            "runtime without the Duo type": ([DUO_TYPE], [runtime(types=("iPhone 17",))]),
        }
        for name, (types, runtimes) in cases.items():
            with self.subTest(name):
                result, created = self.run_script(types, runtimes)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), "")
                self.assertIsNone(created)

    def test_a_patch_runtime_of_27_1_matches(self):
        result, _ = self.run_script([DUO_TYPE], [runtime(version="27.1.2")])
        self.assertEqual(result.stdout.strip(), UDID)

    def test_a_failed_simulator_creation_fails_the_script(self):
        result, _ = self.run_script([DUO_TYPE], [runtime()], create_fails=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout.strip(), "")


if __name__ == "__main__":
    unittest.main()
