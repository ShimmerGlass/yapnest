import Combine
import Foundation
import GRDB
@preconcurrency import Martin

/// What others see of us: our avatar (XEP-0084), kept in PEP. Contacts read
/// it from there, so its nodes must be readable by them; by everyone, only
/// while the user shares their profile publicly.
extension XMPPSession {
    /// Whether our name and photo are readable by everyone, or only by the
    /// contacts who see our presence.
    public var sharesProfilePublicly: Bool { database.flag(.sharesProfilePublicly, default: false) }

    /// The access model our profile nodes should have now.
    var profileAccessModel: String { sharesProfilePublicly ? "open" : "presence" }

    /// Saves the setting and has the nodes follow it. Offline, or when the
    /// server's answer is one that can pass, the setting is kept and the nodes
    /// are put right at the next connect. A server that refuses for good
    /// throws, and the setting goes back to what it was.
    public func setSharesProfilePublicly(_ on: Bool) async throws {
        let before = sharesProfilePublicly
        try database.setFlag(.sharesProfilePublicly, on)
        // Owed until applied or refused, as for `reconcileProfileAccess`: a
        // stream that resumes runs no catch-up, and would otherwise leave it
        // for the next new session.
        lock.withLock { _ = $0.owedOnResume.insert(.profileAccess) }
        guard isConnected else { return }
        do {
            try await applyProfileAccess()
            lock.withLock { _ = $0.owedOnResume.remove(.profileAccess) }
        } catch {
            if passesByItself(error, "Couldn't change who reads the profile now") { return }
            lock.withLock { _ = $0.owedOnResume.remove(.profileAccess) }
            try? database.setFlag(.sharesProfilePublicly, before)
            // The nodes that did change would otherwise stay as the refused
            // setting left them. This can fail as well, and the user is told
            // of the first error, which is the one they can act on; what's
            // left is put right at the next connect.
            try? await applyProfileAccess()
            throw error
        }
    }

    /// Whether `error` is one that can pass, which is left for the next
    /// connect; it is logged, as the caller has nothing more to do with it.
    private func passesByItself(_ error: Error, _ what: StaticString) -> Bool {
        guard ServerError.classify(error).isPassing else { return false }
        logger.info("\(what): \(error.localizedDescription, privacy: .private)")
        return true
    }

    private static let profileNodes = [NS.avatarData, NS.avatarMetadata, NS.nick]

    /// Makes every profile node's access model match the setting. The nodes
    /// are read back rather than trusted to a marker: another device or an
    /// older version may have left them either way, and a node a server
    /// refused to change is found again at the next connect. A node that
    /// doesn't exist yet is created with the right model when published.
    func applyProfileAccess() async throws {
        var firstError: Error?
        var wanted: String
        repeat {
            wanted = profileAccessModel
            let model = wanted
            let errors = await withTaskGroup(of: (Int, Error?).self) { group in
                for (index, node) in Self.profileNodes.enumerated() {
                    group.addTask {
                        do {
                            let current = try await self.pepNodeAccessModel(node)
                            if current != model { try await self.configurePEPNode(node, fields: ["pubsub#access_model": [model]]) }
                            return (index, nil)
                        } catch let error as PubSubError where error.error == .item_not_found {
                            return (index, nil)
                        } catch {
                            return (index, error)
                        }
                    }
                }
                return await group.reduce(into: [Int: Error]()) { if let error = $1.1 { $0[$1.0] = error } }
            }
            // The first in the nodes' order, as when they were read one by one.
            if firstError == nil { firstError = errors.sorted { $0.key < $1.key }.first?.value }
            // The setting changed while this ran, as another change was
            // applying: go round again, so the last word is the setting's.
        } while wanted != profileAccessModel
        if let firstError { throw firstError }
    }

    /// Runs `applyProfileAccess` on connecting and when another device changes
    /// the setting. A failure that can pass is left for the next connect, or the stream resuming; a
    /// final one is shown, with a Retry, as the user would otherwise believe
    /// their name and photo are as private as they chose.
    func reconcileProfileAccess() async {
        guard policy.syncsAccountState else { return }
        // Owed until it's applied or refused, so a stream that resumes
        // applies a change made while it was down.
        lock.withLock { _ = $0.owedOnResume.insert(.profileAccess) }
        guard isConnected else { return }
        let outcome = await warnings.attempt(
            "profile-access", title: String(localized: "Name and photo visibility not updated"),
            friendly: String(localized: "The server wouldn't change who can see your name and photo"),
            stillWanted: { true },
            passingErrors: .leave,
        ) { [self] in try await applyProfileAccess() }
        switch outcome {
        case .passed(let error):
            logger.info("Couldn't check who reads the profile: \(error.localizedDescription, privacy: .private)")
        case .posted(let error):
            lock.withLock { _ = $0.owedOnResume.remove(.profileAccess) }
            logger.error("Couldn't change who reads the profile: \(error.localizedDescription, privacy: .private)")
        case .succeeded:
            lock.withLock { _ = $0.owedOnResume.remove(.profileAccess) }
        case .abandoned, .declined:
            break
        }
    }

    public enum ProfileError: Error, LocalizedError {
        case offline
        case imageTooLarge
        /// The picture queued for sending is gone from the avatar store.
        case imageMissing
        /// The server said no; `reason` is its own condition and text.
        case refused(reason: String)

        public var errorDescription: String? {
            switch self {
            case .refused(let reason): String(localized: "The server refused it: \(reason)")
            case .offline: String(localized: "You're offline.")
            case .imageTooLarge: String(localized: "That picture is too large.")
            case .imageMissing: String(localized: "The picture is no longer on this device.")
            }
        }
    }

    /// Makes `data` our avatar. It shows at once and is kept until the server
    /// has it, so it can be set offline; see `sendOwedProfile`.
    public func publishAvatar(_ data: Data, mimeType: String, width: Int? = nil, height: Int? = nil) async throws {
        guard data.count <= AvatarStore.maxSize else { throw ProfileError.imageTooLarge }
        let hash = AvatarStore.hash(of: data)
        // The file is what gets sent later, so it has to be there first. They
        // are named by their hash, so only a failed write keeps the picture
        // from showing.
        guard avatars.save(data, hash: hash) else { throw ProfileError.imageTooLarge }
        try queueAvatar(OwedAvatarChange.Image(hash: hash, mimeType: mimeType, size: data.count, width: width, height: height))
    }

    /// Removes our avatar, by publishing empty metadata (XEP-0084 §4.2), once
    /// connected.
    public func removeAvatar() async throws {
        try queueAvatar(nil)
    }

    private func queueAvatar(_ image: OwedAvatarChange.Image?) throws {
        try database.queueAvatarChange(image, for: account)
        warnings.clear(Self.avatarWarning)
        sendOwedProfile()
    }

    /// Whether our avatar or name is waiting to be sent.
    public var avatarPending: Bool { (try? database.owedAvatarChange()) != nil }
    public var nicknamePending: Bool { (try? database.owedNicknameChange()) != nil }

    private static let avatarWarning = "profile/avatar"
    private static let nicknameWarning = "profile/nickname"

    /// Sends our avatar and name changes that the server doesn't have yet,
    /// once connected, after checking that it still has what it had when
    /// each was made: if another device changed it meanwhile, that wins and
    /// ours is dropped with a notice. A passing error leaves the change owed
    /// for the next connect, and a refusal for good puts the old value back
    /// and shows a warning with a Retry. Only the app sends. The task is
    /// returned for a caller that needs to wait for the round.
    @discardableResult
    func sendOwedProfile() -> Task<Void, Never>? {
        guard policy.syncsAccountState else { return nil }
        return coalesced(\.profileRun) { await $0.sendOwedProfileRound() }
    }

    private func sendOwedProfileRound() async {
        guard isConnected else { return }
        do {
            // Two nodes with their own warnings and owed state, so neither waits for the other.
            let avatar = try database.owedAvatarChange()
            let nickname = try database.owedNicknameChange()
            async let avatarSent: Void = {
                if let avatar { await sendOwed(avatar) }
            }()
            async let nicknameSent: Void = {
                if let nickname { await sendOwed(nickname) }
            }()
            _ = await (avatarSent, nicknameSent)
        } catch {
            logger.error("Failed to read the profile changes owed: \(error)")
        }
    }

    /// Whether a failed send is one for good, rather than one that can pass.
    private func isFinalProfileRefusal(_ error: Error) -> Bool {
        if let error = error as? ProfileError {
            if case .offline = error { return false }
            return true
        }
        return ServerError.isFinalRefusal(error)
    }

    private func sendOwed(_ owed: OwedAvatarChange) async {
        do {
            let server = try await serverAvatarId()
            // An answer that was lost after the server took the change leaves
            // it owed with the server already holding ours.
            if server != owed.image?.hash.lowercased() {
                guard !owed.baseKnown || server == owed.base?.lowercased() else {
                    avatarChangedElsewhere(owed, server: server)
                    return
                }
                try await publish(owed)
            }
            try database.settleAvatarChange(owed, serverNow: owed.image?.hash)
            settleWarning(Self.avatarWarning)
        } catch {
            logger.info("Couldn't send the avatar: \(error.localizedDescription, privacy: .private)")
            guard isFinalProfileRefusal(error) else { return }
            // Showing the avatar the server has again needs its file; without
            // it none shows until the server's is fetched.
            let shown = owed.base.flatMap { avatars.contains($0) ? $0 : nil }
            do {
                guard try database.revertAvatarChange(owed, shows: shown, for: account) else { return }
            } catch {
                logger.error("Failed to put back the avatar the server refused: \(error)")
            }
            if owed.base != nil, shown == nil { fetchAvatar(of: account) }
            let image = owed.image
            let base = AppDatabase.OwedBase(value: owed.base, known: owed.baseKnown)
            var retry: (@Sendable () async throws -> Void)?
            if !(error is ProfileError) {
                retry = { [weak self] in
                    guard let self else { return }
                    try await retryOwed(Self.avatarWarning) {
                        try database.queueAvatarChange(image, for: account, base: base)
                    } run: { sendOwedProfile() }
                }
            }
            recordRefusal(Self.avatarWarning, error)
            warnings.post(
                Self.avatarWarning, title: String(localized: "Photo not updated"),
                friendly: String(localized: "The server wouldn't change your photo"), error: error, retry: retry,
            )
        }
    }

    private func sendOwed(_ owed: OwedNicknameChange) async {
        do {
            let server = try await serverNickname()
            if server != Self.normalizedNickname(owed.value) {
                guard !owed.baseKnown || server == owed.base else {
                    nicknameChangedElsewhere(owed, server: server)
                    return
                }
                if let value = owed.value {
                    try await publishProfilePEP(node: NS.nick, itemId: Self.nicknameItemId, payload: ProfileStanza.nick(value), accessModel: profileAccessModel)
                } else {
                    try await retractNicknames()
                }
            }
            try database.settleNicknameChange(owed, serverNow: owed.value)
            settleWarning(Self.nicknameWarning)
        } catch {
            logger.info("Couldn't send the nickname: \(error.localizedDescription, privacy: .private)")
            guard isFinalProfileRefusal(error) else { return }
            do {
                guard try database.revertNicknameChange(owed, shows: owed.base) else { return }
            } catch {
                logger.error("Failed to put back the nickname the server refused: \(error)")
            }
            let value = owed.value
            let base = AppDatabase.OwedBase(value: owed.base, known: owed.baseKnown)
            recordRefusal(Self.nicknameWarning, error)
            warnings.post(
                Self.nicknameWarning, title: String(localized: "Name not updated"),
                friendly: String(localized: "The server wouldn't change your name"), error: error,
            ) { [weak self] in
                guard let self else { return }
                try await retryOwed(Self.nicknameWarning) {
                    try database.queueNicknameChange(value, base: base)
                } run: { sendOwedProfile() }
            }
        }
    }

    /// Another device changed it first: that is the one kept.
    private func avatarChangedElsewhere(_ owed: OwedAvatarChange, server: String?) {
        let shown = server.flatMap { avatars.contains($0) ? $0 : nil }
        guard (try? database.revertAvatarChange(owed, shows: shown, for: account)) == true else { return }
        if server != nil, shown == nil { fetchAvatar(of: account) }
        warnings.post(
            Self.avatarWarning, title: String(localized: "Photo not changed"),
            detail: String(localized: "Your photo was changed on another device, so the one you chose here wasn't used."),
        )
    }

    private func nicknameChangedElsewhere(_ owed: OwedNicknameChange, server: String?) {
        guard (try? database.revertNicknameChange(owed, shows: server)) == true else { return }
        warnings.post(
            Self.nicknameWarning, title: String(localized: "Name not changed"),
            detail: String(localized: "Your name was changed on another device, so the one you chose here wasn't used."),
        )
    }

    /// The id of the avatar the server has for us, lowercased; nil for none.
    private func serverAvatarId() async throws -> String? {
        switch try await readOwnNode(NS.avatarMetadata, "Avatar", limit: .lastItems(1)) {
        case .items(let page): ProfileStanza.avatarId(in: page.items.first?.payload)
        // A server that can't hold the node has none; publishing says why.
        // `readOwnNode` has already thrown a failure.
        case .noNode, .unsupported, .failed: nil
        }
    }

    /// `readNode`, with what passes retried and a failure thrown.
    private func readOwnNode(_ node: String, _ what: StaticString, limit: PubSubModule.QueryLimit = .none) async throws -> NodeRead {
        try await retryingPassingErrors {
            let read = await readNode(node, as: what, limit: limit)
            if case .failed(let error) = read { throw error }
            return read
        }
    }

    private func serverNickname() async throws -> String? {
        // The newest item, as `fetchNickname` reads it, so the base and this
        // are the same item however many others clients have left.
        switch try await readOwnNode(NS.nick, "Nickname", limit: .lastItems(1)) {
        case .items(let page): Self.normalizedNickname(page.items.first.flatMap { ProfileStanza.nick(from: $0.payload) })
        case .noNode, .unsupported, .failed: nil
        }
    }

    private func publish(_ owed: OwedAvatarChange) async throws {
        guard let image = owed.image else {
            try await publishProfilePEP(node: NS.avatarMetadata, itemId: nil, payload: ProfileStanza.avatarMetadata(nil), accessModel: profileAccessModel)
            return
        }
        guard let data = try? Data(contentsOf: avatars.url(for: image.hash)) else { throw ProfileError.imageMissing }
        // Martin's own publishAvatar sends no publish-options, leaving the
        // node at the server's default, which is readable only by contacts
        // we've approved, and it refuses anything that isn't PNG.
        try await publishProfilePEP(node: NS.avatarData, itemId: image.hash, payload: ProfileStanza.avatarData(data), accessModel: profileAccessModel)
        let info = PEPUserAvatarModule.Info(id: image.hash, size: image.size, mimeType: image.mimeType, height: image.height, width: image.width)
        try await publishProfilePEP(node: NS.avatarMetadata, itemId: image.hash, payload: ProfileStanza.avatarMetadata(info), accessModel: profileAccessModel)
    }

    /// `publishPEP` for the profile, which a screen waits on: what passes is
    /// retried, and the server's error is thrown as it came, so the screen can
    /// give its reason and a Retry. A connection that went away on the way is
    /// the not-connected error.
    private func publishProfilePEP(node: String, itemId: String?, payload: Element, accessModel: String) async throws {
        do {
            try await retryingPassingErrors {
                try await publishPEPKeepingErrors(node: node, itemId: itemId, payload: payload, accessModel: accessModel)
            }
        } catch {
            throw profileFailure(error)
        }
    }

    /// `error` as the profile calls throw it: the not-connected error when the
    /// connection dropped under a request, otherwise as it is.
    private func profileFailure(_ error: Error) -> Error {
        !isConnected && ServerError.classify(error).isPassing ? ProfileError.offline : error
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
                type: "submit", formType: NS.publishOptions,
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

    /// A node and the options a reconfiguration sets on it.
    struct NodeConfiguration: Hashable {
        let node: String
        let fields: [String: [String]]
    }

    func publishPEPItem(node: String, itemId: String?, payload: Element, options: Element?, timeout: TimeInterval?) async throws {
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
    /// Shared by the callers that ask for the same options while it is in
    /// flight: publishes sent together to a node made with other options are
    /// all refused, and each need not set it right again.
    func configurePEPNode(_ node: String, fields: [String: [String]]) async throws {
        let key = NodeConfiguration(node: node, fields: fields)
        let task = lock.withLock { state -> Task<Void, Error> in
            if let running = state.nodeReconfigurations[key] { return running }
            let started = Task { [self] in
                defer { lock.withLock { _ = $0.nodeReconfigurations.removeValue(forKey: key) } }
                _ = try await client.context.writer.write(iq: OutboundStanza.configureNode(node, fields: fields), errorDecoder: PubSubError.from(stanza:))
            }
            state.nodeReconfigurations[key] = started
            return started
        }
        try await task.value
    }
}

/// The PEP payloads and publish-options for our profile.
enum ProfileStanza {
    static func publishOptions(accessModel: String) -> Element {
        XMPPSession.dataForm(type: "submit", formType: NS.publishOptions, fields: [
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

    /// The id of the first picture a metadata item lists, lowercased; nil for
    /// the empty metadata that says there is none.
    static func avatarId(in payload: Element?) -> String? {
        payload?.firstChild(name: "info")?.attribute("id")?.lowercased()
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

    /// Makes `name` ours, or takes it back when it's blank. It shows at once
    /// and is kept until the server has it, so it can be set offline; see
    /// `sendOwedProfile`.
    public func setNickname(_ name: String?) async throws {
        try database.queueNicknameChange(Self.normalizedNickname(name))
        warnings.clear(Self.nicknameWarning)
        sendOwedProfile()
    }

    /// XEP-0172 fixes no item id, so whatever the node holds is taken back,
    /// including a name another client published under its own id. A node
    /// that isn't there has nothing to take back.
    private func retractNicknames() async throws {
        do {
            let page: PubSubModule.RetrievedItems = try await retryingPassingErrors(callback: { done in
                self.client.module(.pubsub).retrieveItems(from: self.account.martin, for: NS.nick) { done($0.mapError { $0 }) }
            })
            for item in page.items {
                do {
                    try await retryingPassingErrors { try await retractPEPItem(node: NS.nick, itemId: item.id) }
                } catch let error as PubSubError where error.error == .item_not_found {
                    // Taken back meanwhile.
                }
            }
        } catch let error as PubSubError where error.error == .item_not_found {
            // No node, so no name.
        } catch {
            throw profileFailure(error)
        }
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
        // Our name stays as it is when the read fails, and is read again at the
        // next catch-up, which is after every connect.
        readNode(NS.nick, as: "Nickname", limit: .lastItems(1)) { [weak self] read in
            guard let self else { return }
            switch read {
            case .items(let page): nicknameChanged(account, to: page.items.first.flatMap { ProfileStanza.nick(from: $0.payload) })
            case .noNode: nicknameChanged(account, to: nil)
            case .unsupported, .failed: break
            }
        }
    }

    /// `jid` published a new name, or took theirs back; ours may come from
    /// another of our devices.
    func nicknameChanged(_ jid: JID, to nickname: String?) {
        let nickname = Self.normalizedNickname(nickname)
        // A stranger's event would add a contact row for them.
        guard jid == account || (try? database.isKnownPeer(jid)) == true else { return }
        // Our own change not yet sent is what shows; once it's sent or the
        // server's wins, the sender sets the name.
        if jid == account, (try? database.owedNicknameChange()) != nil { return }
        do {
            if jid == account {
                try database.setSetting(.nickname, nickname)
                try database.markOwnNicknameRead()
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
        ValueObservation.trackingConstantRegion { db in
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

    /// Shows us away while the user isn't there, and as chosen again once
    /// they're back: on iOS while the app is suspended, as the server keeps a
    /// suspended session for pushes (XEP-0198), for days on some, and contacts
    /// would see us online all that time; on the Mac while it's idle or
    /// locked. Only while sharing last seen: it tells contacts when we go.
    public func setAway(_ away: Bool) {
        let changed = lock.withLock {
            defer { $0.isAway = away }
            return $0.isAway != away
        }
        // Called as the app leaves or returns, on the main thread, and what
        // goes out reads the database. In order, so the last one sent says
        // the latest.
        if changed { presenceQueue.async { [weak self] in self?.sendPresence() } }
    }

    /// What we send for `availability`. Only available gives way to away:
    /// do not disturb says more, and would be lost.
    static func show(for availability: Availability, away: Bool) -> Presence.Show {
        away && availability == .available ? .away : availability.show
    }

    /// Our presence, through `setPresence` so Martin adds the entity
    /// capabilities that tell the server what notifications we want. Martin
    /// keeps it and sends it again when we reconnect.
    func sendPresence() {
        // The extensions send no presence.
        guard policy.announcesPresence else { return }
        let connected = isConnected
        let away = lock.withLock {
            if connected { $0.owedOnResume.remove(.presence) } else { $0.owedOnResume.insert(.presence) }
            return $0.isAway
        }
        let show = Self.show(for: availability, away: away && sharesLastSeen)
        client.module(.presence).setPresence(show: show, status: Self.normalizedStatus(try? database.setting(.statusMessage)), priority: nil)
    }
}
