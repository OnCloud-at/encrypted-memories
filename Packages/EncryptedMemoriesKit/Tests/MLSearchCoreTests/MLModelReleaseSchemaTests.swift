import Foundation
import Testing

@Suite struct MLModelReleaseSchemaTests {
    @Test func releaseSchemasAreStrictVersionOneObjects() throws {
        for name in [
            "release-manifest.schema.json",
            "release-evidence.schema.json",
            "release-qualification.schema.json",
            "retired-models.schema.json",
        ] {
            let schema = try Self.loadJSON(Self.toolsRoot.appendingPathComponent(name))
            #expect(schema["type"] as? String == "object")
            #expect(schema["additionalProperties"] as? Bool == false)
            let properties = try #require(schema["properties"] as? [String: Any])
            let version = try #require(properties["schemaVersion"] as? [String: Any])
            #expect(version["const"] as? Int == 1)
            let required = try #require(schema["required"] as? [String])
            #expect(Set(required) == Set(properties.keys))
            if name == "release-manifest.schema.json" {
                let descriptorVersion = try #require(properties["descriptorVersion"] as? [String: Any])
                #expect(descriptorVersion["minimum"] as? Int == 1)
                #expect(descriptorVersion["maximum"] as? Int == 65_535)
            }
        }
    }

    @Test func modelIDSchemasMatchSwiftConstraints() throws {
        let names = [
            "release-manifest.schema.json",
            "release-evidence.schema.json",
            "release-qualification.schema.json",
            "retired-models.schema.json",
        ]
        let expectedPattern = "^(?:[a-z0-9]|[a-z0-9](?:[a-z0-9]|-(?!-)){0,126}[a-z0-9])$"
        let valid = ["x", "model-one"]
        let invalid = ["X", "model.one", "model--one", String(repeating: "x", count: 129)]

        for name in names {
            let schema = try Self.loadJSON(Self.toolsRoot.appendingPathComponent(name))
            let properties = try #require(schema["properties"] as? [String: Any])
            let pattern: String
            if name == "retired-models.schema.json" {
                let modelIDs = try #require(properties["modelIDs"] as? [String: Any])
                let items = try #require(modelIDs["items"] as? [String: Any])
                pattern = try #require(items["pattern"] as? String)
            } else {
                let modelID = try #require(properties["modelID"] as? [String: Any])
                pattern = try #require(modelID["pattern"] as? String)
            }
            #expect(pattern == expectedPattern)
            let expression = try NSRegularExpression(pattern: pattern)
            for value in valid {
                #expect(Self.matches(expression, value))
            }
            for value in invalid {
                #expect(!Self.matches(expression, value))
            }
        }
    }

    @Test func releaseToolAndRuntimeShareTheSameCompatibilityKeys() throws {
        let releaseTool = try String(
            contentsOf: Self.repositoryRoot.appendingPathComponent("scripts/prepare-ml-model-release.swift"),
            encoding: .utf8
        )
        let runtimeRegistry = try String(
            contentsOf: Self.repositoryRoot.appendingPathComponent(
                "Packages/EncryptedMemoriesKit/Sources/MLSearchCore/MLModelCompatibilityRegistry.swift"
            ),
            encoding: .utf8
        )

        for key in ["clip-dual-encoder-v1", "siglip-dual-encoder-v1"] {
            #expect(releaseTool.contains("\"\(key)\""))
            #expect(runtimeRegistry.contains("key: \"\(key)\""))
        }
    }

    @Test func publicTreeDoesNotContainThePrivateCandidateRegistry() {
        #expect(
            !FileManager.default.fileExists(
                atPath: Self.toolsRoot.appendingPathComponent("model-evidence.json").path
            ))
        #expect(
            !FileManager.default.fileExists(
                atPath: Self.toolsRoot.appendingPathComponent("model-evidence.schema.json").path
            ))
    }

    private static let repositoryRoot: URL = {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        return root
    }()

    private static var toolsRoot: URL {
        repositoryRoot.appendingPathComponent("Tools/MLModels")
    }

    private static func loadJSON(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private static func matches(_ expression: NSRegularExpression, _ value: String) -> Bool {
        let range = NSRange(location: 0, length: value.utf16.count)
        return expression.firstMatch(in: value, range: range)?.range == range
    }
}
