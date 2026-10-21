import Combine
import Foundation
import GRDB
@preconcurrency import Martin

/// What others see of us: our avatar (XEP-0084), kept in PEP. Contacts read
/// it from there, so its nodes must be readable by them.
extension XMPPSession {
    public enum ProfileError: Error, LocalizedError {
        case offline
        case imageTooLarge
        /// The server said no; `reason` is its own condition and text.
        case refused(reason: String)

        public var errorDescription: String? {
            switch self {
            case .refused(let reason): String(localized: "The server refused it: \(reason)")
            case .offline: String(localized: "You're offline.")
            case .imageTooLarge: String(localized: "That picture is too large.")
            }
        }
    }

    /// Publishes `data` as our avatar and shows it right away, without
    /// waiting for the server to notify us of our own change.
    public func publishAvatar(_ data: Data, mimeType: String, width: Int? = nil, height: Int? = nil) async throws {
        guard isConnected else { throw ProfileError.offline }
        guard data.count <= AvatarStore.maxSize else { throw ProfileError.imageTooLarge }
        let hash = AvatarStore.hash(of: data)
        // Martin's own publishAvatar sends no publish-options, leaving the
        // node at the server's default, which is readable only by contacts
        // we've approved, and it refuses anything that isn't PNG.
        try await publishPEP(node: NS.avatarData, itemId: hash, payload: ProfileStanza.avatarData(data), accessModel: "open")
        let info = PEPUserAvatarModule.Info(id: hash, size: data.count, mimeType: mimeType, height: height, width: width)
        try await publishPEP(node: NS.avatarMetadata, itemId: hash, payload: ProfileStanza.avatarMetadata(info), accessModel: "open")
        // The files are named by their hash, so only a failed write keeps
        // the picture from showing.
        guard avatars.save(data, hash: hash) else { throw ProfileError.imageTooLarge }
        try database.setAvatarHash(hash, for: account)
    }

    /// Removes our avatar, by publishing empty metadata (XEP-0084 §4.2).
    public func removeAvatar() async throws {
        guard isConnected else { throw ProfileError.offline }
        try await publishPEP(node: NS.avatarMetadata, itemId: nil, payload: ProfileStanza.avatarMetadata(nil), accessModel: "open")
        try database.setAvatarHash(nil, for: account)
    }

    /// Publishes one item to our own PEP node, with `accessModel` set on the
    /// node. A node that already exists with another access model refuses
    /// the options, so then it's reconfigured and the item published again.
    /// `config`, when given, replaces the default (persisting, with
    /// `accessModel`) as the node's fields, both asked for in the publish
    /// options and set on a refusing node. A limit of its own isn't asked
    /// for, as the node already has it. With a `timeout`, a server that never
    /// answers throws `TimeoutError`.
    func publishPEP(
        node: String, itemId: String?, payload: Element, accessModel: String,
        config: [String: [String]]? = nil, timeout: TimeInterval? = nil,
    ) async throws {
        do {
            try await publishPEPKeepingErrors(
                node: node, itemId: itemId, payload: payload, accessModel: accessModel, config: config, timeout: timeout,
            )
        } catch let error as PubSubError {
            logger.error("Publishing to \(node, privacy: .private) failed: \(error.localizedDescription, privacy: .private)")
            throw ProfileError.refused(reason: error.localizedDescription)
        }
    }

    /// The same, throwing the server's own `PubSubError`, for a caller that
    /// tells its conditions apart.
    func publishPEPKeepingErrors(
        node: String, itemId: String?, payload: Element, accessModel: String,
        config: [String: [String]]? = nil, timeout: TimeInterval? = nil,
    ) async throws {
        let options = config.map { fields in
            XMPPSession.dataForm(
                type: "submit", formType: "http://jabber.org/protocol/pubsub#publish-options",
                fields: fields.filter { $0.key != "pubsub#max_items" || $0.value == ["max"] },
            )
        }
        do {
            try await publishPEPItem(
                node: node, itemId: itemId, payload: payload,
                options: options ?? ProfileStanza.publishOptions(accessModel: accessModel), timeout: timeout,
            )
        } catch let error as PubSubError where error.error.errorCondition == .conflict {
            logger.info("Reconfiguring \(node, privacy: .public) to be \(accessModel, privacy: .public)")
            try await configurePEPNode(node, fields: config ?? ["pubsub#access_model": [accessModel]])
            try await publishPEPItem(node: node, itemId: itemId, payload: payload, options: nil, timeout: timeout)
        }
    }

    private func publishPEPItem(node: String, itemId: String?, payload: Element, options: Element?, timeout: TimeInterval?) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = Once()
            client.module(.pubsub).publishItem(
                at: nil, to: node, itemId: itemId, payload: payload,
                publishOptions: options, errorDecoder: PubSubError.from(stanza:),
            ) { (result: Result<Iq, PubSubError>) in
                if once.first() { continuation.resume(with: result.map { _ in () }) }
            }
            if let timeout {
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    if once.first() { continuation.resume(throwing: TimeoutError()) }
                }
            }
        }
    }

    /// Submits only the given fields, with the form type, rather than the
    /// form the node handed out: that carries read-only and fixed fields,
    /// which servers like ejabberd refuse in a submission.
    func configurePEPNode(_ node: String, fields: [String: [String]]) async throws {
        let set = Iq()
        set.type = .set
        let pubsub = Element(name: "pubsub", xmlns: "http://jabber.org/protocol/pubsub#owner")
        let configure = Element(name: "configure")
        configure.setAttribute("node", value: node)
        configure.addChild(XMPPSession.dataForm(type: "submit", formType: "http://jabber.org/protocol/pubsub#node_config", fields: fields))
        pubsub.addChild(configure)
        set.addChild(pubsub)
        _ = try await client.context.writer.write(iq: set, errorDecoder: PubSubError.from(stanza:))
    }
}

/// The PEP payloads and publish-options for our profile.
enum ProfileStanza {
    static func publishOptions(accessModel: String) -> Element {
        XMPPSession.dataForm(type: "submit", formType: "http://jabber.org/protocol/pubsub#publish-options", fields: [
            "pubsub#persist_items": ["true"],
            "pubsub#access_model": [accessModel],
        ])
    }

    static func nick(_ name: String) -> Element {
        Element(name: "nick", cdata: name, xmlns: NS.nick)
    }

    static func nick(from payload: Element?) -> String? {
        guard let payload, payload.name == "nick", payload.xmlns == NS.nick else { return nil }
        return payload.value
    }

    static func avatarData(_ data: Data) -> Element {
        Element(name: "data", cdata: data.base64EncodedString(), xmlns: NS.avatarData)
    }

    /// Metadata with no `info` says we have no avatar.
    static func avatarMetadata(_ info: PEPUserAvatarModule.Info?) -> Element {
        let metadata = Element(name: "metadata", xmlns: NS.avatarMetadata)
        if let info { metadata.addChild(info.toElement()) }
        return metadata
    }
}

/// The name we publish for ourselves and read for contacts (XEP-0172), kept
/// in PEP.
extension XMPPSession {
    /// The longest name kept, so nobody's is unbounded.
    static let maxNicknameLength = 64

    /// `name` without format characters (category Cf): the bidi controls that
    /// reorder text around them, such as U+202E, and the zero-width ones that
    /// make a name look like another. Names come from strangers.
    public static func removingFormatCharacters(_ name: String) -> String {
        String(String.UnicodeScalarView(name.unicodeScalars.filter { $0.properties.generalCategory != .format }))
    }

    /// A name as it's published and shown: one line, without stray spaces or
    /// format characters; nil if nothing is left.
    public static func normalizedNickname(_ name: String?) -> String? {
        normalizedStatus(name.map(removingFormatCharacters), limit: maxNicknameLength)
    }

    /// The name others see for us, if we've set one.
    public var nickname: String? {
        Self.normalizedNickname(try? database.setting(.nickname))
    }

    /// Publishes `name` as ours, readable by anyone, or takes it back when
    /// it's blank. Our copy is kept once the server has it.
    public func setNickname(_ name: String?) async throws {
        guard isConnected else { throw ProfileError.offline }
        let name = Self.normalizedNickname(name)
        if let name {
            try await publishPEP(node: NS.nick, itemId: Self.nicknameItemId, payload: ProfileStanza.nick(name), accessModel: "open")
        } else {
            do {
                try await retractPEPItem(node: NS.nick, itemId: Self.nicknameItemId)
            } catch let error as PubSubError where error.error == .item_not_found {
                // Nothing there to take back.
            } catch let error as PubSubError {
                throw ProfileError.refused(reason: error.localizedDescription)
            }
        }
        try database.setSetting(.nickname, name)
    }

    static let nicknameItemId = "current"

    func retractPEPItem(node: String, itemId: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            client.module(.pubsub).retractItem(at: nil, from: node, itemId: itemId, notify: true) { result in
                continuation.resume(with: result.map { _ in () })
            }
        }
    }

    /// Takes our name from the server on connecting, as another device may
    /// have changed it.
    func fetchNickname() {
        client.module(.pubsub).retrieveItems(from: account.martin, for: NS.nick, limit: .lastItems(1)) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let items):
                nicknameChanged(account, to: items.items.first.flatMap { ProfileStanza.nick(from: $0.payload) })
            case .failure(let error) where error.error == .item_not_found:
                nicknameChanged(account, to: nil)
            case .failure(let error):
                logger.info("Nickname unavailable: \(error.localizedDescription, privacy: .private)")
            }
        }
    }

    /// `jid` published a new name, or took theirs back; ours may come from
    /// another of our devices.
    func nicknameChanged(_ jid: JID, to nickname: String?) {
        let nickname = Self.normalizedNickname(nickname)
        do {
            if jid == account {
                try database.setSetting(.nickname, nickname)
            } else {
                try database.setNickname(nickname, for: jid)
            }
        } catch {
            logger.error("Failed to store a nickname: \(error)")
        }
    }
}

/// Notifies us when contacts, and our other devices, change their published
/// name (XEP-0172 §4.3).
final class NickModule: AbstractPEPModule, XmppModule, @unchecked Sendable {
    static let ID = NS.nick
    static let IDENTIFIER = XmppModuleIdentifier<NickModule>()

    struct Change {
        var jid: JID
        var nickname: String?
    }

    let criteria = Criteria.empty()
    let features = [NS.nick + "+notify"]
    let changes = PassthroughSubject<Change, Never>()

    func process(stanza: Stanza) throws {
        throw XMPPError.feature_not_implemented
    }

    override func onItemNotification(notification: PubSubModule.ItemNotification) {
        guard notification.node == NS.nick, let context else { return }
        let from = notification.message.from?.bareJid ?? context.userBareJid
        guard let jid = JID(Martin.JID(from)) else { return }
        switch notification.action {
        case .published(let item):
            changes.send(Change(jid: jid, nickname: ProfileStanza.nick(from: item.payload)))
        case .retracted:
            changes.send(Change(jid: jid, nickname: nil))
        }
    }
}

/// What we tell contacts about ourselves: availability and a status message,
/// as the `<show>` and `<status>` of every presence we send (RFC 6121 §4.7).
extension XMPPSession {
    public enum Availability: String, CaseIterable, Sendable {
        case available, away, dnd

        var show: Presence.Show {
            switch self {
            case .available: .online
            case .away: .away
            case .dnd: .dnd
            }
        }
    }

    /// The longest status message kept.
    public static let maxStatusLength = 140

    /// One line, trimmed and bounded; nil if empty.
    public static func normalizedStatus(_ text: String?, limit: Int = maxStatusLength) -> String? {
        guard let text else { return nil }
        let line = text.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return line.isEmpty ? nil : String(line.prefix(limit))
    }

    public var availability: Availability {
        (try? database.setting(.availability)).flatMap(Availability.init(rawValue:)) ?? .available
    }

    public var statusMessage: String {
        Self.normalizedStatus(try? database.setting(.statusMessage)) ?? ""
    }

    /// What we show contacts, together.
    public struct OwnStatus: Equatable, Sendable {
        public let availability: Availability
        /// Empty when there's none.
        public let message: String
    }

    /// What we show contacts as it changes, here or through the settings
    /// another device syncs.
    public func observeOwnStatus() -> ValueObservation<ValueReducers.RemoveDuplicates<ValueReducers.Fetch<OwnStatus>>> {
        ValueObservation.tracking { db in
            OwnStatus(
                availability: try AppDatabase.setting(db, .availability).flatMap(Availability.init(rawValue:)) ?? .available,
                message: Self.normalizedStatus(try AppDatabase.setting(db, .statusMessage)) ?? "",
            )
        }
        .removeDuplicates()
    }

    /// Saves what we show contacts and sends it, to be sent on every connection
    /// from now on. Offline, it goes out when we connect.
    public func setStatus(availability: Availability, message: String) throws {
        try storeAvailability(availability)
        try storeStatusMessage(message)
        sendPresence()
    }

    /// The same for the availability alone, for a caller whose copy of the
    /// message may be older than ours: only what changed is recorded as a
    /// change to publish.
    public func setAvailability(_ availability: Availability) throws {
        try storeAvailability(availability)
        sendPresence()
    }

    public func setStatusMessage(_ message: String) throws {
        try storeStatusMessage(message)
        sendPresence()
    }

    private func storeAvailability(_ availability: Availability) throws {
        try database.setSetting(.availability, availability == .available ? nil : availability.rawValue)
    }

    private func storeStatusMessage(_ message: String) throws {
        try database.setSetting(.statusMessage, Self.normalizedStatus(message))
    }

    /// Our presence, through `setPresence` so Martin adds the entity
    /// capabilities that tell the server what notifications we want. Martin
    /// keeps it and sends it again when we reconnect.
    func sendPresence() {
        // The extensions send no presence.
        guard policy.announcesPresence else { return }
        client.module(.presence).setPresence(show: availability.show, status: Self.normalizedStatus(try? database.setting(.statusMessage)), priority: nil)
    }
}
