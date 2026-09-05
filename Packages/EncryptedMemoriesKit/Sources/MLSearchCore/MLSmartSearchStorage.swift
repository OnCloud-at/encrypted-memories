import Foundation

/// One consciously refreshed, account-local view of Smart Search disk usage. Media bytes and the
/// shared thumbnail cache are intentionally excluded because their existing owners remain the
/// authority for those caches.
public struct MLSmartSearchStorageBreakdown: Sendable, Equatable {
    public let appleVisionIndexBytes: Int64
    public let semanticVectorIndexBytes: Int64
    public let installedVisualModelsBytes: Int64
    public let partialModelDownloadsBytes: Int64
    public let otherMLDataBytes: Int64

    public init(
        appleVisionIndexBytes: Int64,
        semanticVectorIndexBytes: Int64,
        installedVisualModelsBytes: Int64,
        partialModelDownloadsBytes: Int64,
        otherMLDataBytes: Int64
    ) {
        self.appleVisionIndexBytes = max(0, appleVisionIndexBytes)
        self.semanticVectorIndexBytes = max(0, semanticVectorIndexBytes)
        self.installedVisualModelsBytes = max(0, installedVisualModelsBytes)
        self.partialModelDownloadsBytes = max(0, partialModelDownloadsBytes)
        self.otherMLDataBytes = max(0, otherMLDataBytes)
    }

    public var totalBytes: Int64 {
        appleVisionIndexBytes + semanticVectorIndexBytes + installedVisualModelsBytes
            + partialModelDownloadsBytes + otherMLDataBytes
    }

    public static let empty = MLSmartSearchStorageBreakdown(
        appleVisionIndexBytes: 0,
        semanticVectorIndexBytes: 0,
        installedVisualModelsBytes: 0,
        partialModelDownloadsBytes: 0,
        otherMLDataBytes: 0
    )
}

/// Runs a single bounded directory enumeration only when the lifecycle/controller explicitly asks
/// for a refresh. The scan never executes on the main actor and does not create a second cache-size
/// authority or background polling loop.
public actor MLSmartSearchStorageMeter {
    private let layout: MLModelInstallLayout

    public init(layout: MLModelInstallLayout) {
        self.layout = layout
    }

    public func measure() async -> MLSmartSearchStorageBreakdown {
        let layout = self.layout
        return await Task.detached(priority: .utility) {
            Self.measureSynchronously(layout: layout)
        }.value
    }

    private nonisolated static func measureSynchronously(
        layout: MLModelInstallLayout
    ) -> MLSmartSearchStorageBreakdown {
        let fileManager = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        guard
            let enumerator = fileManager.enumerator(
                at: layout.rootDirectory,
                includingPropertiesForKeys: keys,
                options: [],
                errorHandler: { _, _ in true }
            )
        else { return .empty }

        let modelPrefix = layout.modelsDirectory.standardizedFileURL.path + "/"
        let temporaryPrefix = layout.temporaryDirectory.standardizedFileURL.path + "/"
        let semanticName = layout.indexDatabaseURL.lastPathComponent
        let visionName = layout.derivedIndexDatabaseURL.lastPathComponent
        var vision: Int64 = 0
        var semantic: Int64 = 0
        var models: Int64 = 0
        var partial: Int64 = 0
        var other: Int64 = 0

        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if values.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            guard values.isRegularFile == true else { continue }
            let bytes = Int64(values.fileSize ?? 0)
            let standardized = url.standardizedFileURL
            let name = standardized.lastPathComponent
            if name == visionName || name.hasPrefix(visionName + "-") {
                vision += bytes
            } else if name == semanticName || name.hasPrefix(semanticName + "-") {
                semantic += bytes
            } else if standardized.path.hasPrefix(modelPrefix) {
                models += bytes
            } else if standardized.path.hasPrefix(temporaryPrefix) {
                partial += bytes
            } else {
                other += bytes
            }
        }
        return MLSmartSearchStorageBreakdown(
            appleVisionIndexBytes: vision,
            semanticVectorIndexBytes: semantic,
            installedVisualModelsBytes: models,
            partialModelDownloadsBytes: partial,
            otherMLDataBytes: other
        )
    }
}
