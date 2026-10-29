import Foundation
@preconcurrency import Martin

/// A chat manager that has a chat for every JID, so Martin's `MessageModule`
/// publishes body-less stanzas (receipts, reactions, markers) even for peers
/// it hasn't seen in this process. Conversations live in our database, not here.
final class AnyPeerChatManager: ChatManager {
    private let store = DefaultChatStore()

    func chats(for context: Context) -> [ChatProtocol] { store.chats(for: context) }

    func chat(for context: Context, with jid: BareJID) -> ChatProtocol? {
        createChat(for: context, with: jid)
    }

    func createChat(for context: Context, with jid: BareJID) -> ChatProtocol? {
        switch store.createChat(for: context, with: jid) {
        case .created(let chat), .found(let chat): chat
        case .none: nil
        }
    }

    func close(chat: ChatProtocol) -> Bool { false }
    func initialize(context: Context) { store.initialize(context: context) }
    func deinitialize(context: Context) { store.deinitialize(context: context) }
}

/// Resolves the account's domain to a fixed host, for servers without SRV records.
struct FixedHostResolver: DNSSrvResolver {
    var host: String
    var port: Int
    var directTLS: Bool

    func resolve(domain: String, for jid: BareJID, completionHandler: @escaping (Result<XMPPSrvResult, DNSError>) -> Void) {
        let record = XMPPSrvRecord(port: port, weight: 0, priority: 0, target: host, directTls: directTLS)
        completionHandler(.success(XMPPSrvResult(domain: domain, records: [record])))
    }

    func markAsInvalid(for domain: String, record: XMPPSrvRecord, for: TimeInterval) {}
    func markAsInvalid(for domain: String, host: String, port: Int, for: TimeInterval) {}
}

/// The roster as Martin sees it, kept in our database with its version, so
/// a new session asks only for what changed (RFC 6121 roster versioning).
/// Synchronous, because `RosterManagerBase` reads an item back right after
/// writing it.
final class DatabaseRosterStore: RosterStore, @unchecked Sendable {
    typealias RosterItem = RosterItemBase

    private let database: AppDatabase
    private let subscriptionEnded: @Sendable (JID) -> Void

    /// `subscriptionEnded` hears of every roster item we don't see the
    /// presence of: its subscription isn't `to` or `both`, or it was removed.
    /// Every roster push and the roster fetched on connecting come through
    /// here, so this is the one place that sees them all.
    init(database: AppDatabase, subscriptionEnded: @escaping @Sendable (JID) -> Void = { _ in }) {
        self.database = database
        self.subscriptionEnded = subscriptionEnded
    }

    func clear(for context: Context) {
        try? database.setSetting(.rosterVersion, nil)
    }

    func items(for context: Context) -> [RosterItemBase] {
        ((try? database.roster()) ?? []).map(Self.item(for:))
    }

    func item(for context: Context, jid: Martin.JID) -> RosterItemBase? {
        guard let jid = JID(jid), let contact = try? database.contact(jid), contact.isInRoster else { return nil }
        return Self.item(for: contact)
    }

    func updateItem(for context: Context, jid: Martin.JID, name: String?, subscription: RosterItemSubscription, groups: [String], ask: Bool, annotations: [RosterItemAnnotation]) {
        guard let jid = JID(jid) else { return }
        try? database.updateRosterItem(jid: jid, name: name, subscription: Contact.Subscription(rawValue: subscription.rawValue) ?? .none, isPending: ask, groups: groups)
        if subscription != .to && subscription != .both { subscriptionEnded(jid) }
    }

    func deleteItem(for context: Context, jid: Martin.JID) {
        guard let jid = JID(jid) else { return }
        try? database.removeRosterItem(jid: jid)
        subscriptionEnded(jid)
    }

    func version(for context: Context) -> String? { try? database.setting(.rosterVersion) }
    func set(version: String?, for context: Context) { try? database.setSetting(.rosterVersion, version) }
    func initialize(context: Context) {}
    func deinitialize(context: Context) {}

    /// Groups are kept only to send them back with a rename.
    private static func item(for contact: Contact) -> RosterItemBase {
        RosterItemBase(
            jid: Martin.JID(contact.jid.martin), name: contact.name,
            subscription: RosterItemSubscription(rawValue: contact.subscription.rawValue) ?? .none,
            groups: contact.rosterGroups, ask: contact.isSubscriptionPending, annotations: [],
        )
    }
}

/// Refuses to continue on an unencrypted stream: Yapnest requires TLS.
/// Withholding the features stops Martin before it authenticates;
/// `onInsecure` then tears the connection down.
final class RequireTLSStreamFeaturesModule: StreamFeaturesModule, @unchecked Sendable {
    private let isTLSActive: () -> Bool
    private let onInsecure: () -> Void

    init(isTLSActive: @escaping () -> Bool, onInsecure: @escaping () -> Void) {
        self.isTLSActive = isTLSActive
        self.onInsecure = onInsecure
        super.init()
    }

    override func process(stanza: Stanza) throws {
        let offersTLS = stanza.element.firstChild(name: "starttls", xmlns: "urn:ietf:params:xml:ns:xmpp-tls") != nil
        guard offersTLS || isTLSActive() else {
            onInsecure()
            return
        }
        try super.process(stanza: stanza)
    }
}
