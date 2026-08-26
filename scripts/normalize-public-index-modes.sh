#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

git ls-files -z | xargs -0 git update-index --chmod=-x --

while IFS= read -r -d '' path; do
  [[ -f "$path" ]] || continue
  if [[ "$(head -c 2 -- "$path")" == '#!' ]]; then
    git update-index --chmod=+x -- "$path"
  fi
done < <(git ls-files -z)

echo "Normalized public index file modes."
