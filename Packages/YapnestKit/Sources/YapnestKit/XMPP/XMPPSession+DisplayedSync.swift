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
    /// Starts, or asks again for, the one run that sends the read states owed
    /// (`Conversation.readStateOwed`), which is the only outbox for them: a read
    /// records that the chat owes its state, and this sends it. Reading again
    /// while it goes asks it for another round, not a second publish.
    func publishOwedReadStates() {
        guard policy.resendsPending else { return }
        coalesced(\.readStateRun) { await $0.publishOwedRound() }
    }

    /// One round over the chats owing a state. It publishes from what the
    /// server is known to hold (`publishedDisplayed`: our own publishes,
    /// notifications and the fetch on connect) and the database, without
    /// fetching: a fetch per read would cost a round trip for nothing, as the
    /// server tells us when another device reads. Only the catch-up and a
    /// return to the app fetch, and the round that follows is theirs: until
    /// then the server's states are not all known, and publishing could move
    /// another device's read point back.
    private func publishOwedRound() async {
        let settled = lock.withLock { !$0.isSyncing && $0.displayedFetches == 0 }
        guard policy.resendsPending, isConnected, settled else { return }
        let owed: [Conversation]
        do {
            owed = try database.conversationsOwingReadState()
        } catch {
            logger.error("Failed to look up the read states owed: \(error)")
            return
        }
        for conversation in owed {
            guard isConnected, let id = conversation.id else { return }
            do {
                // Nothing we read can be named, such as messages without a stanza-id.
                guard let last = try database.newestReadMessageWithServerId(conversationId: id), let stanzaId = last.serverId else {
                    try database.clearReadStateOwed(conversationId: id, ifNewest: nil)
                    continue
                }
                if let held = lock.withLock({ $0.publishedDisplayed[conversation.peer] }) {
                    // A state for a message we don't have may be newer than ours; a room's
                    // catch-up stores it, and the next connect decides again.
                    if try !database.hasMessage(conversationId: id, serverId: held) { continue }
                    // One that reaches as far as ours, ours included, is not ours to publish over.
                    if try database.readState(conversationId: id, naming: held) {
                        try database.clearReadStateOwed(conversationId: id, ifNewest: held)
                        continue
                    }
                }
                await publish(stanzaId: stanzaId, conversationId: id, route: route(for: conversation))
            } catch {
                logger.error("Failed to publish an owed read state: \(error)")
            }
        }
    }

    private func publish(stanzaId: String, conversationId: Int64, route: Route) async {
        let peer = route.peer
        let state = DisplayedState(peer: peer, stanzaId: stanzaId, by: route.isGroup ? peer : account)
        do {
            // A node another client made with other options refuses the
            // publish; this one reconfigures it and goes again.
            try await publishPEPKeepingErrors(
                node: NS.mds, itemId: peer.description, payload: state.element, accessModel: "whitelist",
                config: Self.settingsNodeFields(maxItems: "max"),
            )
            lock.withLock { $0.publishedDisplayed[peer] = stanzaId }
            warnings.clear("readState")
            do {
                try database.clearReadStateOwed(conversationId: conversationId, ifNewest: stanzaId)
            } catch {
                logger.error("Failed to record the read state as published: \(error)")
            }
        } catch {
            logger.info("Couldn't publish read state for \(peer, privacy: .private): \(error.localizedDescription, privacy: .private)")
            // The chat stays owed, so the next connect tries again; only a refusal for good is shown.
            if ServerError.isFromServer(error), ServerError.classify(error).isFinal {
                try? database.clearReadStateOwed(conversationId: conversationId, ifNewest: nil)
                warnings.post("readState", title: String(localized: "Read state not synced"), friendly: String(localized: "The server wouldn't take the read state"), error: error)
            }
        }
    }

    /// Another of our devices read a chat.
    func displayedChanged(_ state: DisplayedState) {
        lock.withLock { $0.publishedDisplayed[state.peer] = state.stanzaId }
        do {
            try database.applyDisplayed(peer: state.peer, stanzaId: state.stanzaId)
            try database.clearReadStateOwed(peer: state.peer, ifNewest: state.stanzaId)
        } catch {
            logger.error("Failed to apply read state: \(error)")
        }
    }

    /// Catches up on what our other devices read while we were away, or while
    /// the server held our notifications back and sent only the newest.
    /// `done` says whether the states were read.
    func fetchDisplayed(then done: (@Sendable (Bool) -> Void)? = nil) {
        lock.withLock { $0.displayedFetches += 1 }
        // A failure is owed again by the callers: at the next catch-up (every
        // connect) or return to the app.
        readNode(NS.mds, as: "Read states") { [weak self] read in
            self?.lock.withLock { $0.displayedFetches = max(0, $0.displayedFetches - 1) }
            switch read {
            case .items(let page):
                let states = page.items.compactMap { DisplayedState(id: $0.id, payload: $0.payload) }
                self?.applyFetchedDisplayed(states)
                self?.publishOwedReadStates()
            case .noNode:
                self?.lock.withLock { $0.publishedDisplayed = [:] }
                self?.publishOwedReadStates()
            case .unsupported:
                // There is nowhere to publish, so nothing stays owed to make
                // every resume read the node again.
                if self?.policy.resendsPending == true {
                    do {
                        try self?.database.clearAllReadStatesOwed()
                    } catch {
                        self?.logger.error("Failed to drop the read states owed: \(error)")
                    }
                }
            case .failed:
                break
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
