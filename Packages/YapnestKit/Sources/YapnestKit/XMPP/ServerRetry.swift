import Foundation

/// Runs a server request again while it fails in a way that can pass by
/// itself, and hands back the error that is final or that outlasted the
/// attempts. The caller shows that one; nothing here hides an error.
enum ServerRetry {
    /// How many times a request is made in all.
    static let attempts = 3
    /// The wait before the first retry; each one after waits twice as long.
    static let backoff: TimeInterval = 3

    /// Whether `error` may be gone on its own: a timeout, a dropped
    /// connection, a `wait` error. Anything that isn't from the server or
    /// the connection is final.
    static func isPassing(_ error: Error) -> Bool {
        ServerError.classify(error).isPassing
    }

    /// Whether the server answered with a refusal that says it did nothing: an
    /// error of type `wait`, other than a timeout. A timeout (Martin's
    /// `remote-server-timeout`, a `TimeoutError`) or a dropped connection says
    /// nothing about whether the request was applied, so these are not.
    static func isRefusal(_ error: Error) -> Bool {
        guard let answer = ServerError(error), answer.type == .wait else { return false }
        return answer.condition != "remote-server-timeout"
    }

    /// With `onlyRefusals`, only a refusal is retried (see `isRefusal`): for a
    /// request that isn't safe to repeat, as the first attempt may have been
    /// applied without our hearing of it.
    ///
    /// `isStillWanted` is asked before each retry, and ends the run when it
    /// is false (the connection dropped, or a new session began and redoes
    /// its own work); the error that was last seen is thrown then. A
    /// cancelled task ends it too.
    ///
    /// `failure` is a first attempt that already failed, for a caller that
    /// made it through a callback: it counts as an attempt, and the run begins
    /// with the wait before the next.
    static func run<T>(
        attempts: Int = ServerRetry.attempts, backoff: TimeInterval = ServerRetry.backoff,
        onlyRefusals: Bool = false, afterFailure failure: Error? = nil,
        isStillWanted: () -> Bool, operation: () async throws -> T,
    ) async throws -> T {
        var attempt = 1
        var failure = failure
        while true {
            do {
                if let earlier = failure {
                    failure = nil
                    throw earlier
                }
                return try await operation()
            } catch {
                guard attempt < attempts, (onlyRefusals ? isRefusal(error) : isPassing(error)), !(error is CancellationError) else { throw error }
                let delay = backoff * Double(1 << (attempt - 1))
                if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
                guard isStillWanted() else { throw error }
                attempt += 1
            }
        }
    }
}

extension XMPPSession {
    /// Makes a request, and again after a wait that doubles (3 seconds, then
    /// 6) while it fails with something that can pass, up to 3 attempts. The
    /// error it throws is the final one, ready to show. It stops early when
    /// the session is no longer connected or a new connection began, as that
    /// one redoes its own work.
    ///
    /// A request that isn't safe to repeat (a destroy, a kick, a form-based
    /// password change) passes `onlyRefusals`: it is made again only after the
    /// server answered with a `wait` error, never after a timeout or a dropped
    /// connection, as the first attempt may have been applied.
    ///
    ///     let result = try await session.retryingPassingErrors { try await session.fetchSomething() }
    public func retryingPassingErrors<T>(onlyRefusals: Bool = false, _ operation: () async throws -> T) async throws -> T {
        try await retryingPassingErrors(attempts: ServerRetry.attempts, backoff: lock.withLock { $0.retryBackoff }, onlyRefusals: onlyRefusals, operation)
    }

    /// For a request that answers through a callback.
    ///
    ///     let items = try await session.retryingPassingErrors(callback: { done in
    ///         pubsub.retrieveItems(from: jid, node: node, completionHandler: { done($0.mapError { $0 }) })
    ///     })
    public func retryingPassingErrors<T: Sendable>(callback request: @escaping (@escaping (Result<T, Error>) -> Void) -> Void) async throws -> T {
        try await retryingPassingErrors {
            try await withCheckedThrowingContinuation { continuation in
                request { continuation.resume(with: $0) }
            }
        }
    }

    /// After a first attempt that failed with `failure` outside this helper;
    /// `attempts` counts it.
    func retryingPassingErrors<T>(afterFailure failure: Error, attempts: Int = ServerRetry.attempts, _ operation: () async throws -> T) async throws -> T {
        try await retryingPassingErrors(attempts: attempts, backoff: lock.withLock { $0.retryBackoff }, afterFailure: failure, operation)
    }

    func retryingPassingErrors<T>(
        attempts: Int, backoff: TimeInterval, onlyRefusals: Bool = false, afterFailure failure: Error? = nil, _ operation: () async throws -> T,
    ) async throws -> T {
        let started = lock.withLock { $0.attempt }
        return try await ServerRetry.run(
            attempts: attempts, backoff: backoff, onlyRefusals: onlyRefusals, afterFailure: failure,
            isStillWanted: { isConnected && lock.withLock { $0.attempt } == started },
            operation: operation,
        )
    }
}
