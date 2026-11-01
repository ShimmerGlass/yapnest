import Foundation
import Testing

/// How long a test waits for something another queue does. The full suite runs thousands of tests
/// at once, starving the cooperative pool and the disk for ten seconds or more, so a shorter wait
/// fails there while passing alone.
let defaultWait: TimeInterval = 30

/// Polls until `condition` holds and says whether it did in time, for a caller that reports the
/// outcome itself. A test that waits for something *not* to happen passes a short `timeout` and
/// keeps that fixed window.
func eventually(timeout: TimeInterval = defaultWait, _ condition: () async throws -> Bool) async rethrows -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while true {
        if try await condition() { return true }
        if Date() >= deadline { return false }
        try? await Task.sleep(for: .milliseconds(20))
    }
}

/// Polls until `condition` holds, and records an issue naming `what` if it doesn't in time.
@discardableResult
func eventually(
    _ what: String, timeout: TimeInterval = defaultWait, sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: () async throws -> Bool,
) async rethrows -> Bool {
    let held = try await eventually(timeout: timeout, condition)
    if !held { Issue.record("Timed out waiting for \(what)", sourceLocation: sourceLocation) }
    return held
}
