#!/usr/bin/env bash
# Keep each scenario in a separate FIFO turn so other worktrees can build between scenarios.
set -euo pipefail
current="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
release="${1:-v1.0.5}"
[[ "$release" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Use a stable release tag.' >&2; exit 64; }
historical="$(dirname "$current")/upgrade-fixtures-$release"
[[ ! -e "$historical" ]] || { echo 'The historical worktree path must be unused.' >&2; exit 73; }
commit="$(git -C "$current" rev-parse "$release^{commit}")"
git -C "$current" worktree add --detach "$historical" "$release"
cleanup() {
  # Only this script's disposable checkout contains the overlay and vendored SDK.
  git -C "$current" worktree remove --force "$historical"
}
trap cleanup EXIT
python3 "$current/Tools/upgrade-fixtures/apply-overlay.py" "$current" "$historical" "$commit"
source "$current/scripts/build-paths.sh"
mkdir -p "$ENCRYPTED_MEMORIES_BUILD_ROOT/UpgradeFixtures.noindex/$release"
run_directory="$(mktemp -d "$ENCRYPTED_MEMORIES_BUILD_ROOT/UpgradeFixtures.noindex/$release/run.XXXXXX")"
export UPGRADE_FIXTURE_RUN_ID="${run_directory##*/}"
first=1
for scenario in cache backup model index location; do
  if [[ "$first" == 1 ]]; then
    "$HOME/.claude/agent-watch/scripts/build-turn.sh" "upgrade-fixtures-$scenario" -- \
      bash "$current/Tools/upgrade-fixtures/record-scenario.sh" "$current" "$historical" "$scenario"
  else
    "$HOME/.claude/agent-watch/scripts/build-turn.sh" "upgrade-fixtures-$scenario" -- \
      bash "$current/Tools/upgrade-fixtures/record-scenario.sh" "$current" "$historical" "$scenario" --skip-build
  fi
  first=0
done
"$HOME/.claude/agent-watch/scripts/build-turn.sh" upgrade-fixtures-wal-policy -- \
  bash "$current/Tools/upgrade-fixtures/verify-observer.sh" "$current" "$release"
python3 "$current/Tools/upgrade-fixtures/corpus.py" \
  "$run_directory/recorded" \
  "$current/Packages/EncryptedMemoriesKit/Tests/UpgradeFixtureTests/Fixtures"
