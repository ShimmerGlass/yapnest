import Foundation
import Testing
@testable import YapnestKit

/// A request that fails in a way that can pass is made again, a final answer
/// is not, and nothing keeps trying once the session is gone.
struct ServerRetryTests {
    private let passing = ServerError(condition: "resource-constraint", type: .wait)
    private let final = ServerError(condition: "forbidden")

    /// Fails with `failures` in order, then succeeds; counts the calls.
    private final class Flaky: @unchecked Sendable {
        private let lock = NSLock()
        private var failures: [Error]
        private(set) var calls = 0

        init(_ failures: [Error]) { self.failures = failures }

        func call() throws -> String {
            try lock.withLock {
                calls += 1
                if failures.isEmpty { return "done" }
                throw failures.removeFirst()
            }
        }
    }

    @Test func succeedsAfterPassingFailures() async throws {
        let flaky = Flaky([passing, ServerError(condition: "remote-server-timeout"), URLError(.timedOut)])
        let result = try await ServerRetry.run(attempts: 4, backoff: 0, isStillWanted: { true }) { try flaky.call() }
        #expect(result == "done")
        #expect(flaky.calls == 4)
    }

    @Test func aFinalErrorIsReturnedAtOnce() async {
        let flaky = Flaky([final])
        await #expect(throws: ServerError.self) {
            try await ServerRetry.run(attempts: 3, backoff: 0, isStillWanted: { true }) { try flaky.call() }
        }
        #expect(flaky.calls == 1)
    }

    @Test func anErrorOfOurOwnIsFinal() async {
        struct Mistake: Error {}
        let flaky = Flaky([Mistake()])
        await #expect(throws: Mistake.self) {
            try await ServerRetry.run(attempts: 3, backoff: 0, isStillWanted: { true }) { try flaky.call() }
        }
        #expect(flaky.calls == 1)
    }

    @Test func givesUpAfterTheBoundWithTheLastError() async {
        let flaky = Flaky([passing, passing, ServerError(condition: "remote-server-timeout", type: .wait), passing])
        await #expect(throws: ServerError(condition: "remote-server-timeout", type: .wait)) {
            try await ServerRetry.run(attempts: 3, backoff: 0, isStillWanted: { true }) { try flaky.call() }
        }
        #expect(flaky.calls == 3)
    }

    @Test func aFinalErrorAfterPassingOnesEndsIt() async {
        let flaky = Flaky([passing, final, passing])
        await #expect(throws: final) {
            try await ServerRetry.run(attempts: 5, backoff: 0, isStillWanted: { true }) { try flaky.call() }
        }
        #expect(flaky.calls == 2)
    }

    @Test func stopsWhenNoLongerWanted() async {
        let flaky = Flaky([passing, passing, passing])
        await #expect(throws: passing) {
            try await ServerRetry.run(attempts: 3, backoff: 0, isStillWanted: { false }) { try flaky.call() }
        }
        #expect(flaky.calls == 1)
    }

    @Test func aCancelledRunIsNotRetried() async {
        let flaky = Flaky([CancellationError()])
        await #expect(throws: CancellationError.self) {
            try await ServerRetry.run(attempts: 3, backoff: 0, isStillWanted: { true }) { try flaky.call() }
        }
        #expect(flaky.calls == 1)
    }

    @Test func waitsLongerEachTime() async throws {
        let flaky = Flaky([passing, passing])
        let started = Date()
        _ = try await ServerRetry.run(attempts: 3, backoff: 0.05, isStillWanted: { true }) { try flaky.call() }
        // 0.05 then 0.1.
        #expect(Date().timeIntervalSince(started) >= 0.14)
    }

    // MARK: On a session

    @Test func aSessionThatIsNotConnectedDoesNotRetry() async throws {
        let session = try makeSession(JID("me@localhost")!)
        let flaky = Flaky([passing, passing])
        await #expect(throws: passing) {
            try await session.retryingPassingErrors(attempts: 3, backoff: 0) { try flaky.call() }
        }
        #expect(flaky.calls == 1)
    }

    @Test func aConnectedSessionRetries() async throws {
        let session = try makeSession(JID("me@localhost")!)
        session.connectForTesting(FakeWire())
        session.lock.withLock { $0.retryBackoff = 0 }
        let flaky = Flaky([passing, passing])
        let result = try await session.retryingPassingErrors { try flaky.call() }
        #expect(result == "done")
        #expect(flaky.calls == 3)
    }

    @Test func aNewConnectionEndsTheRetries() async throws {
        let session = try makeSession(JID("me@localhost")!)
        session.connectForTesting(FakeWire())
        let flaky = Flaky([passing, passing])
        await #expect(throws: passing) {
            try await session.retryingPassingErrors(attempts: 3, backoff: 0) {
                session.lock.withLock { $0.attempt += 1 }
                return try flaky.call()
            }
        }
        #expect(flaky.calls == 1)
    }

    @Test func callbackStyleRequestsRetryToo() async throws {
        let session = try makeSession(JID("me@localhost")!)
        session.connectForTesting(FakeWire())
        session.lock.withLock { $0.retryBackoff = 0 }
        let flaky = Flaky([passing])
        let result: String = try await session.retryingPassingErrors(callback: { done in
            done(Result { try flaky.call() })
        })
        #expect(result == "done")
        #expect(flaky.calls == 2)
    }
}
