import Foundation
import PhotosCore
import SQLite3

/// Account-scoped derived pipeline queue and encrypted output store.
///
/// Assets and artifact descriptors are interned once. The hot work and token indexes contain only
/// integer foreign keys, which avoids repeating long account, namespace and PhotoUID strings for
/// every pipeline stage while preserving independent artifact retry and purge semantics.
public final class SQLiteMLDerivedPipelineStore: MLDerivedPipelineStore, @unchecked Sendable {
    public static let databaseFileName = "ml-derived-index-v1.sqlite"

    // v4 adds transactionally maintained progress counters. The derived store is entirely
    // rebuildable, so a schema mismatch deliberately resets it instead of paying a large
    // migration cost on every device. This prevents a progress update from scanning the complete
    // asset × artifact work matrix after every bounded ML quantum.
    private static let schemaVersion: Int32 = 4
    private static let pending = Int32(0)
    private static let completed = Int32(1)
    private static let skipped = Int32(2)
    private static let permanentFailure = Int32(3)
    private static let retry = Int32(4)

    private let cipher: any MLDerivedDataCipher
    private let walURL: URL
    private let journalSizeLimitBytes: Int
    private let walCheckpointRowThreshold: Int
    private let lock = NSLock()
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private var db: OpaquePointer?
    private var walRowsSinceCheckpoint = 0

    private struct QueuedWork: Sendable {
        let assetID: Int64
        let artifactID: Int64
        let item: MLDerivedPipelineWorkItem
    }

    public init?(
        url: URL,
        policy: LibraryDatabasePolicy = .conservative,
        cipher: any MLDerivedDataCipher
    ) {
        self.cipher = cipher
        walURL = URL(fileURLWithPath: url.path + "-wal")
        journalSizeLimitBytes = policy.journalSizeLimitBytes
        walCheckpointRowThreshold = policy.walCheckpointRowThreshold
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard let handle = Self.openVerified(url: url, policy: policy) else { return nil }
        db = handle
    }

    deinit { close() }

    public func close() {
        lock.withLock {
            guard db != nil else { return }
            checkpointWALLocked(force: true)
            sqlite3_exec(db, "PRAGMA optimize;", nil, nil, nil)
            sqlite3_close(db)
            db = nil
        }
    }

    @discardableResult
    public func enqueue(_ assets: [MLPipelineAssetRevision], for key: MLPipelineExecutionKey) -> Bool {
        return lock.withLock {
            defer { checkpointWALLocked() }
            guard begin(), let artifactIDs = artifactIDsLocked(for: key, create: true) else {
                return rollback()
            }
            guard let removedObsoleteArtifacts = removeObsoleteWorkLocked(for: key) else {
                return rollback()
            }
            if assets.isEmpty {
                guard !removedObsoleteArtifacts || bumpGenerationLocked(for: key) else {
                    return rollback()
                }
                return commitTransaction(
                    rowWrites: removedObsoleteArtifacts ? walCheckpointRowThreshold : 0
                )
            }

            var selectAsset: OpaquePointer?
            var insertAsset: OpaquePointer?
            var updateAsset: OpaquePointer?
            var invalidateWork: OpaquePointer?
            var deleteTokens: OpaquePointer?
            var insertWork: OpaquePointer?
            guard
                prepare(
                    "SELECT asset_id, source_revision FROM ml_derived_assets WHERE account_id=? AND volume_id=? AND node_id=?;",
                    &selectAsset),
                prepare(
                    "INSERT INTO ml_derived_assets(account_id, volume_id, node_id, source_revision) VALUES(?,?,?,?);",
                    &insertAsset),
                prepare("UPDATE ml_derived_assets SET source_revision=? WHERE asset_id=?;", &updateAsset),
                prepare(
                    "UPDATE ml_derived_work SET state=0, attempts=0, retry_at=NULL, terminal_reason=NULL, payload=NULL, updated_at=? WHERE asset_id=?;",
                    &invalidateWork),
                prepare("DELETE FROM ml_derived_tokens WHERE asset_id=?;", &deleteTokens),
                prepare(
                    "INSERT OR IGNORE INTO ml_derived_work(asset_id, artifact_id, state, attempts, retry_at, terminal_reason, payload, updated_at) VALUES(?,?,0,0,NULL,NULL,NULL,?);",
                    &insertWork)
            else {
                finalize([selectAsset, insertAsset, updateAsset, invalidateWork, deleteTokens, insertWork])
                return rollback()
            }
            defer { finalize([selectAsset, insertAsset, updateAsset, invalidateWork, deleteTokens, insertWork]) }

            let now = Date().timeIntervalSince1970
            var changed = removedObsoleteArtifacts
            var invalidatedExistingPipelines = false
            var seenUIDs: Set<PhotoUID> = []
            seenUIDs.reserveCapacity(assets.count)

            for asset in assets where seenUIDs.insert(asset.uid).inserted {
                reset(selectAsset)
                bindText(selectAsset, 1, key.accountIdentifier)
                bindText(selectAsset, 2, asset.uid.volumeID)
                bindText(selectAsset, 3, asset.uid.nodeID)

                let assetID: Int64
                if sqlite3_step(selectAsset) == SQLITE_ROW {
                    assetID = sqlite3_column_int64(selectAsset, 0)
                    let storedRevision = columnText(selectAsset, 1)
                    if storedRevision != asset.sourceRevision {
                        reset(deleteTokens)
                        sqlite3_bind_int64(deleteTokens, 1, assetID)
                        guard sqlite3_step(deleteTokens) == SQLITE_DONE else { return rollback() }

                        reset(invalidateWork)
                        sqlite3_bind_double(invalidateWork, 1, now)
                        sqlite3_bind_int64(invalidateWork, 2, assetID)
                        guard sqlite3_step(invalidateWork) == SQLITE_DONE else { return rollback() }

                        reset(updateAsset)
                        bindText(updateAsset, 1, asset.sourceRevision)
                        sqlite3_bind_int64(updateAsset, 2, assetID)
                        guard sqlite3_step(updateAsset) == SQLITE_DONE else { return rollback() }
                        changed = true
                        invalidatedExistingPipelines = true
                    }
                } else {
                    reset(insertAsset)
                    bindText(insertAsset, 1, key.accountIdentifier)
                    bindText(insertAsset, 2, asset.uid.volumeID)
                    bindText(insertAsset, 3, asset.uid.nodeID)
                    bindText(insertAsset, 4, asset.sourceRevision)
                    guard sqlite3_step(insertAsset) == SQLITE_DONE else { return rollback() }
                    assetID = sqlite3_last_insert_rowid(db)
                    changed = true
                }

                for artifactID in artifactIDs.values {
                    reset(insertWork)
                    sqlite3_bind_int64(insertWork, 1, assetID)
                    sqlite3_bind_int64(insertWork, 2, artifactID)
                    sqlite3_bind_double(insertWork, 3, now)
                    guard sqlite3_step(insertWork) == SQLITE_DONE else { return rollback() }
                    changed = changed || sqlite3_changes(db) > 0
                }
            }

            if changed {
                let bumped =
                    invalidatedExistingPipelines
                    ? bumpAllGenerationsLocked(accountIdentifier: key.accountIdentifier)
                    : bumpGenerationLocked(for: key)
                guard bumped else { return rollback() }
            }
            return commitTransaction(
                rowWrites: changed ? Self.saturatedProduct(assets.count, artifactIDs.count) : 0
            )
        }
    }

    public func nextWorkBatch(
        for key: MLPipelineExecutionKey,
        limit: Int,
        now: Date
    ) -> [MLDerivedPipelineWorkItem] {
        guard limit > 0 else { return [] }
        return lock.withLock {
            guard let artifactIDs = artifactIDsLocked(for: key, create: false), !artifactIDs.isEmpty else { return [] }
            let artifactsByID = Dictionary(
                uniqueKeysWithValues: key.artifacts.compactMap { artifact in
                    artifactIDs[artifact.stableNamespace].map { ($0, artifact) }
                })
            let ids = artifactsByID.keys.sorted()
            // The old combined `state=0 OR retry` query made SQLite start from every account
            // asset and sort the dense work matrix. Query pending and retryable work through their
            // respective partial indexes, then merge the two bounded ordered streams. This keeps
            // retry fairness identical while making the common all-pending path proportional to
            // one quantum instead of the complete library.
            let pending = queuedWorkLocked(
                state: Self.pending,
                accountIdentifier: key.accountIdentifier,
                artifactsByID: artifactsByID,
                artifactIDs: ids,
                limit: limit,
                now: now
            )
            let retryable = queuedWorkLocked(
                state: Self.retry,
                accountIdentifier: key.accountIdentifier,
                artifactsByID: artifactsByID,
                artifactIDs: ids,
                limit: limit,
                now: now
            )
            return mergeQueuedWork(pending, retryable, limit: limit).map(\.item)
        }
    }

    private func queuedWorkLocked(
        state: Int32,
        accountIdentifier: String,
        artifactsByID: [Int64: MLDerivedArtifactIdentity],
        artifactIDs: [Int64],
        limit: Int,
        now: Date
    ) -> [QueuedWork] {
        let predicate: String
        let index: String
        switch state {
        case Self.pending:
            predicate = "w.state=0"
            index = "ml_derived_pending_work"
        case Self.retry:
            predicate = "w.state=4 AND w.retry_at<=?"
            index = "ml_derived_retry_work"
        default:
            return []
        }
        var stmt: OpaquePointer?
        guard
            prepare(
                """
                SELECT w.asset_id, w.artifact_id, a.volume_id, a.node_id, a.source_revision, w.attempts
                FROM ml_derived_work w INDEXED BY \(index)
                JOIN ml_derived_assets a ON a.asset_id=w.asset_id
                WHERE \(predicate)
                  AND w.artifact_id IN (\(Self.placeholders(artifactIDs.count)))
                  AND w.asset_id IN (
                    SELECT asset_id FROM ml_derived_assets WHERE account_id=?
                  )
                ORDER BY w.asset_id, w.artifact_id
                LIMIT ?;
                """,
                &stmt
            )
        else { return [] }
        defer { sqlite3_finalize(stmt) }
        var bindIndex: Int32 = 1
        if state == Self.retry {
            sqlite3_bind_double(stmt, bindIndex, now.timeIntervalSince1970)
            bindIndex += 1
        }
        for id in artifactIDs {
            sqlite3_bind_int64(stmt, bindIndex, id)
            bindIndex += 1
        }
        bindText(stmt, bindIndex, accountIdentifier)
        bindIndex += 1
        sqlite3_bind_int64(stmt, bindIndex, Int64(limit))

        var work: [QueuedWork] = []
        work.reserveCapacity(limit)
        while sqlite3_step(stmt) == SQLITE_ROW {
            let artifactID = sqlite3_column_int64(stmt, 1)
            guard let artifact = artifactsByID[artifactID],
                let asset = try? MLPipelineAssetRevision(
                    uid: PhotoUID(volumeID: columnText(stmt, 2), nodeID: columnText(stmt, 3)),
                    sourceRevision: columnText(stmt, 4)
                )
            else { continue }
            work.append(
                QueuedWork(
                    assetID: sqlite3_column_int64(stmt, 0),
                    artifactID: artifactID,
                    item: MLDerivedPipelineWorkItem(
                        asset: asset,
                        artifact: artifact,
                        attempts: Int(sqlite3_column_int64(stmt, 5))
                    )
                ))
        }
        return work
    }

    private func mergeQueuedWork(
        _ pending: [QueuedWork],
        _ retryable: [QueuedWork],
        limit: Int
    ) -> [QueuedWork] {
        var result: [QueuedWork] = []
        result.reserveCapacity(limit)
        var pendingIndex = 0
        var retryIndex = 0
        while result.count < limit, pendingIndex < pending.count || retryIndex < retryable.count {
            let next: QueuedWork
            if retryIndex == retryable.count {
                next = pending[pendingIndex]
                pendingIndex += 1
            } else if pendingIndex == pending.count {
                next = retryable[retryIndex]
                retryIndex += 1
            } else {
                let pendingItem = pending[pendingIndex]
                let retryItem = retryable[retryIndex]
                if pendingItem.assetID < retryItem.assetID
                    || (pendingItem.assetID == retryItem.assetID
                        && pendingItem.artifactID <= retryItem.artifactID)
                {
                    next = pendingItem
                    pendingIndex += 1
                } else {
                    next = retryItem
                    retryIndex += 1
                }
            }
            result.append(next)
        }
        return result
    }

    @discardableResult
    public func commit(
        _ results: [MLPipelineStageResult],
        for key: MLPipelineExecutionKey,
        now: Date
    ) -> Bool {
        guard !results.isEmpty else { return true }
        return lock.withLock {
            defer { checkpointWALLocked() }
            guard begin(), let artifactIDs = artifactIDsLocked(for: key, create: false) else {
                return rollback()
            }
            var selectAsset: OpaquePointer?
            var updateWork: OpaquePointer?
            var deleteTokens: OpaquePointer?
            var insertToken: OpaquePointer?
            guard
                prepare(
                    "SELECT asset_id FROM ml_derived_assets WHERE account_id=? AND volume_id=? AND node_id=? AND source_revision=?;",
                    &selectAsset),
                prepare(
                    "UPDATE ml_derived_work SET state=?, attempts=attempts+1, retry_at=?, terminal_reason=?, payload=?, updated_at=? WHERE asset_id=? AND artifact_id=?;",
                    &updateWork),
                prepare("DELETE FROM ml_derived_tokens WHERE asset_id=? AND artifact_id=?;", &deleteTokens),
                prepare(
                    "INSERT OR IGNORE INTO ml_derived_tokens(asset_id, artifact_id, token_digest) VALUES(?,?,?);",
                    &insertToken)
            else {
                finalize([selectAsset, updateWork, deleteTokens, insertToken])
                return rollback()
            }
            defer { finalize([selectAsset, updateWork, deleteTokens, insertToken]) }

            var changed = false
            var changedRows = 0
            for result in results where key.artifacts.contains(result.workItem.artifact) {
                let item = result.workItem
                guard let artifactID = artifactIDs[item.artifact.stableNamespace] else { continue }
                reset(selectAsset)
                bindText(selectAsset, 1, key.accountIdentifier)
                bindText(selectAsset, 2, item.asset.uid.volumeID)
                bindText(selectAsset, 3, item.asset.uid.nodeID)
                bindText(selectAsset, 4, item.asset.sourceRevision)
                guard sqlite3_step(selectAsset) == SQLITE_ROW else { continue }
                let assetID = sqlite3_column_int64(selectAsset, 0)

                let state: Int32
                let retryAt: Date?
                let terminalReason: String?
                let ciphertext: Data?
                let tokens: [String]
                switch result.outcome {
                case .completed(let output):
                    state = Self.completed
                    retryAt = nil
                    terminalReason = nil
                    tokens = output.normalizedSearchTokens
                    do {
                        ciphertext = try cipher.seal(
                            output.payload,
                            context: cipherContext(
                                accountIdentifier: key.accountIdentifier,
                                item: item
                            ))
                    } catch { return rollback() }
                case .completedEmpty:
                    state = Self.completed
                    retryAt = nil
                    terminalReason = MLPipelineSkipReason.emptyOutput.rawValue
                    ciphertext = nil
                    tokens = []
                case .skipped(let reason):
                    state = Self.skipped
                    retryAt = nil
                    terminalReason = reason.rawValue
                    ciphertext = nil
                    tokens = []
                case .retryableFailure(let reason, let date):
                    state = Self.retry
                    retryAt = date ?? now
                    terminalReason = reason.rawValue
                    ciphertext = nil
                    tokens = []
                case .permanentInputFailure(let reason):
                    state = Self.permanentFailure
                    retryAt = nil
                    terminalReason = reason.rawValue
                    ciphertext = nil
                    tokens = []
                case .cancelled, .suspended:
                    continue
                }

                reset(updateWork)
                sqlite3_bind_int(updateWork, 1, state)
                if let retryAt {
                    sqlite3_bind_double(updateWork, 2, retryAt.timeIntervalSince1970)
                } else {
                    sqlite3_bind_null(updateWork, 2)
                }
                if let terminalReason {
                    bindText(updateWork, 3, terminalReason)
                } else {
                    sqlite3_bind_null(updateWork, 3)
                }
                if let ciphertext { bindBlob(updateWork, 4, ciphertext) } else { sqlite3_bind_null(updateWork, 4) }
                sqlite3_bind_double(updateWork, 5, now.timeIntervalSince1970)
                sqlite3_bind_int64(updateWork, 6, assetID)
                sqlite3_bind_int64(updateWork, 7, artifactID)
                guard sqlite3_step(updateWork) == SQLITE_DONE else { return rollback() }
                guard sqlite3_changes(db) > 0 else { continue }

                reset(deleteTokens)
                sqlite3_bind_int64(deleteTokens, 1, assetID)
                sqlite3_bind_int64(deleteTokens, 2, artifactID)
                guard sqlite3_step(deleteTokens) == SQLITE_DONE else { return rollback() }

                for token in tokens {
                    let digest: Data
                    do {
                        digest = try cipher.tokenDigest(
                            normalizedToken: token,
                            accountIdentifier: key.accountIdentifier,
                            artifactNamespace: item.artifact.stableNamespace
                        )
                    } catch { return rollback() }
                    reset(insertToken)
                    sqlite3_bind_int64(insertToken, 1, assetID)
                    sqlite3_bind_int64(insertToken, 2, artifactID)
                    bindBlob(insertToken, 3, digest)
                    guard sqlite3_step(insertToken) == SQLITE_DONE else { return rollback() }
                }
                changed = true
                changedRows += 1
            }
            guard !changed || bumpGenerationLocked(for: key) else { return rollback() }
            return commitTransaction(rowWrites: changedRows)
        }
    }

    public func progress(for key: MLPipelineExecutionKey) -> MLDerivedPipelineProgress {
        lock.withLock {
            guard let artifactIDs = artifactIDsLocked(for: key, create: false), !artifactIDs.isEmpty else {
                return emptyProgress(for: key)
            }
            let ids = artifactIDs.values.sorted()
            var stmt: OpaquePointer?
            guard
                prepare(
                    """
                    SELECT COALESCE(SUM(total), 0),
                      COALESCE(SUM(completed), 0),
                      COALESCE(SUM(skipped), 0),
                      COALESCE(SUM(permanent_failure), 0),
                      COALESCE(SUM(retry_pending), 0)
                    FROM ml_derived_progress
                    WHERE account_id=? AND pipeline_id=? AND schema_version=?
                      AND artifact_id IN (\(Self.placeholders(ids.count)));
                    """,
                    &stmt
                )
            else { return emptyProgress(for: key) }
            defer { sqlite3_finalize(stmt) }
            var index: Int32 = 1
            bindText(stmt, index, key.accountIdentifier)
            index += 1
            bindText(stmt, index, key.pipelineID.rawValue)
            index += 1
            sqlite3_bind_int64(stmt, index, Int64(key.schemaVersion))
            index += 1
            for id in ids {
                sqlite3_bind_int64(stmt, index, id)
                index += 1
            }
            guard sqlite3_step(stmt) == SQLITE_ROW else { return emptyProgress(for: key) }
            let permanentFailure = Int(sqlite3_column_int64(stmt, 3))
            return MLDerivedPipelineProgress(
                total: Int(sqlite3_column_int64(stmt, 0)),
                completed: Int(sqlite3_column_int64(stmt, 1)),
                skipped: Int(sqlite3_column_int64(stmt, 2)),
                permanentFailure: permanentFailure,
                retryPending: Int(sqlite3_column_int64(stmt, 4)),
                // Terminal input failures are exceptional. Keep their detailed, asset-level
                // diagnostics precise without making the normal zero-failure path scan work.
                unavailableAssets: permanentFailure == 0
                    ? 0
                    : unavailableAssetCountLocked(accountIdentifier: key.accountIdentifier, artifactIDs: ids),
                unavailableAssetReasons: permanentFailure == 0
                    ? [:]
                    : unavailableAssetReasonsLocked(accountIdentifier: key.accountIdentifier, artifactIDs: ids),
                generation: generationLocked(for: key)
            )
        }
    }

    public func unavailableAssetUIDs(for key: MLPipelineExecutionKey) -> Set<PhotoUID> {
        lock.withLock {
            guard let artifactIDs = artifactIDsLocked(for: key, create: false), !artifactIDs.isEmpty else {
                return []
            }
            let ids = artifactIDs.values.sorted()
            var stmt: OpaquePointer?
            guard
                prepare(
                    """
                    SELECT DISTINCT a.volume_id, a.node_id
                    FROM ml_derived_work w
                    JOIN ml_derived_assets a ON a.asset_id=w.asset_id
                    WHERE a.account_id=? AND w.state=3
                      AND w.artifact_id IN (\(Self.placeholders(ids.count)));
                    """,
                    &stmt
                )
            else { return [] }
            defer { sqlite3_finalize(stmt) }
            var index: Int32 = 1
            bindText(stmt, index, key.accountIdentifier)
            index += 1
            for id in ids {
                sqlite3_bind_int64(stmt, index, id)
                index += 1
            }
            var result: Set<PhotoUID> = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let volumeID = columnText(stmt, 0)
                let nodeID = columnText(stmt, 1)
                result.insert(PhotoUID(volumeID: volumeID, nodeID: nodeID))
            }
            return result
        }
    }

    public func output(
        for uid: PhotoUID,
        artifact: MLDerivedArtifactIdentity,
        accountIdentifier: String
    ) -> MLDerivedPipelineOutput? {
        lock.withLock {
            var stmt: OpaquePointer?
            guard
                prepare(
                    """
                    SELECT w.payload
                    FROM ml_derived_work w
                    JOIN ml_derived_assets a ON a.asset_id=w.asset_id
                    JOIN ml_derived_artifacts f ON f.artifact_id=w.artifact_id
                    WHERE a.account_id=? AND a.volume_id=? AND a.node_id=?
                      AND f.artifact_namespace=? AND w.state=1;
                    """,
                    &stmt
                )
            else { return nil }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, accountIdentifier)
            bindText(stmt, 2, uid.volumeID)
            bindText(stmt, 3, uid.nodeID)
            bindText(stmt, 4, artifact.stableNamespace)
            guard sqlite3_step(stmt) == SQLITE_ROW, let ciphertext = columnBlob(stmt, 0) else { return nil }
            let context = MLDerivedDataCipherContext(
                accountIdentifier: accountIdentifier,
                uid: uid,
                artifactNamespace: artifact.stableNamespace
            )
            guard let plaintext = try? cipher.open(ciphertext, context: context) else { return nil }
            return MLDerivedPipelineOutput(payload: plaintext)
        }
    }

    public func search(
        normalizedTokens: [String],
        in key: MLPipelineExecutionKey,
        limit: Int
    ) -> [MLDerivedSearchHit] {
        let tokens = Array(Set(normalizedTokens.filter { !$0.isEmpty })).sorted()
        guard !tokens.isEmpty, limit > 0 else { return [] }
        return lock.withLock {
            guard let artifactIDs = artifactIDsLocked(for: key, create: false), !artifactIDs.isEmpty else { return [] }
            let artifacts = key.artifacts.sorted { $0.stableNamespace < $1.stableNamespace }
            let digestGroups: [[(artifactID: Int64, digest: Data)]]
            do {
                digestGroups = try tokens.map { token in
                    try artifacts.compactMap { artifact in
                        guard let artifactID = artifactIDs[artifact.stableNamespace] else { return nil }
                        return (
                            artifactID,
                            try cipher.tokenDigest(
                                normalizedToken: token,
                                accountIdentifier: key.accountIdentifier,
                                artifactNamespace: artifact.stableNamespace
                            )
                        )
                    }
                }
            } catch { return [] }
            guard digestGroups.allSatisfy({ !$0.isEmpty }) else { return [] }

            let conditions = digestGroups.map { group in
                let pairs = Array(repeating: "(t.artifact_id=? AND t.token_digest=?)", count: group.count)
                    .joined(separator: " OR ")
                return "EXISTS(SELECT 1 FROM ml_derived_tokens t WHERE t.asset_id=a.asset_id AND (\(pairs)))"
            }.joined(separator: " AND ")
            var stmt: OpaquePointer?
            guard
                prepare(
                    """
                    SELECT a.volume_id, a.node_id
                    FROM ml_derived_assets a
                    WHERE a.account_id=? AND \(conditions)
                    ORDER BY a.asset_id
                    LIMIT ?;
                    """,
                    &stmt
                )
            else { return [] }
            defer { sqlite3_finalize(stmt) }
            var index: Int32 = 1
            bindText(stmt, index, key.accountIdentifier)
            index += 1
            for group in digestGroups {
                for pair in group {
                    sqlite3_bind_int64(stmt, index, pair.artifactID)
                    index += 1
                    bindBlob(stmt, index, pair.digest)
                    index += 1
                }
            }
            sqlite3_bind_int64(stmt, index, Int64(limit))

            var hits: [MLDerivedSearchHit] = []
            hits.reserveCapacity(min(limit, 64))
            while sqlite3_step(stmt) == SQLITE_ROW {
                hits.append(
                    MLDerivedSearchHit(
                        uid: PhotoUID(volumeID: columnText(stmt, 0), nodeID: columnText(stmt, 1)),
                        matchedTokenCount: tokens.count
                    ))
            }
            return hits
        }
    }

    @discardableResult
    public func reconcile(liveUIDs: Set<PhotoUID>, for key: MLPipelineExecutionKey) -> Bool {
        lock.withLock {
            defer { checkpointWALLocked() }
            guard let artifactIDs = artifactIDsLocked(for: key, create: false), !artifactIDs.isEmpty else {
                return true
            }
            let ids = artifactIDs.values.sorted()
            var select: OpaquePointer?
            guard
                prepare(
                    """
                    SELECT DISTINCT a.asset_id, a.volume_id, a.node_id
                    FROM ml_derived_assets a
                    JOIN ml_derived_work w ON w.asset_id=a.asset_id
                    WHERE a.account_id=? AND w.artifact_id IN (\(Self.placeholders(ids.count)));
                    """,
                    &select
                )
            else { return false }
            var index: Int32 = 1
            bindText(select, index, key.accountIdentifier)
            index += 1
            for id in ids {
                sqlite3_bind_int64(select, index, id)
                index += 1
            }
            var staleAssetIDs: [Int64] = []
            while sqlite3_step(select) == SQLITE_ROW {
                let uid = PhotoUID(volumeID: columnText(select, 1), nodeID: columnText(select, 2))
                if !liveUIDs.contains(uid) { staleAssetIDs.append(sqlite3_column_int64(select, 0)) }
            }
            sqlite3_finalize(select)
            guard !staleAssetIDs.isEmpty else { return true }
            guard begin() else { return false }

            var deleteWork: OpaquePointer?
            var deleteOrphan: OpaquePointer?
            guard
                prepare(
                    "DELETE FROM ml_derived_work WHERE asset_id=? AND artifact_id IN (\(Self.placeholders(ids.count)));",
                    &deleteWork
                ),
                prepare(
                    "DELETE FROM ml_derived_assets WHERE asset_id=? AND NOT EXISTS(SELECT 1 FROM ml_derived_work WHERE asset_id=?);",
                    &deleteOrphan
                )
            else {
                finalize([deleteWork, deleteOrphan])
                return rollback()
            }
            defer { finalize([deleteWork, deleteOrphan]) }
            for assetID in staleAssetIDs {
                reset(deleteWork)
                sqlite3_bind_int64(deleteWork, 1, assetID)
                var binding: Int32 = 2
                for id in ids {
                    sqlite3_bind_int64(deleteWork, binding, id)
                    binding += 1
                }
                guard sqlite3_step(deleteWork) == SQLITE_DONE else { return rollback() }

                reset(deleteOrphan)
                sqlite3_bind_int64(deleteOrphan, 1, assetID)
                sqlite3_bind_int64(deleteOrphan, 2, assetID)
                guard sqlite3_step(deleteOrphan) == SQLITE_DONE else { return rollback() }
            }
            guard bumpGenerationLocked(for: key) else { return rollback() }
            return commitTransaction(
                rowWrites: Self.saturatedProduct(staleAssetIDs.count, ids.count)
            )
        }
    }

    public func purge(artifact: MLDerivedArtifactIdentity, accountIdentifier: String) {
        lock.withLock {
            defer { checkpointWALLocked() }
            guard let artifactID = artifactIDLocked(namespace: artifact.stableNamespace) else { return }
            guard begin(),
                deleteWorkLocked(accountIdentifier: accountIdentifier, artifactIDs: [artifactID]),
                deleteOrphanAssetsLocked(accountIdentifier: accountIdentifier),
                bumpGenerationsLocked(accountIdentifier: accountIdentifier, pipelineID: artifact.pipelineID.rawValue)
            else {
                _ = rollback()
                return
            }
            _ = commitTransaction(rowWrites: walCheckpointRowThreshold)
        }
    }

    public func purge(pipelineID: MLPipelineID, accountIdentifier: String) {
        lock.withLock {
            defer { checkpointWALLocked() }
            let artifactIDs = artifactIDsLocked(pipelineID: pipelineID.rawValue)
            guard !artifactIDs.isEmpty else { return }
            guard begin(),
                deleteWorkLocked(accountIdentifier: accountIdentifier, artifactIDs: artifactIDs),
                deleteOrphanAssetsLocked(accountIdentifier: accountIdentifier),
                bumpGenerationsLocked(accountIdentifier: accountIdentifier, pipelineID: pipelineID.rawValue)
            else {
                _ = rollback()
                return
            }
            _ = commitTransaction(rowWrites: walCheckpointRowThreshold)
        }
    }

    private static func openVerified(url: URL, policy: LibraryDatabasePolicy) -> OpaquePointer? {
        if let handle = openOnce(url: url, policy: policy) { return handle }
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
        }
        return openOnce(url: url, policy: policy)
    }

    private static func openOnce(url: URL, policy: LibraryDatabasePolicy) -> OpaquePointer? {
        var handle: OpaquePointer?
        guard sqlite3_open(url.path, &handle) == SQLITE_OK else {
            sqlite3_close(handle)
            return nil
        }
        sqlite3_exec(handle, "PRAGMA foreign_keys=ON;", nil, nil, nil)
        sqlite3_exec(handle, "PRAGMA journal_mode=WAL;", nil, nil, nil)
        sqlite3_exec(handle, "PRAGMA synchronous=NORMAL;", nil, nil, nil)
        sqlite3_exec(handle, "PRAGMA busy_timeout=\(policy.busyTimeoutMs);", nil, nil, nil)
        sqlite3_exec(handle, "PRAGMA cache_size=-\(max(0, policy.cacheSizeKiB));", nil, nil, nil)
        sqlite3_exec(handle, "PRAGMA mmap_size=\(max(0, policy.mmapBytes));", nil, nil, nil)
        sqlite3_exec(handle, "PRAGMA journal_size_limit=\(policy.journalSizeLimitBytes);", nil, nil, nil)
        let schema = """
            CREATE TABLE IF NOT EXISTS ml_derived_assets(
              asset_id         INTEGER PRIMARY KEY,
              account_id       TEXT NOT NULL,
              volume_id        TEXT NOT NULL,
              node_id          TEXT NOT NULL,
              source_revision  TEXT NOT NULL,
              UNIQUE(account_id, volume_id, node_id)
            );
            CREATE TABLE IF NOT EXISTS ml_derived_artifacts(
              artifact_id          INTEGER PRIMARY KEY,
              pipeline_id          TEXT NOT NULL,
              schema_version       INTEGER NOT NULL,
              artifact_namespace  TEXT NOT NULL UNIQUE
            );
            CREATE TABLE IF NOT EXISTS ml_derived_work(
              asset_id     INTEGER NOT NULL,
              artifact_id  INTEGER NOT NULL,
              state        INTEGER NOT NULL,
              attempts     INTEGER NOT NULL,
              retry_at     REAL,
              terminal_reason TEXT,
              payload      BLOB,
              updated_at   REAL NOT NULL,
              PRIMARY KEY(asset_id, artifact_id),
              FOREIGN KEY(asset_id) REFERENCES ml_derived_assets(asset_id) ON DELETE CASCADE,
              FOREIGN KEY(artifact_id) REFERENCES ml_derived_artifacts(artifact_id) ON DELETE CASCADE
            ) WITHOUT ROWID;
            CREATE INDEX IF NOT EXISTS ml_derived_next_work
              ON ml_derived_work(artifact_id, state, retry_at, asset_id);
            CREATE INDEX IF NOT EXISTS ml_derived_pending_work
              ON ml_derived_work(asset_id, artifact_id) WHERE state=0;
            CREATE INDEX IF NOT EXISTS ml_derived_retry_work
              ON ml_derived_work(retry_at, asset_id, artifact_id) WHERE state=4;
            CREATE INDEX IF NOT EXISTS ml_derived_permanent_failure_work
              ON ml_derived_work(asset_id, artifact_id) WHERE state=3;
            CREATE TABLE IF NOT EXISTS ml_derived_tokens(
              asset_id      INTEGER NOT NULL,
              artifact_id   INTEGER NOT NULL,
              token_digest  BLOB NOT NULL,
              PRIMARY KEY(asset_id, artifact_id, token_digest),
              FOREIGN KEY(asset_id, artifact_id)
                REFERENCES ml_derived_work(asset_id, artifact_id) ON DELETE CASCADE
            ) WITHOUT ROWID;
            CREATE INDEX IF NOT EXISTS ml_derived_token_lookup
              ON ml_derived_tokens(artifact_id, token_digest, asset_id);
            CREATE TABLE IF NOT EXISTS ml_derived_generation(
              account_id      TEXT NOT NULL,
              pipeline_id     TEXT NOT NULL,
              schema_version  INTEGER NOT NULL,
              generation      INTEGER NOT NULL,
              PRIMARY KEY(account_id, pipeline_id, schema_version)
            ) WITHOUT ROWID;
            CREATE TABLE IF NOT EXISTS ml_derived_progress(
              account_id        TEXT NOT NULL,
              pipeline_id       TEXT NOT NULL,
              schema_version    INTEGER NOT NULL,
              artifact_id       INTEGER NOT NULL,
              total             INTEGER NOT NULL DEFAULT 0,
              completed         INTEGER NOT NULL DEFAULT 0,
              skipped           INTEGER NOT NULL DEFAULT 0,
              permanent_failure INTEGER NOT NULL DEFAULT 0,
              retry_pending     INTEGER NOT NULL DEFAULT 0,
              PRIMARY KEY(account_id, pipeline_id, schema_version, artifact_id),
              FOREIGN KEY(artifact_id) REFERENCES ml_derived_artifacts(artifact_id) ON DELETE CASCADE
            ) WITHOUT ROWID;
            CREATE TRIGGER IF NOT EXISTS ml_derived_work_progress_insert
            AFTER INSERT ON ml_derived_work BEGIN
              INSERT INTO ml_derived_progress(
                account_id, pipeline_id, schema_version, artifact_id,
                total, completed, skipped, permanent_failure, retry_pending
              )
              SELECT a.account_id, f.pipeline_id, f.schema_version, NEW.artifact_id,
                1, NEW.state=1, NEW.state=2, NEW.state=3, NEW.state=4
              FROM ml_derived_assets a
              JOIN ml_derived_artifacts f ON f.artifact_id=NEW.artifact_id
              WHERE a.asset_id=NEW.asset_id
              ON CONFLICT(account_id, pipeline_id, schema_version, artifact_id) DO UPDATE SET
                total=total+1,
                completed=completed+(NEW.state=1),
                skipped=skipped+(NEW.state=2),
                permanent_failure=permanent_failure+(NEW.state=3),
                retry_pending=retry_pending+(NEW.state=4);
            END;
            CREATE TRIGGER IF NOT EXISTS ml_derived_work_progress_update
            AFTER UPDATE OF state ON ml_derived_work BEGIN
              UPDATE ml_derived_progress SET
                completed=completed-(OLD.state=1)+(NEW.state=1),
                skipped=skipped-(OLD.state=2)+(NEW.state=2),
                permanent_failure=permanent_failure-(OLD.state=3)+(NEW.state=3),
                retry_pending=retry_pending-(OLD.state=4)+(NEW.state=4)
              WHERE artifact_id=NEW.artifact_id
                AND account_id=(SELECT account_id FROM ml_derived_assets WHERE asset_id=NEW.asset_id)
                AND pipeline_id=(SELECT pipeline_id FROM ml_derived_artifacts WHERE artifact_id=NEW.artifact_id)
                AND schema_version=(SELECT schema_version FROM ml_derived_artifacts WHERE artifact_id=NEW.artifact_id);
            END;
            CREATE TRIGGER IF NOT EXISTS ml_derived_work_progress_delete
            AFTER DELETE ON ml_derived_work BEGIN
              UPDATE ml_derived_progress SET
                total=total-1,
                completed=completed-(OLD.state=1),
                skipped=skipped-(OLD.state=2),
                permanent_failure=permanent_failure-(OLD.state=3),
                retry_pending=retry_pending-(OLD.state=4)
              WHERE artifact_id=OLD.artifact_id
                AND account_id=(SELECT account_id FROM ml_derived_assets WHERE asset_id=OLD.asset_id)
                AND pipeline_id=(SELECT pipeline_id FROM ml_derived_artifacts WHERE artifact_id=OLD.artifact_id)
                AND schema_version=(SELECT schema_version FROM ml_derived_artifacts WHERE artifact_id=OLD.artifact_id);
              DELETE FROM ml_derived_progress WHERE total=0;
            END;
            """
        guard sqlite3_exec(handle, schema, nil, nil, nil) == SQLITE_OK,
            verifyAndStampVersion(handle)
        else {
            sqlite3_close(handle)
            return nil
        }
        // A previous process may have exited with a large committed WAL. This is the one canonical
        // derived index, so fold it into the main database before starting another indexing pass.
        _ = sqlite3_wal_checkpoint_v2(
            handle,
            nil,
            SQLITE_CHECKPOINT_TRUNCATE,
            nil,
            nil
        )
        return handle
    }

    private static func verifyAndStampVersion(_ handle: OpaquePointer?) -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "PRAGMA user_version;", -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return false }
        let version = sqlite3_column_int(stmt, 0)
        if version == 0 {
            return sqlite3_exec(handle, "PRAGMA user_version=\(schemaVersion);", nil, nil, nil) == SQLITE_OK
        }
        return version == schemaVersion
    }

    private func artifactIDsLocked(
        for key: MLPipelineExecutionKey,
        create: Bool
    ) -> [String: Int64]? {
        var insert: OpaquePointer?
        if create,
            !prepare(
                "INSERT OR IGNORE INTO ml_derived_artifacts(pipeline_id, schema_version, artifact_namespace) VALUES(?,?,?);",
                &insert
            )
        {
            return nil
        }
        defer { sqlite3_finalize(insert) }
        var select: OpaquePointer?
        guard
            prepare(
                "SELECT artifact_id, pipeline_id, schema_version FROM ml_derived_artifacts WHERE artifact_namespace=?;",
                &select
            )
        else { return nil }
        defer { sqlite3_finalize(select) }

        var result: [String: Int64] = [:]
        result.reserveCapacity(key.artifacts.count)
        for artifact in key.artifacts {
            if create {
                reset(insert)
                bindText(insert, 1, key.pipelineID.rawValue)
                sqlite3_bind_int64(insert, 2, Int64(key.schemaVersion))
                bindText(insert, 3, artifact.stableNamespace)
                guard sqlite3_step(insert) == SQLITE_DONE else { return nil }
            }
            reset(select)
            bindText(select, 1, artifact.stableNamespace)
            guard sqlite3_step(select) == SQLITE_ROW,
                columnText(select, 1) == key.pipelineID.rawValue,
                sqlite3_column_int64(select, 2) == Int64(key.schemaVersion)
            else { continue }
            result[artifact.stableNamespace] = sqlite3_column_int64(select, 0)
        }
        return result
    }

    private func artifactIDLocked(namespace: String) -> Int64? {
        var stmt: OpaquePointer?
        guard prepare("SELECT artifact_id FROM ml_derived_artifacts WHERE artifact_namespace=?;", &stmt) else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, namespace)
        return sqlite3_step(stmt) == SQLITE_ROW ? sqlite3_column_int64(stmt, 0) : nil
    }

    private func artifactIDsLocked(pipelineID: String) -> [Int64] {
        var stmt: OpaquePointer?
        guard prepare("SELECT artifact_id FROM ml_derived_artifacts WHERE pipeline_id=?;", &stmt) else { return [] }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, pipelineID)
        var ids: [Int64] = []
        while sqlite3_step(stmt) == SQLITE_ROW { ids.append(sqlite3_column_int64(stmt, 0)) }
        return ids
    }

    /// Removes account-local work from older request revisions or stages no longer present in the
    /// active execution key. Artifact descriptors remain interned while any account still uses
    /// them; only encrypted work, postings, and now-orphaned assets are reclaimed here.
    private func removeObsoleteWorkLocked(for key: MLPipelineExecutionKey) -> Bool? {
        let namespaces = key.artifacts.map(\.stableNamespace).sorted()
        guard !namespaces.isEmpty else { return false }
        var stmt: OpaquePointer?
        guard
            prepare(
                """
                DELETE FROM ml_derived_work
                WHERE asset_id IN (
                  SELECT asset_id FROM ml_derived_assets WHERE account_id=?
                )
                  AND artifact_id IN (
                    SELECT artifact_id
                    FROM ml_derived_artifacts
                    WHERE pipeline_id=?
                      AND artifact_namespace NOT IN (\(Self.placeholders(namespaces.count)))
                  );
                """,
                &stmt
            )
        else { return nil }
        defer { sqlite3_finalize(stmt) }
        var index: Int32 = 1
        bindText(stmt, index, key.accountIdentifier)
        index += 1
        bindText(stmt, index, key.pipelineID.rawValue)
        index += 1
        for namespace in namespaces {
            bindText(stmt, index, namespace)
            index += 1
        }
        guard sqlite3_step(stmt) == SQLITE_DONE else { return nil }
        let changed = sqlite3_changes(db) > 0
        guard !changed || deleteOrphanAssetsLocked(accountIdentifier: key.accountIdentifier) else {
            return nil
        }
        return changed
    }

    private func deleteWorkLocked(accountIdentifier: String, artifactIDs: [Int64]) -> Bool {
        guard !artifactIDs.isEmpty else { return true }
        var stmt: OpaquePointer?
        guard
            prepare(
                "DELETE FROM ml_derived_work WHERE artifact_id IN (\(Self.placeholders(artifactIDs.count))) AND asset_id IN (SELECT asset_id FROM ml_derived_assets WHERE account_id=?);",
                &stmt
            )
        else { return false }
        defer { sqlite3_finalize(stmt) }
        var index: Int32 = 1
        for id in artifactIDs {
            sqlite3_bind_int64(stmt, index, id)
            index += 1
        }
        bindText(stmt, index, accountIdentifier)
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    private func deleteOrphanAssetsLocked(accountIdentifier: String) -> Bool {
        var stmt: OpaquePointer?
        guard
            prepare(
                "DELETE FROM ml_derived_assets WHERE account_id=? AND NOT EXISTS(SELECT 1 FROM ml_derived_work WHERE asset_id=ml_derived_assets.asset_id);",
                &stmt
            )
        else { return false }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, accountIdentifier)
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    private func unavailableAssetReasonsLocked(
        accountIdentifier: String,
        artifactIDs: [Int64]
    ) -> [MLPipelineFailureReason: Int] {
        guard !artifactIDs.isEmpty else { return [:] }
        var stmt: OpaquePointer?
        guard
            prepare(
                """
                SELECT reason, COUNT(*)
                FROM (
                  SELECT w.asset_id, MIN(w.terminal_reason) AS reason
                  FROM ml_derived_work w
                  JOIN ml_derived_assets a ON a.asset_id=w.asset_id
                  WHERE a.account_id=? AND w.state=3
                    AND w.artifact_id IN (\(Self.placeholders(artifactIDs.count)))
                    AND w.terminal_reason IS NOT NULL
                  GROUP BY w.asset_id
                )
                GROUP BY reason;
                """,
                &stmt
            )
        else { return [:] }
        defer { sqlite3_finalize(stmt) }
        var index: Int32 = 1
        bindText(stmt, index, accountIdentifier)
        index += 1
        for id in artifactIDs {
            sqlite3_bind_int64(stmt, index, id)
            index += 1
        }

        var reasons: [MLPipelineFailureReason: Int] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let reason = MLPipelineFailureReason(rawValue: columnText(stmt, 0)) else { continue }
            reasons[reason] = Int(sqlite3_column_int64(stmt, 1))
        }
        return reasons
    }

    private func unavailableAssetCountLocked(
        accountIdentifier: String,
        artifactIDs: [Int64]
    ) -> Int {
        guard !artifactIDs.isEmpty else { return 0 }
        var stmt: OpaquePointer?
        guard
            prepare(
                """
                SELECT COUNT(DISTINCT w.asset_id)
                FROM ml_derived_work w
                JOIN ml_derived_assets a ON a.asset_id=w.asset_id
                WHERE a.account_id=? AND w.state=3
                  AND w.artifact_id IN (\(Self.placeholders(artifactIDs.count)));
                """,
                &stmt
            )
        else { return 0 }
        defer { sqlite3_finalize(stmt) }
        var index: Int32 = 1
        bindText(stmt, index, accountIdentifier)
        index += 1
        for id in artifactIDs {
            sqlite3_bind_int64(stmt, index, id)
            index += 1
        }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    private func emptyProgress(for key: MLPipelineExecutionKey) -> MLDerivedPipelineProgress {
        MLDerivedPipelineProgress(
            total: 0,
            completed: 0,
            skipped: 0,
            permanentFailure: 0,
            retryPending: 0,
            generation: generationLocked(for: key)
        )
    }

    private func bumpGenerationLocked(for key: MLPipelineExecutionKey) -> Bool {
        var stmt: OpaquePointer?
        guard
            prepare(
                """
                INSERT INTO ml_derived_generation(account_id, pipeline_id, schema_version, generation)
                VALUES(?,?,?,1)
                ON CONFLICT(account_id, pipeline_id, schema_version)
                DO UPDATE SET generation=generation+1;
                """,
                &stmt
            )
        else { return false }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, key.accountIdentifier)
        bindText(stmt, 2, key.pipelineID.rawValue)
        sqlite3_bind_int64(stmt, 3, Int64(key.schemaVersion))
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    private func bumpAllGenerationsLocked(accountIdentifier: String) -> Bool {
        var stmt: OpaquePointer?
        guard
            prepare(
                "UPDATE ml_derived_generation SET generation=generation+1 WHERE account_id=?;",
                &stmt
            )
        else { return false }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, accountIdentifier)
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    private func bumpGenerationsLocked(accountIdentifier: String, pipelineID: String) -> Bool {
        var stmt: OpaquePointer?
        guard
            prepare(
                "UPDATE ml_derived_generation SET generation=generation+1 WHERE account_id=? AND pipeline_id=?;",
                &stmt
            )
        else { return false }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, accountIdentifier)
        bindText(stmt, 2, pipelineID)
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    private func generationLocked(for key: MLPipelineExecutionKey) -> UInt64 {
        var stmt: OpaquePointer?
        guard
            prepare(
                "SELECT generation FROM ml_derived_generation WHERE account_id=? AND pipeline_id=? AND schema_version=?;",
                &stmt
            )
        else { return 0 }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, key.accountIdentifier)
        bindText(stmt, 2, key.pipelineID.rawValue)
        sqlite3_bind_int64(stmt, 3, Int64(key.schemaVersion))
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return UInt64(max(0, sqlite3_column_int64(stmt, 0)))
    }

    private func begin() -> Bool {
        db != nil && sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK
    }

    @discardableResult
    private func rollback() -> Bool {
        sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
        return false
    }

    private func commitTransaction(rowWrites: Int = 0) -> Bool {
        guard sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK else { return rollback() }
        if rowWrites > 0 {
            let (sum, overflow) = walRowsSinceCheckpoint.addingReportingOverflow(rowWrites)
            walRowsSinceCheckpoint = overflow ? Int.max : sum
        }
        return true
    }

    private static func saturatedProduct(_ lhs: Int, _ rhs: Int) -> Int {
        let (product, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        return overflow ? Int.max : product
    }

    private func checkpointWALLocked(force: Bool = false) {
        guard db != nil else { return }
        let rowThresholdReached =
            walCheckpointRowThreshold > 0
            && walRowsSinceCheckpoint >= walCheckpointRowThreshold
        let walAttributes = try? FileManager.default.attributesOfItem(atPath: walURL.path)
        let walBytes = (walAttributes?[.size] as? NSNumber)?.intValue ?? 0
        let sizeLimitReached = walBytes > journalSizeLimitBytes
        guard force || rowThresholdReached || sizeLimitReached else { return }
        let result = sqlite3_wal_checkpoint_v2(
            db,
            nil,
            SQLITE_CHECKPOINT_TRUNCATE,
            nil,
            nil
        )
        if result == SQLITE_OK {
            walRowsSinceCheckpoint = 0
        }
    }

    private func cipherContext(
        accountIdentifier: String,
        item: MLDerivedPipelineWorkItem
    ) -> MLDerivedDataCipherContext {
        MLDerivedDataCipherContext(
            accountIdentifier: accountIdentifier,
            uid: item.asset.uid,
            artifactNamespace: item.artifact.stableNamespace
        )
    }

    private func prepare(_ sql: String, _ statement: inout OpaquePointer?) -> Bool {
        sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK
    }

    private func reset(_ statement: OpaquePointer?) {
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
    }

    private func finalize(_ statements: [OpaquePointer?]) {
        for statement in statements { sqlite3_finalize(statement) }
    }

    private func bindText(_ statement: OpaquePointer?, _ index: Int32, _ value: String) {
        sqlite3_bind_text(statement, index, value, -1, transient)
    }

    private func bindBlob(_ statement: OpaquePointer?, _ index: Int32, _ value: Data) {
        _ = value.withUnsafeBytes { buffer in
            sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(buffer.count), transient)
        }
    }

    private func columnText(_ statement: OpaquePointer?, _ index: Int32) -> String {
        guard let value = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: value)
    }

    private func columnBlob(_ statement: OpaquePointer?, _ index: Int32) -> Data? {
        let count = Int(sqlite3_column_bytes(statement, index))
        guard count > 0, let bytes = sqlite3_column_blob(statement, index) else { return nil }
        return Data(bytes: bytes, count: count)
    }

    private static func placeholders(_ count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ",")
    }
}
