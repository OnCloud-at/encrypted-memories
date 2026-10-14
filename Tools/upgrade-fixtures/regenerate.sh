#!/usr/bin/env bash
# Keep each scenario in a separate FIFO turn so other worktrees can build between scenarios.
set -euo pipefail
current="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
release="${1:-v1.0.5}"
python3 "$current/Tools/upgrade-fixtures/corpus.py" --check-release "$release" || exit 64
source "$current/scripts/build-paths.sh"
historical="$ENCRYPTED_MEMORIES_BUILD_ROOT/UpgradeFixtures.noindex/src-$release"
mkdir -p "$(dirname "$historical")"
[[ ! -e "$historical" ]] || { echo 'The historical worktree path must be unused.' >&2; exit 73; }
commit="$(git -C "$current" rev-parse "refs/tags/$release^{commit}")"
git -C "$current" worktree add --detach "$historical" "$commit"
cleanup() {
  # The recorded data tree is no corpus, and every local user can read the shared folder: remove only this run's tree.
  if [[ -n "${UPGRADE_FIXTURE_DATA_BASE:-}" && -n "${UPGRADE_FIXTURE_RUN_ID:-}" ]]; then
    rm -rf -- "$UPGRADE_FIXTURE_DATA_BASE/$release/$UPGRADE_FIXTURE_RUN_ID"
    rmdir "$UPGRADE_FIXTURE_DATA_BASE/$release" "$UPGRADE_FIXTURE_DATA_BASE" 2>/dev/null || true
  fi
  # Only this script's disposable checkout contains the overlay and vendored SDK.
  git -C "$current" worktree remove --force "$historical"
  if git -C "$current" worktree list --porcelain | /usr/bin/grep -Fxq "worktree $historical"; then
    echo 'Historical worktree remains registered after cleanup.' >&2
    return 70
  fi
}
trap cleanup EXIT
python3 "$current/Tools/upgrade-fixtures/apply-overlay.py" "$current" "$historical" "$commit"
export UPGRADE_FIXTURE_RELEASE="$release"
# The recorded data tree lives in the shared folder, so no stored path names a person; the packer rejects any hit.
export UPGRADE_FIXTURE_DATA_BASE="${UPGRADE_FIXTURE_DATA_BASE:-/Users/Shared/EncryptedMemoriesUpgradeFixtures}"
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
  "$current/Packages/EncryptedMemoriesKit/Tests/UpgradeFixtureTests/Fixtures/$release"
