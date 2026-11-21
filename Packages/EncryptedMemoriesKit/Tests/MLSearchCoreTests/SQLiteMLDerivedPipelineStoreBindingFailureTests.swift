import Foundation
import PhotosCore
import SQLiteTestSupport
import XCTest

@testable import MLSearchCore

/// Every text and blob bind of the derived pipeline store checks its result (#1194). A failed bind leaves its parameter
/// NULL: an unchecked payload bind stored a completed result without its payload, a namespace bind let a removal or a
/// purge match no row and report success, and a read reported no account, no artifact or empty progress instead of a
/// failed read. Each test fails only the binds of the target statement: a value longer than the lowered
/// SQLITE_LIMIT_LENGTH fails with SQLITE_TOOBIG, as a bind that runs out of memory does. The limit is 2048, because
/// the statements that fire the progress triggers do not prepare under a lower one. A test whose earlier statements
/// bind the same value lowers the limit only after them. With the check the statement never steps, and the call gives
/// the answer of a failed statement. The token digest tests use a cipher with digests longer than the limit; the
/// terminal reasons (24 bytes at most) cannot exceed the smallest limit (30), so no test fails their bind.
final class SQLiteMLDerivedPipelineStoreBindingFailureTests: XCTestCase {
    private static let limit: Int32 = 2_048
    private static let long = String(repeating: "x", count: 3_000)
    private let longPipeline = MLPipelineID(rawValue: long)
    private let shortUID = PhotoUID(volumeID: "volume", nodeID: "node")
    private let longUID = PhotoUID(volumeID: long, nodeID: "node")

    private var directory: URL!
    private var store: SQLiteMLDerivedPipelineStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ml-derived-binding-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = try XCTUnwrap(
            SQLiteMLDerivedPipelineStore(
                url: directory.appendingPathComponent(SQLiteMLDerivedPipelineStore.databaseFileName),
                cipher: TestDerivedCipher(key: 0x5a)))
    }

    override func tearDownWithError() throws {
        store?.close()
        store = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private func artifact() throws -> MLDerivedArtifactIdentity { try makeArtifact(stage: "ocr", revision: "r1") }

    /// An artifact whose namespace is longer than the lowered limit.
    private func longNamespaceArtifact() throws -> MLDerivedArtifactIdentity {
        try makeArtifact(stage: "ocr", revision: "r1", preprocessingRevision: Self.long)
    }

    /// An artifact of a pipeline whose identifier is longer than the lowered limit.
    private func longPipelineArtifact(revision: String = "r1") throws -> MLDerivedArtifactIdentity {
        try makeArtifact(stage: "ocr", revision: revision, pipelineID: longPipeline)
    }

    private func key(
        account: String = "account", _ artifact: MLDerivedArtifactIdentity, pipelineID: MLPipelineID = .nativeSearch
    ) throws -> MLPipelineExecutionKey {
        try makeKey(account: account, artifacts: [artifact], pipelineID: pipelineID)
    }

    private func asset(_ uid: PhotoUID, revision: String = "r1") throws -> MLPipelineAssetRevision {
        try MLPipelineAssetRevision(uid: uid, sourceRevision: revision)
    }

    private func completed(
        _ asset: MLPipelineAssetRevision, _ artifact: MLDerivedArtifactIdentity, payload: Data = Data("text".utf8)
    ) -> MLPipelineStageResult {
        MLPipelineStageResult(
            workItem: MLDerivedPipelineWorkItem(asset: asset, artifact: artifact),
            outcome: .completed(MLDerivedPipelineOutput(payload: payload, normalizedSearchTokens: ["text"])))
    }

    /// Fails the binds of the first statement whose SQL contains `statement` that starts after the first statement whose
    /// SQL contains `earlier` finished, or at once without `earlier`.
    private func failBinds(of statement: String, after earlier: String? = nil) throws -> BindFailureUntilStep {
        let fault = BindFailureUntilStep(
            onDatabase: try XCTUnwrap(storeDatabase(store!)), statement: statement, after: earlier, limit: Self.limit)
        if earlier == nil { XCTAssertEqual(fault.effectiveLimit, Self.limit, "The lowered length limit must apply") }
        return fault
    }

    // MARK: Enqueue

    func testEnqueueWithAnAccountThatDoesNotBindFailsBeforeTheAccountInsert() throws {
        let key = try key(account: Self.long, artifact())
        let fault = try failBinds(of: "INSERT OR IGNORE INTO ml_derived_accounts")
        defer { fault.remove() }
        XCTAssertFalse(store.enqueue([try asset(shortUID)], for: key))
        XCTAssertNil(fault.failedBeforeStepProblem)
    }

    func testEnqueueWithAnAccountThatDoesNotBindFailsBeforeTheAccountRead() throws {
        let key = try key(account: Self.long, artifact())
        let fault = try failBinds(
            of: "SELECT account_key FROM ml_derived_accounts", after: "INSERT OR IGNORE INTO ml_derived_accounts")
        defer { fault.remove() }
        XCTAssertFalse(store.enqueue([try asset(shortUID)], for: key))
        XCTAssertNil(fault.failedBeforeStepProblem)
    }

    func testEnqueueWithANamespaceThatDoesNotBindFailsBeforeTheArtifactInsert() throws {
        let key = try key(longNamespaceArtifact())
        let fault = try failBinds(of: "INSERT OR IGNORE INTO ml_derived_artifacts")
        defer { fault.remove() }
        XCTAssertFalse(
            store.enqueue([try asset(shortUID)], for: key), "An artifact that was never written cannot take work")
        XCTAssertNil(fault.failedBeforeStepProblem)
    }

    func testEnqueueWithANamespaceThatDoesNotBindFailsTheObsoleteWorkRemoval() throws {
        let key = try key(longNamespaceArtifact())
        let fault = try failBinds(
            of: "AND artifact_namespace NOT IN", after: "SELECT artifact_id, pipeline_id, schema_version")
        defer { fault.remove() }
        XCTAssertFalse(store.enqueue([], for: key), "A removal that matched no row is no complete removal")
        XCTAssertNil(fault.failedBeforeStepProblem)
    }

    func testEnqueueWithAKeyThatDoesNotBindFailsBeforeTheAssetRead() throws {
        let key = try key(artifact())
        let fault = try failBinds(of: "SELECT asset_id, source_revision FROM ml_derived_assets")
        defer { fault.remove() }
        XCTAssertFalse(store.enqueue([try asset(longUID)], for: key))
        XCTAssertNil(fault.failedBeforeStepProblem)
    }

    func testEnqueueWithANodeThatDoesNotBindFailsBeforeTheAssetRead() throws {
        let key = try key(artifact())
        let fault = try failBinds(of: "SELECT asset_id, source_revision FROM ml_derived_assets")
        defer { fault.remove() }
        XCTAssertFalse(store.enqueue([try asset(PhotoUID(volumeID: "volume", nodeID: Self.long))], for: key))
        XCTAssertNil(fault.failedBeforeStepProblem)
    }

    func testEnqueueWithANodeThatDoesNotBindFailsBeforeTheAssetInsert() throws {
        let key = try key(artifact())
        let fault = try failBinds(
            of: "INSERT INTO ml_derived_assets", after: "SELECT asset_id, source_revision FROM ml_derived_assets")
        defer { fault.remove() }
        XCTAssertFalse(store.enqueue([try asset(PhotoUID(volumeID: "volume", nodeID: Self.long))], for: key))
        XCTAssertNil(fault.failedBeforeStepProblem)
    }

    func testEnqueueWithARevisionThatDoesNotBindFailsBeforeTheAssetInsert() throws {
        let key = try key(artifact())
        let fault = try failBinds(
            of: "INSERT INTO ml_derived_assets", after: "SELECT asset_id, source_revision FROM ml_derived_assets")
        defer { fault.remove() }
        XCTAssertFalse(store.enqueue([try asset(shortUID, revision: Self.long)], for: key))
        XCTAssertNil(fault.failedBeforeStepProblem)
    }

    func testEnqueueWithAKeyThatDoesNotBindFailsBeforeTheAssetInsert() throws {
        let key = try key(artifact())
        let fault = try failBinds(
            of: "INSERT INTO ml_derived_assets", after: "SELECT asset_id, source_revision FROM ml_derived_assets")
        defer { fault.remove() }
        XCTAssertFalse(store.enqueue([try asset(longUID)], for: key))
        XCTAssertNil(fault.failedBeforeStepProblem)
    }

    func testEnqueueWithARevisionThatDoesNotBindFailsBeforeTheRevisionUpdate() throws {
        let key = try key(artifact())
        XCTAssertTrue(store.enqueue([try asset(shortUID)], for: key))
        let fault = try failBinds(of: "UPDATE ml_derived_assets SET source_revision")
        defer { fault.remove() }
        XCTAssertFalse(store.enqueue([try asset(shortUID, revision: Self.long)], for: key))
        XCTAssertNil(fault.failedBeforeStepProblem)
    }

    func testEnqueueWithAPipelineThatDoesNotBindFailsTheGenerationBump() throws {
        let key = try key(longPipelineArtifact(), pipelineID: longPipeline)
        let fault = try failBinds(
            of: "INSERT INTO ml_derived_generation", after: "INSERT OR IGNORE INTO ml_derived_work")
        defer { fault.remove() }
        XCTAssertFalse(store.enqueue([try asset(shortUID)], for: key))
        XCTAssertNil(fault.failedBeforeStepProblem)
    }

    // MARK: Reads

    func testNextWorkBatchWithAnAccountThatDoesNotBindIsAReadFailure() throws {
        let key = try key(account: Self.long, artifact())
        XCTAssertTrue(store.enqueue([try asset(shortUID)], for: key))
        let fault = try failBinds(of: "SELECT account_key FROM ml_derived_accounts")
        defer { fault.remove() }
        XCTAssertThrowsError(
            try store.nextWorkBatch(for: key, limit: 8, now: .now), "An account that does not bind is no empty queue")
        XCTAssertNil(fault.failedBeforeStepProblem)
    }

    func testNextWorkBatchWithANamespaceThatDoesNotBindIsAReadFailure() throws {
        let key = try key(longNamespaceArtifact())
        XCTAssertTrue(store.enqueue([try asset(shortUID)], for: key))
        let fault = try failBinds(
            of: "SELECT artifact_id, pipeline_id, schema_version", after: "SELECT account_key FROM ml_derived_accounts")
        defer { fault.remove() }
        XCTAssertThrowsError(
            try store.nextWorkBatch(for: key, limit: 8, now: .now), "A namespace that does not bind is no empty queue")
        XCTAssertNil(fault.failedBeforeStepProblem)
    }

    func testProgressWithAPipelineThatDoesNotBindIsAReadFailure() throws {
        let key = try key(longPipelineArtifact(), pipelineID: longPipeline)
        XCTAssertTrue(store.enqueue([try asset(shortUID)], for: key))
        let fault = try failBinds(
            of: "FROM ml_derived_progress", after: "SELECT artifact_id, pipeline_id, schema_version")
        defer { fault.remove() }
        XCTAssertThrowsError(try store.progress(for: key), "A pipeline that does not bind is no empty progress")
        XCTAssertNil(fault.failedBeforeStepProblem)
    }

    func testProgressWithAPipelineThatDoesNotBindInTheGenerationReadIsAReadFailure() throws {
        XCTAssertTrue(
            store.enqueue([try asset(shortUID)], for: try key(longPipelineArtifact(), pipelineID: longPipeline)))
        let other = try key(longPipelineArtifact(revision: "r2"), pipelineID: longPipeline)
        let fault = try failBinds(
            of: "SELECT generation FROM ml_derived_generation",
            after: "SELECT artifact_id, pipeline_id, schema_version")
        defer { fault.remove() }
        XCTAssertThrowsError(try store.progress(for: other), "A pipeline that does not bind is no first generation")
        XCTAssertNil(fault.failedBeforeStepProblem)
    }

    func testOutputWithAVolumeThatDoesNotBindDoesNotRunTheRead() throws {
        try assertOutputReadDoesNotRun(uid: longUID, artifact: artifact())
    }

    func testOutputWithANodeThatDoesNotBindDoesNotRunTheRead() throws {
        try assertOutputReadDoesNotRun(uid: PhotoUID(volumeID: "volume", nodeID: Self.long), artifact: artifact())
    }

    func testOutputWithANamespaceThatDoesNotBindDoesNotRunTheRead() throws {
        try assertOutputReadDoesNotRun(uid: shortUID, artifact: longNamespaceArtifact())
    }

    private func assertOutputReadDoesNotRun(
        uid: PhotoUID, artifact: MLDerivedArtifactIdentity, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let key = try key(artifact)
        let asset = try asset(uid)
        XCTAssertTrue(store.enqueue([asset], for: key), file: file, line: line)
        XCTAssertTrue(store.commit([completed(asset, artifact)], for: key, now: .now), file: file, line: line)
        let fault = try failBinds(of: "SELECT w.payload", after: "SELECT account_key FROM ml_derived_accounts")
        defer { fault.remove() }
        XCTAssertNil(store.output(for: uid, artifact: artifact, accountIdentifier: "account"), file: file, line: line)
        XCTAssertNil(fault.failedBeforeStepProblem, file: file, line: line)
    }

    // MARK: Commit

    /// No later statement of the commit binds the namespace, so only the artifact read itself can fail the call.
    func testCommitWithANamespaceThatDoesNotBindInTheArtifactReadFails() throws {
        let artifact = try longNamespaceArtifact()
        let key = try key(artifact)
        let asset = try asset(shortUID)
        XCTAssertTrue(store.enqueue([asset], for: key))
        let fault = try failBinds(
            of: "SELECT artifact_id, pipeline_id, schema_version", after: "SELECT account_key FROM ml_derived_accounts")
        XCTAssertFalse(
            store.commit([completed(asset, artifact)], for: key, now: .now),
            "A namespace that does not bind is no proof that the artifact is missing")
        XCTAssertNil(fault.failedBeforeStepProblem)
        fault.remove()
        XCTAssertEqual(try store.nextWorkBatch(for: key, limit: 8, now: .now).map(\.asset), [asset])
    }

    func testCommitWithAVolumeThatDoesNotBindFailsAndKeepsTheWork() throws {
        try assertCommitFailsAndKeepsTheWork(for: try asset(longUID))
    }

    func testCommitWithANodeThatDoesNotBindFailsAndKeepsTheWork() throws {
        try assertCommitFailsAndKeepsTheWork(for: try asset(PhotoUID(volumeID: "volume", nodeID: Self.long)))
    }

    func testCommitWithARevisionThatDoesNotBindFailsAndKeepsTheWork() throws {
        try assertCommitFailsAndKeepsTheWork(for: try asset(shortUID, revision: Self.long))
    }

    /// A key that does not bind in the commit's asset read is no proof that the asset is gone: the commit fails and the
    /// work stays pending.
    private func assertCommitFailsAndKeepsTheWork(
        for asset: MLPipelineAssetRevision, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let artifact = try artifact()
        let key = try key(artifact)
        XCTAssertTrue(store.enqueue([asset], for: key), file: file, line: line)
        let fault = try failBinds(of: "SELECT asset_id FROM ml_derived_assets WHERE account_key=? AND volume_id")
        XCTAssertFalse(store.commit([completed(asset, artifact)], for: key, now: .now), file: file, line: line)
        XCTAssertNil(fault.failedBeforeStepProblem, file: file, line: line)
        fault.remove()
        XCTAssertEqual(
            try store.nextWorkBatch(for: key, limit: 8, now: .now).map(\.asset), [asset], file: file, line: line)
    }

    func testCommitWithAPayloadThatDoesNotBindFailsInsteadOfStoringNull() throws {
        let artifact = try artifact()
        let key = try key(artifact)
        let asset = try asset(shortUID)
        XCTAssertTrue(store.enqueue([asset], for: key))
        let fault = try failBinds(of: "UPDATE ml_derived_work SET state=?")
        defer { fault.remove() }
        XCTAssertFalse(
            store.commit([completed(asset, artifact, payload: Data(repeating: 7, count: 4_096))], for: key, now: .now),
            "A completed result must not be stored without its payload")
        XCTAssertNil(fault.failedBeforeStepProblem)
    }

    func testCommitWithATokenDigestThatDoesNotBindFailsAndStoresNoToken() throws {
        let store = try wideDigestStore()
        defer { store.close() }
        let artifact = try artifact()
        let key = try key(artifact)
        let asset = try asset(shortUID)
        XCTAssertTrue(store.enqueue([asset], for: key))
        let fault = BindFailureUntilStep(
            onDatabase: try XCTUnwrap(storeDatabase(store)), statement: "INSERT OR IGNORE INTO ml_derived_tokens",
            after: "UPDATE ml_derived_work SET state=?", limit: Self.limit)
        XCTAssertFalse(
            store.commit([completed(asset, artifact)], for: key, now: .now),
            "A token that was never written must not leave the output unsearchable")
        XCTAssertNil(fault.failedBeforeStepProblem)
        fault.remove()
        XCTAssertFalse(store.hasIndexedEntries(for: key))
        XCTAssertEqual(try store.nextWorkBatch(for: key, limit: 8, now: .now).map(\.asset), [asset])
    }

    func testSearchWithATokenDigestThatDoesNotBindDoesNotRunTheRead() throws {
        let store = try wideDigestStore()
        defer { store.close() }
        let key = try key(artifact())
        XCTAssertTrue(store.enqueue([try asset(shortUID)], for: key))
        let fault = BindFailureUntilStep(
            onDatabase: try XCTUnwrap(storeDatabase(store)), statement: "SELECT a.volume_id, a.node_id",
            after: "SELECT artifact_id, pipeline_id, schema_version", limit: Self.limit)
        defer { fault.remove() }
        XCTAssertEqual(store.search(normalizedTokens: ["text"], in: key, limit: 10), [])
        XCTAssertNil(fault.failedBeforeStepProblem)
    }

    /// A store whose token digests are longer than the lowered limit.
    private func wideDigestStore() throws -> SQLiteMLDerivedPipelineStore {
        try XCTUnwrap(
            SQLiteMLDerivedPipelineStore(
                url: directory.appendingPathComponent("wide-" + SQLiteMLDerivedPipelineStore.databaseFileName),
                cipher: WideDigestCipher()))
    }

    /// A step that fails is no proof that the asset is gone: the commit fails and the work stays pending.
    func testCommitWithAnAssetReadThatFailsInItsStepFailsAndKeepsTheWork() throws {
        let artifact = try artifact()
        let key = try key(artifact)
        let asset = try asset(shortUID)
        XCTAssertTrue(store.enqueue([asset], for: key))
        let fault = SQLiteStatementFaults(onDatabase: try XCTUnwrap(storeDatabase(store!)), failures: 1) {
            $0.contains("SELECT asset_id FROM ml_derived_assets WHERE account_key=")
        }
        defer { fault.stop() }
        XCTAssertFalse(store.commit([completed(asset, artifact)], for: key, now: .now))
        XCTAssertEqual(fault.firedCount, 1, "The fault must reach the target statement")
        fault.stop()
        XCTAssertEqual(try store.nextWorkBatch(for: key, limit: 8, now: .now).map(\.asset), [asset])
    }

    /// A step that fails is no proof that the artifact is missing: the commit fails and the work stays pending.
    func testCommitWithAnArtifactReadThatFailsInItsStepFailsAndKeepsTheWork() throws {
        let artifact = try artifact()
        let key = try key(artifact)
        let asset = try asset(shortUID)
        XCTAssertTrue(store.enqueue([asset], for: key))
        let fault = SQLiteStatementFaults(onDatabase: try XCTUnwrap(storeDatabase(store!)), failures: 1) {
            $0.contains("SELECT artifact_id, pipeline_id, schema_version")
        }
        defer { fault.stop() }
        XCTAssertFalse(store.commit([completed(asset, artifact)], for: key, now: .now))
        XCTAssertEqual(fault.firedCount, 1, "The fault must reach the target statement")
        fault.stop()
        XCTAssertEqual(try store.nextWorkBatch(for: key, limit: 8, now: .now).map(\.asset), [asset])
    }

    // MARK: Reconcile

    func testReconcileWithAnAccountThatDoesNotBindFailsAndKeepsTheRows() throws {
        let key = try key(account: Self.long, artifact())
        let asset = try asset(shortUID)
        XCTAssertTrue(store.enqueue([asset], for: key))
        let fault = try failBinds(of: "SELECT account_key FROM ml_derived_accounts")
        XCTAssertFalse(
            store.reconcile(liveUIDs: [], for: key), "An account that does not bind is no proof that it has no rows")
        XCTAssertNil(fault.failedBeforeStepProblem)
        fault.remove()
        XCTAssertEqual(try store.nextWorkBatch(for: key, limit: 8, now: .now).map(\.asset), [asset])
    }

    func testReconcileWithANamespaceThatDoesNotBindFailsAndKeepsTheRows() throws {
        let key = try key(longNamespaceArtifact())
        let asset = try asset(shortUID)
        XCTAssertTrue(store.enqueue([asset], for: key))
        let fault = try failBinds(
            of: "SELECT artifact_id, pipeline_id, schema_version", after: "SELECT account_key FROM ml_derived_accounts")
        XCTAssertFalse(
            store.reconcile(liveUIDs: [], for: key), "A namespace that does not bind is no proof that it has no rows")
        XCTAssertNil(fault.failedBeforeStepProblem)
        fault.remove()
        XCTAssertEqual(try store.nextWorkBatch(for: key, limit: 8, now: .now).map(\.asset), [asset])
    }

    // MARK: Obsolete work removal

    /// The pipeline, its stage prefix and the artifact namespace nest: a namespace contains its stage prefix, and the
    /// prefix contains the pipeline. A length limit therefore cannot fail the pipeline bind or the prefix binds alone,
    /// and the binds stop at the first one that fails. With a pipeline that does not bind, only the pipeline bind runs.
    /// Without its check the namespace bind still fails the removal, so this test cannot tell the pipeline check or the
    /// prefix checks apart from the namespace check; those two checks stay without a test of their own.
    func testEnqueueWithAPipelineThatDoesNotBindFailsTheObsoleteWorkRemovalAtThePipelineBind() throws {
        let key = try key(longPipelineArtifact(), pipelineID: longPipeline)
        let fault = try failBinds(
            of: "AND artifact_namespace NOT IN", after: "SELECT artifact_id, pipeline_id, schema_version")
        defer { fault.remove() }
        XCTAssertFalse(store.enqueue([], for: key), "A removal that matched no row is no complete removal")
        XCTAssertNil(fault.failedBeforeStepProblem)
    }

    // MARK: Purge

    func testPurgeWithAPipelineThatDoesNotBindRollsBackAndKeepsTheWork() throws {
        let artifact = try longPipelineArtifact()
        let key = try key(artifact, pipelineID: longPipeline)
        XCTAssertTrue(store.enqueue([try asset(shortUID)], for: key))
        let fault = try failBinds(
            of: "UPDATE ml_derived_generation SET generation=generation+1 WHERE account_key=? AND pipeline_id",
            after: "DELETE FROM ml_derived_assets WHERE account_key=? AND NOT EXISTS")
        store.purge(artifact: artifact, accountIdentifier: "account")
        XCTAssertNil(fault.failedBeforeStepProblem)
        fault.remove()
        XCTAssertEqual(
            try store.progress(for: key).total, 1, "A purge whose generation bump does not bind must roll back")
    }

    func testPurgeWithANamespaceThatDoesNotBindDoesNotRunTheArtifactRead() throws {
        let artifact = try longNamespaceArtifact()
        XCTAssertTrue(store.enqueue([try asset(shortUID)], for: try key(artifact)))
        let fault = try failBinds(
            of: "SELECT artifact_id FROM ml_derived_artifacts WHERE artifact_namespace",
            after: "SELECT account_key FROM ml_derived_accounts")
        defer { fault.remove() }
        store.purge(artifact: artifact, accountIdentifier: "account")
        XCTAssertNil(fault.failedBeforeStepProblem)
    }

    func testPipelinePurgeWithAPipelineThatDoesNotBindDoesNotRunTheArtifactRead() throws {
        XCTAssertTrue(
            store.enqueue([try asset(shortUID)], for: try key(longPipelineArtifact(), pipelineID: longPipeline)))
        let fault = try failBinds(of: "SELECT artifact_id FROM ml_derived_artifacts WHERE pipeline_id")
        defer { fault.remove() }
        store.purge(pipelineID: longPipeline, accountIdentifier: "account")
        XCTAssertNil(fault.failedBeforeStepProblem)
    }
}

/// The test cipher with token digests of 4096 bytes, longer than the lowered limit.
private struct WideDigestCipher: MLDerivedDataCipher {
    private let base = TestDerivedCipher(key: 0x5a)

    func seal(_ plaintext: Data, context: MLDerivedDataCipherContext) throws -> Data {
        try base.seal(plaintext, context: context)
    }

    func open(_ ciphertext: Data, context: MLDerivedDataCipherContext) throws -> Data {
        try base.open(ciphertext, context: context)
    }

    func tokenDigest(normalizedToken: String, accountIdentifier: String, artifactNamespace: String) throws -> Data {
        let digest = try base.tokenDigest(
            normalizedToken: normalizedToken, accountIdentifier: accountIdentifier,
            artifactNamespace: artifactNamespace)
        return Data((0..<512).flatMap { _ in digest })
    }
}
