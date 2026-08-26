import Foundation

public protocol ProtonSessionStorage: Sendable {
    func load() throws -> ProtonSession?
    func save(_ session: ProtonSession) throws
    func clear() throws
}

extension SessionKeychainStore: ProtonSessionStorage {}

public protocol ProtonAuthenticating: Sendable {
    func authenticate(
        openURL: @escaping @Sendable (URL) -> Void,
        onProgress: @escaping @Sendable (ProtonForkAuthenticator.Progress) -> Void
    ) async throws -> ProtonSession
}

extension ProtonForkAuthenticator: ProtonAuthenticating {}

public enum ProtonAuthState: Equatable, Sendable {
    case checking
    case signedOut(error: String?)
    case authenticating(ProtonForkAuthenticator.Progress)
    case signedIn(ProtonSession)

    public var session: ProtonSession? {
        guard case .signedIn(let session) = self else { return nil }
        return session
    }
}

/// Platform-neutral session lifecycle around Proton's fork-auth flow.
///
/// UI targets provide only the platform browser opener and presentation strings. Token/key-password
/// persistence, fork progress, cancellation, and state transitions stay shared across macOS, iOS, and iPadOS.
@MainActor
public final class ProtonAuthController {
    public private(set) var state: ProtonAuthState = .checking

    private let store: any ProtonSessionStorage
    private let authenticator: any ProtonAuthenticating
    private let signInTimeout: Duration
    private var signInTask: Task<Void, Never>?
    private var signInTimeoutTask: Task<Void, Never>?
    private var signInAttemptID: UUID?

    public init(
        store: any ProtonSessionStorage = SessionKeychainStore(),
        authenticator: any ProtonAuthenticating,
        signInTimeout: Duration = .seconds(300)
    ) {
        self.store = store
        self.authenticator = authenticator
        self.signInTimeout = signInTimeout
    }

    public var currentSession: ProtonSession? {
        state.session
    }

    @discardableResult
    public func bootstrap() -> ProtonAuthState {
        do {
            if let session = try store.load() {
                return setState(.signedIn(session))
            }
            return setState(.signedOut(error: nil))
        } catch {
            return setState(.signedOut(error: Self.message(for: error)))
        }
    }

    public func signIn(
        openURL: @escaping @Sendable (URL) -> Void,
        onStateChange: @escaping @MainActor (ProtonAuthState) -> Void = { _ in }
    ) {
        signInTask?.cancel()
        signInTimeoutTask?.cancel()
        let attemptID = UUID()
        signInAttemptID = attemptID
        setState(.authenticating(.requestingLink), notify: onStateChange)
        signInTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let session = try await authenticator.authenticate(
                    openURL: openURL,
                    onProgress: { progress in
                        Task { @MainActor [weak self] in
                            guard self?.signInAttemptID == attemptID else { return }
                            self?.setState(.authenticating(progress), notify: onStateChange)
                        }
                    }
                )
                try Task.checkCancellation()
                guard signInAttemptID == attemptID else { return }
                try store.save(session)
                finishSignInAttempt(attemptID)
                setState(.signedIn(session), notify: onStateChange)
            } catch is CancellationError {
                guard signInAttemptID == attemptID else { return }
                finishSignInAttempt(attemptID)
                setState(.signedOut(error: nil), notify: onStateChange)
            } catch {
                guard signInAttemptID == attemptID else { return }
                finishSignInAttempt(attemptID)
                setState(.signedOut(error: Self.message(for: error)), notify: onStateChange)
            }
        }
        let timeout = signInTimeout
        signInTimeoutTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            guard let self, self.signInAttemptID == attemptID else { return }
            self.signInTask?.cancel()
            self.signInTask = nil
            self.signInTimeoutTask = nil
            self.signInAttemptID = nil
            self.setState(
                .signedOut(error: Self.message(for: ProtonAuthError.timedOut)),
                notify: onStateChange
            )
        }
    }

    @discardableResult
    public func cancelSignIn() -> ProtonAuthState {
        signInTask?.cancel()
        signInTimeoutTask?.cancel()
        signInTask = nil
        signInTimeoutTask = nil
        signInAttemptID = nil
        return setState(.signedOut(error: nil))
    }

    @discardableResult
    public func signOut() -> ProtonAuthState {
        signInTask?.cancel()
        signInTimeoutTask?.cancel()
        signInTask = nil
        signInTimeoutTask = nil
        signInAttemptID = nil
        do {
            try store.clear()
            return setState(.signedOut(error: nil))
        } catch {
            return setState(.signedOut(error: Self.message(for: error)))
        }
    }

    @discardableResult
    private func setState(
        _ newState: ProtonAuthState,
        notify: (@MainActor (ProtonAuthState) -> Void)? = nil
    ) -> ProtonAuthState {
        state = newState
        notify?(newState)
        return newState
    }

    private func finishSignInAttempt(_ attemptID: UUID) {
        guard signInAttemptID == attemptID else { return }
        signInTimeoutTask?.cancel()
        signInTask = nil
        signInTimeoutTask = nil
        signInAttemptID = nil
    }

    private static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
