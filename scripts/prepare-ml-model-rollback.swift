#!/usr/bin/env swift
import CryptoKit
import Foundation

private struct FileDigest: Encodable {
    let path: String
    let sha256: String
    let bytes: Int64
}

private struct ModelRevision: Encodable {
    let id: String
    let revision: String
    let availability: String?
}

private struct RollbackPairManifest: Encodable {
    let schemaVersion = 1
    let catalogSequence: UInt64
    let repositoryRevision: String
    let releasedAt: String
    let rollbackSourcePair: String
    let files: [FileDigest]
    let models: [ModelRevision]
}

private struct ActivePairObject: Codable, Equatable {
    let name: String
    let path: String
    let sha256: String
    let bytes: Int64
}

private struct ActivePairPayload: Codable, Equatable {
    let schemaVersion: Int
    let pairID: String
    let catalogSequence: UInt64
    let objects: [ActivePairObject]

    init(pairID: String, catalogSequence: UInt64, objects: [ActivePairObject]) {
        schemaVersion = 1
        self.pairID = pairID
        self.catalogSequence = catalogSequence
        self.objects = objects
    }
}

private struct ActivePairPointer: Codable, Equatable {
    let payload: ActivePairPayload
    let signature: String
}

private struct Options {
    let catalogV1: URL
    let catalogV2: URL
    let privateKey: URL
    let output: URL
    let catalogSequence: UInt64
    let repositoryRevision: String
    let releasedAt: String
    let sourcePair: String
}

private enum RollbackError: Error, CustomStringConvertible {
    case usage
    case invalid(String)

    var description: String {
        switch self {
        case .usage:
            return
                "Usage: prepare-ml-model-rollback.swift --catalog-v1 FILE --catalog-v2 FILE --private-key FILE --output DIR --catalog-sequence NUMBER --repository-revision SHA --released-at ISO8601 --source-pair SHA256"
        case .invalid(let reason):
            return reason
        }
    }
}

private func parseOptions() throws -> Options {
    var values: [String: String] = [:]
    let allowed = Set([
        "--catalog-v1", "--catalog-v2", "--private-key", "--output", "--catalog-sequence",
        "--repository-revision", "--released-at", "--source-pair",
    ])
    var index = 1
    while index < CommandLine.arguments.count {
        guard index + 1 < CommandLine.arguments.count else { throw RollbackError.usage }
        let key = CommandLine.arguments[index]
        let value = CommandLine.arguments[index + 1]
        guard allowed.contains(key), values[key] == nil else { throw RollbackError.usage }
        values[key] = value
        index += 2
    }
    guard let catalogV1 = values["--catalog-v1"],
        let catalogV2 = values["--catalog-v2"],
        let privateKey = values["--private-key"],
        let output = values["--output"],
        let rawSequence = values["--catalog-sequence"],
        let sequence = UInt64(rawSequence), sequence > 0,
        let repositoryRevision = values["--repository-revision"],
        let releasedAt = values["--released-at"],
        let sourcePair = values["--source-pair"]
    else { throw RollbackError.usage }
    guard isRevision(repositoryRevision),
        isSHA256(sourcePair),
        ISO8601DateFormatter().date(from: releasedAt) != nil
    else {
        throw RollbackError.invalid("Rollback metadata is invalid")
    }
    return Options(
        catalogV1: URL(fileURLWithPath: catalogV1),
        catalogV2: URL(fileURLWithPath: catalogV2),
        privateKey: URL(fileURLWithPath: privateKey),
        output: URL(fileURLWithPath: output, isDirectory: true),
        catalogSequence: sequence,
        repositoryRevision: repositoryRevision,
        releasedAt: releasedAt,
        sourcePair: sourcePair
    )
}

private func isRevision(_ value: String) -> Bool {
    (value.count == 40 || value.count == 64)
        && value.allSatisfy { $0 >= "0" && $0 <= "9" || $0 >= "a" && $0 <= "f" }
}

private func isSafeModelID(_ value: String) -> Bool {
    let bytes = Array(value.utf8)
    guard !bytes.isEmpty, bytes.count <= 128,
        isASCIILowercaseLetterOrDigit(bytes[0]),
        isASCIILowercaseLetterOrDigit(bytes[bytes.count - 1])
    else {
        return false
    }
    var previousSeparator = false
    for byte in bytes {
        guard isASCIILowercaseLetterOrDigit(byte) || byte == 0x2D else {
            return false
        }
        if byte == 0x2D {
            guard !previousSeparator else { return false }
            previousSeparator = true
        } else {
            previousSeparator = false
        }
    }
    return true
}

private func isASCIILowercaseLetterOrDigit(_ byte: UInt8) -> Bool {
    (0x61...0x7A).contains(byte) || (0x30...0x39).contains(byte)
}

private func isSafeCatalogRevision(_ value: String) -> Bool {
    !value.isEmpty && value.count <= 128
        && value.allSatisfy {
            ($0.isLetter || $0.isNumber) && $0.isASCII || $0 == "-" || $0 == "_"
        }
}

private func isSHA256(_ value: String) -> Bool {
    value.count == 64
        && value.allSatisfy { $0 >= "0" && $0 <= "9" || $0 >= "a" && $0 <= "f" }
}

private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func sha256(_ url: URL) throws -> String {
    sha256(try Data(contentsOf: url))
}

private func fileSize(_ url: URL) throws -> Int64 {
    Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
}

private func digest(_ url: URL, path: String) throws -> FileDigest {
    FileDigest(path: path, sha256: try sha256(url), bytes: try fileSize(url))
}

private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(value)
    try data.write(to: url, options: .atomic)
    return data
}

private func canonicalJSON<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
}

private func requireEmptyOutputDirectory(_ directory: URL) throws {
    let fileManager = FileManager.default
    guard fileManager.fileExists(atPath: directory.path) else { return }
    let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard values.isDirectory == true, values.isSymbolicLink != true else {
        throw RollbackError.invalid("The output path must be a regular directory")
    }
    guard try fileManager.contentsOfDirectory(atPath: directory.path).isEmpty else {
        throw RollbackError.invalid("The output directory must be empty")
    }
}

do {
    let options = try parseOptions()
    try requireEmptyOutputDirectory(options.output)
    let keyData = try Data(contentsOf: options.privateKey)
    guard keyData.count == 32,
        let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: keyData)
    else {
        throw RollbackError.invalid("The signing key must contain exactly 32 raw Ed25519 bytes")
    }

    let sourceV1 = try Data(contentsOf: options.catalogV1)
    let sourceV2 = try Data(contentsOf: options.catalogV2)
    guard let v1 = try JSONSerialization.jsonObject(with: sourceV1) as? [String: Any],
        v1["schemaVersion"] as? Int == 1,
        let v1Models = v1["models"] as? [[String: Any]],
        !v1Models.isEmpty,
        var v2 = try JSONSerialization.jsonObject(with: sourceV2) as? [String: Any],
        v2["schemaVersion"] as? Int == 2,
        let oldSequence = v2["catalogSequence"] as? UInt64,
        oldSequence > 0,
        options.catalogSequence > oldSequence,
        let v2Models = v2["models"] as? [[String: Any]],
        !v2Models.isEmpty
    else {
        throw RollbackError.invalid("Historical catalogs or rollback sequence are invalid")
    }

    let legacyModels = try v1Models.map { model -> (id: String, revision: String) in
        guard let id = model["id"] as? String,
            let revision = model["revision"] as? String,
            isSafeModelID(id),
            isSafeCatalogRevision(revision)
        else {
            throw RollbackError.invalid("Historical catalog contains an invalid legacy model")
        }
        return (id, revision)
    }
    guard Set(legacyModels.map(\.id)).count == legacyModels.count else {
        throw RollbackError.invalid("Historical catalog contains duplicate legacy models")
    }

    let models = try v2Models.map { model -> ModelRevision in
        guard let id = model["id"] as? String,
            let revision = model["revision"] as? String,
            let releaseSequence = model["releaseSequence"] as? UInt64,
            isSafeModelID(id),
            isSafeCatalogRevision(revision),
            releaseSequence > 0
        else {
            throw RollbackError.invalid("Historical catalog contains an invalid model")
        }
        let availability: String?
        if let rawAvailability = model["availability"] {
            guard let value = rawAvailability as? String, value == "active" || value == "retired" else {
                throw RollbackError.invalid("Historical catalog contains an invalid model availability")
            }
            availability = value
        } else {
            availability = nil
        }
        return ModelRevision(id: id, revision: revision, availability: availability)
    }.sorted { $0.id < $1.id }
    guard Set(models.map(\.id)).count == models.count else {
        throw RollbackError.invalid("Historical catalog contains duplicate models")
    }

    try FileManager.default.createDirectory(at: options.output, withIntermediateDirectories: true)
    let catalogV1URL = options.output.appendingPathComponent("catalog-v1.json")
    try sourceV1.write(to: catalogV1URL, options: .atomic)
    let signatureV1URL = options.output.appendingPathComponent("catalog-v1.sig")
    try key.signature(for: sourceV1).write(to: signatureV1URL, options: .atomic)

    v2["catalogSequence"] = options.catalogSequence
    v2["models"] = v2Models.map { model in
        var updated = model
        updated["releaseSequence"] = options.catalogSequence
        return updated
    }
    let catalogV2Data = try JSONSerialization.data(
        withJSONObject: v2,
        options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    )
    let catalogV2URL = options.output.appendingPathComponent("catalog-v2.json")
    try catalogV2Data.write(to: catalogV2URL, options: .atomic)
    let signatureV2URL = options.output.appendingPathComponent("catalog-v2.sig")
    try key.signature(for: catalogV2Data).write(to: signatureV2URL, options: .atomic)

    let files = try [
        digest(catalogV1URL, path: "catalog-v1.json"),
        digest(signatureV1URL, path: "catalog-v1.sig"),
        digest(catalogV2URL, path: "catalog-v2.json"),
        digest(signatureV2URL, path: "catalog-v2.sig"),
    ].sorted { $0.path < $1.path }
    let pair = RollbackPairManifest(
        catalogSequence: options.catalogSequence,
        repositoryRevision: options.repositoryRevision,
        releasedAt: options.releasedAt,
        rollbackSourcePair: options.sourcePair,
        files: files,
        models: models
    )
    let pairURL = options.output.appendingPathComponent("release-pair.json")
    let pairData = try writeJSON(pair, to: pairURL)
    let pairID = sha256(pairData)
    try (pairID + "\n").write(
        to: options.output.appendingPathComponent("release-pair.sha256"),
        atomically: true,
        encoding: .utf8
    )

    let pointerObjects =
        files.map { file in
            ActivePairObject(
                name: file.path,
                path: "catalog-history/\(pairID)/\(file.path)",
                sha256: file.sha256,
                bytes: file.bytes
            )
        } + [
            ActivePairObject(
                name: "release-pair.json",
                path: "catalog-history/\(pairID)/release-pair.json",
                sha256: pairID,
                bytes: try fileSize(pairURL)
            )
        ]
    let pointerPayload = ActivePairPayload(
        pairID: pairID,
        catalogSequence: options.catalogSequence,
        objects: pointerObjects
    )
    let pointerPayloadData = try canonicalJSON(pointerPayload)
    let pointerSignature = try key.signature(for: pointerPayloadData).base64EncodedString()
    let pointerURL = options.output.appendingPathComponent("active-pair.json")
    let pointerData = try writeJSON(
        ActivePairPointer(payload: pointerPayload, signature: pointerSignature),
        to: pointerURL
    )

    guard key.publicKey.isValidSignature(try Data(contentsOf: signatureV1URL), for: sourceV1),
        key.publicKey.isValidSignature(try Data(contentsOf: signatureV2URL), for: catalogV2Data),
        let pointerSignatureData = Data(base64Encoded: pointerSignature),
        key.publicKey.isValidSignature(pointerSignatureData, for: pointerPayloadData),
        try JSONDecoder().decode(ActivePairPointer.self, from: pointerData).payload == pointerPayload
    else {
        throw RollbackError.invalid("Generated rollback signatures are invalid")
    }
    print("Prepared rollback pair \(pairID) at sequence \(options.catalogSequence)")
    print("No remote state was changed")
} catch {
    fputs("error: \(error)\n", stderr)
    exit(1)
}
