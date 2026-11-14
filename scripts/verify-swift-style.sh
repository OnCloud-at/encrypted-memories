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
# The store-read rules check core sources only (the StoreLookup rule checks every file), so the canary files sit below a
# core source path. SwiftLint must report exactly the lines that the `expect` comments of the forbidden canary name,
# nothing in the allowed one, and a comment that turns a decision-read rule off must fail.
decision_canary="$canary_directory/Packages/EncryptedMemoriesKit/Sources/UploadCore/Backup"
mkdir -p "$decision_canary"
cp scripts/decision-read-canary/Forbidden.swift.txt "$decision_canary/DecisionReadCanary.swift"
cp scripts/decision-read-canary/Allowed.swift.txt "$decision_canary/DisplayReadCanary.swift"
cp scripts/decision-read-canary/Disabled.swift.txt "$decision_canary/DisabledReadCanary.swift"
expected_decision_reads="$(
  grep -n '// expect: ' "$decision_canary/DecisionReadCanary.swift" |
    awk -F '// expect: ' '{ split($1, place, ":"); print place[1] + 1, $2 }' | sort
)"
decision_canary_output="$(bash scripts/lint-swift.sh "$decision_canary/DecisionReadCanary.swift" 2>&1 || true)"
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
if ! display_canary_output="$(bash scripts/lint-swift.sh "$decision_canary/DisplayReadCanary.swift" 2>&1)"; then
  echo "SwiftLint reported the display read of the canary file; the decision-read rules are too wide." >&2
  printf '%s\n' "$display_canary_output" >&2
  exit 1
fi
if bash scripts/lint-swift.sh "$decision_canary/DisabledReadCanary.swift" > /dev/null 2>&1; then
  echo "A comment that turns off a decision-read rule passed the canary; the style check does not run completely." >&2
  exit 1
fi

if [[ -n "${BASE_SHA:-}" ]] && git cat-file -e "$BASE_SHA^{commit}" 2>/dev/null; then
  bash scripts/lint-swift.sh --diff "$BASE_SHA" "${HEAD_SHA:?HEAD_SHA is required with BASE_SHA}"
else
  bash scripts/lint-swift.sh --all
fi
bash scripts/check-swift-format.sh --all
