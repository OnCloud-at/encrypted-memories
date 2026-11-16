#!/usr/bin/env bash
# The style check of CI: SwiftLint on the changed files (all files without a base commit) and swift-format on all files.
# BASE_SHA and HEAD_SHA name the commits of the change. SWIFTLINT_EXECUTABLE and SWIFT_FORMAT_EXECUTABLE select the
# tools; without them the macOS toolchain is used.
set -euo pipefail

cd "$(dirname "$0")/.."

# SwiftLint can skip its comment rules without a message that this script knows. Before the real run, a file with a
# comment that the rules forbid must fail the check; if it passes, the check does not run completely.
canary_directory="$(mktemp -d)"
trap 'rm -rf "$canary_directory"' EXIT
printf '// canary \xe2\x80\x94 canary\nlet canary = 1\n' > "$canary_directory/StyleCanary.swift"
if bash scripts/lint-swift.sh "$canary_directory/StyleCanary.swift" > /dev/null 2>&1; then
  echo "SwiftLint did not report the forbidden comment of the canary file; the style check does not run completely." >&2
  exit 1
fi
# The store-read rules check core sources only (the StoreLookup rule checks every file), and the host rules check only
# the two app trees, so the canary files sit below a core source path and below `App/`. SwiftLint must report exactly
# the lines that the `expect` comments of the forbidden canary name, nothing in the allowed one, and a comment that
# turns a decision rule off must fail.
check_decision_canary() {
  local directory="$1" prefix="$2" host_root="$3" forbidden allowed disabled
  forbidden="$directory/${prefix}DecisionReadCanary.swift"
  allowed="$directory/${prefix}DisplayReadCanary.swift"
  disabled="$directory/${prefix}DisabledReadCanary.swift"
  mkdir -p "$directory"
  cp "scripts/decision-read-canary/${prefix}Forbidden.swift.txt" "$forbidden"
  cp "scripts/decision-read-canary/${prefix}Allowed.swift.txt" "$allowed"
  cp "scripts/decision-read-canary/${prefix}Disabled.swift.txt" "$disabled"
  local expected_decision_reads reported_decision_reads decision_canary_output display_canary_output
  expected_decision_reads="$(
    grep -n '// expect: ' "$forbidden" |
      awk -F '// expect: ' '{ split($1, place, ":"); print place[1] + 1, $2 }' | sort
  )"
  decision_canary_output="$(DECISION_HOST_ROOT="$host_root" bash scripts/lint-swift.sh "$forbidden" 2>&1 || true)"
  reported_decision_reads="$(
    sed -nE 's#^.*DecisionReadCanary\.swift:([0-9]+):[0-9]+: error: .*\(([a-z_]+)\)$#\1 \2#p' \
      <<< "$decision_canary_output" | sort -u
  )"
  if [[ "$reported_decision_reads" != "$expected_decision_reads" ]]; then
    echo "SwiftLint did not report exactly the decision reads of the canary file; the style check does not run completely." >&2
    diff <(printf '%s\n' "$expected_decision_reads") <(printf '%s\n' "$reported_decision_reads") >&2 || true
    printf '%s\n' "$decision_canary_output" >&2
    exit 1
  fi
  if ! display_canary_output="$(DECISION_HOST_ROOT="$host_root" bash scripts/lint-swift.sh "$allowed" 2>&1)"; then
    echo "SwiftLint reported the display read of the canary file; the decision-read rules are too wide." >&2
    printf '%s\n' "$display_canary_output" >&2
    exit 1
  fi
  if DECISION_HOST_ROOT="$host_root" bash scripts/lint-swift.sh "$disabled" > /dev/null 2>&1; then
    echo "A comment that turns off a decision-read rule passed the canary; the style check does not run completely." >&2
    exit 1
  fi
}
check_decision_canary "$canary_directory/Packages/EncryptedMemoriesKit/Sources/UploadCore/Backup" "" "$canary_directory"
check_decision_canary "$canary_directory/App" "Host" "$canary_directory"
# The host rules match absolute paths below the root of the checkout. A directory called App above the checkout must not
# turn a core file into a host file.
leak_root="$canary_directory/App/leak-root"
leak_file="$leak_root/Packages/EncryptedMemoriesKit/Sources/PhotosCore/LeakCanary.swift"
mkdir -p "$(dirname "$leak_file")"
cp scripts/decision-read-canary/HostLeak.swift.txt "$leak_file"
if ! leak_output="$(DECISION_HOST_ROOT="$leak_root" bash scripts/lint-swift.sh "$leak_file" 2>&1)"; then
  echo "A directory called App above the checkout made a core file a host file; the host rules are anchored too wide." >&2
  printf '%s\n' "$leak_output" >&2
  exit 1
fi

if [[ -n "${BASE_SHA:-}" ]] && git cat-file -e "$BASE_SHA^{commit}" 2>/dev/null; then
  bash scripts/lint-swift.sh --diff "$BASE_SHA" "${HEAD_SHA:?HEAD_SHA is required with BASE_SHA}"
else
  bash scripts/lint-swift.sh --all
fi
bash scripts/check-swift-format.sh --all
