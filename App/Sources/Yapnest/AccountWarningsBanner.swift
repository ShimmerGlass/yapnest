import SwiftUI
import YapnestKit

/// What went wrong on the account, in one row above the chat list: the
/// first warning and how many more there are. Tapping it opens the details,
/// each with Retry where trying again could help.
struct AccountWarningsBanner: View {
    let warnings: AccountWarnings

    @State private var list: [AccountWarning] = []
    @State private var showsDetails = false

    var body: some View {
        // A stack, not a Group: the task below must run while there is nothing to show.
        VStack(spacing: 0) {
            if let first = list.first {
                Button {
                    showsDetails = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text(list.count > 1 ? "\(first.title) and \(list.count - 1) more" : first.title)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                    }
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 16)
                    .frame(maxWidth: .infinity)
                    .background(.bar)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("accountWarnings")
                .accessibilityHint("Shows what went wrong")
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.default, value: list.map(\.key))
        .task {
            for await current in warnings.updates { list = current }
        }
        .onChange(of: list.isEmpty) { _, isEmpty in
            if isEmpty { showsDetails = false }
        }
        .sheet(isPresented: $showsDetails) {
            AccountWarningsSheet(warnings: warnings, list: list)
        }
    }
}

private struct AccountWarningsSheet: View {
    let warnings: AccountWarnings
    let list: [AccountWarning]

    @Environment(\.dismiss) private var dismiss
    @State private var retrying: Set<String> = []

    var body: some View {
        NavigationStack {
            List(list) { warning in
                VStack(alignment: .leading, spacing: 6) {
                    Text(warning.title)
                        .font(.headline)
                    Text(warning.detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    if warning.retry != nil {
                        Button {
                            retry(warning.key)
                        } label: {
                            if retrying.contains(warning.key) {
                                ProgressView()
                            } else {
                                Text("Retry")
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(retrying.contains(warning.key))
                        .accessibilityIdentifier("accountWarningRetry")
                    }
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("accountWarning")
            }
            .navigationTitle("Problems")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .sheetSizedForMac()
    }

    private func retry(_ key: String) {
        retrying.insert(key)
        Task {
            await warnings.retry(key)
            retrying.remove(key)
        }
    }
}
