#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
source "$ROOT/scripts/swift-file-selection.sh"

select_swift_files check-swift-format.sh "$@"

if [[ ${#source_files[@]} -eq 0 ]]; then
  echo "No Swift files require a format check."
  exit 0
fi

# CI on Linux passes its own swift-format; everywhere else the tool of the selected Xcode runs.
if [[ -n "${SWIFT_FORMAT_EXECUTABLE:-}" ]]; then
  swift_format=("$SWIFT_FORMAT_EXECUTABLE")
else
  swift_format=(xcrun swift-format)
fi

"${swift_format[@]}" lint \
  --strict \
  --parallel \
  --configuration "$ROOT/.swift-format" \
  "${source_files[@]}"
