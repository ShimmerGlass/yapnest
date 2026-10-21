import Combine
import Foundation
@preconcurrency import Martin
import os

/// True for the first caller only: one of an answer and a timeout wins.
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func first() -> Bool {
        lock.withLock {
            defer { done = true }
            return !done
        }
    }
}

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
        self.init(jid: jid, name: fields.name, autojoin: fields.autojoin, nick: fields.nick)
    }

    static func legacyList(in storage: Element) -> [Bookmark] {
        storage.children.compactMap(Bookmark.init(legacy:))
    }

    /// The conference as XEP-0048 writes it.
    var legacyElement: Element {
        let conference = Element(name: "conference")
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

    /// The groups in the old bookmarks, or nil if the server wouldn't say.
    func fetchLegacyBookmarks(then done: @escaping @Sendable ([Bookmark]?) -> Void) {
        client.module(.pubsub).retrieveItems(from: account.martin, for: NS.legacyBookmarks) { [weak self] result in
            switch result {
            case .success(let items):
                done(items.items.first?.payload.map(Bookmark.legacyList(in:)) ?? [])
            case .failure(let error) where error.error == .item_not_found:
                done([])
            case .failure(let error):
                self?.logger.info("Bookmarks unavailable: \(error.localizedDescription, privacy: .private)")
                done(nil)
            }
        }
    }

    func publishLegacyBookmark(_ bookmark: Bookmark, for group: GroupChat) {
        let room = bookmark.jid
        updateLegacyBookmarks { storage in
            storage.removeChildren { $0.getAttribute("jid") == room.description }
            storage.addChild(bookmark.legacyElement)
        } then: { [weak self] succeeded in
            if succeeded { try? self?.database.updateGroupChat(group.jid) { $0.isBookmarked = true } }
        }
    }

    func removeLegacyBookmark(_ room: JID, then done: @escaping @Sendable (Bool) -> Void = { _ in }) {
        updateLegacyBookmarks({ storage in
            storage.removeChildren { $0.getAttribute("jid") == room.description }
        }, then: done)
    }

    /// Another of our clients changed the old bookmarks. A server with
    /// `#compat` also sends the XEP-0402 change, which says the same.
    func legacyBookmarksChanged(_ bookmarks: [Bookmark]) {
        guard usesLegacyBookmarks else { return }
        for bookmark in bookmarks { bookmarkChanged(.published(bookmark)) }
        let listed = Set(bookmarks.map(\.jid))
        for group in (try? database.groupChats()) ?? [] where group.isBookmarked && !group.hasLeft && !listed.contains(group.jid) {
            bookmarkChanged(.retracted(group.jid))
        }
    }

    /// Reads the list, changes it and writes it back, keeping what we don't
    /// understand (URL bookmarks, other clients' extensions) as it was.
    private func updateLegacyBookmarks(_ change: @escaping @Sendable (Element) -> Void, then done: @escaping @Sendable (Bool) -> Void) {
        Self.legacyBookmarkQueue.async { [self] in
            let pubsub = client.module(.pubsub)
            let storage: Element
            let current = waitFor { (finish: @escaping @Sendable (PubSubRetrieveItemsResult) -> Void) in
                pubsub.retrieveItems(from: account.martin, for: NS.legacyBookmarks, completionHandler: finish)
            }
            switch current {
            case .success(let items)?:
                storage = items.items.first?.payload ?? Element(name: "storage", xmlns: NS.legacyBookmarks)
            case .failure(let error)? where error.error == .item_not_found:
                storage = Element(name: "storage", xmlns: NS.legacyBookmarks)
            default:
                // Writing back a list we couldn't read would drop the others.
                logger.warning("Couldn't read the old bookmarks to change them")
                done(false)
                return
            }
            change(storage)
            let options = Self.dataForm(type: "submit", formType: "http://jabber.org/protocol/pubsub#publish-options", fields: [
                "pubsub#persist_items": ["true"],
                "pubsub#access_model": ["whitelist"],
            ])
            let result = waitFor { (finish: @escaping @Sendable (Result<Iq, PubSubError>) -> Void) in
                pubsub.publishItem(at: nil, to: NS.legacyBookmarks, itemId: "current", payload: storage,
                                   publishOptions: options, errorDecoder: PubSubError.from(stanza:), completionHandler: finish)
            }
            if case .success? = result {
                done(true)
            } else {
                logger.warning("Couldn't publish the old bookmarks: \(String(describing: result), privacy: .private)")
                done(false)
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
