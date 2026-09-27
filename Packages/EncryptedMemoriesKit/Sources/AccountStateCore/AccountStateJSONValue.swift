import Foundation

/// A JSON value that the account state reads and writes with its own codec.
///
/// The codec is lossless and canonical: a number keeps its exact text, every string and key must already be in
/// Unicode normalization form C, and object keys are sorted by their UTF-8 bytes. Equal values therefore always give
/// equal bytes, and different values give different bytes, which gives every device the same order for values.
/// Foundation's JSON coders round numbers through Decimal or Double and cannot give that guarantee.
///
/// The codec and `AccountStateDocument.setValue` accept at most `maximumDepth` levels of nesting and only strings in
/// normalization form C. Comparing, hashing, and writing are recursive, so code that builds values directly must stay
/// within the same rules.
public enum AccountStateJSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    /// The number's JSON text, exactly as written.
    case number(String)
    case string(String)
    case array([AccountStateJSONValue])
    case object([String: AccountStateJSONValue])

    /// Nesting deeper than this is refused when reading and when changing a value.
    static let maximumDepth = 64

    static func integer<Integer: FixedWidthInteger>(_ value: Integer) -> AccountStateJSONValue {
        .number(String(value))
    }

    subscript(key: String) -> AccountStateJSONValue? {
        if case .object(let object) = self { object[key] } else { nil }
    }

    var stringValue: String? {
        if case .string(let value) = self { value } else { nil }
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { value } else { nil }
    }

    /// The value when it is written as a plain whole number in `range`: no sign other than a leading minus, no
    /// fraction, no exponent, no leading zero.
    func integerValue<Integer: FixedWidthInteger>(in range: ClosedRange<Integer>) -> Integer? {
        guard case .number(let text) = self, Self.isPlainInteger(text), let integer = Integer(text),
            range.contains(integer)
        else { return nil }
        return integer
    }

    private static func isPlainInteger(_ text: String) -> Bool {
        let digits = text.utf8.first == UInt8(ascii: "-") ? text.utf8.dropFirst() : text.utf8[...]
        guard let first = digits.first, digits.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { return false }
        return first != 0x30 || digits.count == 1
    }

    /// Whether this value may be written inside `enclosingLevels` containers: the whole nesting stays within the
    /// limit, and each number is valid JSON number text. The check stops at the limit, so a value nested far deeper
    /// cannot exhaust the stack.
    func isWritable(insideLevels enclosingLevels: Int) -> Bool {
        isWritable(remainingDepth: Self.maximumDepth - enclosingLevels)
    }

    private func isWritable(remainingDepth: Int) -> Bool {
        switch self {
        case .null, .bool: true
        case .string(let text): Self.isNormalized(text)
        case .number(let text): JSONScanner.isNumber(Array(text.utf8))
        case .array(let values):
            remainingDepth > 0 && values.allSatisfy { $0.isWritable(remainingDepth: remainingDepth - 1) }
        case .object(let values):
            remainingDepth > 0
                && values.allSatisfy {
                    Self.isNormalized($0.key) && $0.value.isWritable(remainingDepth: remainingDepth - 1)
                }
        }
    }

    /// The value with every string and key in normalization form C, up to the depth limit. Deeper parts stay as they
    /// are; `isWritable` refuses them.
    func normalizingStrings(remainingDepth: Int = maximumDepth) -> AccountStateJSONValue {
        guard remainingDepth > 0 else { return self }
        switch self {
        case .null, .bool, .number: return self
        case .string(let text): return .string(Self.normalized(text))
        case .array(let values): return .array(values.map { $0.normalizingStrings(remainingDepth: remainingDepth - 1) })
        case .object(let values):
            var result: [String: AccountStateJSONValue] = [:]
            for (key, value) in values {
                result[Self.normalized(key)] = value.normalizingStrings(remainingDepth: remainingDepth - 1)
            }
            return .object(result)
        }
    }

    // MARK: - Canonical text

    /// The canonical UTF-8 bytes of the value.
    var canonicalBytes: [UInt8] {
        var output: [UInt8] = []
        write(to: &output)
        return output
    }

    /// A total order that agrees with equality: it compares canonical bytes.
    static func precedes(_ lhs: AccountStateJSONValue, _ rhs: AccountStateJSONValue) -> Bool {
        lhs.canonicalBytes.lexicographicallyPrecedes(rhs.canonicalBytes)
    }

    private func write(to output: inout [UInt8]) {
        switch self {
        case .null: output += Array("null".utf8)
        case .bool(let value): output += Array((value ? "true" : "false").utf8)
        case .number(let text): output += Array(text.utf8)
        case .string(let text): Self.writeString(text, to: &output)
        case .array(let values):
            output.append(UInt8(ascii: "["))
            for (index, value) in values.enumerated() {
                if index > 0 { output.append(UInt8(ascii: ",")) }
                value.write(to: &output)
            }
            output.append(UInt8(ascii: "]"))
        case .object(let values):
            output.append(UInt8(ascii: "{"))
            let sorted = values.map { (Array($0.key.utf8), $0.value) }
                .sorted { $0.0.lexicographicallyPrecedes($1.0) }
            for (index, (key, value)) in sorted.enumerated() {
                if index > 0 { output.append(UInt8(ascii: ",")) }
                Self.writeString(String(decoding: key, as: UTF8.self), to: &output)
                output.append(UInt8(ascii: ":"))
                value.write(to: &output)
            }
            output.append(UInt8(ascii: "}"))
        }
    }

    private static func writeString(_ text: String, to output: inout [UInt8]) {
        output.append(UInt8(ascii: "\""))
        for byte in text.utf8 {
            switch byte {
            case UInt8(ascii: "\""): output += Array(#"\""#.utf8)
            case UInt8(ascii: "\\"): output += Array(#"\\"#.utf8)
            case 0x0A: output += Array(#"\n"#.utf8)
            case 0x0D: output += Array(#"\r"#.utf8)
            case 0x09: output += Array(#"\t"#.utf8)
            case 0x00..<0x20:
                let hex = Array("0123456789abcdef".utf8)
                output += Array(#"\u00"#.utf8) + [hex[Int(byte >> 4)], hex[Int(byte & 0x0F)]]
            default: output.append(byte)
            }
        }
        output.append(UInt8(ascii: "\""))
    }

    static func normalized(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping
    }

    /// Whether `text` is in normalization form C byte for byte. Foundation shortens some very long runs of combining
    /// marks while normalizing, so such text is never stable and never accepted.
    static func isNormalized(_ text: String) -> Bool {
        text.utf8.elementsEqual(normalized(text).utf8)
    }

    // MARK: - Reading

    /// Reads one JSON value that fills all of `data`. Nil for invalid JSON, invalid UTF-8, nesting beyond the limit,
    /// a string or key that is not in normalization form C, or an object with the same key twice.
    init?(json data: Data) {
        var scanner = JSONScanner(bytes: Array(data))
        guard let value = scanner.value(depth: 0), scanner.isAtEndAfterWhitespace else { return nil }
        self = value
    }
}

/// A strict RFC 8259 reader for `AccountStateJSONValue`.
private struct JSONScanner {
    let bytes: [UInt8]
    var index = 0

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    var isAtEndAfterWhitespace: Bool {
        mutating get {
            skipWhitespace()
            return index == bytes.count
        }
    }

    mutating func value(depth: Int) -> AccountStateJSONValue? {
        skipWhitespace()
        guard index < bytes.count else { return nil }
        switch bytes[index] {
        case UInt8(ascii: "{"): return object(depth: depth + 1)
        case UInt8(ascii: "["): return array(depth: depth + 1)
        case UInt8(ascii: "\""): return string().map { .string($0) }
        case UInt8(ascii: "t"): return literal("true", .bool(true))
        case UInt8(ascii: "f"): return literal("false", .bool(false))
        case UInt8(ascii: "n"): return literal("null", .null)
        default: return number()
        }
    }

    private mutating func object(depth: Int) -> AccountStateJSONValue? {
        guard depth <= AccountStateJSONValue.maximumDepth else { return nil }
        index += 1
        var result: [String: AccountStateJSONValue] = [:]
        skipWhitespace()
        if consume(UInt8(ascii: "}")) { return .object(result) }
        repeat {
            skipWhitespace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: "\""), let key = string() else { return nil }
            skipWhitespace()
            guard consume(UInt8(ascii: ":")), let value = value(depth: depth) else { return nil }
            guard result.updateValue(value, forKey: key) == nil else { return nil }
            skipWhitespace()
        } while consume(UInt8(ascii: ","))
        return consume(UInt8(ascii: "}")) ? .object(result) : nil
    }

    private mutating func array(depth: Int) -> AccountStateJSONValue? {
        guard depth <= AccountStateJSONValue.maximumDepth else { return nil }
        index += 1
        var result: [AccountStateJSONValue] = []
        skipWhitespace()
        if consume(UInt8(ascii: "]")) { return .array(result) }
        repeat {
            guard let value = value(depth: depth) else { return nil }
            result.append(value)
            skipWhitespace()
        } while consume(UInt8(ascii: ","))
        return consume(UInt8(ascii: "]")) ? .array(result) : nil
    }

    private mutating func string() -> String? {
        index += 1
        var utf8: [UInt8] = []
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            switch byte {
            case UInt8(ascii: "\""):
                guard let text = String(bytes: utf8, encoding: .utf8), AccountStateJSONValue.isNormalized(text) else {
                    return nil
                }
                return text
            case UInt8(ascii: "\\"):
                guard index < bytes.count else { return nil }
                let escape = bytes[index]
                index += 1
                switch escape {
                case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"): utf8.append(escape)
                case UInt8(ascii: "b"): utf8.append(0x08)
                case UInt8(ascii: "f"): utf8.append(0x0C)
                case UInt8(ascii: "n"): utf8.append(0x0A)
                case UInt8(ascii: "r"): utf8.append(0x0D)
                case UInt8(ascii: "t"): utf8.append(0x09)
                case UInt8(ascii: "u"):
                    guard let scalar = unicodeEscape() else { return nil }
                    utf8 += Array(String(Character(scalar)).utf8)
                default: return nil
                }
            case 0x00..<0x20:
                return nil
            default:
                utf8.append(byte)
            }
        }
        return nil
    }

    /// The scalar of a `\u` escape, including a surrogate pair. Nil for a lone surrogate.
    private mutating func unicodeEscape() -> Unicode.Scalar? {
        guard let high = hexUnit() else { return nil }
        if (0xD800...0xDBFF).contains(high) {
            guard consume(UInt8(ascii: "\\")), consume(UInt8(ascii: "u")), let low = hexUnit(),
                (0xDC00...0xDFFF).contains(low)
            else { return nil }
            return Unicode.Scalar(0x10000 + ((high - 0xD800) << 10) + (low - 0xDC00))
        }
        return Unicode.Scalar(high)
    }

    private mutating func hexUnit() -> UInt32? {
        guard index + 4 <= bytes.count else { return nil }
        var result: UInt32 = 0
        for byte in bytes[index..<index + 4] {
            guard let digit = Self.hexDigit(byte) else { return nil }
            result = result << 4 | digit
        }
        index += 4
        return result
    }

    private static func hexDigit(_ byte: UInt8) -> UInt32? {
        switch byte {
        case 0x30...0x39: UInt32(byte - 0x30)
        case 0x41...0x46: UInt32(byte - 0x41 + 10)
        case 0x61...0x66: UInt32(byte - 0x61 + 10)
        default: nil
        }
    }

    private mutating func number() -> AccountStateJSONValue? {
        let start = index
        while index < bytes.count, Self.isNumberByte(bytes[index]) { index += 1 }
        let text = Array(bytes[start..<index])
        guard Self.isNumber(text) else { return nil }
        return .number(String(decoding: text, as: UTF8.self))
    }

    private static func isNumberByte(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte) || byte == UInt8(ascii: "-") || byte == UInt8(ascii: "+")
            || byte == UInt8(ascii: ".") || byte == UInt8(ascii: "e") || byte == UInt8(ascii: "E")
    }

    /// RFC 8259: `-? (0 | [1-9][0-9]*) (. [0-9]+)? ([eE] [+-]? [0-9]+)?`
    static func isNumber(_ text: [UInt8]) -> Bool {
        var position = 0
        func digits() -> Int {
            let start = position
            while position < text.count, (0x30...0x39).contains(text[position]) { position += 1 }
            return position - start
        }
        if position < text.count, text[position] == UInt8(ascii: "-") { position += 1 }
        guard position < text.count else { return false }
        if text[position] == 0x30 {
            position += 1
        } else if digits() == 0 {
            return false
        }
        if position < text.count, text[position] == UInt8(ascii: ".") {
            position += 1
            guard digits() > 0 else { return false }
        }
        if position < text.count, text[position] == UInt8(ascii: "e") || text[position] == UInt8(ascii: "E") {
            position += 1
            if position < text.count, text[position] == UInt8(ascii: "+") || text[position] == UInt8(ascii: "-") {
                position += 1
            }
            guard digits() > 0 else { return false }
        }
        return position == text.count
    }

    private mutating func literal(_ word: String, _ value: AccountStateJSONValue) -> AccountStateJSONValue? {
        let expected = Array(word.utf8)
        guard index + expected.count <= bytes.count, Array(bytes[index..<index + expected.count]) == expected else {
            return nil
        }
        index += expected.count
        return value
    }

    private mutating func consume(_ byte: UInt8) -> Bool {
        guard index < bytes.count, bytes[index] == byte else { return false }
        index += 1
        return true
    }

    private mutating func skipWhitespace() {
        while index < bytes.count,
            bytes[index] == 0x20 || bytes[index] == 0x09 || bytes[index] == 0x0A || bytes[index] == 0x0D
        {
            index += 1
        }
    }
}
