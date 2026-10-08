#!/usr/bin/env bash
set -euo pipefail
root="$1"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
unset SDKROOT
source "$root/scripts/build-paths.sh"
encryptedmemories_acquire_build_lock upgrade-fixture-wal-policy
fixture_build="$ENCRYPTED_MEMORIES_BUILD_ROOT/UpgradeFixtures.noindex/${2:-v1.0.5}"
if [[ -n "${UPGRADE_FIXTURE_RUN_ID:-}" ]]; then
  [[ "$UPGRADE_FIXTURE_RUN_ID" =~ ^run\.[A-Za-z0-9]+$ ]] || { echo 'Invalid recording run ID.' >&2; exit 64; }
  fixture_build="$fixture_build/$UPGRADE_FIXTURE_RUN_ID"
fi
proof="$fixture_build/policy-proof"
[[ ! -e "$proof" ]] || { echo 'Use a fresh policy-proof destination.' >&2; exit 73; }
mkdir -p "$proof/plain" "$proof/observed" "$proof/snapshots"
xcrun clang -Wall -Wextra -Werror -O2 "$root/Tools/upgrade-fixtures/Recorder/PolicyProof.c" -lsqlite3 -o "$proof/policy-proof"
"$proof/policy-proof" "$proof/plain" "$proof/plain.json"
printf '%s\n' '{"generation":1,"remote":[],"complete":[],"queueKeys":[]}' > "$proof/oracle.json"
/usr/bin/env DYLD_INSERT_LIBRARIES="$fixture_build/observe.dylib" UPGRADE_RECORD_ROOT="$proof/observed" \
  UPGRADE_RECORD_OUTPUT="$proof/snapshots" UPGRADE_RECORD_ORACLE="$proof/oracle.json" \
  "$proof/policy-proof" "$proof/observed" "$proof/observed.json"
python3 "$root/Tools/upgrade-fixtures/check-wal-policy.py" "$proof" \
  "$root/Packages/EncryptedMemoriesKit/Tests/UpgradeFixtureTests/Fixtures/wal-policy-proof.json"
