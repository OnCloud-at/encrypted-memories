import AppleSecurityCore
import Foundation
import ProtonAuth
import Testing

@testable import ProtonDriveBackend

/// A 401 for credentials that another request already replaced retries with the new credentials and
/// sends no refresh. Only the waiter of the current refresh flight can retire it (#535).
@Suite("Drive session token refresh", .serialized)
struct DriveSessionRefreshTests {
    private struct Answer: Decodable {
        let code: Int
        enum CodingKeys: String, CodingKey { case code = "Code" }
    }

    /// The request with the old token gets its 401 only after another request refreshed the token.
    @Test func aLate401AfterARefreshRetriesWithTheNewTokenWithoutRefreshing() async throws {
        RefreshServerProtocol.reset(heldPath: "/tests/held")
        let session = makeSession()

        let held = Task { try await session.getJSON("/tests/held", as: Answer.self) }
        try await RefreshServerProtocol.waitForHeldRequest()
        let other = try await session.getJSON("/tests/other", as: Answer.self)
        #expect(other.code == 1000)
        #expect(RefreshServerProtocol.refreshCount == 1)

        RefreshServerProtocol.releaseHeldRequest()
        let late = try await held.value

        #expect(late.code == 1000)
        #expect(RefreshServerProtocol.refreshCount == 1, "the late 401 must not send a second refresh")
        #expect(
            RefreshServerProtocol.authorizations(for: "/tests/held") == ["Bearer test-access", "Bearer access-1"])
    }

    @Test func theSDKClientRetriesALate401WithTheNewTokenWithoutRefreshing() async throws {
        RefreshServerProtocol.reset(heldPath: "/drive/tests/held")
        let session = makeSession()
        let client = SDKHttpClient(
            driveSession: session, requestGovernor: session.requestGovernor,
            urlProtocolClasses: [RefreshServerProtocol.self])

        let held = Task {
            await client.requestDriveApi(method: "GET", relativePath: "/drive/tests/held", content: Data(), headers: [])
        }
        try await RefreshServerProtocol.waitForHeldRequest()
        let other = try await client.requestDriveApi(
            method: "GET", relativePath: "/drive/tests/other", content: Data(), headers: []
        ).get()
        #expect(other.statusCode == 200)
        #expect(RefreshServerProtocol.refreshCount == 1)

        RefreshServerProtocol.releaseHeldRequest()
        let late = try await held.value.get()

        #expect(late.statusCode == 200)
        #expect(RefreshServerProtocol.refreshCount == 1, "the late 401 must not send a second refresh")
        #expect(
            RefreshServerProtocol.authorizations(for: "/drive/tests/held")
                == ["Bearer test-access", "Bearer access-1"])
    }

    @Test func aFailedRefreshReturnsThe401AndTheNextRequestRefreshesAgain() async throws {
        RefreshServerProtocol.reset(heldPath: nil, refreshFails: true)
        let session = makeSession()

        await #expect(throws: ProtonAuthError.self) { try await session.getJSON("/tests/first", as: Answer.self) }
        await #expect(throws: ProtonAuthError.self) { try await session.getJSON("/tests/second", as: Answer.self) }

        #expect(RefreshServerProtocol.refreshCount == 2, "a failed refresh changes no credentials")
        #expect(RefreshServerProtocol.authorizations(for: "/tests/first") == ["Bearer test-access"])
    }

    /// A late waiter of an earlier flight must not retire the flight that runs now.
    @Test func aLateWaiterOfAnEarlierFlightKeepsTheCurrentFlight() {
        var flights = RefreshFlight()
        let first = flights.join { Task { true } }
        flights.retire(first.id)
        let second = flights.join { Task { true } }

        flights.retire(first.id)

        #expect(flights.id == second.id)
        let third = flights.join { Task { false } }
        #expect(third.id == second.id, "a new caller joins the current flight")
    }

    @Test func theWaiterOfTheCurrentFlightRetiresIt() {
        var flights = RefreshFlight()
        let flight = flights.join { Task { true } }

        flights.retire(flight.id)

        #expect(flights.id == nil)
        #expect(flights.join { Task { true } }.id != flight.id)
    }

    private func makeSession() -> DriveSession {
        DriveSession(
            session: ProtonSession(
                uid: "test-uid", accessToken: "test-access", refreshToken: "test-refresh", keyPassword: "test-key"),
            store: SessionKeychainStore(
                service: "at.oncloud.encryptedmemories.tests.refresh-\(UUID().uuidString)",
                account: "default",
                keychain: RefreshTestKeychainStore()
            ),
            accountCacheDirectory: FileManager.default.temporaryDirectory,
            urlProtocolClasses: [RefreshServerProtocol.self]
        )
    }
}

/// A server whose first token has expired. Every refresh issues the next token `access-<n>`; an API request
/// succeeds only with the newest token. One request path can be held until the test releases it.
private final class RefreshServerProtocol: URLProtocol {
    static let refreshPath = "/auth/v4/refresh"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var issued = 0
    nonisolated(unsafe) private static var refreshFails = false
    nonisolated(unsafe) private static var heldPath: String?
    nonisolated(unsafe) private static var held: RefreshServerProtocol?
    nonisolated(unsafe) private static var recorded: [(path: String, authorization: String?)] = []
    private static let release = DispatchSemaphore(value: 0)

    static var refreshCount: Int { lock.withLock { recorded.filter { $0.path == refreshPath }.count } }

    static func authorizations(for path: String) -> [String?] {
        lock.withLock { recorded.filter { $0.path == path }.map(\.authorization) }
    }

    static func reset(heldPath: String?, refreshFails: Bool = false) {
        lock.withLock {
            issued = 0
            self.refreshFails = refreshFails
            self.heldPath = heldPath
            held = nil
            recorded = []
        }
    }

    static func waitForHeldRequest() async throws {
        for _ in 0..<500 {
            if lock.withLock({ held != nil }) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("the held request never reached the server")
    }

    static func releaseHeldRequest() { release.signal() }

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url!.path
        let authorization = request.value(forHTTPHeaderField: "Authorization")
        let hold: Bool = Self.lock.withLock {
            guard path == Self.heldPath, Self.held == nil else { return false }
            Self.held = self
            return true
        }
        guard hold else { return answer(path: path, authorization: authorization) }
        // Answer from another queue once the test releases it; the token check runs at answer time.
        DispatchQueue.global().async {
            Self.release.wait()
            self.answer(path: path, authorization: authorization)
        }
    }

    private func answer(path: String, authorization: String?) {
        let (status, body): (Int, String) = Self.lock.withLock {
            Self.recorded.append((path, authorization))
            if path == Self.refreshPath {
                if Self.refreshFails { return (401, "{}") }
                Self.issued += 1
                return (200, #"{"AccessToken":"access-\#(Self.issued)","RefreshToken":"refresh-\#(Self.issued)"}"#)
            }
            let newest = Self.issued > 0 ? "Bearer access-\(Self.issued)" : nil
            return authorization != nil && authorization == newest ? (200, #"{"Code":1000}"#) : (401, "{}")
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class RefreshTestKeychainStore: AppleKeychainStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [AppleKeychainItem: Data] = [:]

    func data(for item: AppleKeychainItem) throws -> Data? { lock.withLock { storage[item] } }

    func setData(_ data: Data, for item: AppleKeychainItem) throws { lock.withLock { storage[item] = data } }

    func dataOrInsert(_ data: Data, for item: AppleKeychainItem) throws -> Data {
        lock.withLock {
            if let existing = storage[item] { return existing }
            storage[item] = data
            return data
        }
    }

    func removeData(for item: AppleKeychainItem) throws { lock.withLock { _ = storage.removeValue(forKey: item) } }

    func removeAllData(service: String) throws {
        lock.withLock { storage = storage.filter { $0.key.service != service } }
    }
}
