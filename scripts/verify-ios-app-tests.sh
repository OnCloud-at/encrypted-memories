#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
source "$ROOT/scripts/build-paths.sh"
DERIVED_DATA="${ENCRYPTED_MEMORIES_IOS_TEST_DERIVED_DATA:-$ENCRYPTED_MEMORIES_BUILD_ROOT/DD.tests.ios.noindex}"
# No argument runs the hosted tests. `ui` runs the UI tests, which launch the app on the offline fixture account and
# tap through it in the simulator.
case "${1:-hosted}" in
  hosted) SCHEME="EncryptedMemoriesMobileTests" ;;
  ui) SCHEME="EncryptedMemoriesMobileUITests" ;;
  *)
    echo "usage: $0 [hosted|ui]" >&2
    exit 64
    ;;
esac
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

# The device that `OS=latest` selects: the simulator with this name on the newest installed iOS runtime.
resolve_simulator_udid() {
  xcrun simctl list devices available --json | python3 -c '
import json, re, sys

name = sys.argv[1]
best = None
for runtime, devices in json.load(sys.stdin)["devices"].items():
    match = re.search(r"\.iOS-([0-9-]+)$", runtime)
    if not match:
        continue
    version = tuple(int(part) for part in match.group(1).split("-"))
    for device in devices:
        if device.get("isAvailable") and device["name"] == name and (best is None or version > best[0]):
            best = (version, device["udid"])
print(best[1] if best else "")
' "$1"
}

if [[ -n "${IOS_TEST_DESTINATION:-}" ]]; then
  DESTINATION="$IOS_TEST_DESTINATION"
else
  SIMULATOR_NAME="$(resolve_iphone_simulator)"
  if [[ -z "$SIMULATOR_NAME" ]]; then
    echo "[ios-tests] no available iPhone simulator; install an iOS runtime or set IOS_TEST_DESTINATION." >&2
    exit 69
  fi
  SIMULATOR_UDID="$(resolve_simulator_udid "$SIMULATOR_NAME")"
  if [[ -n "$SIMULATOR_UDID" ]]; then
    # The booted device and the tested device must be the same, also when two simulators share the name.
    DESTINATION="platform=iOS Simulator,id=$SIMULATOR_UDID"
  else
    echo "[ios-tests] no device ID for $SIMULATOR_NAME; xcodebuild boots the simulator itself."
    DESTINATION="platform=iOS Simulator,name=$SIMULATOR_NAME,OS=latest"
  fi
fi
export DEVELOPER_DIR

encryptedmemories_acquire_build_lock "verify-ios-app-tests ${1:-hosted}"

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
  -scheme "$SCHEME" \
  -clonedSourcePackagesDirPath "$ENCRYPTED_MEMORIES_XCODE_SOURCE_PACKAGES" \
  -packageCachePath "$ENCRYPTED_MEMORIES_XCODE_PACKAGE_CACHE" \
  -packageAuthorizationProvider netrc \
  -onlyUsePackageVersionsFromResolvedFile

# Without this, xcodebuild boots a cold simulator on demand and the first test launches the app while the
# boot still runs; on CI that launch times out ("Failed to get background assertion"). Boot first and wait
# until the boot, data migration included, is complete.
if [[ -n "${SIMULATOR_UDID:-}" ]]; then
  echo "[ios-tests] booting $SIMULATOR_NAME and waiting until it is ready"
  # macOS has no `timeout`; perl's alarm ends a boot that hangs after 10 minutes.
  if ! perl -e 'alarm shift; exec @ARGV' 600 xcrun simctl bootstatus "$SIMULATOR_UDID" -b; then
    echo "[ios-tests] the simulator did not finish booting within 10 minutes." >&2
    exit 1
  fi
fi

echo "[ios-tests] scheme: $SCHEME, destination: $DESTINATION"
xcrun xcodebuild \
  -project "$ROOT/EncryptedMemories.xcodeproj" \
  -scheme "$SCHEME" \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED_DATA" \
  -clonedSourcePackagesDirPath "$ENCRYPTED_MEMORIES_XCODE_SOURCE_PACKAGES" \
  -packageCachePath "$ENCRYPTED_MEMORIES_XCODE_PACKAGE_CACHE" \
  -disableAutomaticPackageResolution \
  -skipPackagePluginValidation \
  CODE_SIGNING_ALLOWED=NO \
  test
