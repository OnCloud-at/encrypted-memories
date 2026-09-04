import CryptoKit
import Foundation
import PhotosCore
import Testing

@testable import MediaByteCache

private let byteCacheTestKey = SymmetricKey(size: .bits256)

private actor AsyncLatch {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if opened { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func signal() {
        guard !opened else { return }
        opened = true
        let pending = waiters
        waiters.removeAll(keepingCapacity: false)
        for waiter in pending {
            waiter.resume()
        }
    }
}

@Suite("MediaByteCache")
struct MediaByteCacheTests {
    private static let pngSignature = Data([0x89, 0x50, 0x4E, 0x47])

    private func png() -> Data {
        var data = Self.pngSignature
        data.append(Data([0x0D, 0x0A, 0x1A, 0x0A]))
        data.append(Data((0..<512).map { UInt8($0 % 251) }))
        return data
    }

    private func uniqueNamespace() -> String {
        "byte-cache-\(UUID().uuidString)"
    }

    private func uniqueRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EncryptedMemoriesKit-byte-cache-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func uid(_ id: String = "node-1") -> PhotoUID {
        PhotoUID(volumeID: "vol-1", nodeID: id)
    }

    private func sourceGraph(
        retaining uids: [PhotoUID],
        authoritative: Bool
    ) -> (graph: LibrarySourceGraph, scope: ThumbnailRetentionDerivedDataScope) {
        let source = LibrarySource(
            id: SourceID("cache-source"),
            capabilities: .readThumbnail
        )
        let graph = LibrarySourceGraph()
        let sourceSetLease = graph.beginSourceSetRefresh()
        _ = graph.commitSourceSet([source], using: sourceSetLease)
        let refresh = graph.beginRefresh(source.id)!
        _ = graph.commit(
            uids.enumerated().map { offset, uid in
                .complete(
                    PhotoItem(
                        uid: uid,
                        captureTime: Date(timeIntervalSince1970: TimeInterval(offset)),
                        mediaType: "image/jpeg"
                    )
                )
            },
            validationToken: nil,
            using: refresh
        )
        if !authoritative { _ = graph.beginRefresh(source.id) }
        return (graph, graph.thumbnailRetentionDerivedDataScope())
    }

    @Test func encryptedBlobHasNoPlaintextAndRoundTrips() throws {
        let cache = ThumbnailCache(namespace: uniqueNamespace(), rootDirectory: uniqueRoot())
        cache.configure(accountUID: "acct-A", key: byteCacheTestKey)

        let plaintext = png()
        cache.storeToDisk(plaintext, for: uid())

        let blob = try Data(contentsOf: cache.diskURL(for: uid()))
        #expect(!blob.isEmpty)
        #expect(blob != plaintext)
        #expect(blob.range(of: plaintext) == nil)
        #expect(blob.range(of: Self.pngSignature) == nil)
        #expect(cache.diskData(for: uid()) == plaintext)
    }

    @Test func configuredCacheSurvivesAcrossInstances() {
        let namespace = uniqueNamespace()
        let root = uniqueRoot()
        let first = ThumbnailCache(namespace: namespace, rootDirectory: root)
        first.configure(accountUID: "acct-A", key: byteCacheTestKey)
        first.storeToDisk(png(), for: uid())

        let relaunched = ThumbnailCache(namespace: namespace, rootDirectory: root)
        relaunched.configure(accountUID: "acct-A", key: byteCacheTestKey)

        #expect(relaunched.has(uid()) == true)
        #expect(relaunched.diskData(for: uid()) == png())
    }

    @Test func oneAccountContextConfiguresEveryDerivativeWithTheSameKey() {
        let root = uniqueRoot()
        let context = LocalMediaCacheContext(accountUID: "acct-context", keyPassword: "key-password")
        let thumbnail = ThumbnailCache(namespace: "context", derivative: "thumbnail", rootDirectory: root)
        let preview = ThumbnailCache(namespace: "context", derivative: "preview", rootDirectory: root)
        context.configure(thumbnail, preview)

        thumbnail.storeToDisk(png(), for: uid("thumbnail"))
        preview.storeToDisk(png(), for: uid("preview"))

        #expect(thumbnail.diskData(for: uid("thumbnail")) == png())
        #expect(preview.diskData(for: uid("preview")) == png())
    }

    @Test func missingKeyIsCacheMissNotCrash() {
        let cache = ThumbnailCache(namespace: uniqueNamespace(), rootDirectory: uniqueRoot())
        cache.configure(accountUID: "acct-A", key: nil)
        cache.storeToDisk(png(), for: uid())

        #expect(cache.has(uid()) == false)
        #expect(cache.diskData(for: uid()) == nil)
    }

    @Test func corruptBlobIsMissAndDeleted() throws {
        let cache = ThumbnailCache(namespace: uniqueNamespace(), rootDirectory: uniqueRoot())
        cache.configure(accountUID: "acct-A", key: byteCacheTestKey)
        cache.storeToDisk(png(), for: uid())

        let url = cache.diskURL(for: uid())
        try Data([1, 2, 3, 4, 5, 6, 7, 8]).write(to: url)

        #expect(cache.diskData(for: uid()) == nil)
        #expect(FileManager.default.fileExists(atPath: url.path) == false)
    }

    @Test func validatedPresenceDoesNotSurviveFileRemoval() throws {
        let cache = ThumbnailCache(namespace: uniqueNamespace(), rootDirectory: uniqueRoot())
        cache.configure(accountUID: "acct-A", key: byteCacheTestKey)
        let photo = uid("memoized-presence")
        let token = cache.captureWriterGeneration()
        #expect(cache.storeToDisk(png(), for: photo, ifCurrent: token) == .stored)
        #expect(cache.hasUsableDiskData(photo))

        try FileManager.default.removeItem(at: cache.diskURL(for: photo))

        #expect(cache.hasUsableDiskData(photo) == false)
    }

    @Test func storeReportsIoFailureWhenCacheDirectoryCannotBeWritten() throws {
        let root = uniqueRoot()
        let blockedDirectory = root.appendingPathComponent("forced.enc")
        try Data([0x01]).write(to: blockedDirectory)
        let cache = ThumbnailCache(namespace: "forced", rootDirectory: root)
        cache.configure(accountUID: "acct-A", key: byteCacheTestKey)

        let result = cache.storeToDisk(png(), for: uid("io-failure"), ifCurrent: cache.captureWriterGeneration())

        #expect(result == .ioFailure)
    }

    @Test func configurationSanitizesMemoryBudget() {
        #expect(ThumbnailCacheConfiguration(dataMemoryBudgetBytes: 0).dataMemoryBudgetBytes == 1)
        #expect(ThumbnailCacheConfiguration(dataMemoryBudgetBytes: 42).dataMemoryBudgetBytes == 42)
        #expect(ThumbnailCacheConfiguration(diskByteBudgetBytes: -1).diskByteBudgetBytes == 0)
        #expect(ThumbnailCache.defaultDiskByteBudget(for: "thumbnail") == nil)
        #expect(ThumbnailCacheConfiguration.defaultPreviewDiskBudgetBytes == 2_147_483_648)
        #expect(
            ThumbnailCache.defaultDiskByteBudget(for: "preview")
                == ThumbnailCacheConfiguration.defaultPreviewDiskBudgetBytes)
    }

    @Test func automaticThumbnailDiskCapKeepsNewestDataWithinBound() async throws {
        let cache = ThumbnailCache(
            namespace: uniqueNamespace(),
            derivative: "thumbnail",
            configuration: ThumbnailCacheConfiguration(diskByteBudgetBytes: 200),
            rootDirectory: uniqueRoot()
        )
        cache.configure(accountUID: "acct-A", key: byteCacheTestKey)
        let old = uid("automatic-cap-old")
        let keepA = uid("automatic-cap-a")
        let keepB = uid("automatic-cap-b")

        cache.storeToDisk(Data(repeating: 0x11, count: 64), for: old)
        cache.storeToDisk(Data(repeating: 0x22, count: 64), for: keepA)
        cache.storeToDisk(Data(repeating: 0x33, count: 64), for: keepB)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1)],
            ofItemAtPath: cache.diskURL(for: old).path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 2)],
            ofItemAtPath: cache.diskURL(for: keepA).path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 3)],
            ofItemAtPath: cache.diskURL(for: keepB).path
        )

        await cache.flushAutomaticDiskCap()

        #expect(cache.diskSizeBytes() <= 200)
        #expect(cache.diskData(for: old) == nil)
        #expect(cache.diskData(for: keepB) != nil)
    }

    @Test func byteCapDoesNotAccountForAFileThatCouldNotBeDeleted() throws {
        let cache = ThumbnailCache(namespace: uniqueNamespace(), rootDirectory: uniqueRoot())
        cache.configure(accountUID: "acct-A", key: byteCacheTestKey)
        let photo = uid("failed-cap-deletion")
        let generation = cache.captureWriterGeneration()
        #expect(cache.storeToDisk(png(), for: photo, ifCurrent: generation) == .stored)

        let blobURL = cache.diskURL(for: photo)
        let cacheDirectory = blobURL.deletingLastPathComponent()
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500],
            ofItemAtPath: cacheDirectory.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: cacheDirectory.path
            )
        }

        #expect(cache.enforceByteCap(0, ifCurrent: generation) == false)
        #expect(FileManager.default.fileExists(atPath: blobURL.path))
        #expect(cache.diskSizeBytes() > 0)

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: cacheDirectory.path
        )
        #expect(cache.enforceByteCap(0, ifCurrent: generation))
        #expect(FileManager.default.fileExists(atPath: blobURL.path) == false)
        #expect(cache.diskSizeBytes() == 0)
    }

    @Test func reusedInstanceDoesNotReturnAccountADataToAccountB() async {
        let cache = ThumbnailCache(namespace: uniqueNamespace(), rootDirectory: uniqueRoot())
        let photo = uid("reused-account")
        let accountAData = Data("account-a".utf8)
        let accountBData = Data("account-b".utf8)
        let accountBKey = SymmetricKey(size: .bits256)

        cache.configure(accountUID: "acct-A", key: byteCacheTestKey)
        await cache.store(accountAData, for: photo)
        #expect(await cache.data(for: photo) == accountAData)

        cache.configure(accountUID: "acct-B", key: accountBKey)
        #expect(await cache.data(for: photo) == nil)
        await cache.store(accountBData, for: photo)
        #expect(await cache.data(for: photo) == accountBData)
    }

    @Test func capturedWriterCannotLandAfterDestructiveClear() async {
        let cache = ThumbnailCache(namespace: uniqueNamespace(), rootDirectory: uniqueRoot())
        cache.configure(accountUID: "acct-A", key: byteCacheTestKey)
        let photo = uid("late-writer")
        let token = cache.captureWriterGeneration()
        let entered = AsyncLatch()
        let release = AsyncLatch()

        let lateWriter = Task.detached {
            await entered.signal()
            await release.wait()
            return cache.storeToDisk(Data("late".utf8), for: photo, ifCurrent: token)
        }
        await entered.wait()
        await cache.clear()
        await release.signal()

        #expect(await lateWriter.value == .stale)
        #expect(cache.has(photo) == false)
    }

    @Test func destructiveClearRejectsLatePreviewWriter() async {
        let cache = ThumbnailCache(
            namespace: uniqueNamespace(),
            derivative: "preview",
            rootDirectory: uniqueRoot()
        )
        cache.configure(accountUID: "acct-A", key: byteCacheTestKey)
        let photo = uid("late-preview")
        let token = cache.captureWriterGeneration()
        let entered = AsyncLatch()
        let release = AsyncLatch()

        let lateWriter = Task.detached {
            await entered.signal()
            await release.wait()
            return cache.storeToDisk(Data("late-preview".utf8), for: photo, ifCurrent: token)
        }
        await entered.wait()
        await cache.clear()
        await release.signal()

        #expect(await lateWriter.value == .stale)
        #expect(cache.has(photo) == false)
    }

    @Test func nonAuthoritativeScopeCannotDeleteEncryptedBlobs() async {
        let cache = ThumbnailCache(namespace: uniqueNamespace(), rootDirectory: uniqueRoot())
        cache.configure(accountUID: "acct-A", key: byteCacheTestKey)
        let retained = uid("retained-cached")
        let unknown = uid("unknown-cached")
        cache.storeToDisk(png(), for: retained)
        cache.storeToDisk(png(), for: unknown)
        let source = sourceGraph(retaining: [retained], authoritative: false)
        let session = cache.captureSessionLease()
        #expect(cache.bindDerivedDataEpoch(source.graph.runtimeEpoch, sessionLease: session))

        let result = cache.reconcile(with: source.scope)

        #expect(result == .deferred)
        #expect(cache.diskData(for: retained) == png())
        #expect(cache.diskData(for: unknown) == nil)
        #expect(FileManager.default.fileExists(atPath: cache.diskURL(for: unknown).path))
    }

    @Test func authoritativeScopePurgesOrphansAndRejectsCapturedWriter() async throws {
        let root = uniqueRoot()
        let cache = ThumbnailCache(namespace: uniqueNamespace(), rootDirectory: root)
        cache.configure(accountUID: "acct-A", key: byteCacheTestKey)
        let retained = uid("retained-authoritative")
        let removed = uid("removed-authoritative")
        cache.storeToDisk(png(), for: retained)
        cache.storeToDisk(png(), for: removed)
        let staleWriter = cache.captureWriterGeneration()
        let checkpoint = cache.coverageCheckpointDirectory()
        try FileManager.default.createDirectory(at: checkpoint, withIntermediateDirectories: true)
        try Data("checkpoint".utf8).write(to: checkpoint.appendingPathComponent("state"))
        let source = sourceGraph(retaining: [retained], authoritative: true)
        let session = cache.captureSessionLease()
        #expect(cache.bindDerivedDataEpoch(source.graph.runtimeEpoch, sessionLease: session))

        let result = cache.reconcile(with: source.scope)

        #expect(result == .reconciled(removedEntries: 1))
        #expect(cache.diskData(for: retained) == png())
        #expect(cache.diskData(for: removed) == nil)
        #expect(FileManager.default.fileExists(atPath: checkpoint.path) == false)
        #expect(cache.storeToDisk(png(), for: removed, ifCurrent: staleWriter) == .stale)
    }

    @Test func delayedOlderScopeCannotRemoveResourcesAcceptedByNewerScope() async {
        let cache = ThumbnailCache(namespace: uniqueNamespace(), rootDirectory: uniqueRoot())
        cache.configure(accountUID: "acct-A", key: byteCacheTestKey)
        let retained = uid("retained")
        let added = uid("added-later")
        await cache.store(png(), for: retained)
        await cache.store(png(), for: added)
        let source = sourceGraph(retaining: [retained], authoritative: true)
        let older = source.scope
        let sourceID = SourceID("cache-source")
        let refresh = source.graph.beginRefresh(sourceID)!
        let newer = source.graph.commit(
            [retained, added].enumerated().map { offset, uid in
                .complete(
                    PhotoItem(
                        uid: uid,
                        captureTime: Date(timeIntervalSince1970: TimeInterval(offset)),
                        mediaType: "image/jpeg"
                    )
                )
            },
            validationToken: nil,
            using: refresh
        )!.thumbnailRetentionScope
        let session = cache.captureSessionLease()
        #expect(cache.bindDerivedDataEpoch(source.graph.runtimeEpoch, sessionLease: session))

        #expect(cache.reconcile(with: newer) == .reconciled(removedEntries: 0))
        #expect(cache.reconcile(with: older) == .staleScope)

        #expect(await cache.data(for: retained) == png())
        #expect(await cache.data(for: added) == png())
    }

    @Test func authoritativeAddOnlyScopeKeepsTheWriterGenerationAndCoverageCheckpoint() throws {
        let cache = ThumbnailCache(namespace: uniqueNamespace(), rootDirectory: uniqueRoot())
        cache.configure(accountUID: "acct-A", key: byteCacheTestKey)
        let retained = uid("retained-add-only")
        let added = uid("added-only")
        cache.storeToDisk(png(), for: retained)
        let source = sourceGraph(retaining: [retained], authoritative: true)
        let session = cache.captureSessionLease()
        #expect(cache.bindDerivedDataEpoch(source.graph.runtimeEpoch, sessionLease: session))
        #expect(cache.reconcile(with: source.scope) == .reconciled(removedEntries: 0))
        let existingWriter = cache.captureWriterGeneration()
        let checkpoint = cache.coverageCheckpointDirectory()
        try FileManager.default.createDirectory(at: checkpoint, withIntermediateDirectories: true)
        try Data("checkpoint".utf8).write(to: checkpoint.appendingPathComponent("state"))

        let refresh = source.graph.beginRefresh(SourceID("cache-source"))!
        let addedScope = source.graph.commit(
            [retained, added].enumerated().map { offset, uid in
                .complete(
                    PhotoItem(
                        uid: uid,
                        captureTime: Date(timeIntervalSince1970: TimeInterval(offset)),
                        mediaType: "image/jpeg"
                    )
                )
            },
            validationToken: nil,
            using: refresh
        )!.thumbnailRetentionScope

        #expect(cache.reconcile(with: addedScope) == .reconciled(removedEntries: 0))
        #expect(cache.storeToDisk(png(), for: retained, ifCurrent: existingWriter) == .stored)
        #expect(FileManager.default.fileExists(atPath: checkpoint.path))
    }
}

@Suite("MediaByteCache platform purity")
struct MediaByteCachePlatformPurityTests {
    private var packageRoot: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        return url
    }

    private var mediaByteCacheSources: URL {
        packageRoot.appendingPathComponent("Sources/MediaByteCache")
    }

    private static let forbiddenFrameworkImports: [String] = [
        "AppKit",
        "UIKit",
        "SwiftUI",
        "AVKit",
        "MetalKit",
        "ImageIO",
    ]

    private static let forbiddenTokens: [String] = [
        "NSImage",
        "UIImage",
        "NSView",
        "UIView",
        "NSWorkspace",
        "NSOpenPanel",
        "UIApplication",
        "NSApplication",
        "CGImage",
        "ProcessInfo.processInfo.physicalMemory",
        "ProcessInfo.processInfo.activeProcessorCount",
    ]

    private static let allowedFrameworkImports: Set<String> = [
        "AppleSecurityCore",
        "CryptoKit",
        "Foundation",
        "PhotosCore",
    ]

    @Test func hasNoPlatformOrDecoderFrameworkImports() throws {
        let files = try swiftFiles(in: mediaByteCacheSources)
        #expect(!files.isEmpty)

        var violations: [String] = []
        var seen: Set<String> = []
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for line in source.split(whereSeparator: { $0.isNewline }) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("import ") else { continue }
                let remainder = trimmed.dropFirst("import ".count)
                let moduleName = remainder.split(separator: " ").first.map(String.init) ?? String(remainder)
                seen.insert(moduleName)
                if Self.forbiddenFrameworkImports.contains(moduleName) {
                    violations.append("\(file.lastPathComponent): \(trimmed)")
                }
            }
        }

        #expect(
            violations.isEmpty,
            "MediaByteCache must not import UI or decoder frameworks:\n\(violations.joined(separator: "\n"))")
        #expect(
            seen.subtracting(Self.allowedFrameworkImports).isEmpty,
            "Unexpected MediaByteCache imports: \(seen.subtracting(Self.allowedFrameworkImports).sorted())")
    }

    @Test func hasNoPlatformOrDecodedImageTokens() throws {
        let files = try swiftFiles(in: mediaByteCacheSources)
        #expect(!files.isEmpty)

        var violations: [String] = []
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for token in Self.forbiddenTokens
            where source.range(of: "\\b\(token)\\b", options: .regularExpression) != nil {
                violations.append("\(file.lastPathComponent): \(token)")
            }
        }

        #expect(
            violations.isEmpty,
            "MediaByteCache must not reference platform UI or decoded-image types:\n\(violations.joined(separator: "\n"))"
        )
    }

    private func swiftFiles(in directory: URL) throws -> [URL] {
        guard
            let enumerator = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        else { return [] }
        var results: [URL] = []
        for case let url as URL in enumerator {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                !isDirectory.boolValue,
                url.pathExtension == "swift"
            else { continue }
            results.append(url)
        }
        return results.sorted { $0.path < $1.path }
    }
}
