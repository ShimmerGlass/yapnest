import SwiftUI
import YapnestKit

/// The commands one or more entities offer, to pick one to run. A contact has
/// an entity per device, and each is listed on its own.
struct CommandsListView: View {
    let title: LocalizedStringKey
    let session: XMPPSession
    let entities: [(label: String?, jid: String)]

    private enum Loaded {
        case loading
        case commands([AdHocCommand])
        case failed(String)
    }

    @State private var loaded: [String: Loaded] = [:]

    var body: some View {
        Form {
            ForEach(entities, id: \.jid) { entity in
                Section {
                    switch loaded[entity.jid] ?? .loading {
                    case .loading:
                        HStack { Spacer(); ProgressView(); Spacer() }
                    case .commands(let commands):
                        if commands.isEmpty {
                            Text("No commands").foregroundStyle(.secondary)
                        }
                        ForEach(commands) { command in
                            NavigationLink {
                                CommandRunView(command: command, session: session)
                            } label: {
                                Text(verbatim: command.name)
                            }
                        }
                    case .failed(let message):
                        Text(verbatim: message).foregroundStyle(.secondary)
                        Button("Retry") {
                            loaded[entity.jid] = .loading
                            Task { await load(entity.jid) }
                        }
                    }
                } header: {
                    if entities.count > 1 { Text(verbatim: entity.label ?? entity.jid) }
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        // A group's entities grow while its occupants are still being probed, so
        // a screen opened early gets a longer list later. Keyed on the addresses,
        // the load runs again and fetches the newcomers.
        .task(id: entities.map(\.jid)) { await loadAll(onlyMissing: true) }
        .refreshable { await loadAll(onlyMissing: false) }
    }

    private func loadAll(onlyMissing: Bool) async {
        await withTaskGroup(of: Void.self) { group in
            for entity in entities where !onlyMissing || loaded[entity.jid] == nil {
                group.addTask { await load(entity.jid) }
            }
        }
    }

    private func load(_ jid: String) async {
        do {
            loaded[jid] = .commands(try await session.adHocCommands(at: jid))
        } catch {
            // A cancelled load (the list changed under it) isn't a failure; the
            // entity stays unloaded and the next run fetches it.
            if Task.isCancelled { return }
            loaded[jid] = .failed(error.localizedDescription)
        }
    }
}
