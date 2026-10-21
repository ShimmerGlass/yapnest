import Combine
import Foundation
@preconcurrency import Martin

public enum RoomAffiliation: String, Sendable, Hashable {
    case owner, admin, member, none, outcast

    /// Owners, admins and members: who belongs in a members-only room.
    public var isMember: Bool { self == .owner || self == .admin || self == .member }
}

public struct RoomOccupant: Hashable, Sendable {
    public var nick: String
    /// Their real address, if the room shows it.
    public var jid: JID?
    public var affiliation: RoomAffiliation
    /// visitor, participant or moderator.
    public var role: String
    /// XEP-0421, if the room vouches for them.
    public var occupantId: String?

    public init(nick: String, jid: JID?, affiliation: RoomAffiliation, role: String = "participant", occupantId: String? = nil) {
        self.nick = nick
        self.jid = jid
        self.affiliation = affiliation
        self.role = role
        self.occupantId = occupantId
    }
}

/// A group chat's state on the current connection.
public struct RoomStatus: Hashable, Sendable {
    public enum Phase: Hashable, Sendable {
        case joining
        case joined
        case failed(String)
    }

    public var phase: Phase
    /// Who's in the room now, by nickname.
    public var occupants: [String: RoomOccupant] = [:]
    /// Real addresses of everyone with membership, present or not, when the
    /// room lets us see them; who OMEMO messages are encrypted for.
    public var members: Set<JID> { Set(memberAffiliations.keys) }
    public var affiliation: RoomAffiliation = .none
    /// Our role there (visitor, participant or moderator).
    public var role = "participant"
    /// What the room's members are, where it says so: those not here now
    /// have no presence to tell by. Present occupants are in `occupants`.
    /// Only members are kept, so its keys are `members`.
    public private(set) var memberAffiliations: [JID: RoomAffiliation] = [:]
    /// Who is banned, as far as we know. Only admins and owners can list
    /// them, so it stays empty for the rest.
    public internal(set) var banned: Set<JID> = []
    /// The room offers moderated retraction (XEP-0425).
    public var supportsModeration = false
    /// The room lists ad-hoc commands (XEP-0050) among its features. Ask for
    /// them with `adHocCommands(at:)`.
    public var offersCommands = false
    /// Whether participants, not just moderators, may change the subject,
    /// from the room's info or its configuration; nil if the room doesn't say.
    public internal(set) var participantsMayChangeSubject: Bool?

    /// Ours there.
    public internal(set) var nickname: String
    /// Ours (XEP-0421), from our own presence, if the room vouches for them.
    var occupantId: String?
    var hasArchive = false
    /// Our join created the room, which stays locked until configured.
    var wasCreated = false
    var triedOtherNickname = false
    /// A failed room that's worth joining again: the cause was probably
    /// temporary, and nobody removed us on purpose.
    var canRetry = false
    /// Catching up on the room's archive after joining.
    public internal(set) var isSyncing = false
    /// This visit's catch-up read to the end of the room's archive, so what
    /// the room sends live continues it. A catch-up that gave up leaves a gap
    /// that moving the cursor on would hide for good.
    var catchUpReachedEnd = false
    /// Joining may create the room if it doesn't exist. Not when the user was
    /// invited: an address anyone can send us must not make a room.
    var mayCreate = true
    var joinedAt = Date()

    public var isJoined: Bool { phase == .joined }

    /// What `jid` is in the room, as far as we know.
    public func affiliation(of jid: JID) -> RoomAffiliation {
        occupants.values.first { $0.jid == jid }?.affiliation ?? memberAffiliations[jid] ?? (banned.contains(jid) ? .outcast : .none)
    }

    /// Records what `jid` is, which keeps them in `members` only if that's a
    /// membership, and in `banned` only if they are.
    public mutating func setAffiliation(_ affiliation: RoomAffiliation, of jid: JID) {
        memberAffiliations[jid] = affiliation.isMember ? affiliation : nil
        if affiliation == .outcast { banned.insert(jid) } else { banned.remove(jid) }
    }

    /// Whether `account` is the room's only owner, as far as we know. An
    /// owner nobody has told us about isn't counted, so this errs towards
    /// hiding the step down, which the room would refuse for the last one.
    public func isLastOwner(_ account: JID) -> Bool {
        let others = Set(memberAffiliations.filter { $0.value == .owner && $0.key != account }.keys)
            .union(occupants.values.filter { $0.affiliation == .owner && $0.jid != account && $0.nick != nickname }.compactMap(\.jid))
        let unnamed = occupants.values.contains { $0.affiliation == .owner && $0.jid == nil && $0.nick != nickname }
        return others.isEmpty && !unnamed
    }

    /// Owners edit the room's configuration, name and picture.
    public var canEditInfo: Bool { isJoined && affiliation == .owner }
    public var canDestroy: Bool { isJoined && affiliation == .owner }
    var isOwnerOrAdmin: Bool { affiliation == .owner || affiliation == .admin }
    /// Admins and owners may see who is banned, and unban them.
    public var canSeeBans: Bool { isJoined && isOwnerOrAdmin }
    /// Admins and owners may invite to any room, whoever the room lets in.
    public var canInvite: Bool { isJoined && isOwnerOrAdmin }
    /// Moderators always; participants if the room lets them. A room that
    /// doesn't say counts as not letting them: the room has the last word.
    public var canChangeSubject: Bool {
        isJoined && (role == "moderator" || (role == "participant" && participantsMayChangeSubject == true))
    }

    /// There is something in the group's info for us to edit: the owner's
    /// settings, or the subject.
    public var canEditAnything: Bool { canEditInfo || canChangeSubject }

    /// We may take other people's messages back.
    public var canModerateMessages: Bool { isJoined && supportsModeration && role == "moderator" }
}

public enum GroupError: Error, LocalizedError {
    case notConnected
    case noService
    case joinFailed(String)
    case timedOut
    case notPrivate
    case couldntLeave
    case notAllowed
    /// The room or its server doesn't offer what was asked.
    case unsupported
    /// The room said no, in its own words.
    case refused(String)

    public var errorDescription: String? {
        switch self {
        case .notConnected: String(localized: "You're offline.")
        case .noService: String(localized: "Your server doesn't host group chats.")
        case .joinFailed(let reason): reason
        case .timedOut: String(localized: "The group didn't respond.")
        case .couldntLeave: String(localized: "Couldn't leave the group. Try again when you're online.")
        case .notAllowed: String(localized: "You're not allowed to do that in this group.")
        case .unsupported: String(localized: "This group's server doesn't support that.")
        case .refused(let reason): String(localized: "The group refused it: \(reason)")
        case .notPrivate: String(localized: "Only private groups, where members see each other's addresses, can be encrypted.")
        }
    }
}

/// Delivers group chat messages (type groupchat), which Martin's
/// `MessageModule` leaves alone. Martin's `MucModule` is not used: rooms
/// live in our database, and their state in the session.
final class RoomsModule: XmppModuleBase, XmppModule, @unchecked Sendable {
    static let ID = "yapnest-rooms"
    static let IDENTIFIER = XmppModuleIdentifier<RoomsModule>()

    let criteria = Criteria.name("message", types: [.groupchat], containsAttribute: "from")
    /// Group chat support and XEP-0249 direct invitations.
    let features = [NS.muc, NS.conference]
    let messages = PassthroughSubject<Martin.Message, Never>()

    func process(stanza: Stanza) throws {
        if let message = stanza as? Martin.Message { messages.send(message) }
    }
}

/// XEP-0402 bookmarks: the rooms we're in, shared with our other clients.
final class BookmarksModule: AbstractPEPModule, XmppModule, @unchecked Sendable {
    static let ID = NS.bookmarks
    static let IDENTIFIER = XmppModuleIdentifier<BookmarksModule>()

    enum Change {
        case published(Bookmark)
        case retracted(JID)
    }

    let criteria = Criteria.empty()
    let features = [NS.bookmarks + "+notify"]
    let changes = PassthroughSubject<Change, Never>()

    func process(stanza: Stanza) throws {
        throw XMPPError.feature_not_implemented
    }

    override func onItemNotification(notification: PubSubModule.ItemNotification) {
        guard notification.node == NS.bookmarks, let context,
              notification.message.from == nil || notification.message.from?.bareJid == context.userBareJid else { return }
        switch notification.action {
        case .published(let item):
            if let bookmark = Bookmark(id: item.id, payload: item.payload) { changes.send(.published(bookmark)) }
        case .retracted(let id):
            if let jid = JID(id) { changes.send(.retracted(jid)) }
        }
    }
}

struct Bookmark: Sendable {
    var jid: JID
    var name: String?
    var autojoin: Bool
    var nick: String?
    /// XEP-0492, in the bookmark's extensions; absent means always.
    var notify: GroupChat.Notify

    init(jid: JID, name: String?, autojoin: Bool, nick: String?, notify: GroupChat.Notify = .always) {
        self.jid = jid
        self.name = name
        self.autojoin = autojoin
        self.nick = nick
        self.notify = notify
    }

    init?(id: String, payload: Element?) {
        guard let jid = JID(id), let conference = payload, conference.name == "conference", conference.xmlns == NS.bookmarks else { return nil }
        self.jid = jid
        (self.name, self.autojoin, self.nick) = Self.conferenceFields(conference)
        self.notify = conference.firstChild(name: "extensions")?.firstChild(name: "notify", xmlns: NS.notificationSettings)
            .flatMap(Self.notify(in:)) ?? .always
    }

    /// The fields XEP-0048 and XEP-0402 write alike.
    static func conferenceFields(_ conference: Element) -> (name: String?, autojoin: Bool, nick: String?) {
        (conference.getAttribute("name"), ["true", "1"].contains(conference.getAttribute("autojoin")), conference.firstChild(name: "nick")?.value)
    }

    func addConferenceFields(to conference: Element) {
        if let name { conference.setAttribute("name", value: name) }
        conference.setAttribute("autojoin", value: autojoin ? "true" : "false")
        if let nick { conference.addChild(Element(name: "nick", cdata: nick)) }
    }

    /// The setting that applies to us: one for phones, then for clients,
    /// then for everyone.
    private static func notify(in element: Element) -> GroupChat.Notify? {
        let settings = element.children.compactMap { child -> (GroupChat.Notify, category: String?, type: String?)? in
            guard let value = GroupChat.Notify(rawValue: child.name) else { return nil }
            return (value, child.getAttribute("identity-category"), child.getAttribute("identity-type"))
        }
        let ranked: [(String?, String?)] = [("client", "phone"), ("client", nil), (nil, nil)]
        return ranked.lazy.compactMap { category, type in
            settings.first { $0.category == category && $0.type == type }?.0
        }.first
    }

    var element: Element {
        let conference = Element(name: "conference", xmlns: NS.bookmarks)
        addConferenceFields(to: conference)
        if notify != .always {
            let notify = Element(name: "notify", xmlns: NS.notificationSettings)
            notify.addChild(Element(name: self.notify.rawValue))
            let extensions = Element(name: "extensions")
            extensions.addChild(notify)
            conference.addChild(extensions)
        }
        return conference
    }
}

extension XMPPSession {
    /// Our nickname in groups we join, unless the room or a bookmark says otherwise.
    var defaultNickname: String { account.shortName }

    func isGroup(_ jid: JID) -> Bool {
        lock.withLock { $0.knownRooms.contains(jid) }
    }

    func reloadKnownRooms() {
        let rooms = Set(((try? database.groupChats()) ?? []).map(\.jid))
        lock.withLock { $0.knownRooms = rooms }
    }

    public func roomStatus(_ jid: JID) -> RoomStatus? {
        lock.withLock { $0.rooms[jid] }
    }

    /// The room's status while we're connected and in it, for what only
    /// works there.
    func joinedStatus(_ room: JID) throws -> RoomStatus {
        guard isConnected, let status = roomStatus(room), status.isJoined else { throw GroupError.notConnected }
        return status
    }

    /// Changes one room's live state and publishes the result.
    @discardableResult
    func updateRoom(_ jid: JID, _ change: (inout RoomStatus?) -> Void) -> RoomStatus? {
        publish(rooms, under: roomsPublishLock) { state in
            let before = state.rooms[jid]
            var room = before
            change(&room)
            state.rooms[jid] = room
            return (room, room == before ? nil : state.rooms)
        }
    }

    func clearRooms() {
        cancelAllRejoins()
        publish(rooms, under: roomsPublishLock) { state in
            state.rooms = [:]
            return ((), rooms.value.isEmpty ? nil : [:])
        }
    }

    // MARK: Joining

    /// Rejoins every group we're in, after a new session's catch-up.
    func joinRooms() {
        let groups = (try? database.groupChats()) ?? []
        let rooms = Set(groups.map(\.jid))
        lock.withLock { $0.knownRooms = rooms }
        for group in groups where !group.hasLeft {
            join(group.jid, nickname: group.nickname)
        }
    }

    /// Looks the room up, then enters it. Its archive replaces the history
    /// the room would replay on join.
    func join(_ room: JID, nickname: String, discover: Bool = true, mayCreate: Bool = true) {
        guard isConnected else { return }
        var started = false
        updateRoom(room) { status in
            if status?.phase == .joining || status?.phase == .joined { return }
            status = RoomStatus(phase: .joining, nickname: nickname, mayCreate: mayCreate)
            started = true
        }
        guard started else { return }
        cancelRejoin(room)
        guard discover else {
            sendJoin(room, nickname: nickname, hasArchive: false)
            return
        }
        var missing: (@Sendable () -> Void)?
        if !mayCreate {
            missing = { [weak self] in
                self?.updateRoom(room) {
                    $0?.phase = .failed(String(localized: "This group doesn't exist."))
                    $0?.canRetry = false
                }
            }
        }
        refreshRoomInfo(room, then: { [weak self] hasArchive in
            self?.sendJoin(room, nickname: nickname, hasArchive: hasArchive)
        }, missing: missing)
    }

    /// Rooms a drop left joining: the answers they waited for died with the
    /// stream, and `join` won't start one again.
    static func stuckJoins(_ rooms: [JID: RoomStatus]) -> [JID] {
        rooms.filter { $0.value.phase == .joining }.keys.sorted()
    }

    /// On a resumed stream, joins again the rooms the drop left joining.
    func rejoinStuckRooms() {
        let rooms = lock.withLock { $0.rooms }
        for room in Self.stuckJoins(rooms) {
            guard let status = rooms[room] else { continue }
            updateRoom(room) { $0 = nil }
            join(room, nickname: status.nickname, mayCreate: status.mayCreate)
        }
    }

    private func sendJoin(_ room: JID, nickname: String, hasArchive: Bool) {
        updateRoom(room) { $0?.hasArchive = hasArchive }
        let presence = Presence()
        presence.to = room.martin.with(resource: nickname)
        let x = Element(name: "x", xmlns: NS.muc)
        let history = Element(name: "history")
        if hasArchive || !policy.readsRoomHistory {
            // Rooms with an archive are read through it; the share extension only writes.
            history.setAttribute("maxstanzas", value: "0")
        } else if let last = try? database.lastMessageDate(in: room) {
            history.setAttribute("since", value: ISO8601DateFormatter().string(from: last))
        } else {
            history.setAttribute("maxstanzas", value: "50")
        }
        x.addChild(history)
        presence.addChild(x)
        write(presence)
    }

    /// Asks the room what it is (name, privacy, archive) and stores it.
    /// `missing` stands in for `then` when the room can't be looked up: without
    /// it the room is taken to be new, as joining creates it.
    func refreshRoomInfo(_ room: JID, then: (@Sendable (_ hasArchive: Bool) -> Void)? = nil, missing: (@Sendable () -> Void)? = nil) {
        client.module(.disco).getInfo(for: Martin.JID(room.martin), completionHandler: { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let info):
                let features = Set(info.features)
                let name = info.identities.first { $0.category == "conference" }?.name
                let before = try? self.database.groupChat(room)
                try? self.database.setRoomInfo(
                    room, name: name,
                    isMembersOnly: features.contains("muc_membersonly"),
                    isNonAnonymous: features.contains("muc_nonanonymous"),
                    hasOccupantIds: features.contains(NS.occupantId),
                )
                // Prosody calls it roominfo, ejabberd keeps the configuration's name.
                let participantsMayChangeSubject = ["muc#roominfo_changesubject", "muc#roomconfig_changesubject"].lazy
                    .compactMap { Self.formValues($0, in: info.form?.element) }.first.flatMap { Self.formBool($0.first) }
                self.updateRoom(room) {
                    $0?.supportsModeration = features.contains(NS.moderation)
                    $0?.offersCommands = features.contains(NS.commands)
                    if let participantsMayChangeSubject { $0?.participantsMayChangeSubject = participantsMayChangeSubject }
                }
                self.roomAvatarAnnounced(room, form: info.form)
                self.roomInfoChanged(room, from: before)
                then?(features.contains("urn:xmpp:mam:2"))
            case .failure:
                // A room that doesn't exist yet is created by joining it.
                if let missing { missing() } else { then?(false) }
            }
        })
    }

    @discardableResult
    func refreshedRoomInfo(_ room: JID) async -> Bool {
        await withCheckedContinuation { continuation in
            refreshRoomInfo(room, then: { continuation.resume(returning: $0) }, missing: { continuation.resume(returning: false) })
        }
    }

    /// What a change to the room, by us or by another owner, leaves for us to
    /// catch up on once its info is read again. Joining does its own, so only
    /// a room we are already in is looked at.
    private func roomInfoChanged(_ room: JID, from before: GroupChat?) {
        guard roomStatus(room)?.isJoined == true, let group = try? database.groupChat(room) else { return }
        // Members are only listed on joining, and a room that has just
        // started showing addresses has nobody listed to encrypt for.
        if group.isNonAnonymous, before?.isNonAnonymous != true { fetchMembers(room, lists: Self.memberLists) }
        // Our bookmark carries the name too, and would put the old one back.
        if group.name != before?.name, group.isBookmarked, !group.hasLeft { publishBookmark(group) }
    }

    /// XEP-0486: the room's info form carries the hash of its picture, which
    /// is kept like a contact's, under the room's address.
    private func roomAvatarAnnounced(_ room: JID, form: JabberDataElement?) {
        guard let hash = Self.formValues("muc#roominfo_avatarhash", in: form?.element)?.first?.lowercased(), !hash.isEmpty else {
            if form != nil, (try? database.contact(room))??.avatarHash != nil { try? database.setAvatarHash(nil, for: room) }
            return
        }
        vCardAvatarAnnounced(room, hash: hash)
    }

    func roomPresence(_ presence: Presence, room: JID) {
        let nick = presence.from?.resource
        let x = presence.firstChild(name: "x", xmlns: NS.mucUser)
        let item = x?.firstChild(name: "item")
        let statuses = Set(x?.filterChildren(name: "status", xmlns: nil).compactMap { $0.getAttribute("code").flatMap(Int.init) } ?? [])
        guard let status = roomStatus(room) else { return }

        if presence.type == .error {
            guard status.phase == .joining || nick == status.nickname else { return }
            joinFailed(room, presence: presence, status: status)
            return
        }
        guard let nick else { return }
        let isSelf = statuses.contains(110) || (status.phase == .joining && nick == status.nickname)

        if presence.type == .unavailable {
            // The room tells every occupant of its end, and servers leave out
            // the status that says it is about us. Only the presence under
            // our own nickname is the room's alone: another occupant could
            // put a destroy in theirs, and this drops the bookmark everywhere.
            if isSelf || nick == status.nickname, x?.firstChild(name: "destroy") != nil {
                groupDestroyed(room)
                return
            }
            if isSelf, !statuses.contains(303) {
                removedFromRoom(room, presence: presence, statuses: statuses)
                return
            }
            updateRoom(room) { status in
                let occupant = status?.occupants.removeValue(forKey: nick)
                // Taken out of the room for good: 301 banned, 321 and 322 no
                // longer a member. A kick or a plain leave keeps membership.
                if !statuses.isDisjoint(with: [301, 321, 322]), let jid = item?.getAttribute("jid").flatMap(JID.init(_:)) {
                    status?.setAffiliation(statuses.contains(301) ? .outcast : .none, of: jid)
                }
                if statuses.contains(303), let newNick = item?.getAttribute("nick"), var occupant {
                    occupant.nick = newNick
                    status?.occupants[newNick] = occupant
                    if isSelf { status?.nickname = newNick }
                }
            }
            return
        }

        let claimedId = InboundMessage.occupantId(in: presence.element)
        let trustsOccupantIds = claimedId != nil && ((try? database.groupChat(room))??.hasOccupantIds ?? false)
        let occupant = RoomOccupant(
            nick: nick,
            jid: item?.getAttribute("jid").flatMap(JID.init(_:)),
            affiliation: item?.getAttribute("affiliation").flatMap(RoomAffiliation.init) ?? .none,
            role: item?.getAttribute("role") ?? "participant",
            occupantId: trustsOccupantIds ? claimedId : nil,
        )
        let joinedNow = updateRoom(room) { status in
            status?.occupants[nick] = occupant
            if let jid = occupant.jid { status?.setAffiliation(occupant.affiliation, of: jid) }
            guard isSelf else { return }
            status?.affiliation = occupant.affiliation
            status?.role = occupant.role
            status?.nickname = nick
            status?.occupantId = occupant.occupantId
            if statuses.contains(201) { status?.wasCreated = true }
            if status?.phase != .joined {
                status?.phase = .joined
                status?.canRetry = false
                status?.joinedAt = Date()
                status?.isSyncing = true
            }
        }
        guard isSelf else { return }
        if statuses.contains(210) || nick != status.nickname {
            // The room picked our nickname.
            try? database.updateGroupChat(room) { $0.nickname = nick }
        }
        if status.phase != .joined, joinedNow?.isJoined == true {
            cancelRejoin(room, resettingBackoff: true)
            didJoin(room)
        }
    }

    /// What a self-ping says about our place in a room (XEP-0410).
    enum SelfPingResult: Equatable {
        case joined
        case notJoined
        /// The room or its server didn't answer; try again later.
        case unknown
    }

    static func selfPingResult(_ result: Result<Void, ErrorCondition>) -> SelfPingResult {
        switch result {
        case .success:
            .joined
        // Our own client answered, without ping support, or the room
        // routed it to us under a nickname that just changed.
        case .failure(.service_unavailable), .failure(.feature_not_implemented), .failure(.item_not_found):
            .joined
        case .failure(.remote_server_not_found), .failure(.remote_server_timeout):
            .unknown
        case .failure:
            .notJoined
        }
    }

    /// Checks we're still in each room we think we're in, and rejoins
    /// those that dropped us. A room that restarted, or a connection that
    /// resumed after a while, can leave us out without telling us.
    func selfPingRooms() {
        guard isConnected, policy.checksRoomMembership else { return }
        retryFailedRooms()
        let joined = lock.withLock { $0.rooms.filter { $0.value.isJoined }.mapValues(\.nickname) }
        for (room, nickname) in joined {
            client.module(.ping).ping(room.martin.with(resource: nickname), timeout: 30) { [weak self] result in
                guard let self, Self.selfPingResult(result) == .notJoined,
                      self.roomStatus(room)?.isJoined == true, self.roomStatus(room)?.nickname == nickname else { return }
                self.logger.info("No longer in \(room, privacy: .private); joining again")
                self.updateRoom(room) { $0 = nil }
                self.join(room, nickname: (try? self.database.groupChat(room))??.nickname ?? nickname)
            }
        }
    }

    // MARK: Rejoining

    /// Join errors that a later try can fix. A join error with no
    /// recognizable condition counts, as the room may only have hiccuped.
    static func isRetryable(joinCondition condition: String?) -> Bool {
        guard let condition else { return true }
        return ["remote-server-timeout", "remote-server-not-found", "internal-server-error", "resource-constraint"].contains(condition)
    }

    /// Only a restart of the room's service (332) is temporary. A kick (307)
    /// is a moderator's decision, so coming straight back would be rude.
    static func isRetryable(removalStatuses statuses: Set<Int>) -> Bool {
        statuses.contains(332)
    }

    /// Seconds to wait before the `attempt`th (from 0) automatic rejoin.
    static func rejoinDelay(attempt: Int) -> TimeInterval {
        let steps: [TimeInterval] = [5, 15, 60]
        return attempt < steps.count ? steps[attempt] : 300
    }

    /// Joins `room` again in a while, if it's still failed by then.
    func scheduleRejoin(_ room: JID) {
        let (attempt, previous) = lock.withLock { state in
            let attempt = state.rejoinAttempts[room] ?? 0
            state.rejoinAttempts[room] = attempt + 1
            return (attempt, state.rejoinTasks[room])
        }
        previous?.cancel()
        let delay = Self.rejoinDelay(attempt: attempt)
        let task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.rejoinFailed(room)
        }
        lock.withLock { $0.rejoinTasks[room] = task }
    }

    /// Stops a scheduled rejoin, and forgets the backoff once the room works.
    func cancelRejoin(_ room: JID, resettingBackoff: Bool = false) {
        let task = lock.withLock { state in
            if resettingBackoff { state.rejoinAttempts[room] = nil }
            return state.rejoinTasks.removeValue(forKey: room)
        }
        task?.cancel()
    }

    func cancelAllRejoins() {
        let tasks = lock.withLock { state in
            defer { state.rejoinTasks = [:]; state.rejoinAttempts = [:] }
            return Array(state.rejoinTasks.values)
        }
        tasks.forEach { $0.cancel() }
    }

    /// Whether a rejoin is waiting for `room`.
    func hasScheduledRejoin(_ room: JID) -> Bool {
        lock.withLock { $0.rejoinTasks[room] != nil }
    }

    /// Joins the failed rooms whose failure was temporary, for when we're
    /// back from a while away.
    private func retryFailedRooms() {
        let failed = lock.withLock { state in
            state.rooms.filter { if case .failed = $0.value.phase { $0.value.canRetry } else { false } }.keys
        }
        for room in failed {
            cancelRejoin(room, resettingBackoff: true)
            rejoinFailed(room)
        }
    }

    private func rejoinFailed(_ room: JID) {
        guard isConnected, let status = roomStatus(room), case .failed = status.phase, status.canRetry,
              let group = try? database.groupChat(room), !group.hasLeft else { return }
        logger.info("Joining \(room, privacy: .private) again")
        lock.withLock { _ = $0.rejoinTasks.removeValue(forKey: room) }
        updateRoom(room) { $0 = nil }
        join(room, nickname: group.nickname)
    }

    private static func errorCondition(of stanza: Stanza) -> String? {
        stanza.firstChild(name: "error")?.children.first { $0.xmlns == "urn:ietf:params:xml:ns:xmpp-stanzas" && $0.name != "text" }?.name
    }

    private func joinFailed(_ room: JID, presence: Presence, status: RoomStatus) {
        let condition = Self.errorCondition(of: presence)
        if condition == "conflict", !status.triedOtherNickname {
            // Someone has our nickname; try once with a variant.
            let nickname = status.nickname + "_"
            // The status stays, so what the room lookup learned before the
            // first join is not asked again; only what a join sets is reset.
            updateRoom(room) {
                $0?.phase = .joining
                $0?.nickname = nickname
                $0?.triedOtherNickname = true
                $0?.occupants = [:]
                $0?.occupantId = nil
                $0?.affiliation = .none
                $0?.role = "participant"
                $0?.wasCreated = false
                $0?.canRetry = false
                $0?.isSyncing = false
                $0?.catchUpReachedEnd = false
                $0?.joinedAt = Date()
            }
            sendJoin(room, nickname: nickname, hasArchive: status.hasArchive)
            return
        }
        let reason = switch condition {
        case "registration-required": String(localized: "Only members can join this group.")
        case "forbidden": String(localized: "You're banned from this group.")
        case "not-authorized": String(localized: "This group needs a password.")
        case "conflict": String(localized: "Your nickname is taken in this group.")
        case "service-unavailable": String(localized: "This group is full.")
        case "item-not-found": String(localized: "This group doesn't exist or is locked.")
        case "not-allowed": String(localized: "You're not allowed to create this group.")
        default: String(localized: "Couldn't join the group.")
        }
        logger.warning("Joining \(room, privacy: .private) failed: \(condition ?? "?", privacy: .private)")
        let retryable = Self.isRetryable(joinCondition: condition)
        updateRoom(room) {
            $0?.phase = .failed(reason)
            $0?.canRetry = retryable
        }
        if retryable { scheduleRejoin(room) }
    }

    /// We're out: kicked, banned, removed as a member or the room restarts.
    private func removedFromRoom(_ room: JID, presence: Presence, statuses: Set<Int>) {
        let reason = if statuses.contains(301) {
            String(localized: "You were banned from this group.")
        } else if statuses.contains(321) || statuses.contains(322) {
            String(localized: "You were removed from this group.")
        } else if statuses.contains(307) {
            String(localized: "You were removed from this group for now.")
        } else if statuses.contains(332) {
            String(localized: "The group's server is restarting.")
        } else {
            String(localized: "You're no longer in this group.")
        }
        let retryable = Self.isRetryable(removalStatuses: statuses)
        updateRoom(room) {
            $0?.phase = .failed(reason)
            $0?.canRetry = retryable
        }
        if retryable { scheduleRejoin(room) }
        // Kicks and restarts end this visit; the rest end membership.
        if statuses.contains(301) || statuses.contains(321) || statuses.contains(322) {
            try? database.updateGroupChat(room) { $0.hasLeft = true }
            retractBookmark(room)
        }
    }

    /// The room is gone for good, whether the room said so or we asked for
    /// it: we're out, and the bookmark goes. The room's own notice can arrive
    /// before the answer to our request, or after, so doing it twice is fine.
    func groupDestroyed(_ room: JID) {
        guard (try? database.groupChat(room))?.hasLeft != true else { return }
        updateRoom(room) {
            $0?.phase = .failed(String(localized: "This group was deleted."))
            $0?.canRetry = false
        }
        cancelRejoin(room, resettingBackoff: true)
        try? database.updateGroupChat(room) { $0.hasLeft = true }
        retractBookmark(room)
    }

    private func didJoin(_ room: JID) {
        guard let group = try? database.groupChat(room) else { return }
        if policy.readsRoomHistory {
            didJoinToRead(group)
        } else {
            didJoinToWrite(group)
        }
    }

    private func didJoinToRead(_ group: GroupChat) {
        let lists = Self.listsToFetch(isNonAnonymous: group.isNonAnonymous, isOwnerOrAdmin: roomStatus(group.jid)?.isOwnerOrAdmin ?? false)
        if !lists.isEmpty { fetchMembers(group.jid, lists: lists) }
        catchUpRoom(group)
    }

    /// Nothing to read, but the members are who we encrypt for.
    private func didJoinToWrite(_ group: GroupChat) {
        let room = group.jid
        let attempt = lock.withLock { $0.attempt }
        let ready: @Sendable () -> Void = { [weak self] in
            // The member requests fail when the stream drops, which leaves
            // the room unsynced rather than ready.
            guard let self, self.isConnected, self.lock.withLock({ $0.attempt }) == attempt else { return }
            self.updateRoom(room) { $0?.isSyncing = false }
            self.sendDeferred(in: room)
        }
        if group.isNonAnonymous { fetchMembers(room, lists: Self.memberLists, then: ready) } else { ready() }
    }

    static let memberLists: [RoomAffiliation] = [.owner, .admin, .member]

    /// Which lists to ask a room for. Members are who we encrypt for, which
    /// only a room that shows addresses lets us do; bans are for those who
    /// can lift them, and show addresses to them in any room.
    static func listsToFetch(isNonAnonymous: Bool, isOwnerOrAdmin: Bool) -> [RoomAffiliation] {
        (isNonAnonymous ? memberLists : []) + (isOwnerOrAdmin ? [.outcast] : [])
    }

    /// Members not present right now still need to read what we encrypt.
    /// Not every room lets members see the list; occupants' addresses still
    /// count when it doesn't.
    func fetchMembers(_ room: JID, lists: [RoomAffiliation], then done: (@Sendable () -> Void)? = nil) {
        let pending = DispatchGroup()
        defer { if let done { pending.notify(queue: .global(), execute: done) } }
        for affiliation in lists {
            pending.enter()
            client.context.writer.write(OutboundStanza.affiliationList(affiliation, of: room)) { [weak self] result in
                defer { pending.leave() }
                guard case .success(let response) = result else { return }
                self?.listReceived(affiliation, in: room, response)
            }
        }
    }

    func listReceived(_ affiliation: RoomAffiliation, in room: JID, _ response: Iq) {
        let jids = response.firstChild(name: "query", xmlns: NS.mucAdmin)?.filterChildren(name: "item", xmlns: nil)
            .compactMap { $0.getAttribute("jid").flatMap(JID.init(_:)) } ?? []
        updateRoom(room) { status in
            // The whole ban list is in the answer, so who isn't in it was unbanned.
            if affiliation == .outcast { status?.banned = [] }
            for jid in jids { status?.setAffiliation(affiliation, of: jid) }
        }
    }

    // MARK: Room archive

    /// Which visit to a room, on which connection, a catch-up belongs to.
    /// A rejoin starts a new visit with its own catch-up.
    struct RoomCatchUp: Sendable {
        var attempt: Int
        var joinedAt: Date
    }

    private func catchUpRoom(_ group: GroupChat) {
        guard let joinedAt = roomStatus(group.jid)?.joinedAt else { return }
        updateRoom(group.jid) { $0?.catchUpReachedEnd = false }
        let visit = RoomCatchUp(attempt: lock.withLock { $0.attempt }, joinedAt: joinedAt)
        guard roomStatus(group.jid)?.hasArchive == true else {
            // Nothing is archived, so there's nothing to fall behind.
            finishRoomCatchUp(group.jid, visit, reachedEnd: true)
            return
        }
        omemo.module.mamSyncStarted(for: group.jid.martin)
        if let after = group.lastArchiveId {
            fetchRoomArchivePage(group.jid, rsm: RSM.Query(after: after, max: 100), visit)
        } else {
            // Somewhere to start from for a group new to this device.
            fetchRoomArchivePage(group.jid, rsm: RSM.Query(lastItems: 50), visit, onePage: true)
        }
    }

    /// Whether a room's catch-up may go on. One the connection dropped under
    /// stays unfinished, and is marked so a resumed stream starts it again.
    private func roomCatchUpMayProceed(_ room: JID, _ visit: RoomCatchUp) -> Bool {
        guard let status = roomStatus(room), status.isJoined, status.joinedAt == visit.joinedAt else { return false }
        let outcome = Self.catchUpOutcome(isConnected: isConnected, startedOn: visit.attempt, now: lock.withLock { $0.attempt })
        if outcome == .interrupted { lock.withLock { _ = $0.interruptedRooms.insert(room) } }
        return outcome == .proceed
    }

    /// On a resumed stream, starts again the room catch-ups the drop cut off.
    /// The room's presence survived the resume, so there's no need to rejoin.
    func resumeInterruptedRoomCatchUps() {
        let rooms = lock.withLock { state in
            defer { state.interruptedRooms = [] }
            return state.interruptedRooms
        }
        for room in rooms.sorted() where roomStatus(room)?.isJoined == true && roomStatus(room)?.isSyncing == true {
            // Restarts the visit's own work, from the stored cursor, and
            // gives it a new connection to belong to.
            didJoin(room)
        }
    }

    private func fetchRoomArchivePage(_ room: JID, rsm: RSM.Query, _ visit: RoomCatchUp, onePage: Bool = false) {
        // The room's archive, which discovery found speaks MAM 2.
        let queryId = UUID().uuidString
        client.module(.mam).queryItems(version: .MAM2, componentJid: Martin.JID(room.martin), queryId: queryId, rsm: rsm) { [weak self] result in
            guard let self else { return }
            let stored = self.flushArchive(query: queryId)
            guard self.roomCatchUpMayProceed(room, visit) else { return }
            switch result {
            case .success where !stored:
                // Going on would move the cursor past the page that was lost.
                self.finishRoomCatchUp(room, visit, reachedEnd: false)
            case .success(let page):
                if let last = page.rsm?.last {
                    try? self.database.updateGroupChat(room) { $0.lastArchiveId = last }
                }
                if onePage || page.complete || page.rsm?.last == nil {
                    self.finishRoomCatchUp(room, visit, reachedEnd: true)
                } else {
                    self.fetchRoomArchivePage(room, rsm: RSM.Query(after: page.rsm?.last, max: 100), visit)
                }
            case .failure(.item_not_found):
                try? self.database.updateGroupChat(room) { $0.lastArchiveId = nil }
                self.fetchRoomArchivePage(room, rsm: RSM.Query(lastItems: 50), visit, onePage: true)
            case .failure(let error):
                self.logger.error("Archive sync of \(room, privacy: .private) failed: \(error)")
                self.finishRoomCatchUp(room, visit, reachedEnd: false)
            }
        }
    }

    /// For the notification extension: what arrived in our groups since we
    /// last caught up, from their archives, without joining. Members of a
    /// private group may read its archive; a few pages are enough to notify.
    func catchUpRoomArchives(then done: @escaping @Sendable () -> Void) {
        let pending = DispatchGroup()
        let groups = ((try? database.groupChats()) ?? []).filter { !$0.hasLeft }
        // A room with nothing archived yet: from when it last had news
        // here, if ever. A new conversation's placeholder date isn't one,
        // and ejabberd refuses it.
        let lastActivities = (try? database.reader.read { db in
            groups.map { group in group.lastArchiveId == nil ? (try? Conversation.fetchOne(db, key: group.conversationId))?.lastActivityAt : nil }
        }) ?? Array(repeating: nil, count: groups.count)
        for (group, lastActivity) in zip(groups, lastActivities) {
            let since = lastActivity.flatMap { $0 > .distantPast ? $0 : nil }
            pending.enter()
            fetchRoomArchiveForNotifications(group.jid, after: group.lastArchiveId, since: since, pagesLeft: 3) { pending.leave() }
        }
        pending.notify(queue: .global(), execute: done)
    }

    /// Which page of a room's archive the notification extension reads.
    enum NotificationPage: Equatable {
        /// The newest messages, for a room never read here.
        case newest
        case after(String)
        /// Forward from a date, so a busy room's earlier messages aren't skipped.
        case forward

        var query: RSM.Query {
            switch self {
            case .newest: RSM.Query(lastItems: 50)
            case .after(let id): RSM.Query(after: id, max: 50)
            case .forward: RSM.Query(max: 50)
            }
        }
    }

    static func notificationPage(after: String?, since: Date?) -> NotificationPage {
        if let after { return .after(after) }
        return since == nil ? .newest : .forward
    }

    private func fetchRoomArchiveForNotifications(_ room: JID, after: String?, since: Date?, pagesLeft: Int, done: @escaping @Sendable () -> Void) {
        omemo.module.mamSyncStarted(for: room.martin)
        // Without a cursor or a date the newest page, as the app reads on
        // joining; from the start it would be the room's oldest messages.
        let rsm = Self.notificationPage(after: after, since: since).query
        let queryId = UUID().uuidString
        client.module(.mam).queryItems(
            version: .MAM2, componentJid: Martin.JID(room.martin), start: since, queryId: queryId, rsm: rsm,
        ) { [weak self] result in
            guard let self else { return done() }
            let stored = self.flushArchive(query: queryId)
            self.omemo.module.mamSyncFinished(for: room.martin)
            guard stored, case .success(let page) = result, let last = page.rsm?.last else {
                if case .failure(let error) = result {
                    self.logger.info("Couldn't read the archive of \(room, privacy: .private): \(error)")
                }
                return done()
            }
            try? self.database.updateGroupChat(room) { $0.lastArchiveId = last }
            if page.complete || pagesLeft <= 1 {
                done()
            } else {
                self.fetchRoomArchiveForNotifications(room, after: last, since: nil, pagesLeft: pagesLeft - 1, done: done)
            }
        }
    }

    /// What to send into a room after its catch-up: the never-sent messages
    /// first, then those sent before this visit that didn't come back.
    ///
    /// Without an archive nothing says what was lost: a room that keeps none
    /// doesn't stamp its echoes either, so sent messages would look
    /// unconfirmed for good and go out again on every visit.
    static func roomResends(hasArchive: Bool, unconfirmed: [Message], pending: [Message]) -> [Message] {
        guard hasArchive else { return pending }
        return pending.filter { message in !unconfirmed.contains { $0.id == message.id } } + unconfirmed
    }

    /// Sends what never reached the room: it echoes every message it gets,
    /// so anything sent before this visit that didn't come back was lost.
    private func finishRoomCatchUp(_ room: JID, _ visit: RoomCatchUp, reachedEnd: Bool) {
        flushArchive()
        // Not while the stream is down: the room stays syncing, and what
        // waited for it stays queued, until a catch-up on a live one ends.
        guard roomCatchUpMayProceed(room, visit) else { return }
        lock.withLock { _ = $0.interruptedRooms.remove(room) }
        omemo.module.mamSyncFinished(for: room.martin)
        // Our other devices' read state (XEP-0490) can arrive before the
        // history it points into, on a device new to the group.
        if let stanzaId = lock.withLock({ $0.publishedDisplayed[room] }) {
            _ = try? database.applyDisplayed(peer: room, stanzaId: stanzaId)
        }
        let synced = updateRoom(room) {
            $0?.isSyncing = false
            $0?.catchUpReachedEnd = reachedEnd
        }
        sendDeferred(in: room)
        guard let status = synced,
              let group = try? database.groupChat(room) else { return }
        let unconfirmed = (try? database.unconfirmedOutgoing(
            conversationId: group.conversationId, before: status.joinedAt, since: status.joinedAt.addingTimeInterval(-Self.initialSyncWindow),
        )) ?? []
        let pending = (try? database.pendingOutgoing(conversationId: group.conversationId)) ?? []
        for message in Self.roomResends(hasArchive: status.hasArchive, unconfirmed: unconfirmed, pending: pending) { transmit(message, to: room, resend: true) }
    }

    // MARK: Messages

    func handleRoomStanza(_ stanza: Martin.Message, source: InboundMessage.Source, isHistory: Bool = false, query: String = "") {
        guard let room = stanza.from.flatMap({ JID($0) }), let group = try? database.groupChat(room) else { return }
        reportSubjectOutcome(of: stanza, in: room)
        if stanza.type == .groupchat, stanza.from?.resource == nil {
            // The room itself: status code 104 announces a configuration change.
            let codes = stanza.firstChild(name: "x", xmlns: NS.mucUser)?.filterChildren(name: "status", xmlns: nil).compactMap { $0.getAttribute("code") } ?? []
            if codes.contains("104") { refreshRoomInfo(room) }
            if let target = Self.moderatedRetraction(in: stanza) {
                // Only the room itself can speak for its moderators: its
                // bare address, which no occupant's stanza can carry.
                do {
                    if let attachment = try database.applyModeratedRetraction(in: room, target: target) { attachments.remove(attachment) }
                } catch {
                    logger.error("Failed to apply a moderated retraction: \(error)")
                }
                return
            }
            // A replayed notice is old news: applied, it could make a banned
            // user a member again.
            if source == .live, !isHistory, !Self.isDelayed(stanza) { affiliationChanged(in: room, stanza) }
        }
        let status = roomStatus(room)
        let context = RoomContext(
            jid: room,
            nickname: status?.nickname ?? group.nickname,
            occupants: (status?.occupants ?? [:]).compactMapValues(\.jid),
            trustsOccupantIds: group.hasOccupantIds,
            ownOccupantId: status?.occupantId,
            isNonAnonymous: group.isNonAnonymous,
        )

        var encryption = Message.Encryption.none
        var device: (id: Int32?, trust: OMEMODevice.Trust?)?
        if stanza.type == .groupchat, stanza.firstChild(name: "encrypted", xmlns: NS.omemoLegacy) != nil, let nick = stanza.from?.resource {
            let real = InboundMessage.archivedAddress(in: stanza, source: source, isNonAnonymous: context.isNonAnonymous) ?? context.occupants[nick] ?? (nick == context.nickname ? account : nil)
            if let real {
                let result = omemo.decrypt(stanza, from: real, ownCopy: real == account, isHistory: isHistory, sentAt: source.archivedAt ?? Date())
                switch result {
                case .decrypted(let id, let trust):
                    encryption = .omemo
                    device = (id, trust)
                case .ignore, .ownCopy:
                    // Our own message coming back; note the room's id for it.
                    if let inbound = InboundMessage(groupchat: stanza, room: context, account: account, source: source) {
                        flushArchive(query: query, endsPage: false)
                        try? database.confirmArchived(inbound)
                        // We wrote there, so we'd read what came before.
                        if case .ownCopy = result { try? database.markRead(before: inbound) }
                    }
                    return
                case .failed(let reason):
                    logger.warning("Couldn't decrypt group message \(stanza.id ?? "?", privacy: .private): \(reason, privacy: .private)")
                    encryption = .omemoUndecryptable
                }
            } else {
                // Without the sender's address there's no session to use.
                encryption = .omemoUndecryptable
            }
            if encryption == .omemoUndecryptable, stanza.body?.isEmpty ?? true { stanza.body = "🔒" }
        }

        guard var inbound = InboundMessage(groupchat: stanza, room: context, account: account, source: source, encryption: encryption) else { return }
        // The server can't block someone's group messages, which come from
        // the room; where it shows who they are, we drop them ourselves.
        if !inbound.isOutgoing, inbound.sender != room, (try? database.isBlocked(inbound.sender)) == true { return }
        inbound.omemoDevice = device?.id ?? nil
        inbound.omemoTrust = device?.trust
        inbound.isHistory = isHistory
        let isPrivate = group.isPrivate
        if case .archive = source {
            bufferArchived(inbound, query: query) { [weak self, inbound] result in
                guard !isHistory else {
                    if let attachment = result.retractedAttachment { self?.attachments.remove(attachment) }
                    return
                }
                self?.storedRoomMessage(inbound, result, isPrivate: isPrivate)
            }
            return
        }
        // Once the room has caught up, what it sends live is the end of its
        // archive, so the cursor follows. Left behind, the extension would
        // read a stale page of what the app has already stored.
        let followsArchive = Self.followsArchive(source: source, isHistory: isHistory, status: status)
        do {
            let result = followsArchive ? try database.ingestLive(inbound, in: group) : try database.ingest(inbound)
            storedRoomMessage(inbound, result, isPrivate: isPrivate)
        } catch {
            logger.error("Failed to store group message: \(error)")
        }
    }

    /// The room's history on joining arrives as live stanzas, told apart only
    /// by their XEP-0203 delay. Any delay counts: ignoring a notice wrongly is
    /// the safe mistake.
    static func isDelayed(_ stanza: Martin.Message) -> Bool {
        !stanza.element.filterChildren(name: "delay", xmlns: "urn:xmpp:delay").isEmpty
    }

    /// Not after a catch-up that gave up: the cursor would skip what it missed.
    static func followsArchive(source: InboundMessage.Source, isHistory: Bool, status: RoomStatus?) -> Bool {
        source == .live && !isHistory && status?.isJoined == true && status?.isSyncing == false && status?.catchUpReachedEnd == true
    }

    private func storedRoomMessage(_ inbound: InboundMessage, _ result: IngestResult, isPrivate: Bool) {
        if let attachment = result.retractedAttachment { attachments.remove(attachment) }
        if let message = result.editedMessage { events.send(.editedMessage(message)) }
        if let message = result.newMessage {
            events.send(.newMessage(message))
            if let attachment = result.newAttachment, Self.trustsForAutoDownload(
                isOutgoing: Message.isTrustedOutgoing(isOutgoing: message.direction == .outgoing, isWrittenHere: message.isWrittenHere, inGroup: true),
                isPrivateGroup: isPrivate, isInRoster: (try? database.isInRoster(inbound.sender)) ?? false,
            ) {
                autoDownload(attachment)
            }
        }
    }

    /// Who an encrypted group message goes to, besides our own devices.
    func groupRecipients(_ room: JID) -> [JID] {
        roomStatus(room)?.recipients(excluding: account) ?? []
    }

    // MARK: Invitations

    /// XEP-0249 direct invitations, and XEP-0045 ones relayed by the room.
    static func isInvitation(_ stanza: Martin.Message) -> Bool {
        stanza.firstChild(name: "x", xmlns: NS.conference) != nil
            || stanza.firstChild(name: "x", xmlns: NS.mucUser)?.firstChild(name: "invite") != nil
            || stanza.firstChild(name: "x", xmlns: NS.mucUser)?.firstChild(name: "decline") != nil
    }

    /// An invitation as read from a stanza, before deciding what to do with it.
    struct Invitation: Equatable {
        let room: JID
        let inviter: JID
        /// Sent by the inviter (XEP-0249), rather than relayed by the room.
        let isDirect: Bool
        var reason: String?
    }

    /// What `stanza` invites us to, or nil if it isn't a usable invitation.
    /// A room relays invitations from its bare address. Anything with a
    /// resource came from a client, whose server stamped its full address on
    /// it, and is a user posing as a room.
    static func invitation(in stanza: Martin.Message) -> Invitation? {
        if let direct = stanza.firstChild(name: "x", xmlns: NS.conference) {
            guard let room = direct.getAttribute("jid").flatMap(JID.init(_:)), room.localPart != nil,
                  let inviter = stanza.from.flatMap({ JID($0) }) else { return nil }
            return Invitation(room: room, inviter: inviter, isDirect: true)
        }
        guard let invite = stanza.firstChild(name: "x", xmlns: NS.mucUser)?.firstChild(name: "invite"),
              let from = stanza.from, from.resource == nil,
              let room = JID(from), room.localPart != nil,
              let inviter = invite.getAttribute("from").flatMap(JID.init(_:)) else { return nil }
        let reason = invite.firstChild(name: "reason")?.value.flatMap { $0.isEmpty ? nil : $0 }
        return Invitation(room: room, inviter: inviter, isDirect: false, reason: reason)
    }

    /// Joins groups our contacts invite us to, unless a room relayed the
    /// invitation and can't vouch for the inviter: those wait for the user.
    /// Invitations from strangers are dropped rather than letting anyone add
    /// us to anything.
    func invitationReceived(_ stanza: Martin.Message) {
        // Someone we invited said no. Nothing is shown for it, but it isn't
        // an invitation either.
        if let (room, from) = Self.decline(in: stanza) {
            logger.info("\(from, privacy: .private) declined the invitation to \(room, privacy: .private)")
            return
        }
        guard let invitation = Self.invitation(in: stanza) else {
            logger.info("Ignoring a malformed or forged invitation from \(stanza.from?.stringValue ?? "nobody", privacy: .private)")
            return
        }
        let room = invitation.room, inviter = invitation.inviter
        guard (try? database.isInRoster(inviter)) == true else {
            logger.info("Ignoring invitation to \(room, privacy: .private) from \(inviter, privacy: .private), who isn't a contact")
            return
        }
        if let group = try? database.groupChat(room), !group.hasLeft { return }
        // A room relaying an invitation names the inviter itself, so it could
        // name anyone. It can only speak for its own server's users; for any
        // other the user decides, knowing that.
        if !invitation.isDirect, !Self.vouches(room: room, for: inviter) {
            logger.info("Holding invitation to \(room, privacy: .private) for \(inviter, privacy: .private): the room can't speak for them")
            do {
                try database.recordGroupInvitation(room: room, inviter: inviter, reason: invitation.reason)
            } catch {
                logger.error("Failed to store group invitation: \(error)")
            }
            return
        }
        Task { [self] in
            do {
                // Vouching only holds if the sender really is a room on that
                // server, rather than something else at that address.
                // A direct one names any address its sender likes. If the room
                // can't be looked up it isn't joined: joining would create it.
                if try await !isGroupChatRoom(room) {
                    logger.info("Ignoring invitation to \(room, privacy: .private), which isn't a group chat")
                    return
                }
                try await joinGroup(room, mayCreate: false)
            } catch {
                logger.warning("Couldn't accept invitation to \(room, privacy: .private): \(error.localizedDescription, privacy: .private)")
            }
        }
    }

    private func isGroupChatRoom(_ room: JID) async throws -> Bool {
        let info = try await client.module(.disco).info(for: Martin.JID(room.martin), node: nil)
        return Self.isGroupChat(identities: info.identities.map { ($0.category, $0.type) })
    }

    static func isGroupChat(identities: [(category: String, type: String)]) -> Bool {
        identities.contains { $0.category == "conference" && $0.type == "text" }
    }

    /// Whether `room`'s server can speak for `inviter`: it's their server's
    /// group chat service, say conference.example.org for example.org.
    static func vouches(room: JID, for inviter: JID) -> Bool {
        let service = room.domain.lowercased(), home = inviter.domain.lowercased()
        return service == home || service.hasSuffix("." + home)
    }

    // MARK: Bookmarks

    /// Brings our groups and our bookmarks in line, then joins the groups.
    func syncBookmarks() {
        if usesLegacyBookmarks {
            fetchLegacyBookmarks { [weak self] bookmarks in
                guard let self else { return }
                if let bookmarks {
                    self.applyBookmarks(bookmarks)
                } else {
                    self.joinRooms()
                }
            }
            return
        }
        client.module(.pubsub).retrieveItems(from: account.martin, for: NS.bookmarks) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let items):
                self.applyBookmarks(items.items.compactMap { Bookmark(id: $0.id, payload: $0.payload) })
            case .failure(let error) where error.error == .item_not_found:
                self.applyBookmarks([])
            case .failure(let error):
                // No bookmarks on this server: our own list is all there is.
                self.logger.info("Bookmarks unavailable: \(error.localizedDescription, privacy: .private)")
                self.joinRooms()
            }
        }
    }

    private func applyBookmarks(_ bookmarks: [Bookmark]) {
        let byJID = Dictionary(bookmarks.map { ($0.jid, $0) }, uniquingKeysWith: { a, _ in a })
        let groups = Dictionary(((try? database.groupChats()) ?? []).map { ($0.jid, $0) }, uniquingKeysWith: { a, _ in a })
        for bookmark in bookmarks where bookmark.autojoin {
            try? database.removeGroupInvitation(bookmark.jid)
            let group = groups[bookmark.jid]
            if group == nil || group?.hasLeft == true {
                _ = try? joinBookmarked(bookmark, existing: group)
            }
            applyBookmarkFields(bookmark)
        }
        for group in groups.values where !group.hasLeft {
            let bookmark = byJID[group.jid]
            if bookmark?.autojoin == true { continue }
            if group.isBookmarked {
                // Left on another device.
                try? database.updateGroupChat(group.jid) { $0.hasLeft = true }
            } else {
                publishBookmark(group)
            }
        }
        joinRooms()
    }

    private func joinBookmarked(_ bookmark: Bookmark, existing group: GroupChat?) throws -> GroupChat {
        try database.joinGroupChat(bookmark.jid, nickname: bookmark.nick ?? group?.nickname ?? defaultNickname, name: bookmark.name, isBookmarked: true)
    }

    private func applyBookmarkFields(_ bookmark: Bookmark) {
        try? database.updateGroupChat(bookmark.jid) { group in
            group.isBookmarked = true
            if let name = bookmark.name, !name.isEmpty { group.name = name }
            group.notify = bookmark.notify
        }
    }

    func bookmarkChanged(_ change: BookmarksModule.Change) {
        switch change {
        case .published(let bookmark) where bookmark.autojoin:
            try? database.removeGroupInvitation(bookmark.jid)
            let group = try? database.groupChat(bookmark.jid)
            if group == nil || group?.hasLeft == true {
                guard let joined = try? joinBookmarked(bookmark, existing: group) else { return }
                reloadKnownRooms()
                join(joined.jid, nickname: joined.nickname)
            }
            applyBookmarkFields(bookmark)
        case .published(let bookmark):
            leaveRoom(bookmark.jid)
        case .retracted(let jid):
            leaveRoom(jid)
        }
    }

    func publishBookmark(_ group: GroupChat) {
        let bookmark = Bookmark(jid: group.jid, name: group.name, autojoin: true, nick: group.nickname, notify: group.notify)
        if usesLegacyBookmarks {
            publishLegacyBookmark(bookmark, for: group)
            return
        }
        let options = Self.dataForm(type: "submit", formType: "http://jabber.org/protocol/pubsub#publish-options", fields: [
            "pubsub#persist_items": ["true"],
            "pubsub#max_items": ["max"],
            "pubsub#send_last_published_item": ["never"],
            "pubsub#access_model": ["whitelist"],
        ])
        // Some servers never answer a publish with max_items=max (Openfire),
        // so the wait is bounded, and the old kind of bookmark takes over.
        let once = Once()
        let failed: @Sendable (String) -> Void = { [weak self] reason in
            guard let self else { return }
            self.logger.warning("Couldn't bookmark \(group.jid, privacy: .private): \(reason, privacy: .private)")
            self.publishLegacyBookmark(bookmark, for: group)
        }
        client.module(.pubsub).publishItem(
            at: nil, to: NS.bookmarks, itemId: group.jid.description, payload: bookmark.element,
            publishOptions: options, errorDecoder: PubSubError.from(stanza:),
        ) { [weak self] (result: Result<Iq, PubSubError>) in
            guard once.first() else { return }
            switch result {
            case .success:
                try? self?.database.updateGroupChat(group.jid) { $0.isBookmarked = true }
            case .failure(let error):
                failed(error.localizedDescription)
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.bookmarkTimeout) {
            if once.first() { failed("no answer") }
        }
    }

    /// With notifications, which XEP-0402 relies on to tell our other
    /// devices we left.
    private func retractBookmark(_ room: JID) {
        if usesLegacyBookmarks {
            removeLegacyBookmark(room)
            try? database.updateGroupChat(room) { $0.isBookmarked = false }
            return
        }
        client.module(.pubsub).retractItem(at: nil, from: NS.bookmarks, itemId: room.description, notify: true) { [weak self] result in
            if case .failure(let error) = result {
                self?.logger.warning("Couldn't remove bookmark for \(room, privacy: .private): \(error.localizedDescription, privacy: .private)")
            }
        }
        try? database.updateGroupChat(room) { $0.isBookmarked = false }
    }

    static func dataForm(type: String, formType: String, fields: [String: [String]]) -> Element {
        let x = Element(name: "x", xmlns: NS.dataForms)
        x.setAttribute("type", value: type)
        var all = [("FORM_TYPE", [formType])]
        all += fields.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
        for (name, values) in all {
            let field = Element(name: "field")
            field.setAttribute("var", value: name)
            for value in values { field.addChild(Element(name: "value", cdata: value)) }
            x.addChild(field)
        }
        return x
    }

    // MARK: Public API

    /// Joins the group at `room`, which must let us in, and adds it to our
    /// bookmarks. Throws if the room refuses.
    /// `mayCreate` is false for a room we were invited to, which has to exist.
    public func joinGroup(_ room: JID, nickname: String? = nil, mayCreate: Bool = true) async throws {
        guard isConnected else { throw GroupError.notConnected }
        if let status = roomStatus(room), status.isJoined {
            try database.removeGroupInvitation(room)
            return
        }
        let existing = try database.groupChat(room)
        let nickname = nickname ?? existing?.nickname ?? defaultNickname
        let group = try database.joinGroupChat(room, nickname: nickname)
        reloadKnownRooms()
        if roomStatus(room) != nil { updateRoom(room) { $0 = nil } }
        join(room, nickname: nickname, mayCreate: mayCreate)
        do {
            _ = try await waitForRoom(room)
        } catch {
            if existing == nil {
                try? deleteConversation(id: group.conversationId)
            } else {
                try? database.updateGroupChat(room) { $0.hasLeft = existing?.hasLeft ?? false }
            }
            reloadKnownRooms()
            updateRoom(room) { $0 = nil }
            throw error
        }
        try database.removeGroupInvitation(room)
        if let joined = try database.groupChat(room) { publishBookmark(joined) }
    }

    /// Joins a group we were invited to without knowing who invited us, once
    /// the user has decided to. The invitation stays if the room refuses.
    public func acceptGroupInvitation(_ room: JID) async throws {
        // The address came from a stranger's stanza: it must be a room already.
        guard try await isGroupChatRoom(room) else { throw GroupError.joinFailed(String(localized: "This group doesn't exist.")) }
        try await joinGroup(room, mayCreate: false)
    }

    /// Forgets the invitation, and tells a contact who invited us through the
    /// room (XEP-0045) that we won't come. A decline is also proof that the
    /// account is alive and reading, which a stranger who sprays invitations
    /// must not get; XEP-0249 invitations have no decline at all. It goes
    /// only if we're connected: declining offline isn't worth holding the
    /// invitation for, and the inviter is left unanswered like any other.
    public func declineGroupInvitation(_ room: JID) throws {
        let invitation = try database.groupInvitation(room)
        try database.removeGroupInvitation(room)
        if let invitation, Self.sendsDecline(for: invitation, inviter: try database.contact(invitation.inviter)) {
            write(OutboundStanza.invitationDecline(room: room, inviter: invitation.inviter))
        }
    }

    /// Whether declining `invitation` is told to its inviter: only when
    /// they're a contact we have a subscription with. Every stored invitation
    /// was relayed through the room, as direct ones are joined at once.
    static func sendsDecline(for invitation: GroupInvitation, inviter: Contact?) -> Bool {
        guard let inviter, inviter.isInRoster else { return false }
        return inviter.subscription != .none
    }

    /// A decline of our invitation, which the room relays to us (XEP-0045).
    /// Only the room itself speaks for it: from an occupant it's a forgery.
    static func decline(in stanza: Martin.Message) -> (room: JID, from: JID)? {
        guard let decline = stanza.firstChild(name: "x", xmlns: NS.mucUser)?.firstChild(name: "decline"),
              let from = stanza.from, from.resource == nil,
              let room = JID(from), room.localPart != nil,
              let sender = decline.getAttribute("from").flatMap(JID.init(_:)) else { return nil }
        return (room, sender)
    }

    /// Creates a private group (members only, members see each other's
    /// addresses, archived), as OMEMO needs, and invites `invitees`.
    public func createGroup(name: String, inviting invitees: [JID]) async throws -> JID {
        guard isConnected else { throw GroupError.notConnected }
        let service = try await mucService()
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        let local = String((0..<12).map { _ in alphabet.randomElement()! })
        guard let room = JID("\(local)@\(service)") else { throw GroupError.noService }

        try database.joinGroupChat(room, nickname: defaultNickname, name: name)
        reloadKnownRooms()
        join(room, nickname: defaultNickname, discover: false)
        let status = try await waitForRoom(room)
        if status.wasCreated { try await configurePrivateRoom(room, name: name) }
        let hasArchive = await refreshedRoomInfo(room)
        updateRoom(room) { $0?.hasArchive = hasArchive }
        if let group = try database.groupChat(room) { publishBookmark(group) }
        if !invitees.isEmpty { try await invite(invitees, to: room) }
        return room
    }

    /// Adds `invitees` to the group. Owners and admins make them members and
    /// invite them directly; others ask the room to invite them.
    public func invite(_ invitees: [JID], to room: JID) async throws {
        if try joinedStatus(room).isOwnerOrAdmin {
            // One request each: Prosody only applies the first item of a request.
            for invitee in invitees {
                _ = try await client.context.writer.write(iq: OutboundStanza.affiliation(.member, of: invitee, in: room))
            }
            updateRoom(room) { status in
                for invitee in invitees { status?.setAffiliation(.member, of: invitee) }
            }
        } else {
            let message = Martin.Message()
            message.to = Martin.JID(room.martin)
            message.id = OutboundStanza.newId()
            let x = Element(name: "x", xmlns: NS.mucUser)
            for invitee in invitees {
                x.addChild(Element(name: "invite", attributes: ["to": invitee.description]))
            }
            message.addChild(x)
            write(message)
        }
        // For the relayed branch this is a direct invitation too: the relayed
        // one names us only on the room's word, which clients like ours trust
        // only from a room on our own server. Ours goes out after it, so the
        // room lets them in.
        for invitee in invitees { write(OutboundStanza.invitation(to: invitee, room: room)) }
    }

    /// Changes which of the group's messages notify, on all our devices.
    public func setNotify(_ notify: GroupChat.Notify, in room: JID) throws {
        try database.updateGroupChat(room) { $0.notify = notify }
        if let group = try database.groupChat(room), !group.hasLeft, isConnected { publishBookmark(group) }
    }

    /// Leaves the group for good on all our devices. Its history stays.
    /// Throws, having changed nothing, if we're offline or the server
    /// doesn't take the bookmark away: our bookmark would still say autojoin,
    /// and the next connection would join the group again. The bookmark goes
    /// first for that reason; once it's gone, nothing can undo leaving.
    public func leaveGroup(_ room: JID) async throws {
        guard isConnected else { throw GroupError.notConnected }
        try await retractBookmarkAwaiting(room)
        leaveRoom(room)
    }

    /// Like `retractBookmark`, but says whether it worked.
    private func retractBookmarkAwaiting(_ room: JID) async throws {
        if usesLegacyBookmarks {
            let removed = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                removeLegacyBookmark(room) { continuation.resume(returning: $0) }
            }
            guard removed else { throw GroupError.couldntLeave }
            try? database.updateGroupChat(room) { $0.isBookmarked = false }
            return
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            client.module(.pubsub).retractItem(
                at: nil, from: NS.bookmarks, itemId: room.description, notify: true, errorDecoder: PubSubError.from(stanza:),
            ) { [weak self] (result: Result<Iq, PubSubError>) in
                switch result {
                case .success:
                    continuation.resume()
                // There was no bookmark to remove.
                case .failure(let error) where error.error == .item_not_found:
                    continuation.resume()
                case .failure(let error):
                    self?.logger.warning("Couldn't remove bookmark for \(room, privacy: .private): \(error.localizedDescription, privacy: .private)")
                    continuation.resume(throwing: GroupError.couldntLeave)
                }
            }
        }
        try? database.updateGroupChat(room) { $0.isBookmarked = false }
    }

    func leaveRoom(_ room: JID) {
        if let status = roomStatus(room), status.isJoined {
            let presence = Presence()
            presence.type = .unavailable
            presence.to = room.martin.with(resource: status.nickname)
            write(presence)
        }
        cancelRejoin(room, resettingBackoff: true)
        updateRoom(room) { $0 = nil }
        dropDeferred(in: room)
        try? database.updateGroupChat(room) { $0.hasLeft = true }
        ShareSuggestions.remove([room])
    }

    /// What a room answered to a subject change.
    enum SubjectOutcome: Sendable {
        /// Its echo of a change, from the occupant who made it.
        case changed(room: JID, subject: String)
        case failed(room: JID, id: String, GroupError)
    }

    /// Tells a waiting `setSubject` how the room answered.
    private func reportSubjectOutcome(of stanza: Martin.Message, in room: JID) {
        if stanza.type == .error {
            guard let id = stanza.id else { return }
            let condition = Self.errorCondition(of: stanza)
            let error: GroupError = ["forbidden", "not-allowed"].contains(condition) ? .notAllowed : .refused(condition ?? "error")
            subjectOutcomes.send(.failed(room: room, id: id, error))
        } else if stanza.type == .groupchat, stanza.body == nil, let subject = stanza.firstChild(name: "subject"),
                  stanza.from?.resource == roomStatus(room)?.nickname {
            subjectOutcomes.send(.changed(room: room, subject: subject.value ?? ""))
        }
    }

    /// Changes the group's subject, and returns once the room has put it up
    /// or said why not. Whether we may is the room's call: moderators always,
    /// participants if it lets them (`RoomStatus.canChangeSubject`).
    public func setSubject(_ subject: String, in room: JID) async throws {
        _ = try joinedStatus(room)
        let message = Martin.Message()
        message.to = Martin.JID(room.martin)
        message.type = .groupchat
        let id = OutboundStanza.newId()
        message.id = id
        message.subject = subject
        // Listening starts before writing: the answer may be quick.
        let (outcomes, continuation) = AsyncStream.makeStream(of: SubjectOutcome.self)
        let subscription = subjectOutcomes.sink { continuation.yield($0) }
        defer {
            subscription.cancel()
            continuation.finish()
        }
        write(message)
        do {
            try await withTimeout(Self.subjectTimeout) {
                for await outcome in outcomes {
                    switch outcome {
                    case .changed(room, subject): return
                    case .failed(room, id, let error): throw error
                    default: continue
                    }
                }
            }
        } catch is TimeoutError {
            throw GroupError.timedOut
        }
    }

    static let subjectTimeout: TimeInterval = 15

    private func waitForRoom(_ room: JID, timeout: TimeInterval = 30) async throws -> RoomStatus {
        do {
            return try await withTimeout(timeout) { [self] in
                for await all in rooms.values {
                    switch all[room]?.phase {
                    case .joined?: return all[room]!
                    case .failed(let reason)?: throw GroupError.joinFailed(reason)
                    case .joining?, nil: continue
                    }
                }
                throw GroupError.timedOut
            }
        } catch is TimeoutError {
            throw GroupError.timedOut
        }
    }

    /// The server's group chat service, found once per connection.
    private func mucService() async throws -> String {
        if let service = lock.withLock({ $0.mucService }) { return service }
        let disco = client.module(.disco)
        let items = try await disco.items(for: Martin.JID(account.domain))
        for item in items.items {
            guard let info = try? await disco.info(for: item.jid, node: item.node) else { continue }
            if Self.isGroupChat(identities: info.identities.map { ($0.category, $0.type) }) {
                let service = item.jid.stringValue
                lock.withLock { $0.mucService = service }
                return service
            }
        }
        throw GroupError.noService
    }

    private func configurePrivateRoom(_ room: JID, name: String) async throws {
        let form = try await ownerForm(of: room)
        let offered = Set(form?.filterChildren(name: "field", xmlns: nil).compactMap { $0.getAttribute("var") } ?? [])
        let wanted: [String: [String]] = [
            RoomConfiguration.Field.name: [name],
            "muc#roomconfig_persistentroom": ["1"],
            RoomConfiguration.Field.membersOnly: ["1"],
            RoomConfiguration.Field.whois: ["anyone"],
            "muc#roomconfig_publicroom": ["0"],
            RoomConfiguration.Field.allowInvites: ["1"],
            // Prosody: who may list members, which OMEMO needs.
            "muc#roomconfig_getmemberlist": ["moderator", "participant", "visitor"],
            // Prosody and ejabberd name archiving differently.
            "muc#roomconfig_enablearchiving": ["1"],
            "mam": ["1"],
            // Openfire's archive only keeps what a room logs.
            "muc#roomconfig_enablelogging": ["1"],
        ]
        try await submitOwnerForm(wanted.filter { offered.contains($0.key) }, to: room)
    }

    /// The configuration form the room offers its owner.
    func ownerForm(of room: JID) async throws -> Element? {
        let response = try await client.context.writer.write(iq: OutboundStanza.configurationRequest(of: room))
        return response.firstChild(name: "query", xmlns: NS.mucOwner)?.firstChild(name: "x", xmlns: NS.dataForms)
    }

    func submitOwnerForm(_ fields: [String: [String]], to room: JID) async throws {
        _ = try await client.context.writer.write(iq: OutboundStanza.configuration(fields, of: room))
    }
}
