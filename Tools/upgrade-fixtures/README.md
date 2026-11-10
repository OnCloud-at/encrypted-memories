# Upgrade interruption fixtures

The checker opens disk states written by every recorded stable release when an update terminates the app.
v1.0.5 is the first public App Store release and the oldest supported source.
Versions 1.0.0 through 1.0.4 were admission tests. No user installed them.
The corpus contains synthetic photos, server records, encrypted cache bytes, and tiny synthetic model artifacts.
The checker runs without network access.

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
The checker reads the recorded enable intent before startup. Enabled states must recover without explicit enable or retry.
The installer must verify an artifact before the runtime reads it. Each index recovery may execute at most one synthetic inventory.
Cache reads may return the original complete bytes or no bytes. Location crawling must complete the synthetic inventory.

On macOS, one bounded child process checks each release and scenario with network access denied. Up to three processes run concurrently.
The parent reports crashes, failing assertions, and timeouts. All workers share one 120-second deadline for the complete verification.
The checker rejects missing corpora, unlisted release folders, and manifest metadata that differs from the release list.
The package test target compiles on supported Apple platforms; process isolation runs in the macOS package gate.

This checks Core first launch after process termination. Native host startup, PhotoKit authorization, real service behavior, physical devices, and power loss remain separate checks.
Production behavior and stored formats do not change here.
