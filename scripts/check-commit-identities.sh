#!/usr/bin/env bash
set -euo pipefail

# Rejects commits that credit an account other than the pull request author.
# A noreply address of the form <login>@users.noreply.github.com belongs to
# whoever owns that GitHub login, so the shape of an address proves nothing.
# Allowed for the author and for every account-bound trailer address:
#   <id>+<login>@users.noreply.github.com and <login>@users.noreply.github.com
# of COMMIT_IDENTITY_LOGIN and COMMIT_IDENTITY_ID, plus noreply@github.com for
# the committer (GitHub's web-flow account). Everything else fails.
# Trailers that credit a person or a tool (Co-authored-by, Signed-off-by,
# Reviewed-by, Generated-by) must carry an allowed address and no tool name.
# Without COMMIT_IDENTITY_LOGIN the script uses the noreply address of the
# checkout's own user.email, so the local pre-push guard needs no environment.
# Violations name only the commit and field so the log never repeats an address.
#
# Usage: check-commit-identities.sh [<base-sha> [<head-sha>]]

base_sha="${1:-}"
head_sha="${2:-HEAD}"

lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

login="${COMMIT_IDENTITY_LOGIN:-}"
account_id="${COMMIT_IDENTITY_ID:-}"

if [[ -z "$login" ]]; then
  configured="$(git config user.email || true)"
  configured_pattern='^(([0-9]+)\+)?([A-Za-z0-9-]+(\[bot\])?)@users\.noreply\.github\.com$'
  if [[ "$configured" =~ $configured_pattern ]]; then
    login="${BASH_REMATCH[3]}"
    account_id="${BASH_REMATCH[2]}"
  fi
fi

if [[ ! "$login" =~ ^[A-Za-z0-9-]+(\[bot\])?$ ]] || [[ ! "$account_id" =~ ^[0-9]*$ ]]; then
  echo "No valid account to check commit identities against." >&2
  echo "Set COMMIT_IDENTITY_LOGIN and COMMIT_IDENTITY_ID, or a noreply user.email." >&2
  exit 2
fi

login_lower="$(lower "$login")"

is_author_address() {
  local address
  address="$(lower "$1")"
  [[ "$address" == "$login_lower@users.noreply.github.com" ]] && return 0
  [[ -n "$account_id" && "$address" == "$account_id+$login_lower@users.noreply.github.com" ]]
}

is_committer_address() {
  is_author_address "$1" || [[ "$(lower "$1")" == "noreply@github.com" ]]
}

if [[ -z "$base_sha" ]]; then
  log_range=(-1 "$head_sha")
elif git cat-file -e "$base_sha^{commit}" 2>/dev/null; then
  log_range=("$base_sha..$head_sha")
else
  echo "Base commit is not in this checkout, so the range cannot be checked." >&2
  exit 2
fi

trailer_key='^[[:space:]]*(co-authored-by|co-developed-by|signed-off-by|reviewed-by|generated-by|assisted-by)[[:space:]]*:'
# A tool name counts as a whole word in the name part of a trailer, so "Ali Haider" is not "aider".
tool_name='(^|[^a-z0-9])(anthropic|claude|codex|openai|chatgpt|gpt|t3 ?code|coding[ -]?agent|copilot|gemini|grok|cursor|aider|windsurf|deepseek|lumo|apertus|opencode|assistant)([^a-z0-9]|$)'
trailer_address='<([^<>]*)>(.*)$'
violations=0

fail() {
  echo "Commit ${1:0:12}: $2" >&2
  violations=1
}

check_trailer() {
  local commit="$1" line="$2" key rest found=0 name
  [[ "$line" =~ $trailer_key ]] || return 0
  key="${BASH_REMATCH[1]}"
  name="${line%%<*}"
  name="${name#*:}"
  if [[ "$name" =~ $tool_name ]]; then
    fail "$commit" "$key trailer credits a tool"
    return 0
  fi
  if [[ "$name" == *@* ]]; then
    fail "$commit" "$key trailer carries an address outside brackets"
    return 0
  fi
  rest="$line"
  while [[ "$rest" =~ $trailer_address ]]; do
    found=1
    local address="${BASH_REMATCH[1]}"
    rest="${BASH_REMATCH[2]}"
    if ! is_author_address "$address"; then
      fail "$commit" "$key trailer address is not the pull request author's"
    fi
  done
  if ((!found)); then
    fail "$commit" "$key trailer has no email address"
  fi
}

# Read each git output into a variable first: a failure inside a process substitution would end the loop silently.
commits="$(git rev-list "${log_range[@]}")" || {
  echo "The commit range cannot be read, so it cannot be checked." >&2
  exit 2
}

while IFS= read -r commit; do
  [[ -n "$commit" ]] || continue
  author="$(git log -1 --format=%ae "$commit")"
  committer="$(git log -1 --format=%ce "$commit")"
  message="$(git log -1 --format=%B "$commit")"
  if ! is_author_address "$author"; then
    fail "$commit" "author email is not the pull request author's GitHub noreply address"
  fi
  if ! is_committer_address "$committer"; then
    fail "$commit" "committer email is not the pull request author's GitHub noreply address"
  fi
  while IFS= read -r line; do
    check_trailer "$commit" "$(lower "$line")"
  done <<<"$message"
done <<<"$commits"

if ((violations)); then
  cat >&2 <<'EOF'
Commit as the pull request author with the GitHub noreply address of that account, then rewrite these commits:
  git config --global user.email "<id>+<login>@users.noreply.github.com"
  git config --global user.useConfigOnly true
Remove every attribution trailer that names another person or a tool.
EOF
  exit 1
fi
