import Combine
import Foundation
@preconcurrency import Martin
import os

/// XEP-0048 bookmarks in PEP, the kind Conversations keeps. Servers that
/// don't mirror XEP-0402 bookmarks to them (no `#compat`) leave a new device
/// no other way to find its groups.
final class LegacyBookmarksModule: AbstractPEPModule, XmppModule, @unchecked Sendable {
    static let ID = NS.legacyBookmarks
    static let IDENTIFIER = XmppModuleIdentifier<LegacyBookmarksModule>()

    let criteria = Criteria.empty()
    let features = [NS.legacyBookmarks + "+notify"]
    /// The whole list, whenever it changes.
    let changes = PassthroughSubject<[Bookmark], Never>()

    func process(stanza: Stanza) throws {
        throw XMPPError.feature_not_implemented
    }

    override func onItemNotification(notification: PubSubModule.ItemNotification) {
        guard notification.node == NS.legacyBookmarks, let context,
              notification.message.from == nil || notification.message.from?.bareJid == context.userBareJid else { return }
        if case .published(let item) = notification.action, let storage = item.payload {
            changes.send(Bookmark.legacyList(in: storage))
        }
    }
}

extension Bookmark {
    init?(legacy conference: Element) {
        guard conference.name == "conference", let jid = conference.getAttribute("jid").flatMap(JID.init(_:)) else { return nil }
        let fields = Self.conferenceFields(conference)
        self.init(jid: jid, name: fields.name, autojoin: fields.autojoin, nick: fields.nick, password: fields.password)
    }

    static func legacyList(in storage: Element) -> [Bookmark] {
        storage.children.compactMap(Bookmark.init(legacy:))
    }

    /// The conference as XEP-0048 writes it, over `existing` when the list
    /// holds one, so that what other clients put in it stays.
    var legacyElement: Element { legacyMerged(into: nil) }

    func legacyMerged(into existing: Element?) -> Element {
        let conference = existing.map(Element.init(element:)) ?? Element(name: "conference")
        conference.setAttribute("jid", value: jid.description)
        addConferenceFields(to: conference)
        return conference
    }
}

extension XMPPSession {
    /// How long a bookmark publish may go unanswered.
    static let bookmarkTimeout: TimeInterval = 10

    /// One at a time: each change reads the list and writes it back.
    private static let legacyBookmarkQueue = DispatchQueue(label: "Yapnest.XMPPSession.legacyBookmarks")

    /// Whether our server doesn't keep XEP-0402 bookmarks where other clients
    /// see them, which `#compat` (Prosody) or `#compat-pep` (ejabberd) say it
    /// does.
    var usesLegacyBookmarks: Bool {
        let features = client.module(.disco).accountDiscoResult.features
        return !features.contains(NS.bookmarks + "#compat") && !features.contains(NS.bookmarks + "#compat-pep")
    }

    func publishLegacyBookmark(_ bookmark: Bookmark) async throws {
        let room = bookmark.jid
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            updateLegacyBookmarks { storage in
                let held = storage.children.first { $0.getAttribute("jid") == room.description }
                storage.removeChildren { $0.getAttribute("jid") == room.description }
                storage.addChild(bookmark.legacyMerged(into: held))
            } then: { continuation.resume(with: $0) }
        }
        try? database.updateGroupChat(room) { $0.isBookmarked = true }
    }

    func removeLegacyBookmark(_ room: JID, then done: @escaping @Sendable (Result<Void, Error>) -> Void = { _ in }) {
        updateLegacyBookmarks({ storage in
            storage.removeChildren { $0.getAttribute("jid") == room.description }
        }, unsupportedMeansNothingToChange: true, then: done)
    }

    /// Another of our clients changed the old bookmarks. A server with
    /// `#compat` also sends the XEP-0402 change, which says the same.
    func legacyBookmarksChanged(_ bookmarks: [Bookmark]) {
        guard usesLegacyBookmarks else { return }
        reconcileBookmarks(bookmarks)
    }

    /// Reads the list, changes it and writes it back, keeping what we don't
    /// understand (URL bookmarks, other clients' extensions) as it was. A
    /// server that keeps no such list has nothing to remove from it, which a
    /// removal counts as done. A failure is the server's error, or a timeout.
    private func updateLegacyBookmarks(
        _ change: @escaping @Sendable (Element) -> Void, unsupportedMeansNothingToChange: Bool = false,
        then done: @escaping @Sendable (Result<Void, Error>) -> Void,
    ) {
        Self.legacyBookmarkQueue.async { [self] in
            let pubsub = client.module(.pubsub)
            let storage: Element
            let current = waitFor { (finish: @escaping @Sendable (NodeRead) -> Void) in
                readNode(NS.legacyBookmarks, as: "Old bookmarks", finish)
            }
            switch current {
            case .items(let page)?:
                storage = page.items.first?.payload ?? Element(name: "storage", xmlns: NS.legacyBookmarks)
            case .noNode?:
                storage = Element(name: "storage", xmlns: NS.legacyBookmarks)
            case .unsupported? where unsupportedMeansNothingToChange:
                done(.success(()))
                return
            case .unsupported?:
                done(.failure(ServerError(condition: "feature-not-implemented", type: .cancel)))
                return
            case .failed(let error)?:
                // Writing back a list we couldn't read would drop the others.
                logger.warning("Couldn't read the old bookmarks to change them")
                done(.failure(error))
                return
            case nil:
                logger.warning("Couldn't read the old bookmarks to change them")
                done(.failure(ServerError.timedOut))
                return
            }
            change(storage)
            let options = ProfileStanza.publishOptions(accessModel: "whitelist")
            let result = waitFor { (finish: @escaping @Sendable (Result<Iq, PubSubError>) -> Void) in
                pubsub.publishItem(at: nil, to: NS.legacyBookmarks, itemId: "current", payload: storage,
                                   publishOptions: options, errorDecoder: PubSubError.from(stanza:), completionHandler: finish)
            }
            switch result {
            case .success?:
                done(.success(()))
            case .failure(let error)?:
                logger.warning("Couldn't publish the old bookmarks: \(error.localizedDescription, privacy: .private)")
                done(.failure(ServerError(error)))
            case nil:
                logger.warning("Couldn't publish the old bookmarks: no answer")
                done(.failure(ServerError.timedOut))
            }
        }
    }

    /// Blocks the calling queue (never Martin's) for an answer.
    private func waitFor<T: Sendable>(_ start: (@escaping @Sendable (T) -> Void) -> Void) -> T? {
        let semaphore = DispatchSemaphore(value: 0)
        let box = OSAllocatedUnfairLock<T?>(initialState: nil)
        start { value in
            box.withLock { $0 = value }
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + Self.bookmarkTimeout) == .success else { return nil }
        return box.withLock { $0 }
    }
}
