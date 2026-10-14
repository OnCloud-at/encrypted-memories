import Foundation
import PhotosCore

/// Code-owned names of the work that sends Proton requests. The names enter support reports and logs.
enum ProtonRequestCause: String, CaseIterable, Sendable {
    case timelineFull = "timeline.full"
    case timelineProbe = "timeline.probe"
    case timelineValidation = "timeline.validation"
    case timelineFilter = "timeline.filter"
    case reconcile
    case thumbnails
    case viewer
    case viewerMetadata = "viewer.metadata"
    case export
    case favorites
    case trashList = "trash.list"
    case trashWrite = "trash.write"
    case account
    case backup
    case duplicates
    case series
    case albums
    case librarySave = "library.save"
    case tags
    case photosRoot = "photos.root"
    /// Session-gated work that normally reads only local stores.
    case local
}

/// Method and endpoint template of one request. The template keeps only fixed path words; identifiers and the query
/// never leave the transport.
struct ProtonRequestLabel: Sendable, Equatable {
    static let storageEndpoint = "<storage>"
    static let maximumSegments = 8

    let method: String
    let endpoint: String

    static func api(method: String, path: String) -> ProtonRequestLabel {
        let pathOnly = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        let segments = pathOnly.split(separator: "/").prefix(maximumSegments).map {
            isFixedWord($0) ? String($0) : "{id}"
        }
        return ProtonRequestLabel(method: normalizedMethod(method), endpoint: "/" + segments.joined(separator: "/"))
    }

    /// Block storage URLs are pre-signed or token-addressed, so no part of them is recorded.
    static func storage(method: String) -> ProtonRequestLabel {
        ProtonRequestLabel(method: normalizedMethod(method), endpoint: storageEndpoint)
    }

    /// A fixed word is 3 to 32 lowercase letters with `_` or `-`, or a version such as `v4`. Proton identifiers are
    /// long mixed-case base64 strings, so they never match; a short segment counts as an identifier.
    static func isFixedWord(_ segment: Substring) -> Bool {
        if segment.count > 1, segment.count <= 4, segment.first == "v",
            segment.dropFirst().allSatisfy({ ("0"..."9").contains($0) })
        {
            return true
        }
        guard (3...32).contains(segment.count) else { return false }
        return segment.allSatisfy { ("a"..."z").contains($0) || $0 == "_" || $0 == "-" }
    }

    private static func normalizedMethod(_ method: String) -> String {
        let value = method.uppercased()
        return ["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE"].contains(value) ? value : "OTHER"
    }
}

enum ProtonRequestStatusClass: String, Sendable {
    case success = "2xx"
    case redirect = "3xx"
    case unauthorized = "401"
    case notFound = "404"
    case timeout = "408"
    case rateLimited = "429"
    case clientError = "4xx"
    case serverError = "5xx"
    case transport

    init(statusCode: Int?) {
        switch statusCode {
        case nil: self = .transport
        case 401: self = .unauthorized
        case 404: self = .notFound
        case 408: self = .timeout
        case 429: self = .rateLimited
        case let code? where (200...299).contains(code): self = .success
        case let code? where (300...399).contains(code): self = .redirect
        case let code? where (400...499).contains(code): self = .clientError
        case let code? where (500...599).contains(code): self = .serverError
        default: self = .transport
        }
    }
}

/// Tracks which works run right now. A native SDK callback starts its request in a new task without the caller's
/// task-local values, so its cause can only be inferred from this set.
final class ProtonRequestCauseScopes: @unchecked Sendable {
    private let lock = NSLock()
    private var active: [UUID: ProtonRequestCause] = [:]

    /// Runs `operation` under `cause`. An enclosing cause wins unless `replacing` is set, so a duplicate merge that
    /// trashes photos stays a duplicates request. Work that starts its own unstructured task replaces the cause it
    /// inherited from the scheduling caller.
    func run<T>(
        _ cause: ProtonRequestCause,
        replacing: Bool = false,
        isolation: isolated (any Actor)? = #isolation,
        operation: () async throws -> T
    ) async rethrows -> T {
        let effective = replacing ? cause : (ProtonRequestContext.cause ?? cause)
        let id = UUID()
        lock.withLock { active[id] = effective }
        defer { _ = lock.withLock { active.removeValue(forKey: id) } }
        return try await ProtonRequestContext.$cause.withValue(effective) {
            try await operation()
        }
    }

    /// The exact task-local cause, or the inferred active causes marked with `~`.
    func resolve(taskCause: ProtonRequestCause?) -> String {
        if let taskCause { return taskCause.rawValue }
        let names = Set(lock.withLock { active.values }.map(\.rawValue)).sorted()
        guard !names.isEmpty else { return "unattributed" }
        let shown = names.prefix(3).joined(separator: "+")
        return "~" + shown + (names.count > 3 ? "+more" : "")
    }
}

/// Per-session request counts kept by the governor. Counts only: the keys hold code-owned names and endpoint templates.
struct ProtonRequestTally: Sendable {
    struct Key: Hashable, Sendable {
        let scope: ProtonRequestScope
        let method: String
        let endpoint: String
        let cause: String
        let status: ProtonRequestStatusClass
    }

    struct ScopeTotals: Sendable {
        var peakInFlight = 0
        var maximumRetryAfter: TimeInterval?
        var cooldownSeconds: TimeInterval = 0
    }

    static let maximumKeys = 512
    static let summaryInterval: TimeInterval = 60

    private(set) var counts: [Key: Int] = [:]
    private(set) var overflowRequests = 0
    private(set) var scopes: [ProtonRequestScope: ScopeTotals] = [:]
    private var summaryStart: Date?
    private var summaryCauses: [String: Int] = [:]
    private var summaryStatuses: [ProtonRequestStatusClass: Int] = [:]

    mutating func record(_ key: Key, at timestamp: Date) -> [String: String]? {
        if counts[key] != nil || counts.count < Self.maximumKeys {
            counts[key, default: 0] += 1
        } else {
            overflowRequests += 1
        }
        let summary = dueSummary(at: timestamp)
        if summaryStart == nil { summaryStart = timestamp }
        summaryCauses[key.cause, default: 0] += 1
        summaryStatuses[key.status, default: 0] += 1
        return summary
    }

    mutating func recordInFlight(_ inFlight: Int, scope: ProtonRequestScope) {
        scopes[scope, default: ScopeTotals()].peakInFlight = max(scopes[scope]?.peakInFlight ?? 0, inFlight)
    }

    mutating func recordRateLimit(
        scope: ProtonRequestScope, retryAfter: TimeInterval?, cooldownFrom start: Date, until end: Date
    ) {
        var totals = scopes[scope] ?? ScopeTotals()
        if let retryAfter { totals.maximumRetryAfter = max(totals.maximumRetryAfter ?? 0, retryAfter) }
        totals.cooldownSeconds += max(0, end.timeIntervalSince(start))
        scopes[scope] = totals
    }

    /// One line per minute with requests: the requests of the previous minute by cause and status class.
    private mutating func dueSummary(at timestamp: Date) -> [String: String]? {
        guard let start = summaryStart, timestamp.timeIntervalSince(start) >= Self.summaryInterval else { return nil }
        let total = summaryCauses.values.reduce(0, +)
        var fields = ["requests": "\(total)"]
        fields["causes"] = summaryCauses.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }
            .joined(separator: ",")
        fields["statuses"] = summaryStatuses.sorted { $0.key.rawValue < $1.key.rawValue }
            .map { "\($0.key.rawValue):\($0.value)" }.joined(separator: ",")
        summaryStart = nil
        summaryCauses.removeAll()
        summaryStatuses.removeAll()
        return fields
    }
}

extension ProtonRequestScope {
    var supportName: String {
        switch self {
        case .api: "api"
        case .storageDownload: "storageDownload"
        case .storageUpload: "storageUpload"
        }
    }
}
