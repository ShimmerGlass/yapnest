import Foundation
import SwiftUI

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
