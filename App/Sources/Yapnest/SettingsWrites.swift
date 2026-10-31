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

    /// The control moves at once; the write follows, and the control goes
    /// back if it fails.
    func setOptimistically<Value>(
        _ field: Binding<Value>, to value: Value, _ work: @escaping @Sendable () throws -> Void, onFailure: @escaping @MainActor (Error) -> Void,
    ) {
        let previous = field.wrappedValue
        field.wrappedValue = value
        run(work, onFailure: { error in
            field.wrappedValue = previous
            onFailure(error)
        })
    }
}
