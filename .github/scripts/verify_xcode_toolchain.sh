#!/usr/bin/env bash
# Verify the reviewed hosted toolchain before dependencies or upgrade caches are used.
set -euo pipefail
source .github/scripts/release_failure.sh
expected_version="${EXPECTED_XCODE_VERSION:-27.1}"
expected_build="${EXPECTED_XCODE_BUILD:-27A9275}"
[[ -n "${DEVELOPER_DIR:-}" && -d "$DEVELOPER_DIR" ]] || release_fail toolchain \
  "The selected Xcode developer directory is missing." \
  "Select the reviewed Xcode installation from the hosted image inventory."
if ! xcode_output="$(xcodebuild -version)"; then
  printf '%s\n' "$xcode_output"
  release_fail toolchain "xcodebuild -version failed for the selected Xcode." \
    "Check the selected Xcode installation on the hosted image."
fi
printf 'DEVELOPER_DIR=%s\n%s\n' "$DEVELOPER_DIR" "$xcode_output"
xcode_version="$(awk '/^Xcode / { print $2; exit }' <<< "$xcode_output")"
xcode_build="$(awk '/^Build version / { print $3; exit }' <<< "$xcode_output")"
[[ "$xcode_version" == "$expected_version" && "$xcode_build" == "$expected_build" ]] || release_fail toolchain \
  "The runner uses Xcode '${xcode_version:-unknown}' build '${xcode_build:-unknown}'; expected '$expected_version' build '$expected_build'." \
  "Select the reviewed version and build, or update both pins in a reviewed change."
