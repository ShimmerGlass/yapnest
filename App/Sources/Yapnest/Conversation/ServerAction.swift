import Foundation

/// A server action a button starts: it shows a spinner while it runs and an
/// alert, from `error`, if it fails.
@MainActor
@Observable
final class ServerAction {
    private(set) var isBusy = false
    var error: String?

    func run(_ work: @escaping @MainActor () async throws -> Void) {
        guard !isBusy else { return }
        isBusy = true
        Task {
            do { try await work() } catch { self.error = error.localizedDescription }
            isBusy = false
        }
    }
}
