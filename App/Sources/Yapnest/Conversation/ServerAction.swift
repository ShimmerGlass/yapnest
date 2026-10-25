import Foundation
import SwiftUI
import YapnestKit

/// A server action a button starts: it shows a spinner while it runs and an
/// alert, from `error`, if it fails.
///
/// The kit call it wraps has already retried what passes by itself, so an
/// error that reaches here is final or outlasted the retries. When it is the
/// server's, the alert gives the server's reason in plain words, and a Retry
/// that runs the action again, as the user may have fixed the cause.
@MainActor
@Observable
final class ServerAction {
    private(set) var isBusy = false
    var error: String?
    /// Whether the alert offers Retry: the failure came from the server or the connection.
    private(set) var canRetry = false
    private var lastWork: (@MainActor () async throws -> Void)?

    func run(_ work: @escaping @MainActor () async throws -> Void) {
        guard !isBusy else { return }
        isBusy = true
        lastWork = work
        canRetry = false
        Task {
            do {
                try await work()
            } catch {
                self.error = ServerError.userMessage(for: error)
                canRetry = ServerError.isFromServer(error)
            }
            isBusy = false
        }
    }

    func retry() {
        guard let lastWork else { return }
        run(lastWork)
    }
}

extension View {
    /// An alert for a failed `action`: OK, and Retry when trying again could help.
    func actionAlert(_ title: LocalizedStringKey, _ action: ServerAction) -> some View {
        alert(title, isPresented: Binding(isPresent: Bindable(action).error)) {
            if action.canRetry {
                Button("Retry") { action.retry() }
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text(action.error ?? "")
        }
    }
}

/// A label whose icon is a spinner while its action is busy.
struct BusyLabel: View {
    let title: LocalizedStringKey
    let systemImage: String
    let isBusy: Bool

    var body: some View {
        Label {
            Text(title)
        } icon: {
            if isBusy { ProgressView() } else { Image(systemName: systemImage) }
        }
    }
}
