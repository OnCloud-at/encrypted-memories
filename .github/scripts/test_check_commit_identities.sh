#!/usr/bin/env bash
set -euo pipefail

# Tests scripts/check-commit-identities.sh against commits in a temporary repository.

script="$(cd "$(dirname "$0")/../.." && pwd)/scripts/check-commit-identities.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1
unset COMMIT_IDENTITY_LOGIN COMMIT_IDENTITY_ID

repo="$work/repo"
git init -q "$repo"
cd "$repo"
git config user.name Test
git config commit.gpgsign false

failures=0
counter=0

# commit <author-email> <committer-email> <message>
commit() {
  counter=$((counter + 1))
  echo "$counter" >"file-$counter"
  git add .
  GIT_AUTHOR_EMAIL="$1" GIT_COMMITTER_EMAIL="$2" git commit -q -m "$3"
}

# Starts a new branch from the base commit.
fresh_branch() {
  git checkout -q -B "$1" base
}

# expect <pass|fail> <case> <login> <id> [base]: checks base..HEAD as that account.
expect() {
  local want="$1" name="$2" login="$3" id="$4" base="${5:-base}" status=0 output
  output="$(COMMIT_IDENTITY_LOGIN="$login" COMMIT_IDENTITY_ID="$id" \
    bash "$script" "$base" HEAD 2>&1)" || status=$?
  verdict=fail
  [[ "$status" -eq 0 ]] && verdict=pass
  if [[ "$verdict" != "$want" ]]; then
    echo "FAIL: $name (expected $want, exit $status)" >&2
    echo "$output" >&2
    failures=$((failures + 1))
  else
    echo "ok: $name"
  fi
  last_output="$output"
}

# The repository owner's history before the checked range may carry any address.
commit "old@example.invalid" "old@example.invalid" "initial"
git tag base

alice_id=42
alice="42+alice@users.noreply.github.com"
alice_legacy="alice@users.noreply.github.com"

fresh_branch exact
commit "$alice" "$alice" "Exact id address"
expect pass "author's id address passes" alice "$alice_id"

fresh_branch legacy
commit "$alice_legacy" "$alice_legacy" "Legacy address of the same login"
expect pass "author's login-only address passes" alice "$alice_id"

fresh_branch case
commit "42+Alice@users.noreply.github.com" "42+Alice@users.noreply.github.com" "Login case differs"
expect pass "login comparison ignores case" alice "$alice_id"

fresh_branch web-flow
commit "$alice" "noreply@github.com" "Web-flow committer"
expect pass "noreply@github.com committer passes" alice "$alice_id"

fresh_branch web-flow-author
commit "noreply@github.com" "noreply@github.com" "Web-flow as author"
expect fail "noreply@github.com author fails" alice "$alice_id"

fresh_branch other-login
commit "7+mallory@users.noreply.github.com" "$alice" "Another login with id"
expect fail "another login's id address fails as author" alice "$alice_id"
case "$last_output" in
  *mallory*) echo "FAIL: output repeats the rejected address" >&2; failures=$((failures + 1)) ;;
esac
case "$last_output" in
  *"author email"*) ;;
  *) echo "FAIL: output does not name the field" >&2; failures=$((failures + 1)) ;;
esac

fresh_branch other-legacy
commit "mallory@users.noreply.github.com" "mallory@users.noreply.github.com" "Another login without id"
expect fail "another login's legacy address fails" alice "$alice_id"

fresh_branch other-committer
commit "$alice" "mallory@users.noreply.github.com" "Another login as committer"
expect fail "another login's address fails as committer" alice "$alice_id"

fresh_branch wrong-id
commit "7+alice@users.noreply.github.com" "$alice" "Right login, wrong id"
expect fail "right login with another id fails" alice "$alice_id"

fresh_branch private-address
commit "someone@example.invalid" "$alice" "Not a noreply address"
expect fail "non-noreply author fails" alice "$alice_id"

fresh_branch own-trailer
commit "$alice" "$alice" $'Own trailer\n\nCo-authored-by: Alice <42+alice@users.noreply.github.com>'
expect pass "Co-authored-by of the author passes" alice "$alice_id"

fresh_branch other-trailer
commit "$alice" "$alice" $'Other trailer\n\nCo-authored-by: Mallory <7+mallory@users.noreply.github.com>'
expect fail "Co-authored-by of another login fails" alice "$alice_id"
case "$last_output" in
  *mallory*) echo "FAIL: output repeats the trailer address" >&2; failures=$((failures + 1)) ;;
esac

fresh_branch second-address
commit "$alice" "$alice" $'Two addresses\n\nCo-authored-by: Alice <alice@users.noreply.github.com> <7+mallory@users.noreply.github.com>'
expect fail "a second address on a trailer line fails" alice "$alice_id"

fresh_branch tool-trailer
commit "$alice" "$alice" $'Tool trailer\n\nCo-authored-by: Claude <42+alice@users.noreply.github.com>'
expect fail "tool name with the author's address fails" alice "$alice_id"

fresh_branch generated-by
commit "$alice" "$alice" $'Generated\n\nGenerated-by: Some Assistant'
expect fail "Generated-by naming an assistant fails" alice "$alice_id"

fresh_branch signed-off-other
commit "$alice" "$alice" $'Signed off\n\nSigned-off-by: Bob <7+bob@users.noreply.github.com>'
expect fail "Signed-off-by of another login fails" alice "$alice_id"

fresh_branch reviewed-without-address
commit "$alice" "$alice" $'Reviewed\n\nReviewed-by: Bob'
expect fail "attribution trailer without address fails" alice "$alice_id"

fresh_branch trailer-in-body
commit "$alice" "$alice" $'Hidden\n\nCo-authored-by: Mallory <7+mallory@users.noreply.github.com>\n\nMore text after the trailer.'
expect fail "attribution line outside the trailer block fails" alice "$alice_id"

fresh_branch lowercase-key
commit "$alice" "$alice" $'Key case\n\nco-authored-by: Mallory <7+mallory@users.noreply.github.com>'
expect fail "trailer key comparison ignores case" alice "$alice_id"

fresh_branch plain-body
commit "$alice" "$alice" $'Plain body\n\nMentions co-authors in prose without a trailer.'
expect pass "prose without a trailer passes" alice "$alice_id"

fresh_branch name-contains-tool-word
commit "$alice" "$alice" $'Habitual sign-off\n\nSigned-off-by: Ali Haider <42+alice@users.noreply.github.com>'
expect pass "a name that contains a tool word inside another word passes" alice "$alice_id"

fresh_branch assisted-by
commit "$alice" "$alice" $'Assisted\n\nAssisted-by: Claude <noreply@anthropic.com>'
expect fail "Assisted-by naming a tool fails" alice "$alice_id"

fresh_branch co-developed-by
commit "$alice" "$alice" $'Co-developed\n\nCo-developed-by: Mallory <7+mallory@users.noreply.github.com>'
expect fail "Co-developed-by of another login fails" alice "$alice_id"

fresh_branch bare-address
commit "$alice" "$alice" $'Bare address\n\nCo-authored-by: Mallory mallory@users.noreply.github.com <42+alice@users.noreply.github.com>'
expect fail "an address outside brackets in the name fails" alice "$alice_id"

fresh_branch external
carol="99+carol@users.noreply.github.com"
commit "$carol" "$carol" "External contributor"
commit "$carol" "noreply@github.com" "External contributor, web-flow committer"
expect pass "external contributor passes for the own pull request" carol 99
expect fail "the same commits fail for another author's pull request" alice "$alice_id"

fresh_branch external-legacy
commit "carol@users.noreply.github.com" "carol@users.noreply.github.com" "External contributor, legacy address"
expect pass "external contributor's address without id passes" carol 99

fresh_branch bot
bot="29139614+renovate[bot]@users.noreply.github.com"
commit "$bot" "$bot" "Bot update"
expect pass "bot account passes for its own pull request" 'renovate[bot]' 29139614
expect fail "bot address fails for a human author" alice "$alice_id"

fresh_branch range
commit "7+mallory@users.noreply.github.com" "$alice" "Bad commit before the checked range"
git tag -f range-base >/dev/null
commit "$alice" "$alice" "Good commit in the range"
expect pass "commits before the base are not checked" alice "$alice_id" range-base
expect fail "commits after the base are checked" alice "$alice_id" base

fresh_branch no-base
commit "7+mallory@users.noreply.github.com" "$alice" "Bad parent"
commit "$alice" "$alice" "Good head"
status=0
COMMIT_IDENTITY_LOGIN=alice COMMIT_IDENTITY_ID=$alice_id bash "$script" "" HEAD >/dev/null 2>&1 || status=$?
if [[ "$status" -eq 0 ]]; then echo "ok: without a usable base only the head commit is checked"
else echo "FAIL: without a usable base only the head commit is checked" >&2; failures=$((failures + 1)); fi

status=0
COMMIT_IDENTITY_LOGIN=alice COMMIT_IDENTITY_ID=$alice_id \
  bash "$script" 0123456789abcdef0123456789abcdef01234567 HEAD >/dev/null 2>&1 || status=$?
if [[ "$status" -eq 2 ]]; then echo "ok: a base commit missing from the checkout fails closed"
else echo "FAIL: a base commit missing from the checkout fails closed (exit $status)" >&2; failures=$((failures + 1)); fi

status=0
output="$(COMMIT_IDENTITY_LOGIN=alice COMMIT_IDENTITY_ID=$alice_id \
  bash "$script" base 0123456789abcdef0123456789abcdef01234567 2>&1)" || status=$?
if [[ "$status" -eq 2 && "$output" == *"cannot be checked"* ]]; then echo "ok: a head commit missing from the checkout fails closed"
else echo "FAIL: a head commit missing from the checkout fails closed (exit $status)" >&2; failures=$((failures + 1)); fi

status=0
COMMIT_IDENTITY_LOGIN=alice COMMIT_IDENTITY_ID=$alice_id bash "$script" HEAD HEAD >/dev/null 2>&1 || status=$?
if [[ "$status" -eq 0 ]]; then echo "ok: an empty range passes"
else echo "FAIL: an empty range passes (exit $status)" >&2; failures=$((failures + 1)); fi

# Fallback: no environment, as in the local pre-push guard.
fresh_branch fallback-pass
git config user.email "$alice"
commit "$alice" "$alice" "Local push"
status=0
bash "$script" base HEAD >/dev/null 2>&1 || status=$?
if [[ "$status" -eq 0 ]]; then echo "ok: configured noreply address is the fallback identity"
else echo "FAIL: configured noreply address is the fallback identity" >&2; failures=$((failures + 1)); fi

fresh_branch fallback-fail
commit "7+mallory@users.noreply.github.com" "$alice" "Local push of another login"
status=0
bash "$script" base HEAD >/dev/null 2>&1 || status=$?
if [[ "$status" -eq 1 ]]; then echo "ok: fallback identity rejects another login"
else echo "FAIL: fallback identity rejects another login (exit $status)" >&2; failures=$((failures + 1)); fi

fresh_branch fallback-none
git config user.email "someone@example.invalid"
commit "$alice" "$alice" "No usable identity"
status=0
bash "$script" base HEAD >/dev/null 2>&1 || status=$?
if [[ "$status" -eq 2 ]]; then echo "ok: no identity at all fails closed"
else echo "FAIL: no identity at all fails closed (exit $status)" >&2; failures=$((failures + 1)); fi
git config user.email "$alice"

# Values from the event never run as shell code.
status=0
COMMIT_IDENTITY_LOGIN='alice; touch injected' COMMIT_IDENTITY_ID=42 \
  bash "$script" base HEAD >/dev/null 2>&1 || status=$?
if [[ "$status" -eq 2 && ! -e injected ]]; then echo "ok: an invalid login is refused"
else echo "FAIL: an invalid login is refused (exit $status)" >&2; failures=$((failures + 1)); fi

status=0
COMMIT_IDENTITY_LOGIN=alice COMMIT_IDENTITY_ID='42x' bash "$script" base HEAD >/dev/null 2>&1 || status=$?
if [[ "$status" -eq 2 ]]; then echo "ok: an invalid id is refused"
else echo "FAIL: an invalid id is refused (exit $status)" >&2; failures=$((failures + 1)); fi

if ((failures)); then
  echo "$failures commit identity test(s) failed" >&2
  exit 1
fi
echo "commit identity tests passed"
