#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
source "$ROOT/scripts/build-paths.sh"
if [[ -n "${ENCRYPTED_MEMORIES_TEST_BUILD_ROOT:-}" ]]; then
  PHOTOS_SCRATCH="$ENCRYPTED_MEMORIES_TEST_BUILD_ROOT/EncryptedMemoriesKit"
  SDK_SCRATCH="$ENCRYPTED_MEMORIES_TEST_BUILD_ROOT/sdk-swift"
else
  PHOTOS_SCRATCH="$ENCRYPTED_MEMORIES_SPM_SCRATCH"
  SDK_SCRATCH="$ENCRYPTED_MEMORIES_SDK_SCRATCH"
fi
export DEVELOPER_DIR

encryptedmemories_acquire_build_lock "verify-tests"

# Runs one phase between a start and an end line that carry the elapsed seconds, so a log shows where the time goes.
# The end line also appears when the phase fails; the phase's exit status then ends the script as before.
run_phase() {
  local name="$1" began="$SECONDS" status=0
  shift
  echo "[tests] start: $name"
  "$@" || status=$?
  echo "[tests] end: $name after $((SECONDS - began)) s (exit $status)"
  return "$status"
}

if [[ ! -f "$ROOT/Vendor/sdk-swift/Package.swift" ]]; then
  echo "[tests] Vendor/sdk-swift is missing; restore the pinned checkout before testing." >&2
  exit 66
fi

run_phase "Apple Vision SDK surface" python3 "$ROOT/scripts/verify-apple-vision-sdk-surface.py"

run_phase "upgrade fixture release catalog" python3 "$ROOT/scripts/tests/test_upgrade_fixture_corpus.py"

run_phase "EncryptedMemoriesKit" xcrun swift test \
  --package-path "$ROOT/Packages/EncryptedMemoriesKit" \
  --scratch-path "$PHOTOS_SCRATCH" \
  --cache-path "$ENCRYPTED_MEMORIES_SWIFTPM_CACHE" \
  --force-resolved-versions \
  --no-parallel

# sdk-swift is a local path dependency, so SwiftPM does not execute its own test target while
# testing EncryptedMemoriesKit. Keep a separate invocation in the canonical gate or those tests vanish.
run_phase "vendored sdk-swift" xcrun swift test \
  --package-path "$ROOT/Vendor/sdk-swift" \
  --scratch-path "$SDK_SCRATCH" \
  --cache-path "$ENCRYPTED_MEMORIES_SWIFTPM_CACHE" \
  --force-resolved-versions \
  --no-parallel

echo "[tests] all package suites passed"
echo "[tests] total: $SECONDS s"
