# Upgrade interruption fixtures

Issue #380 checks disk states written by a stable release when an update terminates the app.
The corpus contains synthetic photos, server records, encrypted cache bytes, and tiny synthetic model artifacts.
No transport opens a network connection. The recording process also runs with network access denied.

## Record a release

Run from the repository root:

```sh
./Tools/upgrade-fixtures/regenerate.sh v1.0.5
```

The script creates a detached worktree beside this checkout. It applies only a recorder target.
Historical production sources remain unchanged. The SDK restore uses that release's `update-proton-sdk.sh` and a disposable build root.
For v1.0.5, VendorPatches pins SDK 0.29.1 at `8c21d3f7277bcb7a8506ac3576b51e1cf569de79` with two patches.

Each scenario takes a separate `build-turn.sh` turn and acquires the canonical build lock.
The first turn builds. Later turns use `--skip-build`.
The historical SwiftPM scratch lives under `$ENCRYPTED_MEMORIES_BUILD_ROOT/UpgradeFixtures.noindex/<release>/SPM.noindex`.
Its separate dependency cache lives beside it. Later recordings reuse these caches for the same release.
The script removes its historical worktree after recording. Build output and raw snapshots may remain in that scratch.
Each regeneration creates a fresh run directory. Never share the current package's scratch with the release build.

To test the next release, pass its stable tag. Check the overlay against its public Core interfaces.
Update the checker's expected baseline tag, commit, and SDK after regeneration.
Run the format check, privacy protection, and package tests before committing the new corpus.
CI verifies committed fixtures. It does not rebuild historical releases.

## Capture boundaries

A delegating SQLite VFS observes every successful `xWrite` and `xTruncate`.
The WAL callback records committed transactions before any automatic checkpoint.
It then runs SQLite's original PASSIVE checkpoint at the connection's original positive threshold.
The independent policy probe compares frame and backfill histories with the system callback over 1,030 transactions.
Its event record proves that the unchanged 1,000-page threshold was crossed.

Darwin interposition observes Foundation writes, non-cancellable writes, positioned writes, vector writes, truncation, rename, and unlink.
The observer returns successful short writes for cache files, as POSIX permits.
Foundation still writes the complete bytes; each intermediate prefix becomes a kill boundary.
The recorder redirects public `NSFileManager` item-replacement-directory requests for recorded targets into unique `Temporary/Replacement-*` directories.
`TMPDIR` alone does not isolate those directories on macOS. The overlay preserves the same-volume atomic replacement.
No partial target blob is invented. Both complete atomic targets and actual partial helper files are recorded.
On iOS, these helpers belong in the container's `tmp/` directory.
Apple states that the system may purge `tmp/` while the app is not running ([File System Programming Guide](https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/FileSystemProgrammingGuide/FileSystemOverview/FileSystemOverview.html)).
The checker verifies that helpers cannot become visible cache data. Helpers outside system-managed temporary storage must disappear after recovery.
A location journal starts atomically and then receives direct appends; the checker treats those later prefixes as non-atomic writes.
SQLite writes retain their original size.
Statement and file-operation locks serialize the synthetic workload while a snapshot is copied.
Snapshots include the entire data tree, WAL, SHM, empty directories, temporary files, and partial downloads.
Capture does not open SQLite, close a store, checkpoint a source, or repair a file.
The corpus packer reads SQLite only in disposable copies.

The archive deduplicates identical file contents by SHA-256. It retains every event and reconstructs every directory independently.
The hard budget is 15 MB (15,000,000 bytes) for the complete committed fixture directory, including the archive and manifests.
The packer checks raw file bytes and recovered SQLite values for private paths, hostnames, and private network addresses.

## Scenarios and verification

- Backup: metadata scan, persistent enqueue, persisted runner stages, retry, edit, undo, and remote commit before local settlement.
- Model: interrupted streamed download, verified installation, activation, and first-launch recovery.
- Index: semantic embeddings and native text indexing through persistent encrypted SQLite stores.
- Cache: encrypted thumbnails and previews, including temporary and partial write states.
- Location: positive, negative, and failed probes through the persistent crawl path.

The checker uses existing Core entry points.
One production line removes `private` from `PhotoLibraryBackupController.replayCatalogIfQueueNeedsRecovery`.
Its signature and behavior stay unchanged; `@testable import` reaches the actual launch replay before scan and reconciliation.
The synthetic PhotoKit boundary stores no change token, so it supplies the real missing-token full-scan fallback with an empty change list. It substitutes external photo, backend, transport, inference, and location boundaries.
It checks historical complete revisions before scanning. An independent oracle comes from the copied historical database and synthetic server state.
It rejects duplicate queue identities and new upload work from complete revisions. Terminal `alreadyBackedUp` bookkeeping adds no upload work. It then drains recovered work and checks that server commits are not repeated.
The installer must verify an artifact before the runtime reads it. Each index recovery may execute at most one synthetic inventory.
Cache reads may return the original complete bytes or no bytes. Location crawling must complete the synthetic inventory.

On macOS, one bounded child process checks each scenario with network access denied. Up to three processes run concurrently.
The parent reports crashes, failing assertions, and timeouts. Each scenario has a 120-second deadline.
The complete verification has a 300-second budget.
The package test target compiles on supported Apple platforms; process isolation runs in the macOS package gate.

This checks Core first launch after process termination. Native host startup, PhotoKit authorization, real service behavior, physical devices, and power loss remain separate checks.
Production behavior and stored formats do not change here.

## Committed corpus

| Scenario | Boundaries |
| --- | ---: |
| Backup | 440 |
| Model download and installation | 39 |
| Smart Search indexing | 174 |
| Thumbnail and preview cache | 76 |
| Location crawl | 57 |
| Total | 786 |

The archive contains 805 distinct byte blobs. It uses 5,725,886 compressed bytes.
The complete fixture directory uses 8,562,258 bytes, including the manifests and WAL policy proof.
A local focused verification took about 12 seconds after compilation, within the five-minute CI allowance.
The final local gate runtime is recorded in the pull request.

Strict `XCTExpectFailure` blocks retain these recorded defects without changing production behavior:

- #390: model and index boundary 14, after the staging install record and before promotion.
- #391: backup boundaries 3/4, 20/21, 33/34, and 71/72; model 18/19; index 66/67.
  The new empty database has switched to WAL before its WAL file exists, so read-only schema inspection fails.

Only each exact failure signature is expected. A different error remains a failure.
An unexpected pass fails too; remove the matching expectation when its separate fix lands.
The other 772 boundaries pass without an expected failure.
