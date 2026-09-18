#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
source "$ROOT/scripts/build-paths.sh"
DERIVED_DATA="${ENCRYPTED_MEMORIES_IOS_TEST_DERIVED_DATA:-$ENCRYPTED_MEMORIES_BUILD_ROOT/DD.tests.ios.noindex}"
# The runner image decides which iPhone simulators exist, and Apple renames the lineup every year. A
# pinned device name therefore fails as "Unable to find a device matching the provided destination
# specifier" on a new image. Resolve an installed iPhone instead; IOS_TEST_DESTINATION still overrides it.
resolve_iphone_simulator() {
  xcrun simctl list devices available --json | python3 -c '
import json, re, sys

preferred = ["iPhone 17 Pro", "iPhone 17 Pro Max", "iPhone 17"]
names = {
    device["name"]
    for devices in json.load(sys.stdin)["devices"].values()
    for device in devices
    if device.get("isAvailable") and device["name"].startswith("iPhone")
}
for name in preferred:
    if name in names:
        print(name)
        raise SystemExit

def rank(name):
    model = re.search(r"\d+", name)
    return (int(model.group()) if model else 0, "Pro" in name, "Max" in name, name)

print(max(names, key=rank) if names else "")
'
}

if [[ -n "${IOS_TEST_DESTINATION:-}" ]]; then
  DESTINATION="$IOS_TEST_DESTINATION"
else
  SIMULATOR_NAME="$(resolve_iphone_simulator)"
  if [[ -z "$SIMULATOR_NAME" ]]; then
    echo "[ios-tests] no available iPhone simulator; install an iOS runtime or set IOS_TEST_DESTINATION." >&2
    exit 69
  fi
  DESTINATION="platform=iOS Simulator,name=$SIMULATOR_NAME,OS=latest"
fi
export DEVELOPER_DIR

encryptedmemories_acquire_build_lock "verify-ios-app-tests"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "[ios-tests] xcodegen is required to generate EncryptedMemories.xcodeproj." >&2
  exit 69
fi

echo "[ios-tests] generating project"
(cd "$ROOT" && xcodegen generate)
encryptedmemories_pin_generated_project_packages "$ROOT"

echo "[ios-tests] resolving pinned packages into shared cache"
xcrun xcodebuild \
  -resolvePackageDependencies \
  -project "$ROOT/EncryptedMemories.xcodeproj" \
  -scheme EncryptedMemoriesMobileTests \
  -clonedSourcePackagesDirPath "$ENCRYPTED_MEMORIES_XCODE_SOURCE_PACKAGES" \
  -packageCachePath "$ENCRYPTED_MEMORIES_XCODE_PACKAGE_CACHE" \
  -packageAuthorizationProvider netrc \
  -onlyUsePackageVersionsFromResolvedFile

echo "[ios-tests] destination: $DESTINATION"
xcrun xcodebuild \
  -project "$ROOT/EncryptedMemories.xcodeproj" \
  -scheme EncryptedMemoriesMobileTests \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED_DATA" \
  -clonedSourcePackagesDirPath "$ENCRYPTED_MEMORIES_XCODE_SOURCE_PACKAGES" \
  -packageCachePath "$ENCRYPTED_MEMORIES_XCODE_PACKAGE_CACHE" \
  -disableAutomaticPackageResolution \
  -skipPackagePluginValidation \
  CODE_SIGNING_ALLOWED=NO \
  test
