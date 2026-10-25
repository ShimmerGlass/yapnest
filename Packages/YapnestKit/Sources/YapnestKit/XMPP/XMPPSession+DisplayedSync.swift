import Combine
import Foundation
@preconcurrency import Martin

/// XEP-0490 message displayed synchronization: how far we've read each
/// chat, kept in our PEP so our other devices follow along.
final class DisplayedSyncModule: AbstractPEPModule, XmppModule, @unchecked Sendable {
    static let ID = NS.mds
    static let IDENTIFIER = XmppModuleIdentifier<DisplayedSyncModule>()

    let criteria = Criteria.empty()
    let features = [NS.mds + "+notify"]
    let changes = PassthroughSubject<DisplayedState, Never>()

    func process(stanza: Stanza) throws {
        throw XMPPError.feature_not_implemented
    }

    override func onItemNotification(notification: PubSubModule.ItemNotification) {
        // Only our own server may tell us what we've read.
        guard notification.node == NS.mds, let context,
              notification.message.from == nil || notification.message.from?.bareJid == context.userBareJid,
              case .published(let item) = notification.action,
              let state = DisplayedState(id: item.id, payload: item.payload) else { return }
        changes.send(state)
    }
}

/// One chat's item: the last message read there, by the stanza-id our
/// server gave it in 1:1 chats, or the room in groups.
struct DisplayedState: Sendable, Equatable {
    var peer: JID
    var stanzaId: String
    var by: JID

    init(peer: JID, stanzaId: String, by: JID) {
        self.peer = peer
        self.stanzaId = stanzaId
        self.by = by
    }

    init?(id: String, payload: Element?) {
        guard let peer = JID(id), let displayed = payload, displayed.name == "displayed", displayed.xmlns == NS.mds,
              let stanzaId = displayed.firstChild(name: "stanza-id", xmlns: NS.sid),
              let id = stanzaId.getAttribute("id"), let by = stanzaId.getAttribute("by").flatMap(JID.init(_:)) else { return nil }
        self.init(peer: peer, stanzaId: id, by: by)
    }

    var element: Element {
        let displayed = Element(name: "displayed", xmlns: NS.mds)
        displayed.addChild(Element(name: "stanza-id", attributes: ["xmlns": NS.sid, "id": stanzaId, "by": by.description]))
        return displayed
    }
}

extension XMPPSession {
    /// Tells our other devices we've read the chat with `peer` up to `message`.
    func publishDisplayed(_ message: Message, route: Route) {
        let peer = route.peer
        guard isConnected, let stanzaId = message.serverId else { return }
        let state = DisplayedState(peer: peer, stanzaId: stanzaId, by: route.isGroup ? peer : account)
        // Reading while messages arrive marks the same one again and again.
        let isNew = lock.withLock { $0.publishedDisplayed.updateValue(stanzaId, forKey: peer) != stanzaId }
        guard isNew else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                // A node another client made with other options refuses the
                // publish; this one reconfigures it and goes again.
                try await publishPEPKeepingErrors(
                    node: NS.mds, itemId: peer.description, payload: state.element, accessModel: "whitelist",
                    config: Self.settingsNodeFields(maxItems: "max"),
                )
                warnings.clear("readState")
            } catch {
                lock.withLock { _ = $0.publishedDisplayed.removeValue(forKey: peer) }
                logger.info("Couldn't publish read state for \(peer, privacy: .private): \(error.localizedDescription, privacy: .private)")
                // The next read of a chat tries again, so only a refusal for good is shown.
                if ServerError.isFromServer(error), ServerError.classify(error).isFinal {
                    warnings.post("readState", title: String(localized: "Read state not synced"), friendly: String(localized: "The server wouldn't take the read state"), error: error)
                }
            }
        }
    }

    /// Another of our devices read a chat.
    func displayedChanged(_ state: DisplayedState) {
        lock.withLock { $0.publishedDisplayed[state.peer] = state.stanzaId }
        do {
            try database.applyDisplayed(peer: state.peer, stanzaId: state.stanzaId)
        } catch {
            logger.error("Failed to apply read state: \(error)")
        }
    }

    /// Catches up on what our other devices read while we were away, or while
    /// the server held our notifications back and sent only the newest.
    /// `done` says whether the states were read.
    func fetchDisplayed(then done: (@Sendable (Bool) -> Void)? = nil) {
        // A failure is owed again by the callers: at the next catch-up (every
        // connect) or return to the app.
        readNode(NS.mds, as: "Read states") { [weak self] read in
            if case .items(let page) = read {
                self?.applyFetchedDisplayed(page.items.compactMap { DisplayedState(id: $0.id, payload: $0.payload) })
            }
            done?(read.isRead)
        }
    }

    /// Applies the chats whose state differs from what we last knew, in one
    /// write: this runs on every return to the app, with a state per chat.
    /// A state whose message isn't stored yet is recorded all the same, as
    /// `displayedChanged` does: a room's catch-up applies it when its history
    /// has arrived.
    func applyFetchedDisplayed(_ states: [DisplayedState]) {
        let changed = lock.withLock { state in
            states.filter { state.publishedDisplayed[$0.peer] != $0.stanzaId }
        }
        guard !changed.isEmpty else { return }
        do {
            lock.withLock { state in
                for item in changed { state.publishedDisplayed[item.peer] = item.stanzaId }
            }
            _ = try database.applyDisplayed(changed.map { ($0.peer, $0.stanzaId) })
        } catch {
            logger.error("Failed to apply read states: \(error)")
        }
    }
}
