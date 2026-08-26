#!/usr/bin/env bash

if [[ -n "${ENCRYPTED_MEMORIES_BUILD_PATHS_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
ENCRYPTED_MEMORIES_BUILD_PATHS_LOADED=1

ENCRYPTED_MEMORIES_BUILD_ROOT="${ENCRYPTED_MEMORIES_BUILD_ROOT:-$HOME/Developer/xcode/EncryptedMemories}"
ENCRYPTED_MEMORIES_SWIFTPM_CACHE="${ENCRYPTED_MEMORIES_SWIFTPM_CACHE:-$ENCRYPTED_MEMORIES_BUILD_ROOT/SwiftPMCache.noindex}"
ENCRYPTED_MEMORIES_SPM_SCRATCH="${ENCRYPTED_MEMORIES_SPM_SCRATCH:-$ENCRYPTED_MEMORIES_BUILD_ROOT/SPM.noindex}"
ENCRYPTED_MEMORIES_SDK_SCRATCH="${ENCRYPTED_MEMORIES_SDK_SCRATCH:-$ENCRYPTED_MEMORIES_BUILD_ROOT/SDK.noindex}"
ENCRYPTED_MEMORIES_XCODE_SOURCE_PACKAGES="${ENCRYPTED_MEMORIES_XCODE_SOURCE_PACKAGES:-$ENCRYPTED_MEMORIES_BUILD_ROOT/SourcePackages.noindex}"
ENCRYPTED_MEMORIES_XCODE_PACKAGE_CACHE="${ENCRYPTED_MEMORIES_XCODE_PACKAGE_CACHE:-$ENCRYPTED_MEMORIES_BUILD_ROOT/XcodePackageCache.noindex}"

export ENCRYPTED_MEMORIES_BUILD_ROOT
export ENCRYPTED_MEMORIES_SWIFTPM_CACHE
export ENCRYPTED_MEMORIES_SPM_SCRATCH
export ENCRYPTED_MEMORIES_SDK_SCRATCH
export ENCRYPTED_MEMORIES_XCODE_SOURCE_PACKAGES
export ENCRYPTED_MEMORIES_XCODE_PACKAGE_CACHE

encryptedmemories_acquire_build_lock() {
  local label="${1:-build}"
  local lock_dir="$ENCRYPTED_MEMORIES_BUILD_ROOT/.active-build"
  local owner_file="$lock_dir/owner"

  mkdir -p "$ENCRYPTED_MEMORIES_BUILD_ROOT"
  if ! mkdir "$lock_dir" 2>/dev/null; then
    if [[ -d "$lock_dir" ]]; then
      echo "Build root is already in use; do not create a second scratch path." >&2
      if [[ -f "$owner_file" ]]; then
        echo "Current owner: $(<"$owner_file")" >&2
      fi
      echo "Wait for that build to finish, then rerun this command." >&2
      return 75
    fi

    echo "Cannot create the build lock at $lock_dir." >&2
    echo "Check that the canonical build root is writable; do not fall back to another scratch path." >&2
    return 73
  fi

  printf 'pid=%s command=%s started=%s\n' "$$" "$label" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$owner_file"
  ENCRYPTED_MEMORIES_BUILD_LOCK_DIR="$lock_dir"
  trap encryptedmemories_release_build_lock EXIT
}

encryptedmemories_release_build_lock() {
  if [[ -n "${ENCRYPTED_MEMORIES_BUILD_LOCK_DIR:-}" ]]; then
    rm -rf -- "$ENCRYPTED_MEMORIES_BUILD_LOCK_DIR"
    ENCRYPTED_MEMORIES_BUILD_LOCK_DIR=""
  fi
}

encryptedmemories_pin_generated_project_packages() {
  local root="$1"
  local photos_lock="$root/Packages/EncryptedMemoriesKit/Package.resolved"
  local sdk_lock="$root/Vendor/sdk-swift/Package.resolved"
  local project_destination="$root/EncryptedMemories.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
  local workspace_destination="$root/EncryptedMemories.xcworkspace/xcshareddata/swiftpm/Package.resolved"

  for lock_file in "$photos_lock" "$sdk_lock"; do
    if [[ ! -f "$lock_file" ]]; then
      echo "Missing package lock file: $lock_file" >&2
      return 66
    fi
  done

  python3 "$root/scripts/merge-package-resolved.py" \
    "$photos_lock" \
    "$sdk_lock" \
    "$project_destination"
  mkdir -p "$(dirname "$workspace_destination")"
  cp "$project_destination" "$workspace_destination"
}
