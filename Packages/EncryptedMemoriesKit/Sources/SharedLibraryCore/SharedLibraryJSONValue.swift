import Foundation

/// A JSON value kept verbatim. A change type that a newer build wrote survives when this build rewrites its journal.
public enum SharedLibraryJSONValue: Sendable, Equatable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([SharedLibraryJSONValue])
    case object([String: SharedLibraryJSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([SharedLibraryJSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: SharedLibraryJSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    subscript(key: String) -> SharedLibraryJSONValue? {
        if case .object(let object) = self { object[key] } else { nil }
    }

    var stringValue: String? {
        if case .string(let value) = self { value } else { nil }
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { value } else { nil }
    }

    var numberValue: Double? {
        if case .number(let value) = self, value.isFinite { value } else { nil }
    }
}
