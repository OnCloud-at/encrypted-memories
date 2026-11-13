import Foundation

/// Request counts for a support report. They last since the latest construction of the backend (sign-in, launch or
/// a rebuild); a rebuild starts them again.
/// The report holds only route shapes, causes, status classes and counts. The route shape is a heuristic: a path word
/// is kept when it looks like a route word (3 to 32 lowercase letters, underscores or hyphens), so a token of that
/// shape inside a path segment would be kept.
/// It also holds the newest 32 rate-limit answers as closed fields: scope, cause and numbers.
public struct RemoteRequestSupportSnapshot: Codable, Sendable, Equatable {
    /// One completed transport attempt. Admission is the start; response/error completion is the end.
    /// Offsets use the process-wide monotonic clock, including time while the system sleeps.
    public struct Request: Codable, Sendable, Equatable {
        public let scope: String
        public let method: String
        public let endpoint: String
        public let cause: String
        public let status: String
        public let startMilliseconds: Int64
        public let endMilliseconds: Int64

        public init(
            scope: String, method: String, endpoint: String, cause: String, status: String,
            startMilliseconds: Int64, endMilliseconds: Int64
        ) {
            self.scope = scope
            self.method = method
            self.endpoint = endpoint
            self.cause = cause
            self.status = status
            self.startMilliseconds = startMilliseconds
            self.endMilliseconds = endMilliseconds
        }
    }

    public struct Count: Codable, Sendable, Equatable {
        public let scope: String
        public let method: String
        /// Path with every identifier segment replaced by `{id}` and without the query.
        public let endpoint: String
        /// The work that sent the request. A leading `~` marks a cause inferred from the work that was active when a
        /// native SDK callback sent the request; `a+b` names several such works.
        public let cause: String
        /// `2xx`, `3xx`, `401`, `404`, `408`, `429`, `4xx`, `5xx`, `transport` (no HTTP answer) or `cancelled` (the
        /// caller stopped waiting, for example for a thumbnail that scrolled away).
        public let status: String
        public let count: Int

        public init(scope: String, method: String, endpoint: String, cause: String, status: String, count: Int) {
            self.scope = scope
            self.method = method
            self.endpoint = endpoint
            self.cause = cause
            self.status = status
            self.count = count
        }
    }

    public struct Scope: Codable, Sendable, Equatable {
        public let scope: String
        public let inFlight: Int
        public let queued: Int
        public let concurrencyLimit: Int
        public let admissionIntervalMilliseconds: Int
        public let admittedLastMinute: Int
        public let rateLimitedLastMinute: Int
        public let peakInFlight: Int
        /// The largest Retry-After a response asked for, before the governor's own bounds.
        public let maximumRetryAfterSeconds: Double?
        /// Time that rate-limit cooldowns closed admission, without double-counting overlapping cooldowns.
        public let totalCooldownSeconds: Double

        public init(
            scope: String, inFlight: Int, queued: Int, concurrencyLimit: Int, admissionIntervalMilliseconds: Int,
            admittedLastMinute: Int, rateLimitedLastMinute: Int, peakInFlight: Int,
            maximumRetryAfterSeconds: Double?, totalCooldownSeconds: Double
        ) {
            self.scope = scope
            self.inFlight = inFlight
            self.queued = queued
            self.concurrencyLimit = concurrencyLimit
            self.admissionIntervalMilliseconds = admissionIntervalMilliseconds
            self.admittedLastMinute = admittedLastMinute
            self.rateLimitedLastMinute = rateLimitedLastMinute
            self.peakInFlight = peakInFlight
            self.maximumRetryAfterSeconds = maximumRetryAfterSeconds
            self.totalCooldownSeconds = totalCooldownSeconds
        }
    }

    /// One 429 answer and the state the governor set because of it. The values are the numbers that decide a request
    /// cap: how fast the scope ran before the answer, and how far the governor slowed down after it.
    public struct RateLimitEvent: Codable, Sendable, Equatable {
        public let scope: String
        /// Offset on the same monotonic clock as `Request`.
        public let offsetMilliseconds: Int64
        public let cause: String
        /// The Retry-After the response asked for; nil when it sent none or an unusable value.
        public let retryAfterSeconds: Double?
        /// The wait the governor applied before it admitted the next request of the scope.
        public let cooldownSeconds: Double
        /// The concurrency limit and admission interval after the answer.
        public let concurrencyLimit: Int
        public let admissionIntervalMilliseconds: Int
        /// The successful requests per second of the scope before the answer: the larger of the last second and the
        /// mean of the last minute.
        public let observedRequestsPerSecond: Double
        public let successesLastMinute: Int

        public init(
            scope: String, offsetMilliseconds: Int64, cause: String, retryAfterSeconds: Double?,
            cooldownSeconds: Double, concurrencyLimit: Int, admissionIntervalMilliseconds: Int,
            observedRequestsPerSecond: Double, successesLastMinute: Int
        ) {
            self.scope = scope
            self.offsetMilliseconds = offsetMilliseconds
            self.cause = cause
            self.retryAfterSeconds = retryAfterSeconds
            self.cooldownSeconds = cooldownSeconds
            self.concurrencyLimit = concurrencyLimit
            self.admissionIntervalMilliseconds = admissionIntervalMilliseconds
            self.observedRequestsPerSecond = observedRequestsPerSecond
            self.successesLastMinute = successesLastMinute
        }
    }

    public let counts: [Count]
    /// Requests that arrived after the bounded key table was full; they are counted here only.
    public let overflowRequests: Int
    public let scopes: [Scope]
    /// Newest 8,192 completed attempts, in completion order. In-flight attempts are not zero-duration records.
    public let recentRequests: [Request]
    public let droppedRequestRecords: Int
    public let traceCapturedAtMilliseconds: Int64
    /// The newest 32 rate-limit answers, oldest first.
    public let rateLimitEvents: [RateLimitEvent]

    public init(
        counts: [Count], overflowRequests: Int, scopes: [Scope], recentRequests: [Request] = [],
        droppedRequestRecords: Int = 0, traceCapturedAtMilliseconds: Int64 = 0,
        rateLimitEvents: [RateLimitEvent] = []
    ) {
        self.counts = counts
        self.overflowRequests = overflowRequests
        self.scopes = scopes
        self.recentRequests = recentRequests
        self.droppedRequestRecords = droppedRequestRecords
        self.traceCapturedAtMilliseconds = traceCapturedAtMilliseconds
        self.rateLimitEvents = rateLimitEvents
    }
}

/// The apps initialize this clock at the beginning of App.init, before account composition.
/// Its origin survives account rebuilds. It represents launch instrumentation, not kernel process creation.
public enum RequestTraceClock {
    private static let origin = ContinuousClock.now

    public static func start() { _ = origin }

    public static var milliseconds: Int64 {
        let elapsed = origin.duration(to: .now).components
        return elapsed.seconds * 1_000 + elapsed.attoseconds / 1_000_000_000_000_000
    }
}

public protocol RemoteRequestSupportSource: AnyObject, Sendable {
    func remoteRequestSupportSnapshot() async -> RemoteRequestSupportSnapshot
}
