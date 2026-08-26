import Foundation
import ProtonDriveSDK

/// `HttpClientProtocol` implementation backed by `URLSession`. The SDK builds Drive API and
/// storage requests; we add the session auth headers and perform the I/O, refreshing on 401.
final class SDKHttpClient: HttpClientProtocol, @unchecked Sendable {
    private let driveSession: DriveSession
    private let urlSession: URLSession
    private let requestGovernor: ProtonRequestGovernor

    init(driveSession: DriveSession, requestGovernor: ProtonRequestGovernor) {
        self.driveSession = driveSession
        self.requestGovernor = requestGovernor
        let cfg = URLSessionConfiguration.default
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.urlSession = URLSession(configuration: cfg)
    }

    // MARK: Drive API (relative path)

    func requestDriveApi(
        method: String,
        relativePath: String,
        content: Data,
        headers: [(String, [String])]
    ) async -> Result<HttpClientResponse, NSError> {
        let url = Self.driveURL(relativePath, makeURL: driveSession.makeURL)
        guard Self.isTrustedDriveAPIURL(url, baseURL: driveSession.config.baseURL) else {
            return .failure(Self.invalidURL("Refusing Drive API request outside trusted Proton API host"))
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        applyAuthAndHeaders(&req, headers: headers)
        if !content.isEmpty { req.httpBody = content }
        Self.applyDriveJSONHeaders(&req, hasContent: !content.isEmpty)

        let result = await perform(
            req,
            scope: .api,
            retryOn401: true,
            retryOn429: Self.canRetryAfterRateLimit(method: method)
        )
        switch result {
        case .success(let resp) where resp.statusCode >= 400:
            DebugLog.log("driveApi \(method) \(url.absoluteString) -> \(resp.statusCode)")
        case .failure(let err):
            DebugLog.log("driveApi \(method) \(url.absoluteString) -> ERR \(err.code)")
        default:
            break
        }
        return result
    }

    // MARK: Storage upload (absolute url, streamed)

    /// Streams an encrypted block to block storage. The SDK hands us a bound stream pair via
    /// `StreamForUpload`: it writes encrypted bytes into the pair's output (pumped on the main run
    /// loop by `openOutputStream()`), and `URLSession` reads them from the pair's input as the request
    /// body. Storage URLs carry their own `pm-storage-token` in `headers`, so we add no session auth.
    func requestUploadToStorage(
        method: String,
        url: String,
        content: StreamForUpload,
        headers: [(String, [String])]
    ) async -> Result<HttpClientResponse, NSError> {
        guard let requestURL = Self.httpsURL(url) else {
            return .failure(Self.invalidURL("Invalid storage upload URL"))
        }
        var req = URLRequest(url: requestURL)
        req.httpMethod = method
        applyHeaders(&req, headers: headers)  // storage URLs are token-authed; no session headers
        req.httpBodyStream = content.input

        let streamError = ErrorBox()
        content.onStreamError = { streamError.set($0) }
        let permit: ProtonRequestGovernor.Permit
        do {
            permit = try await requestGovernor.acquire(scope: .storageUpload)
        } catch {
            return .failure(error as NSError)
        }
        // Do not start producing encrypted bytes until block storage admits this request.
        await MainActor.run { content.openOutputStream() }

        do {
            let (data, response) = try await urlSession.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                await requestGovernor.finish(permit, statusCode: nil)
                return .failure(NSError(domain: "EncryptedMemories.SDKHttpClient", code: -6))
            }
            await requestGovernor.finish(
                permit,
                statusCode: http.statusCode,
                retryAfter: ProtonRetryAfter.seconds(from: http)
            )
            if http.statusCode >= 400 {
                DebugLog.log("uploadStorage \(method) -> \(http.statusCode)")
            }
            return .success(
                HttpClientResponse(
                    data: data, headers: Self.headerPairs(http), statusCode: http.statusCode
                ))
        } catch {
            await requestGovernor.finish(permit, statusCode: nil)
            // Prefer a stream-side error (encryption/producer) over the generic transport error.
            return .failure((streamError.value ?? error) as NSError)
        }
    }

    // MARK: Storage download (absolute url, streamed)

    func requestDownloadFromStorage(
        method: String,
        url: String,
        content: Data,
        headers: [(String, [String])],
        downloadStreamCreator: @Sendable @escaping (URLSession.AsyncBytes) -> AnyAsyncSequence<UInt8>
    ) async -> Result<HttpClientStream, NSError> {
        guard let requestURL = Self.httpsURL(url) else {
            return .failure(Self.invalidURL("Invalid storage URL"))
        }
        var req = URLRequest(url: requestURL)
        req.httpMethod = method
        applyHeaders(&req, headers: headers)  // storage URLs are pre-signed; no auth headers
        if !content.isEmpty { req.httpBody = content }

        let permit: ProtonRequestGovernor.Permit
        do {
            permit = try await requestGovernor.acquire(scope: .storageDownload)
        } catch {
            return .failure(error as NSError)
        }
        let completion = StreamPermitCompletion(governor: requestGovernor, permit: permit)
        do {
            let (bytes, response) = try await urlSession.bytes(for: req)
            guard let http = response as? HTTPURLResponse else {
                completion.finish(statusCode: nil)
                return .failure(NSError(domain: "EncryptedMemories.SDKHttpClient", code: -4))
            }
            let retryAfter = ProtonRetryAfter.seconds(from: http)
            completion.recordResponse(statusCode: http.statusCode, retryAfter: retryAfter)
            let stream = PermitFinishingAsyncSequence(
                source: downloadStreamCreator(bytes),
                completion: completion,
                responseStatusCode: http.statusCode,
                retryAfter: retryAfter
            )
            return .success(
                HttpClientStream(
                    source: .stream(AnyAsyncSequence(stream)),
                    headers: Self.headerPairs(http),
                    statusCode: http.statusCode
                ))
        } catch {
            completion.finish(statusCode: nil)
            return .failure(error as NSError)
        }
    }

    // MARK: - Helpers

    private func perform(
        _ request: URLRequest,
        scope: ProtonRequestScope,
        retryOn401: Bool,
        retryOn429: Bool
    ) async -> Result<HttpClientResponse, NSError> {
        let permit: ProtonRequestGovernor.Permit
        do {
            permit = try await requestGovernor.acquire(scope: scope)
        } catch {
            return .failure(error as NSError)
        }
        do {
            let (data, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                await requestGovernor.finish(permit, statusCode: nil)
                return .failure(NSError(domain: "EncryptedMemories.SDKHttpClient", code: -1))
            }
            await requestGovernor.finish(
                permit,
                statusCode: http.statusCode,
                retryAfter: ProtonRetryAfter.seconds(from: http)
            )
            if http.statusCode == 429 {
                if retryOn429 {
                    return await perform(
                        request,
                        scope: scope,
                        retryOn401: retryOn401,
                        retryOn429: false
                    )
                }
            }
            if http.statusCode == 401, retryOn401, await driveSession.refreshToken() {
                var retry = request
                for (k, v) in driveSession.authHeaders() { retry.setValue(v, forHTTPHeaderField: k) }
                return await perform(
                    retry,
                    scope: scope,
                    retryOn401: false,
                    retryOn429: retryOn429
                )
            }
            return .success(
                HttpClientResponse(
                    data: data, headers: Self.headerPairs(http), statusCode: http.statusCode
                ))
        } catch {
            await requestGovernor.finish(permit, statusCode: nil)
            return .failure(error as NSError)
        }
    }

    private static func canRetryAfterRateLimit(method: String) -> Bool {
        switch method.uppercased() {
        case "GET", "HEAD": true
        default: false
        }
    }

    static func applyDriveJSONHeaders(_ request: inout URLRequest, hasContent: Bool) {
        if request.value(forHTTPHeaderField: "Accept") == nil {
            request.setValue("application/vnd.protonmail.v1+json", forHTTPHeaderField: "Accept")
        }
        if hasContent, request.value(forHTTPHeaderField: "Content-Type") == nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
    }

    private func applyAuthAndHeaders(_ req: inout URLRequest, headers: [(String, [String])]) {
        for (k, v) in driveSession.authHeaders() { req.setValue(v, forHTTPHeaderField: k) }
        applyHeaders(&req, headers: headers)
    }

    private func applyHeaders(_ req: inout URLRequest, headers: [(String, [String])]) {
        for (name, values) in headers {
            req.setValue(values.joined(separator: ", "), forHTTPHeaderField: name)
        }
    }

    /// The SDK hands us a Drive-API `relativePath` of the form `"<servicePrefix>/<absolute URL>"`,
    /// e.g. `"drive/https://drive-api.proton.me/v2/shares/photos"`. The real endpoint inserts the
    /// service prefix into the host path: `https://drive-api.proton.me/drive/v2/shares/photos`.
    /// We reconstruct that; clean relative paths fall back to `makeURL`.
    static func driveURL(_ relativePath: String, makeURL: (String) -> URL) -> URL {
        guard let schemeRange = relativePath.range(of: "https://") ?? relativePath.range(of: "http://"),
            let embedded = URL(string: String(relativePath[schemeRange.lowerBound...])),
            let scheme = embedded.scheme, let host = embedded.host
        else {
            return makeURL(relativePath)
        }
        let prefix = relativePath[relativePath.startIndex..<schemeRange.lowerBound]
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var combined = "\(scheme)://\(host)"
        if !prefix.isEmpty { combined += "/\(prefix)" }
        combined += embedded.path.hasPrefix("/") ? embedded.path : "/\(embedded.path)"
        if let query = embedded.query, !query.isEmpty { combined += "?\(query)" }
        return URL(string: combined) ?? makeURL(relativePath)
    }

    private static func isTrustedDriveAPIURL(_ url: URL, baseURL: URL) -> Bool {
        guard url.scheme == "https",
            let host = url.host?.lowercased(),
            let expected = baseURL.host?.lowercased()
        else { return false }
        return host == expected
    }

    private static func httpsURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw), url.scheme == "https", url.host != nil else { return nil }
        return url
    }

    private static func invalidURL(_ reason: String) -> NSError {
        NSError(
            domain: "EncryptedMemories.SDKHttpClient",
            code: -7,
            userInfo: [NSLocalizedDescriptionKey: reason]
        )
    }

    private static func headerPairs(_ http: HTTPURLResponse) -> [(String, [String])] {
        http.allHeaderFields.compactMap { key, value in
            guard let k = key as? String else { return nil }
            return (k, ["\(value)"])
        }
    }
}

/// Thread-safe one-shot holder for a stream-side upload error.
private final class ErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Error?
    func set(_ error: Error) { lock.withLock { if _value == nil { _value = error } } }
    var value: Error? { lock.withLock { _value } }
}

struct PermitFinishingAsyncSequence: AsyncSequence {
    typealias Element = UInt8

    struct Iterator: AsyncIteratorProtocol {
        var source: AnyAsyncIterator<UInt8>
        let completion: StreamPermitCompletion
        let responseStatusCode: Int
        let retryAfter: TimeInterval?

        mutating func next() async throws -> UInt8? {
            do {
                let value = try await source.next()
                if value == nil {
                    completion.finish(statusCode: responseStatusCode, retryAfter: retryAfter)
                }
                return value
            } catch {
                completion.finish(statusCode: nil)
                throw error
            }
        }
    }

    let source: AnyAsyncSequence<UInt8>
    let completion: StreamPermitCompletion
    let responseStatusCode: Int
    let retryAfter: TimeInterval?

    func makeAsyncIterator() -> Iterator {
        Iterator(
            source: source.makeAsyncIterator(),
            completion: completion,
            responseStatusCode: responseStatusCode,
            retryAfter: retryAfter
        )
    }
}

final class StreamPermitCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    private var fallbackStatusCode: Int?
    private var fallbackRetryAfter: TimeInterval?
    private let governor: ProtonRequestGovernor
    private let permit: ProtonRequestGovernor.Permit

    init(governor: ProtonRequestGovernor, permit: ProtonRequestGovernor.Permit) {
        self.governor = governor
        self.permit = permit
    }

    func recordResponse(statusCode: Int, retryAfter: TimeInterval?) {
        lock.withLock {
            guard !completed else { return }
            fallbackStatusCode = statusCode
            fallbackRetryAfter = retryAfter
        }
    }

    func finish(statusCode: Int?, retryAfter: TimeInterval? = nil) {
        let shouldFinish = lock.withLock {
            guard !completed else { return false }
            completed = true
            return true
        }
        guard shouldFinish else { return }
        Task { await governor.finish(permit, statusCode: statusCode, retryAfter: retryAfter) }
    }

    deinit {
        // Do not call `finish` here: its unstructured task would implicitly retain `self` while
        // Swift is already destroying the instance, which aborts at runtime with a non-zero retain
        // count. Capture only the immutable payload needed by the governor fallback.
        let fallback: (ProtonRequestGovernor, ProtonRequestGovernor.Permit, Int?, TimeInterval?)? = lock.withLock {
            guard !completed else { return nil }
            completed = true
            return (governor, permit, fallbackStatusCode, fallbackRetryAfter)
        }
        guard let (governor, permit, statusCode, retryAfter) = fallback else { return }
        Task { await governor.finish(permit, statusCode: statusCode, retryAfter: retryAfter) }
    }
}
