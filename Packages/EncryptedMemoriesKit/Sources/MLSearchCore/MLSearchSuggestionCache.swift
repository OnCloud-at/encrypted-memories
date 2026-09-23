import Foundation
import PhotosCore

/// A lifecycle-owned read and write lease. Hosts cannot write after its account or model retires.
public struct MLSearchSuggestionCacheAccess: Sendable {
    public let data: Data?
    public let save: @Sendable (Data) async throws -> Void

    public init(data: Data?, save: @escaping @Sendable (Data) async throws -> Void) {
        self.data = data
        self.save = save
    }
}

struct MLSearchSuggestionCacheIdentity: Codable, Equatable, Sendable {
    let descriptor: MLModelDescriptor?
    let modelRevision: String?
    let indexGeneration: UInt64?
    let visualSearchEnabled: Bool
}

/// Rebuildable, authenticated account data. Only the lifecycle calls this synchronous store,
/// so its writes finish before shutdown or the existing whole-root Smart Search purge.
public struct MLSearchSuggestionCache: Sendable {
    private struct Envelope: Codable {
        let version: Int
        let identity: MLSearchSuggestionCacheIdentity
        let payload: Data
    }

    enum CacheError: Error { case tooLarge, incompatibleVersion }
    static let maximumBytes = 64 * 1_024 * 1_024
    private let url: URL
    private let cipher: any MLDerivedDataCipher
    private let context: MLDerivedDataCipherContext

    public init(layout: MLModelInstallLayout, accountIdentifier: String, cipher: any MLDerivedDataCipher) {
        url = layout.rootDirectory.appendingPathComponent("suggestions-v1.enc")
        self.cipher = cipher
        context = MLDerivedDataCipherContext(
            accountIdentifier: accountIdentifier,
            uid: PhotoUID(volumeID: "suggestions", nodeID: "snapshot"),
            artifactNamespace: "search-suggestions-v1")
    }

    func load(identity: MLSearchSuggestionCacheIdentity) throws -> Data? {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch let error as NSError
            where error.domain == NSCocoaErrorDomain
            && (error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError)
        {
            return nil
        }
        guard let size = attributes[.size] as? NSNumber, size.int64Value <= Self.maximumBytes else {
            throw CacheError.tooLarge
        }
        let sealed = try Data(contentsOf: url)
        guard sealed.count <= Self.maximumBytes else { throw CacheError.tooLarge }
        let plaintext = try cipher.open(sealed, context: context)
        let envelope = try PropertyListDecoder().decode(Envelope.self, from: plaintext)
        guard envelope.version == 1 else { throw CacheError.incompatibleVersion }
        guard envelope.identity == identity else { return nil }
        return envelope.payload
    }

    func save(_ payload: Data, identity: MLSearchSuggestionCacheIdentity) throws {
        try Task.checkCancellation()
        guard payload.count <= Self.maximumBytes else { throw CacheError.tooLarge }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let plaintext = try encoder.encode(Envelope(version: 1, identity: identity, payload: payload))
        let sealed = try cipher.seal(plaintext, context: context)
        guard sealed.count <= Self.maximumBytes else { throw CacheError.tooLarge }
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try sealed.write(to: url, options: .atomic)
    }

    func remove() throws {
        do {
            try FileManager.default.removeItem(at: url)
        } catch let error as NSError
            where error.domain == NSCocoaErrorDomain
            && (error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError)
        {
            // Journal recovery can repeat a completed removal.
        }
    }
}
