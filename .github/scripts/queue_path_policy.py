"""Choose the macOS jobs for a merge group, from the complete base-to-head diff.

Only non-Swift files under Wiki/ or site/ and exactly README.md or
SECURITY.md are eligible to skip. Every other path runs all macOS jobs.
Empty or unreadable diffs run all macOS jobs.
Renames count both the old and new paths.

The merge queue never runs the iOS UI tests (issues #1134 and #1197): run_ui is always
false, so the UI job and its gate finish as skipped. A person runs the UI tests locally
before a pull request when the change touches a path that the UI tests can observe:
the iOS app and the files that project.yml compiles into it, the UI tests, the vendored
patches, the workflow files, the project and package manifests, the UI test tooling, a
Resources bundle of a package, or a package module that the iOS app or a UI module
reaches (is_ui_relevant). UI_RELEVANT_MODULES
pins that module closure; the test suite recomputes it from Package.swift and
project.yml and fails when it drifted. The log of the policy names the local UI gate
for such a diff. An empty or unreadable diff and every error name it as well: the
decision fails toward more testing. The nightly run on main (issue #1134) and the
release gate (#1166) are the hosted safety net.
"""

import os
import subprocess

# The transitive closure over Packages/EncryptedMemoriesKit/Package.swift of
# the products that project.yml links into EncryptedMemoriesMobile plus every
# package module whose sources import SwiftUI, UIKit or AppKit, with test
# modules (*Tests) removed. An empty tuple disables module matching, which
# makes every Packages path UI-relevant instead of widening a skip.
UI_RELEVANT_MODULES = (
    "AlbumCore",
    "AlbumSyncCore",
    "AlbumsFeature",
    "AppRouteIntents",
    "AppleSecurityCore",
    "DesignSystem",
    "DesignSystemAppKitAdapter",
    "DesignSystemCore",
    "DesignSystemUIKitAdapter",
    "DeviceRootCore",
    "GridCore",
    "LibraryRuntimeAppleAdapter",
    "LibrarySourceRuntime",
    "MLSearchAppleAdapter",
    "MLSearchBackgroundAppleAdapter",
    "MLSearchCore",
    "MLSearchFeature",
    "MapCore",
    "MapFeature",
    "MapUIKitAdapter",
    "MediaByteCache",
    "MediaCache",
    "MediaCacheAppKitAdapter",
    "MediaCacheCore",
    "MediaCacheUIKitAdapter",
    "MediaDecodingCore",
    "MediaFeedCore",
    "MediaLocationCore",
    "MetalGridComposeCore",
    "MetalGridTextureAppKitAdapter",
    "MetalGridTextureCore",
    "MetalGridTextureUIKitAdapter",
    "MetalRenderingCore",
    "PhotoLibraryBackupAdapter",
    "PhotoViewerCore",
    "PhotoViewerFeature",
    "PhotoViewerUIKitAdapter",
    "PhotosCore",
    "PrivacyFeature",
    "ProtonAuth",
    "ProtonDriveBackend",
    "TimelineAppleAdapter",
    "TimelineCore",
    "TimelineFeature",
    "TimelineUIKitAdapter",
    "TimelineUIKitFeature",
    "UploadCore",
    "UploadFeature",
)

# Exact files outside the iOS app whose change the UI tests observe:
# the app manifests that a package hygiene test reads, the Shared resources that
# project.yml compiles into the iOS app (its `sources:` list), the UI test and
# build scripts, and the action that prepares the UI build. A test pins every
# `sources:` entry of the app and UI test targets to this rule.
UI_TOOLING = (
    ".github/actions/prepare-apple-build/action.yml",
    ".github/scripts/queue_path_policy.py",
    ".github/scripts/runner_state.sh",
    ".github/scripts/run_ui_tests_with_retry.sh",
    ".github/scripts/test_queue_path_policy.py",
    ".github/scripts/verify_xcode_toolchain.sh",
    "App/Info.plist",
    "Shared/AppIntents.xcstrings",
    "Shared/PrivacyInfo.xcprivacy",
    "iOSApp/Info.plist",
    "project.yml",
    "scripts/build-paths.sh",
    "scripts/install-xcodegen.sh",
    "scripts/update-proton-sdk.sh",
    "scripts/verify-ios-app-tests.sh",
)

MANIFEST_BASENAMES = ("Package.swift", "Package.resolved")


def can_skip(paths):
    if not paths:
        return False
    for path in paths:
        if path.lower().endswith('.swift'):
            return False
        if path.startswith(('Wiki/', 'site/')) or path in {'README.md', 'SECURITY.md'}:
            continue
        return False
    return True


def is_ui_relevant(path, modules=None):
    """True when a changed path belongs to the iOS app, the UI tests or their tooling."""
    if modules is None:
        modules = UI_RELEVANT_MODULES
    parts = path.split('/')
    if parts[0] in ('iOSApp', 'iOSUITests', 'VendorPatches'):
        return True
    if len(parts) >= 2 and parts[0] == '.github' and parts[1] == 'workflows':
        return True
    # A name that git printed with surrogate-escaped bytes matches no rule; run.
    if any(0xDC80 <= ord(character) <= 0xDCFF for character in path):
        return True
    if path in UI_TOOLING:
        return True
    if parts[-1] in MANIFEST_BASENAMES:
        return True
    if parts[0] == 'Packages':
        if 'Resources' in parts:
            return True
        if not modules:
            return True
        if len(parts) >= 4 and parts[2] == 'Sources' and parts[3] in modules:
            return True
    return False


def main():
    try:
        diff = subprocess.run(
            ['git', 'diff', '--no-renames', '--name-only', '-z', os.environ['BASE_SHA'], os.environ['HEAD_SHA'], '--'],
            check=True, stdout=subprocess.PIPE,
        ).stdout
        paths = [os.fsdecode(path) for path in diff.split(b'\0') if path]
        skip = can_skip(paths)
        local_ui_gate = not paths or any(is_ui_relevant(path) for path in paths)
    except (KeyError, OSError, subprocess.CalledProcessError):
        skip = False
        local_ui_gate = True
    with open(os.environ['GITHUB_OUTPUT'], 'a', encoding='utf-8') as output:
        output.write(f'run_macos={str(not skip).lower()}\n')
        output.write('run_ui=false\n')
    print('skipped by policy' if skip else 'macOS jobs required')
    if local_ui_gate:
        print('local UI gate applies: the queue does not run the iOS UI tests')


if __name__ == '__main__':
    main()
