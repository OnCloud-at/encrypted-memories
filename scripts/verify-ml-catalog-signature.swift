#!/usr/bin/env swift
import CryptoKit
import Foundation

private struct ActiveCatalogObject: Codable {
    let name: String
    let path: String
    let sha256: String
    let bytes: Int64
}

private struct ActiveCatalogPayload: Codable {
    let schemaVersion: Int
    let pairID: String
    let catalogSequence: UInt64
    let objects: [ActiveCatalogObject]
}

private struct ActiveCatalogPointer: Codable {
    let payload: ActiveCatalogPayload
    let signature: String
}

private func publicKey(from base64: String) throws -> Curve25519.Signing.PublicKey {
    guard let data = Data(base64Encoded: base64),
        let key = try? Curve25519.Signing.PublicKey(rawRepresentation: data)
    else {
        throw CocoaError(.fileReadCorruptFile)
    }
    return key
}

private func verifyDetachedSignature(arguments: [String]) throws {
    let catalog = try Data(contentsOf: URL(fileURLWithPath: arguments[1]))
    let signature = try Data(contentsOf: URL(fileURLWithPath: arguments[2]))
    let key = try publicKey(from: arguments[3])
    guard key.isValidSignature(signature, for: catalog) else {
        fputs("Catalog signature is invalid\n", stderr)
        exit(1)
    }
    print("Catalog signature is valid")
}

private func verifyPointerSignature(arguments: [String]) throws {
    let data = try Data(contentsOf: URL(fileURLWithPath: arguments[2]))
    let pointer = try JSONDecoder().decode(ActiveCatalogPointer.self, from: data)
    guard let signature = Data(base64Encoded: pointer.signature), signature.count == 64 else {
        fputs("Active pointer signature is invalid\n", stderr)
        exit(1)
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let payload = try encoder.encode(pointer.payload)
    let key = try publicKey(from: arguments[3])
    guard key.isValidSignature(signature, for: payload) else {
        fputs("Active pointer signature is invalid\n", stderr)
        exit(1)
    }
    print("Active pointer signature is valid")
}

do {
    let arguments = CommandLine.arguments
    if arguments.count == 4, arguments[1] == "--pointer" {
        try verifyPointerSignature(arguments: arguments)
    } else if arguments.count == 4 {
        try verifyDetachedSignature(arguments: arguments)
    } else {
        fputs(
            "Usage: verify-ml-catalog-signature.swift CATALOG SIGNATURE PUBLIC_KEY_BASE64\n"
                + "       verify-ml-catalog-signature.swift --pointer ACTIVE_PAIR PUBLIC_KEY_BASE64\n",
            stderr
        )
        exit(2)
    }
} catch {
    fputs("Catalog verification failed: \(error)\n", stderr)
    exit(1)
}
