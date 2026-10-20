import Foundation

struct TimeoutError: Error {}

/// Runs `operation`, and throws `TimeoutError` if it hasn't returned within
/// `timeout`. The operation is cancelled then, so it should end promptly on
/// cancellation, as waiting on a stream does.
func withTimeout<T: Sendable>(
    _ timeout: TimeInterval, operation: @escaping @Sendable () async throws -> T,
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask(operation: operation)
        group.addTask {
            try await Task.sleep(for: .seconds(timeout))
            throw TimeoutError()
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}
