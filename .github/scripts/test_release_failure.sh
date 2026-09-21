#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
source "$script_dir/release_failure.sh"

summary="$(mktemp)"
error_log="$(mktemp)"
trap 'rm -f "$summary" "$error_log"' EXIT
export GITHUB_STEP_SUMMARY="$summary"
export GITHUB_STEP_NAME="release-test"
if ( release_fail configuration $'cause%\r\nline' 'retry the command' ) 2>"$error_log"; then
  echo "release_fail unexpectedly succeeded" >&2
  exit 1
fi
grep -Fq 'cause%25%0D%0Aline Remediation: retry the command' "$error_log" || {
  echo "release_fail did not escape workflow command data" >&2
  exit 1
}
grep -Fq '| release-test | configuration | cause%  line | retry the command |' "$summary" || {
  echo "release_fail did not write the summary table" >&2
  exit 1
}

attempt_file="$(mktemp)"
trap 'rm -f "$summary" "$error_log" "$attempt_file"' EXIT
if retry_command 3 0 'test retry' -- bash -c 'count=$(cat "$1" 2>/dev/null || echo 0); count=$((count + 1)); echo "$count" > "$1"; ((count >= 2))' _ "$attempt_file"; then
  [[ "$(cat "$attempt_file")" == 2 ]] || { echo "retry success path used the wrong attempt count" >&2; exit 1; }
else
  echo "retry_command did not recover" >&2
  exit 1
fi

if retry_command 2 0 'test final failure' -- false; then
  echo "retry_command unexpectedly succeeded" >&2
  exit 1
fi
echo "release_failure tests passed"
