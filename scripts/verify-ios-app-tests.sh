#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
source "$ROOT/scripts/build-paths.sh"
DERIVED_DATA="${ENCRYPTED_MEMORIES_IOS_TEST_DERIVED_DATA:-$ENCRYPTED_MEMORIES_BUILD_ROOT/DD.tests.ios.noindex}"
DESTINATION="${IOS_TEST_DESTINATION:-platform=iOS Simulator,name=iPhone 17 Pro,OS=latest}"
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
