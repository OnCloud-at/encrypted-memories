#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
source "$ROOT/scripts/build-paths.sh"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$ENCRYPTED_MEMORIES_BUILD_ROOT/DD.noindex}"
export DEVELOPER_DIR

encryptedmemories_acquire_build_lock "verify-macos-app-shell"

cd "$ROOT"
if [[ "${SKIP_XCODEGEN:-0}" != "1" ]]; then
  xcodegen generate >/dev/null
fi
encryptedmemories_pin_generated_project_packages "$ROOT"

xcodebuild -resolvePackageDependencies \
  -project EncryptedMemories.xcodeproj \
  -scheme EncryptedMemories \
  -clonedSourcePackagesDirPath "$ENCRYPTED_MEMORIES_XCODE_SOURCE_PACKAGES" \
  -packageCachePath "$ENCRYPTED_MEMORIES_XCODE_PACKAGE_CACHE" \
  -onlyUsePackageVersionsFromResolvedFile

xcodebuild build \
  -project EncryptedMemories.xcodeproj \
  -scheme EncryptedMemories \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  -clonedSourcePackagesDirPath "$ENCRYPTED_MEMORIES_XCODE_SOURCE_PACKAGES" \
  -packageCachePath "$ENCRYPTED_MEMORIES_XCODE_PACKAGE_CACHE" \
  -disableAutomaticPackageResolution \
  -skipPackagePluginValidation \
  -skipMacroValidation \
  CODE_SIGNING_ALLOWED=NO
