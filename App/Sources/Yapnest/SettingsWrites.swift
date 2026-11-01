import SwiftUI

/// Writes for settings, off the main thread and in the order they were
/// made, so toggling twice quickly ends where the user left it: a write of
/// its own each would let the first land last.
@MainActor
final class SettingsWrites {
    private var tail: Task<Void, Never>?

    func run<Result: Sendable>(
        _ work: @escaping @Sendable () throws -> Result,
        onSuccess: @escaping @MainActor (Result) -> Void = { _ in },
        onFailure: @escaping @MainActor (Error) -> Void,
    ) {
        let previous = tail
        tail = Task {
            await previous?.value
            do {
                onSuccess(try await offMain(work))
            } catch {
                onFailure(error)
            }
        }
    }

    /// The latest write started for each control, by its key.
    private var latest: [String: Int] = [:]

    /// The control moves at once; the write follows, and the control goes
    /// back if it fails. Not when the user has moved it again since: that
    /// later write follows this one and decides what is stored, so going
    /// back would show a value the database doesn't hold. Comparing values
    /// isn't enough for that, as the control may have been moved away and
    /// back to the same one; `key` names the control, so its writes are counted.
    func setOptimistically<Value: Equatable>(
        _ field: Binding<Value>, key: String, to value: Value, _ work: @escaping @Sendable () throws -> Void, onFailure: @escaping @MainActor (Error) -> Void,
    ) {
        let previous = field.wrappedValue
        field.wrappedValue = value
        let mine = (latest[key] ?? 0) + 1
        latest[key] = mine
        run(work, onFailure: { [weak self] error in
            if self?.latest[key] == mine, field.wrappedValue == value { field.wrappedValue = previous }
            onFailure(error)
        })
    }
}
