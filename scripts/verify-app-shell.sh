#!/usr/bin/env bash
set -euo pipefail

# Builds one app shell without signing. The argument is `ios` or `macos`.
# scripts/verify-ios-app-shell.sh and scripts/verify-macos-app-shell.sh call this script.
case "${1:-}" in
  ios)
    scheme=EncryptedMemoriesMobile
    destination='generic/platform=iOS'
    derived_data_name=DD.ios.noindex
    ;;
  macos)
    scheme=EncryptedMemories
    destination='generic/platform=macOS'
    derived_data_name=DD.noindex
    ;;
  *)
    echo "usage: scripts/verify-app-shell.sh ios | macos" >&2
    exit 64
    ;;
esac

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
source "$ROOT/scripts/build-paths.sh"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$ENCRYPTED_MEMORIES_BUILD_ROOT/$derived_data_name}"
export DEVELOPER_DIR

encryptedmemories_acquire_build_lock "verify-$1-app-shell"

cd "$ROOT"

if [[ "${SKIP_XCODEGEN:-0}" != "1" ]]; then
  xcodegen generate >/dev/null
fi
encryptedmemories_pin_generated_project_packages "$ROOT"

encryptedmemories_resolve_xcode_packages "$scheme" EncryptedMemories.xcodeproj

xcodebuild build \
  -project EncryptedMemories.xcodeproj \
  -scheme "$scheme" \
  -destination "$destination" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  -clonedSourcePackagesDirPath "$ENCRYPTED_MEMORIES_XCODE_SOURCE_PACKAGES" \
  -packageCachePath "$ENCRYPTED_MEMORIES_XCODE_PACKAGE_CACHE" \
  -disableAutomaticPackageResolution \
  -skipPackagePluginValidation \
  -skipMacroValidation \
  CODE_SIGNING_ALLOWED=NO
