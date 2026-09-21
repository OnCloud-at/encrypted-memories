#!/usr/bin/env bash
set -euo pipefail

# Rejects commits whose author, committer, or Co-authored-by identity is not a
# GitHub noreply address. Without user.email, Git derives an address from the
# account name and host name; a squash merge then publishes it as a trailer.
# Violations name only the commit and field so the log never repeats the address.

cd "$(dirname "$0")/.."

base_sha="${1:-}"
head_sha="${2:-HEAD}"

if [[ -n "$base_sha" ]] && git cat-file -e "$base_sha^{commit}" 2>/dev/null; then
  log_range=("$base_sha..$head_sha")
else
  log_range=(-1 "$head_sha")
fi

allowed='^([0-9]+\+)?[A-Za-z0-9-]+(\[bot\])?@users\.noreply\.github\.com$|^noreply@github\.com$'
violations=0

check_email() {
  local commit="$1" field="$2" email="$3"
  if [[ ! "$email" =~ $allowed ]]; then
    echo "Commit ${commit:0:12}: $field is not a GitHub noreply address" >&2
    violations=1
  fi
}

while IFS=$'\x1f' read -r -d $'\x1e' commit author committer trailers; do
  commit="${commit#$'\n'}"
  check_email "$commit" "author email" "$author"
  check_email "$commit" "committer email" "$committer"
  while IFS= read -r trailer; do
    [[ -z "$trailer" ]] && continue
    if [[ "$trailer" =~ \<([^>]*)\> ]]; then
      check_email "$commit" "Co-authored-by trailer" "${BASH_REMATCH[1]}"
    else
      echo "Commit ${commit:0:12}: Co-authored-by trailer has no email address" >&2
      violations=1
    fi
  done <<<"$trailers"
done < <(git log "${log_range[@]}" \
  --format='%H%x1f%ae%x1f%ce%x1f%(trailers:key=Co-authored-by,valueonly)%x1e')

if ((violations)); then
  cat >&2 <<'EOF'
Set a GitHub noreply identity before committing, then rewrite these commits:
  git config --global user.email "<id>+<login>@users.noreply.github.com"
  git config --global user.useConfigOnly true
EOF
  exit 1
fi
