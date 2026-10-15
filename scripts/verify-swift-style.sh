#!/usr/bin/env bash
# The style check of CI: SwiftLint on the changed files (all files without a base commit) and swift-format on all files.
# BASE_SHA and HEAD_SHA name the commits of the change. SWIFTLINT_EXECUTABLE and SWIFT_FORMAT_EXECUTABLE select the
# tools; without them the macOS toolchain is used.
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ -n "${BASE_SHA:-}" ]] && git cat-file -e "$BASE_SHA^{commit}" 2>/dev/null; then
  bash scripts/lint-swift.sh --diff "$BASE_SHA" "${HEAD_SHA:?HEAD_SHA is required with BASE_SHA}"
else
  bash scripts/lint-swift.sh --all
fi
bash scripts/check-swift-format.sh --all
