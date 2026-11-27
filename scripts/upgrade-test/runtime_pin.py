#!/usr/bin/env python3
"""Verify the exported Simulator runtime against the accepted build set of the pin.

xcodebuild -downloadPlatform selects an iOS version, never a build. Apple can serve
more than one build for the same version, even within one release run: shards of
hosted run 45890080546 received 23F73 and 23F77 for iOS 26.5. The release pins one
canonical build and any number of accepted alternatives, and every runtime check
compares against that set. run 45890080546, shards 1 and 4 of the iOS 26 matrix,
exported 23F73 and failed the single-build comparison.
"""
import argparse
import os
from pathlib import Path
import plistlib
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / ".github/scripts"))
from release_upgrade import PINS  # noqa: E402

ENVIRONMENT_KEYS = ('UPGRADE_RUNTIME_ID', 'UPGRADE_RUNTIME_VERSION', 'UPGRADE_RUNTIME_BUILD')


def accepted_builds(build, alternatives):
    """One canonical build plus the alternatives the same OS version resolves to."""
    builds = {build, *(alternatives or [])}
    if '' in builds:
        raise ValueError('The accepted runtime build set contains an empty build')
    return sorted(builds)


def _configured_alternatives(version, build):
    for key, pin in sorted(PINS.items()):
        if key[0] == 'iOS' and pin['runtime_version'] == version and pin['runtime_build'] == build:
            return pin.get('runtime_build_alternatives', [])
    return None


def requested_runtime(environ=None):
    """Read the pin from the environment, or use the local default from the config.

    The accepted build set always comes from release_upgrade_config.json, the reviewed
    source of the pin: the environment names the canonical build and version, and an
    unknown pin falls back to its canonical build alone."""
    environ = os.environ if environ is None else environ
    supplied = [environ.get(key) for key in ENVIRONMENT_KEYS]
    if any(value is not None for value in supplied):
        if not all(supplied):
            raise ValueError('The Simulator runtime identifier, version and build must all be supplied')
        version, build = supplied[1], supplied[2]
        alternatives = _configured_alternatives(version, build)
        return {'identifier': supplied[0], 'version': version, 'buildversion': build,
                'buildversions': accepted_builds(build, [] if alternatives is None else alternatives)}
    local = next(pin for key, pin in PINS.items() if key[0] == 'iOS' and pin.get('newest_runtime'))
    return {'identifier': 'com.apple.CoreSimulator.SimRuntime.iOS-' + local['runtime_version'].replace('.', '-'),
            'version': local['runtime_version'], 'buildversion': local['runtime_build'],
            'buildversions': accepted_builds(local['runtime_build'],
                                             local.get('runtime_build_alternatives', []))}


def select_image(root, expected):
    """Return the single runtime image of the export whose metadata matches the pin set."""
    root = Path(root)
    bundles = list(root.glob('*.exportedBundle'))
    if len(bundles) != 1:
        raise ValueError('Expected exactly one exported Simulator runtime bundle')
    with (bundles[0] / 'ExportedMetadata.plist').open('rb') as stream:
        metadata = plistlib.load(stream)['MobileAssetProperties']
    builds = sorted(expected['buildversions'])
    if (metadata.get('SimulatorVersion') != expected['version']
            or metadata.get('Build') not in expected['buildversions']):
        raise ValueError(f"Exported Simulator runtime {metadata.get('SimulatorVersion')} "
                         f"({metadata.get('Build')}) differs from the accepted builds "
                         f"{expected['version']} ({', '.join(builds)})")
    images = list((bundles[0] / 'Restore').glob('*.dmg'))
    if len(images) != 1:
        raise ValueError('Expected exactly one Simulator runtime image')
    return images[0]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('export_root', help='Directory that xcodebuild -downloadPlatform exported to')
    arguments = parser.parse_args()
    try:
        print(select_image(arguments.export_root, requested_runtime()))
    except ValueError as error:
        sys.exit(str(error))


if __name__ == '__main__':
    main()
