import Foundation

/// One MetricKit diagnostic as plain values. The platform collector converts `MXDiagnosticPayload` into this type, so
/// the summary below needs no MetricKit and runs in unit tests. It holds every value the summary may read; a value that
/// the support file must not carry has no place here.
public struct MetricKitDiagnosticInput: Sendable, Equatable {
    public enum Kind: String, Sendable {
        case crash, hang, cpuException, diskWriteException, appLaunch
    }

    public var kind: Kind
    /// The reporting period of the payload (`timeStampBegin` and `timeStampEnd`).
    public var rangeStart: Date
    public var rangeEnd: Date
    public var appVersion: String
    public var appBuild: String
    /// The OS name, version and build, as MetricKit reports it.
    public var osVersion: String
    public var exceptionType: Int?
    public var signal: Int?
    public var terminationReason: String?
    public var hangSeconds: Double?
    public var cpuSeconds: Double?
    public var sampledSeconds: Double?
    public var launchSeconds: Double?
    public var writtenMegabytes: Double?
    /// `MXCallStackTree.jsonRepresentation()`.
    public var callStackTreeJSON: Data?
    /// The executable name of the running app, from its bundle. It is the one binary name that may hold a space, as the
    /// Mac app's `Encrypted Memories` does. No name from the payload passes unless it equals this value.
    public var appExecutableName: String?

    public init(
        kind: Kind, rangeStart: Date, rangeEnd: Date, appVersion: String, appBuild: String, osVersion: String,
        exceptionType: Int? = nil, signal: Int? = nil, terminationReason: String? = nil, hangSeconds: Double? = nil,
        cpuSeconds: Double? = nil, sampledSeconds: Double? = nil, launchSeconds: Double? = nil,
        writtenMegabytes: Double? = nil, callStackTreeJSON: Data? = nil, appExecutableName: String? = nil
    ) {
        self.kind = kind
        self.rangeStart = rangeStart
        self.rangeEnd = rangeEnd
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.osVersion = osVersion
        self.exceptionType = exceptionType
        self.signal = signal
        self.terminationReason = terminationReason
        self.hangSeconds = hangSeconds
        self.cpuSeconds = cpuSeconds
        self.sampledSeconds = sampledSeconds
        self.launchSeconds = launchSeconds
        self.writtenMegabytes = writtenMegabytes
        self.callStackTreeJSON = callStackTreeJSON
        self.appExecutableName = appExecutableName
    }
}

/// Turns one MetricKit diagnostic into the fields of the support file. The result holds only closed values: the kind,
/// version and build tokens, numbers, a minute-rounded period, and for each of the innermost frames of the faulting
/// thread a binary name with an offset into that binary. No path, name, identifier, account value or free text of the
/// payload passes: every value is built from a parsed number or a token of a fixed alphabet, and the keys pass the
/// support allowlist of `PhotoDiagnostics`. The checks prove the alphabet and the length of a value, not its meaning:
/// the values themselves come from the OS and are taken as they are.
public enum MetricKitDiagnosticSummary {
    /// The innermost frames of the faulting thread that a summary keeps.
    static let frameLimit = 8
    /// The keys of those frames: `frame0` is the innermost one.
    static let frameKeys = (0..<frameLimit).map { "frame\($0)" }
    private static let binaryNameLimit = 48

    /// The support-file fields of one diagnostic.
    public static func fields(for input: MetricKitDiagnosticInput) -> [String: String] {
        var fields = ["kind": input.kind.rawValue]
        func set(_ key: String, _ value: String?) {
            if let value { fields[key] = value }
        }
        set("rangeStart", minute(input.rangeStart))
        set("rangeEnd", minute(input.rangeEnd))
        set("appVersion", token(input.appVersion, limit: 24))
        set("appBuild", token(input.appBuild, limit: 24))
        set("osBuild", osBuild(input.osVersion))
        set("exceptionType", input.exceptionType.map(String.init))
        set("signal", input.signal.map(String.init))
        if let reason = input.terminationReason, let termination = termination(reason) {
            fields["terminationNamespace"] = termination.namespace
            fields["terminationCode"] = termination.code
        }
        set("hangSeconds", number(input.hangSeconds))
        set("cpuSeconds", number(input.cpuSeconds))
        set("sampledSeconds", number(input.sampledSeconds))
        set("launchSeconds", number(input.launchSeconds))
        set("writtenMB", number(input.writtenMegabytes))
        if let tree = input.callStackTreeJSON {
            for (key, frame) in zip(frameKeys, frames(in: tree, executableName: input.appExecutableName)) {
                fields[key] = frame
            }
        }
        return PhotoDiagnostics.sanitizedSupportFields(event: "MetricKitDiagnostic", fields: fields) ?? [:]
    }

    /// The date rounded down to the minute, in ISO 8601.
    private static func minute(_ date: Date) -> String {
        let rounded = Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 60).rounded(.down) * 60)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: rounded)
    }

    /// `value` when it has 1 to `limit` characters of letters, digits and `. _ + -`; otherwise nil.
    private static func token(_ value: String, limit: Int) -> String? {
        guard (1...limit).contains(value.count) else { return nil }
        return value.unicodeScalars.allSatisfy(isTokenScalar) ? value : nil
    }

    private static func isTokenScalar(_ scalar: Unicode.Scalar) -> Bool {
        if "._+-".unicodeScalars.contains(scalar) { return true }
        return scalar.isASCII && (scalar.properties.isAlphabetic || ("0"..."9").contains(scalar))
    }

    /// The build token in the last parentheses of the OS version, for example `24B91` of `iPhone OS 27.1 (24B91)`.
    private static func osBuild(_ osVersion: String) -> String? {
        guard osVersion.hasSuffix(")"), let open = osVersion.lastIndex(of: "(") else { return nil }
        let build = String(osVersion[osVersion.index(after: open)..<osVersion.index(before: osVersion.endIndex)])
        return build.count >= 3 ? token(build, limit: 10) : nil
    }

    /// The largest number that a summary prints: 10^12 seconds or megabytes is beyond any real value.
    private static let numberLimit = 1e12

    /// A number with one decimal; nil for a missing, negative, infinite or too large value.
    private static func number(_ value: Double?) -> String? {
        guard let value, (0...numberLimit).contains(value) else { return nil }
        return String(format: "%.1f", value)
    }

    /// The namespace and the code of a termination reason, and nothing else of it. The reason is free text of the OS;
    /// only a text that starts like `Namespace SIGNAL, Code 11` yields fields. UNVERIFIED: this shape comes from crash
    /// logs, not from an Apple documentation page; a text of another shape yields no fields.
    private static func termination(_ reason: String) -> (namespace: String, code: String)? {
        let pattern = #/Namespace ([A-Z0-9_]{1,32}), Code (0x[0-9A-Fa-f]{1,16}|[0-9]{1,10})(?=\s|$)/#
        guard let match = reason.prefixMatch(of: pattern) else { return nil }
        return (String(match.output.1), String(match.output.2))
    }

    /// The innermost frames of the faulting thread, innermost first, as `<binary name>+<offset into the binary>`. A frame
    /// keeps its place when a part is invalid: the binary name or the offset is then `?`, so a rejected frame stays
    /// visible and no outer frame moves up. `MXCallStackTree.jsonRepresentation()` has no documented schema; the keys read here are those of the public
    /// MetricKit samples. Any other shape yields no frames. The faulting thread is the stack marked `threadAttributed`,
    /// else the first. Below each frame the path follows the child with the most samples, the first one on a tie. A
    /// crash tree is one chain, so this path is the faulting stack.
    private static func frames(in tree: Data, executableName: String?) -> [String] {
        guard let object = (try? JSONSerialization.jsonObject(with: tree)) as? [String: Any],
            let stacks = object["callStacks"] as? [[String: Any]]
        else { return [] }
        let stack = stacks.first { ($0["threadAttributed"] as? Bool) == true } ?? stacks.first
        guard var frame = heaviest(stack?["callStackRootFrames"]) else { return [] }
        var path = [frame]
        while let next = heaviest(frame["subFrames"]) {
            path.append(next)
            frame = next
        }
        return Array(path.map { render($0, executableName: executableName) }.suffix(frameLimit).reversed())
    }

    private static func heaviest(_ frames: Any?) -> [String: Any]? {
        guard let frames = frames as? [[String: Any]], var best = frames.first else { return nil }
        for frame in frames.dropFirst() where samples(frame) > samples(best) { best = frame }
        return best
    }

    private static func samples(_ frame: [String: Any]) -> Int { (frame["sampleCount"] as? Int) ?? 0 }

    private static func render(_ frame: [String: Any], executableName: String?) -> String {
        let name = (frame["binaryName"] as? String).flatMap { binaryName($0, executableName: executableName) } ?? "?"
        let offset = (frame["offsetIntoBinaryTextSegment"] as? NSNumber).flatMap(offsetText) ?? "?"
        return "\(name)+\(offset)"
    }

    /// A binary name from the payload: a token, or the app's own executable name from its bundle.
    private static func binaryName(_ value: String, executableName: String?) -> String? {
        if let executableName, !executableName.isEmpty, value == executableName { return value }
        return token(value, limit: binaryNameLimit)
    }

    /// A whole, non-negative offset that fits `UInt64`.
    private static func offsetText(_ offset: NSNumber) -> String? {
        let value = offset.doubleValue
        guard value >= 0, value < 18_446_744_073_709_551_616, value.rounded() == value else { return nil }
        return String(offset.uint64Value)
    }
}
