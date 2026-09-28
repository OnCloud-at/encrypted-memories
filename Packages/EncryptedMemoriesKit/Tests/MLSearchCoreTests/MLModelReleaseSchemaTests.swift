import Foundation
import MLSearchCore
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

    @Test func releaseCompatibilityFileMatchesTheAppRegistry() throws {
        let file = try Self.loadJSON(Self.toolsRoot.appendingPathComponent("catalog-compatibility.json"))
        let recipes = try #require(file["recipes"] as? [[String: Any]])
        let registry = MLModelCompatibilityRegistry.builtIn.recipes
        #expect(recipes.compactMap { $0["key"] as? String }.sorted() == registry.keys.sorted())

        for recipe in recipes {
            let key = try #require(recipe["key"] as? String)
            let expected = try #require(registry[key])
            #expect(recipe["minimumDescriptorVersion"] as? Int == expected.descriptorVersionRange.lowerBound)
            #expect(recipe["maximumDescriptorVersion"] as? Int == expected.descriptorVersionRange.upperBound)
            #expect(recipe["embeddingDimension"] as? Int == expected.embeddingDimension)
            #expect(recipe["role"] as? String == expected.role.rawValue)
            #expect(
                (recipe["capabilities"] as? [String])?.sorted() == expected.capabilities.map(\.rawValue).sorted())
            #expect(
                (recipe["requiredRuntimeResources"] as? [String])?.sorted() == expected.runtimeResourcePaths.sorted())
            #expect((recipe["maximumBytes"] as? NSNumber)?.int64Value == expected.maximumArtifactBytes)
            #expect((recipe["maximumFileBytes"] as? NSNumber)?.int64Value == expected.maximumArtifactFileBytes)
            #expect(recipe["license"] as? String == expected.license.identifier)
        }

        let manifest = try Self.loadJSON(Self.toolsRoot.appendingPathComponent("release-manifest.schema.json"))
        let properties = try #require(manifest["properties"] as? [String: Any])
        let keys = try #require((properties["compatibilityKey"] as? [String: Any])?["enum"] as? [String])
        let licenses = try #require((properties["licenseIdentifier"] as? [String: Any])?["enum"] as? [String])
        #expect(keys.sorted() == registry.keys.sorted())
        #expect(Set(licenses) == Set(registry.values.map(\.license.identifier)))
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
