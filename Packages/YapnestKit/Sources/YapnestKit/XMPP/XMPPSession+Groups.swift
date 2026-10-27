import Combine
import Foundation
@preconcurrency import Martin
import os

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
    /// The room's password, for the joins this visit may need: a retry, a
    /// nickname change, a rejoin.
    var password: String?
    /// The room was named by someone else, so it has to be known to exist: a
    /// lookup that failed leaves that open, and the join waits. Our own room
    /// is joined without knowing, as one whose info never answers must still
    /// be enterable.
    var mustBeFound = false
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
    /// The server couldn't say, for now, so it isn't known whether it can.
    case lookupFailed(ServerError)
    /// What the group's archive sent couldn't be saved on this device.
    case notStored
    /// The group's archive kept saying there was more, past what one read takes.
    case historyIncomplete

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
        case .lookupFailed(let error): error.describe(String(localized: "Couldn't look up your server's group chat service"))
        case .notStored: String(localized: "Couldn't save the group's history on this device.")
        case .historyIncomplete: String(localized: "The group has more earlier messages than were fetched this time.")
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
    /// works there. Back from the background the connection and then the
    /// rejoin take a few seconds, which this waits for, within one grace. A
    /// room we've left or that failed to join won't come, so it doesn't wait.
    func joinedStatus(_ room: JID) async throws -> RoomStatus {
        let started = Date()
        guard await waitForConnection() else { throw GroupError.notConnected }
        if let status = roomStatus(room), status.isJoined { return status }
        guard let group = try? database.groupChat(room), !group.hasLeft else { throw GroupError.notConnected }
        let grace = lock.withLock { $0.connectionGrace }
        let remaining = max(0, grace - Date().timeIntervalSince(started))
        let status = try? await withTimeout(remaining) { [self] () -> RoomStatus? in
            for await all in rooms.values {
                guard let status = all[room] else { continue }
                if case .failed = status.phase { return nil }
                if status.isJoined { return status }
            }
            return nil
        }
        guard let status, isConnected else { throw GroupError.notConnected }
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

    /// Rejoins every group we're in, after a new session's catch-up. Not to
    /// create them: one destroyed while we were away, whose notice we never
    /// got, would come back empty and locked.
    func joinRooms() {
        let groups = (try? database.groupChats()) ?? []
        let rooms = Set(groups.map(\.jid))
        lock.withLock { $0.knownRooms = rooms }
        for group in groups where !group.hasLeft {
            join(group.jid, nickname: group.nickname, mayCreate: false)
        }
    }

    /// Looks the room up, then enters it. Its archive replaces the history
    /// the room would replay on join.
    func join(_ room: JID, nickname: String, discover: Bool = true, mayCreate: Bool = true, mustBeFound: Bool = false, password: String? = nil) {
        guard isConnected else { return }
        // A password given when we were invited is kept with the group, for
        // the joins of later sessions.
        let password = password ?? (try? database.groupChat(room))??.password
        var started = false
        updateRoom(room) { status in
            if status?.phase == .joining || status?.phase == .joined { return }
            status = RoomStatus(phase: .joining, nickname: nickname, mayCreate: mayCreate, password: password, mustBeFound: mustBeFound)
            started = true
        }
        guard started else { return }
        cancelRejoin(room)
        guard discover else {
            sendJoin(room, nickname: nickname, hasArchive: false)
            return
        }
        refreshRoomInfo(room) { [weak self] read in
            guard let self else { return }
            switch read {
            case .info(let hasArchive): sendJoin(room, nickname: nickname, hasArchive: hasArchive)
            case .missing where !mayCreate:
                updateRoom(room) {
                    $0?.phase = .failed(String(localized: "This group doesn't exist."))
                    $0?.canRetry = false
                }
            // A room that doesn't exist yet is created by joining it.
            case .missing: sendJoin(room, nickname: nickname, hasArchive: false)
            // An invited room has to be known to exist, so a lookup that
            // failed leaves that open.
            case .failed(let error) where mustBeFound: lookupFailed(room, error)
            case .failed: sendJoin(room, nickname: nickname, hasArchive: false)
            }
        }
    }

    /// An invited room couldn't be looked up, which says nothing of whether
    /// it exists. A passing failure is joined again later, as a failed join is,
    /// and when we're back from a while away.
    private func lookupFailed(_ room: JID, _ error: ServerError) {
        logger.info("Looking up \(room, privacy: .private) failed: \(error.condition, privacy: .private)")
        let retryable = error.isPassing || error.condition == "service-unavailable"
        updateRoom(room) {
            $0?.phase = .failed(error.describe(String(localized: "Couldn't look up the group")))
            $0?.canRetry = retryable
        }
        if retryable { scheduleRejoin(room) }
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
            join(room, nickname: status.nickname, mayCreate: status.mayCreate, mustBeFound: status.mustBeFound, password: status.password)
        }
    }

    private func sendJoin(_ room: JID, nickname: String, hasArchive: Bool) {
        updateRoom(room) { $0?.hasArchive = hasArchive }
        let presence = Presence()
        presence.to = room.martin.with(resource: nickname)
        let x = Element(name: "x", xmlns: NS.muc)
        if let password = roomStatus(room)?.password { x.addChild(Element(name: "password", cdata: password)) }
        let history = Element(name: "history")
        if hasArchive || !policy.readsRoomHistory {
            // Rooms with an archive are read through it; the share extension only writes.
            history.setAttribute("maxstanzas", value: "0")
        } else if let last = try? database.lastIncomingMessageDate(in: room) {
            history.setAttribute("since", value: ISO8601DateFormatter().string(from: last))
        } else {
            history.setAttribute("maxstanzas", value: "50")
        }
        x.addChild(history)
        presence.addChild(x)
        write(presence)
    }

    /// What asking a room what it is came to.
    enum RoomInfoRead: Sendable {
        case info(hasArchive: Bool)
        /// The room isn't there.
        case missing
        /// Any other failure: a timeout says nothing of the room.
        case failed(ServerError)
    }

    /// Asks the room what it is (name, privacy, archive) and stores it.
    func refreshRoomInfo(_ room: JID, _ done: (@Sendable (RoomInfoRead) -> Void)? = nil) {
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
                done?(.info(hasArchive: features.contains("urn:xmpp:mam:2")))
            case .failure(let error):
                // A component that is down or restarting answers service-unavailable
                // too, so only a room that isn't there (or is gone) is missing.
                let error = ServerError.classify(error)
                done?(error.isNotFound || error.condition == "gone" ? .missing : .failed(error))
            }
        })
    }

    /// The room's info read again, and whether it has an archive; nil if it
    /// couldn't be read, when nothing is known of the room.
    @discardableResult
    func refreshedRoomInfo(_ room: JID) async -> Bool? {
        await withCheckedContinuation { continuation in
            refreshRoomInfo(room) { read in
                if case .info(let hasArchive) = read { continuation.resume(returning: hasArchive) } else { continuation.resume(returning: nil) }
            }
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
            // Servers have left out the status that says it is about us. Nicknames
            // are unique in a room, so a removal under ours is ours; a plain
            // leave isn't, as another device of ours may be the one leaving.
            let isRemovalOfUs = nick == status.nickname && !statuses.isDisjoint(with: Self.removalStatuses)
            if isSelf || isRemovalOfUs, !statuses.contains(303) {
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

        if isSelf, statuses.contains(201), !status.mayCreate {
            roomWasRecreated(room)
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
                let status = self.roomStatus(room)
                self.updateRoom(room) { $0 = nil }
                self.join(room, nickname: (try? self.database.groupChat(room))??.nickname ?? nickname, mayCreate: false, mustBeFound: status?.mustBeFound ?? false, password: status?.password)
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

    /// The statuses that say an occupant was taken out of the room (XEP-0045 §8).
    static let removalStatuses: Set<Int> = [301, 307, 321, 322, 332, 333]

    /// Only a restart of the room's service (332) or a technical failure
    /// on the way to it (333) is temporary. A kick (307) is a moderator's
    /// decision, so coming straight back would be rude.
    static func isRetryable(removalStatuses statuses: Set<Int>) -> Bool {
        !statuses.isDisjoint(with: [332, 333])
    }

    /// Seconds to wait before the `attempt`th (from 0) automatic rejoin, up to
    /// a quarter longer by chance: many rooms failing in one outage would
    /// otherwise all ask the server again at the same moment.
    static func rejoinDelay(attempt: Int, jitter: Double = .random(in: 0...0.25)) -> TimeInterval {
        let steps: [TimeInterval] = [5, 15, 60]
        return (attempt < steps.count ? steps[attempt] : 300) * (1 + jitter)
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
        join(room, nickname: group.nickname, mayCreate: false, mustBeFound: status.mustBeFound, password: status.password)
    }

    private func joinFailed(_ room: JID, presence: Presence, status: RoomStatus) {
        // A bare `<error/>` says nothing, and is retried as that always was;
        // a room that says `undefined-condition` meant it.
        let condition = ServerError.declaredCondition(in: presence.element)
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
        } else if statuses.contains(333) {
            String(localized: "The connection to the group was lost.")
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

    /// A join that wasn't meant to create the room did: it was destroyed while
    /// we were away, and a room made now would stay locked, empty, with us as
    /// its owner. Cancelling the configuration (§10.1.3) destroys it again.
    private func roomWasRecreated(_ room: JID) {
        logger.warning("Joining \(room, privacy: .private) created it; cancelling")
        // Gone for good, or every new session would create it and cancel it again.
        groupDestroyed(room)
        let iq = Iq()
        iq.type = .set
        iq.to = Martin.JID(room.martin)
        let query = Element(name: "query", xmlns: NS.mucOwner)
        let cancel = Element(name: "x", xmlns: NS.dataForms)
        cancel.setAttribute("type", value: "cancel")
        query.addChild(cancel)
        iq.addChild(query)
        client.context.writer.write(iq, completionHandler: { [weak self] result in
            // The room is gone from our side either way; one that stays is
            // an empty locked room under a name nobody has, and nothing for
            // the user to act on.
            if case .failure(let error) = result {
                self?.logger.warning("Couldn't cancel the room \(room, privacy: .private) a join created: \(ServerError.classify(error).condition, privacy: .private)")
            }
        })
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

    /// Whose sessions an encrypted group message is decrypted with. Current
    /// occupants say nothing about who wrote an archived message, and anyone
    /// may have held our nick before we joined, so an archived one is ours
    /// only by the occupant id the room gave us.
    static func encryptedSender(of stanza: Martin.Message, nick: String, in room: RoomContext, account: JID, source: InboundMessage.Source) -> JID? {
        if let real = InboundMessage.archivedAddress(in: stanza, source: source, isNonAnonymous: room.isNonAnonymous) { return real }
        guard case .archive = source else { return room.occupants[nick] ?? (nick == room.nickname ? account : nil) }
        guard room.trustsOccupantIds, let own = room.ownOccupantId, InboundMessage.occupantId(in: stanza.element) == own else { return nil }
        return account
    }

    /// Which lists to ask a room for. Members are who we encrypt for, which
    /// only a room that shows addresses lets us do; bans are for those who
    /// can lift them, and show addresses to them in any room.
    static func listsToFetch(isNonAnonymous: Bool, isOwnerOrAdmin: Bool) -> [RoomAffiliation] {
        (isNonAnonymous ? memberLists : []) + (isOwnerOrAdmin ? [.outcast] : [])
    }

    /// Members not present right now still need to read what we encrypt.
    /// Not every room lets members see the list; occupants' addresses still
    /// count when it doesn't. `done` runs once every list has been asked for,
    /// whether or not they came: the room is usable meanwhile, and the user
    /// is warned that encrypted messages may miss members.
    func fetchMembers(_ room: JID, lists: [RoomAffiliation], then done: (@Sendable () -> Void)? = nil) {
        Task { [weak self] in
            await self?.fetchMembersWarning(room, lists: lists)
            done?()
        }
    }

    private func fetchMembersWarning(_ room: JID, lists: [RoomAffiliation]) async {
        let attempt = lock.withLock { $0.attempt }
        let key = "room-members:\(room)"
        let members = lists.filter(Self.memberLists.contains)
        // The ban list is only for the admins' screen, which asks for it again
        // and shows what goes wrong.
        let others = lists.filter { !Self.memberLists.contains($0) }
        if !others.isEmpty { try? await requestLists(others, of: room) }
        guard !members.isEmpty else { return }
        do {
            try await requestLists(members, of: room)
            warnings.clear(key)
        } catch {
            // A dropped connection is redone by the next session.
            guard isConnected, lock.withLock({ $0.attempt }) == attempt else { return }
            let reason = ServerError.classify(error)
            logger.warning("Couldn't list the members of \(room, privacy: .private): \(reason.condition, privacy: .private)")
            // A room that doesn't show its list to members forbids it: that is
            // the room's setting, and the occupants' addresses stand in.
            guard reason.condition != "forbidden" else { return }
            warnings.post(
                key, title: String(localized: "Encrypted messages may not reach all members"),
                friendly: String(localized: "A group's members couldn't be listed, so encrypted messages may not reach all of them"), error: error,
            ) { [weak self] in
                try await self?.requestLists(members, of: room)
            }
        }
    }

    /// Asks for each list, all of them even when one fails, and throws the
    /// first failure.
    private func requestLists(_ lists: [RoomAffiliation], of room: JID) async throws {
        let failure = await withTaskGroup(of: Error?.self) { group in
            for affiliation in lists {
                group.addTask { [self] in
                    do {
                        let response = try await retryingPassingErrors { try await client.context.writer.write(iq: OutboundStanza.affiliationList(affiliation, of: room)) }
                        listReceived(affiliation, in: room, response)
                        return nil
                    } catch {
                        return error
                    }
                }
            }
            var first: Error?
            for await error in group { first = first ?? error }
            return first
        }
        if let failure { throw failure }
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
            fetchRoomArchivePage(group.jid, rsm: RSM.Query(after: after, max: 100), after: after, visit)
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

    private func fetchRoomArchivePage(_ room: JID, rsm: RSM.Query, after: String? = nil, _ visit: RoomCatchUp, onePage: Bool = false, pagesRead: Int = 0) {
        // The room's archive, which discovery found speaks MAM 2.
        let queryId = UUID().uuidString
        client.module(.mam).queryItems(version: .MAM2, componentJid: Martin.JID(room.martin), queryId: queryId, rsm: rsm) { [weak self] result in
            guard let self else { return }
            let stored = self.flushArchive(query: queryId)
            guard self.roomCatchUpMayProceed(room, visit) else { return }
            switch result {
            case .success(let page): self.roomArchivePageRead(room, page, stored: stored, after: after, visit, onePage: onePage, pagesRead: pagesRead)
            case .failure(let error): self.roomArchivePageFailed(room, rsm: rsm, after: after, error, visit, onePage: onePage, pagesRead: pagesRead)
            }
        }
    }

    private func roomArchivePageRead(
        _ room: JID, _ page: MessageArchiveManagementModule.QueryResult, stored: Bool, after: String?, _ visit: RoomCatchUp, onePage: Bool, pagesRead: Int,
    ) {
        guard stored else {
            // Going on would move the cursor past the page that was lost.
            finishRoomCatchUp(room, visit, reachedEnd: false)
            return
        }
        if let last = page.rsm?.last {
            try? database.updateGroupChat(room) { $0.lastArchiveId = last }
        }
        let pagesRead = pagesRead + 1
        switch Self.nextRoomArchivePage(after: after, last: page.rsm?.last, complete: onePage || page.complete, pagesRead: pagesRead) {
        case .end: finishRoomCatchUp(room, visit, reachedEnd: true)
        // Live messages mustn't move the cursor past what's left; the next
        // visit, or the warning's Retry, reads on from it.
        case .stop:
            warnOfMissingHistory(room, GroupError.historyIncomplete)
            finishRoomCatchUp(room, visit, reachedEnd: false)
        case .after(let last): fetchRoomArchivePage(room, rsm: RSM.Query(after: last, max: 100), after: last, visit, pagesRead: pagesRead)
        }
    }

    /// A page that failed is asked for again while the error can pass. One
    /// that doesn't ends the catch-up with the cursor where the last page left
    /// it, so what the room sends live doesn't move it past the gap, and the
    /// user is told that messages may be missing.
    private func roomArchivePageFailed(_ room: JID, rsm: RSM.Query, after: String?, _ error: XMPPError, _ visit: RoomCatchUp, onePage: Bool, pagesRead: Int) {
        // An archive that no longer knows our cursor is read from its newest
        // page. Not when it was the newest page that failed: asking for it
        // again would never end.
        if case .item_not_found = error, hasArchiveCursor(room) {
            try? database.updateGroupChat(room) { $0.lastArchiveId = nil }
            fetchRoomArchivePage(room, rsm: RSM.Query(lastItems: 50), visit, onePage: true)
            return
        }
        guard ServerRetry.isPassing(error) else {
            archiveGaveUp(room, error, visit)
            return
        }
        Task { [weak self] in
            guard let self else { return }
            // The failure that brought us here is the first attempt.
            var first: Error? = error
            do {
                let read = try await retryingPassingErrors {
                    if let earlier = first {
                        first = nil
                        throw earlier
                    }
                    return try await queryRoomArchive(room, rsm)
                }
                guard roomCatchUpMayProceed(room, visit) else { return }
                roomArchivePageRead(room, read.page, stored: read.stored, after: after, visit, onePage: onePage, pagesRead: pagesRead)
            } catch {
                guard roomCatchUpMayProceed(room, visit) else { return }
                archiveGaveUp(room, error, visit)
            }
        }
    }

    private func archiveGaveUp(_ room: JID, _ error: Error, _ visit: RoomCatchUp) {
        logger.error("Archive sync of \(room, privacy: .private) failed: \(error)")
        warnOfMissingHistory(room, error)
        finishRoomCatchUp(room, visit, reachedEnd: false)
    }

    private func hasArchiveCursor(_ room: JID) -> Bool {
        ((try? database.groupChat(room)) ?? nil)?.lastArchiveId != nil
    }

    /// A page of a room's archive, and whether what it carried was stored.
    private struct ArchivePage: @unchecked Sendable {
        var page: MessageArchiveManagementModule.QueryResult
        var stored: Bool
    }

    private func queryRoomArchive(_ room: JID, _ rsm: RSM.Query) async throws -> ArchivePage {
        let queryId = UUID().uuidString
        return try await withCheckedThrowingContinuation { continuation in
            client.module(.mam).queryItems(version: .MAM2, componentJid: Martin.JID(room.martin), queryId: queryId, rsm: rsm) { [weak self] result in
                let stored = self?.flushArchive(query: queryId) ?? true
                switch result {
                case .success(let page): continuation.resume(returning: ArchivePage(page: page, stored: stored))
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
        }
    }

    private func warnOfMissingHistory(_ room: JID, _ error: Error) {
        warnings.post(
            "room-history:\(room)", title: String(localized: "Some messages may be missing"),
            friendly: String(localized: "A group's earlier messages couldn't be fetched"), error: error,
        ) { [weak self] in
            try await self?.readRoomArchiveAgain(room)
        }
    }

    /// Reads on from the cursor to the end of the room's archive, for the
    /// warning's Retry, and clears the warning once it has.
    private func readRoomArchiveAgain(_ room: JID) async throws {
        guard isConnected, roomStatus(room)?.isJoined == true, let group = try database.groupChat(room) else { throw GroupError.notConnected }
        omemo.module.mamSyncStarted(for: room.martin)
        defer { omemo.module.mamSyncFinished(for: room.martin) }
        var after = group.lastArchiveId
        var rsm = after.map { RSM.Query(after: $0, max: 100) } ?? RSM.Query(lastItems: 50)
        var onePage = after == nil
        var pagesRead = 0
        paging: while true {
            let page: MessageArchiveManagementModule.QueryResult
            do {
                let read = try await retryingPassingErrors { try await queryRoomArchive(room, rsm) }
                guard read.stored else { throw GroupError.notStored }
                page = read.page
            } catch XMPPError.item_not_found where hasArchiveCursor(room) {
                try database.updateGroupChat(room) { $0.lastArchiveId = nil }
                after = nil
                rsm = RSM.Query(lastItems: 50)
                onePage = true
                continue
            }
            if let last = page.rsm?.last { try database.updateGroupChat(room) { $0.lastArchiveId = last } }
            pagesRead += 1
            switch Self.nextRoomArchivePage(after: after, last: page.rsm?.last, complete: onePage || page.complete, pagesRead: pagesRead) {
            case .end: break paging
            // The warning stays, as there's more to read.
            case .stop: throw GroupError.historyIncomplete
            case .after(let last):
                after = last
                rsm = RSM.Query(after: last, max: 100)
            }
        }
        updateRoom(room) { $0?.catchUpReachedEnd = true }
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

    /// A visit reads at most this many pages of a room's archive, 10,000
    /// messages. A room on any server can say there is always more, or
    /// answer every page with the same cursor, and would otherwise be read
    /// from forever.
    static let roomArchivePageLimit = 100

    enum RoomArchivePage: Equatable {
        case end, stop, after(String)
    }

    /// What follows a page of a room's archive read from `after`.
    static func nextRoomArchivePage(after: String?, last: String?, complete: Bool, pagesRead: Int) -> RoomArchivePage {
        guard !complete, let last else { return .end }
        guard last != after, pagesRead < roomArchivePageLimit else { return .stop }
        return .after(last)
    }

    /// What to send into a room after its catch-up: the never-sent messages
    /// first, then those sent before this visit that didn't come back.
    ///
    /// Without an archive nothing says what was lost: a room that keeps none
    /// doesn't stamp its echoes either, so sent messages would look
    /// unconfirmed for good and go out again on every visit. Nor does a
    /// catch-up that stopped short of the archive's end: an echo not read
    /// yet isn't one lost.
    static func roomResends(hasArchive: Bool, reachedEnd: Bool, unconfirmed: [Message], pending: [Message]) -> [Message] {
        guard hasArchive, reachedEnd else { return pending }
        return pending.filter { message in !unconfirmed.contains { $0.id == message.id } } + unconfirmed
    }

    /// Sends what never reached the room: it echoes every message it gets,
    /// so anything sent before this visit that didn't come back was lost.
    private func finishRoomCatchUp(_ room: JID, _ visit: RoomCatchUp, reachedEnd: Bool) {
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
        let resends = Self.roomResends(hasArchive: status.hasArchive, reachedEnd: reachedEnd, unconfirmed: unconfirmed, pending: pending)
        // As in `sendUnclaimedPending`: the room's join and catch-up are acknowledged first.
        if !resends.isEmpty {
            requestAcknowledgement()
            beginProbation(among: resends.compactMap(\.remoteId))
        }
        for message in resends { transmit(message, to: room, resend: true) }
    }

    // MARK: Messages

    func handleRoomStanza(_ stanza: Martin.Message, source: InboundMessage.Source, isHistory: Bool = false, query: String = "") {
        guard let room = stanza.from.flatMap({ JID($0) }), let group = try? database.groupChat(room) else { return }
        if routeBounce(stanza) { return }
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
            let real = Self.encryptedSender(of: stanza, nick: nick, in: context, account: account, source: source)
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
                isPrivateGroup: isPrivate, trustsGroupMembers: downloadsFromGroupMembers,
                isTrusted: (try? database.hasConsented(inbound.sender)) ?? false,
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
        /// The room's password, which the inviter sent along (XEP-0249, XEP-0045 §7.8).
        var password: String?
    }

    /// What `stanza` invites us to, or nil if it isn't a usable invitation.
    /// A room relays invitations from its bare address. Anything with a
    /// resource came from a client, whose server stamped its full address on
    /// it, and is a user posing as a room.
    static func invitation(in stanza: Martin.Message) -> Invitation? {
        if let direct = stanza.firstChild(name: "x", xmlns: NS.conference) {
            guard let room = direct.getAttribute("jid").flatMap(JID.init(_:)), room.localPart != nil,
                  let inviter = stanza.from.flatMap({ JID($0) }) else { return nil }
            return Invitation(room: room, inviter: inviter, isDirect: true, password: Self.nonEmpty(direct.getAttribute("password")))
        }
        guard let invite = stanza.firstChild(name: "x", xmlns: NS.mucUser)?.firstChild(name: "invite"),
              let from = stanza.from, from.resource == nil,
              let room = JID(from), room.localPart != nil,
              let inviter = invite.getAttribute("from").flatMap(JID.init(_:)) else { return nil }
        let reason = invite.firstChild(name: "reason")?.value.flatMap { $0.isEmpty ? nil : $0 }
        let password = stanza.firstChild(name: "x", xmlns: NS.mucUser)?.firstChild(name: "password")?.value
        return Invitation(room: room, inviter: inviter, isDirect: false, reason: reason, password: Self.nonEmpty(password))
    }

    private static func nonEmpty(_ text: String?) -> String? {
        text.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Holds the invitations our contacts send for the user's answer: joining
    /// shows the group our nickname and presence and adds it to every device,
    /// which an invitation alone doesn't entitle anyone to. Invitations from
    /// strangers are dropped rather than letting anyone add us to anything.
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
        guard (try? database.hasConsented(inviter)) == true else {
            logger.info("Ignoring invitation to \(room, privacy: .private) from \(inviter, privacy: .private), who the user hasn't added or approved")
            return
        }
        if let group = try? database.groupChat(room), !group.hasLeft { return }
        // A room relaying an invitation names the inviter itself, so it could
        // name anyone. It can only speak for its own server's users; for any
        // other the user is told that.
        logger.info("Holding invitation to \(room, privacy: .private) from \(inviter, privacy: .private), vouched for: \(invitation.isDirect || Self.vouches(room: room, for: inviter))")
        do {
            try database.recordGroupInvitation(room: room, inviter: inviter, reason: invitation.reason, password: invitation.password, isDirect: invitation.isDirect)
            events.send(.invitationHeld)
        } catch {
            logger.error("Failed to store group invitation: \(error)")
        }
    }

    private func isGroupChatRoom(_ room: JID) async throws -> Bool {
        let info = try await client.module(.disco).info(for: Martin.JID(room.martin), node: nil)
        return Self.isGroupChat(identities: info.identities.map { ($0.category, $0.type) })
    }

    static func isGroupChat(identities: [(category: String, type: String)]) -> Bool {
        identities.contains { $0.category == "conference" && $0.type == "text" }
    }

    /// Whether `room`'s server can speak for `inviter`: it's a group chat
    /// service of their server, say conference.example.org for example.org.
    /// The server's own domain doesn't count: a room never lives there, so
    /// that would be another of its users, who could name anyone.
    static func vouches(room: JID, for inviter: JID) -> Bool {
        room.domain.lowercased().hasSuffix("." + inviter.domain.lowercased())
    }

    // MARK: Bookmarks

    /// Brings our groups and our bookmarks in line, then joins the groups.
    /// `done` says whether the list was read, or the server has none to read;
    /// when it wasn't, the groups we have are joined meanwhile and the read is
    /// owed again (see `owe`).
    func syncBookmarks(then done: @escaping @Sendable (Bool) -> Void = { _ in }) {
        readBookmarks { [weak self] list, isRead in
            guard let self else { return }
            // A server without the node has no list; ours is not emptied for it.
            if let list { self.applyBookmarks(list) } else { self.joinRooms() }
            done(isRead)
        }
    }

    /// Reads the bookmarks again on a live session and applies what differs
    /// the way a notification of each would. `syncBookmarks` isn't used: it
    /// publishes a bookmark for every group that has none, which on a live
    /// session includes one just joined whose publish is still on its way,
    /// and it marks a group whose bookmark is gone as left without leaving
    /// the room. It also joins every room again, failed ones included.
    /// `done` says whether the list was read, or the server has none to read.
    /// The old kind (XEP-0048) is read the same way, from its one item.
    func refreshBookmarks(then done: @escaping @Sendable (Bool) -> Void) {
        readBookmarks { [weak self] list, isRead in
            if let list { self?.reconcileBookmarks(list) }
            done(isRead)
        }
    }

    /// The list on the server, or nil if there is none to apply: the server
    /// doesn't offer bookmarks, or the read failed. A node that isn't there
    /// is an empty list, but a failure is not: applying it would leave every
    /// group we're in as one another device had left.
    func readBookmarks(_ done: @escaping @Sendable (_ list: [Bookmark]?, _ isRead: Bool) -> Void) {
        let legacy = usesLegacyBookmarks
        readNode(legacy ? NS.legacyBookmarks : NS.bookmarks, as: "Bookmarks") { read in
            switch read {
            case .items(let page):
                done(legacy ? page.items.first?.payload.map(Bookmark.legacyList(in:)) ?? [] : page.items.compactMap { Bookmark(id: $0.id, payload: $0.payload) }, true)
            case .noNode: done([], true)
            case .unsupported: done(nil, true)
            case .failed: done(nil, false)
            }
        }
    }

    /// Applies a complete list from another device as its notifications
    /// would, touching only what differs.
    func reconcileBookmarks(_ bookmarks: [Bookmark]) {
        let groups = Dictionary(((try? database.groupChats()) ?? []).map { ($0.jid, $0) }, uniquingKeysWith: { a, _ in a })
        for bookmark in bookmarks {
            let group = groups[bookmark.jid]
            let isIn = group.map { !$0.hasLeft } ?? false
            if bookmark.autojoin {
                if let group, isIn, group.isBookmarked, group.notify == bookmark.notify,
                   bookmark.name?.isEmpty != false || group.name == bookmark.name { continue }
            } else if !isIn {
                // It says to leave a room we aren't in.
                continue
            }
            bookmarkChanged(.published(bookmark))
        }
        let listed = Set(bookmarks.map(\.jid))
        for group in groups.values where !group.hasLeft && group.isBookmarked && !listed.contains(group.jid) {
            bookmarkChanged(.retracted(group.jid))
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
                join(joined.jid, nickname: joined.nickname, mayCreate: false)
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
        let options = Self.dataForm(type: "submit", formType: "http://jabber.org/protocol/pubsub#publish-options", fields: Self.settingsNodeFields(maxItems: "max"))
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
    public func joinGroup(_ room: JID, nickname: String? = nil, mayCreate: Bool = true, password: String? = nil) async throws {
        try await joinGroup(room, nickname: nickname, mayCreate: mayCreate, password: password, timeout: Self.joinTimeout)
    }

    static let joinTimeout: TimeInterval = 30

    func joinGroup(_ room: JID, nickname: String?, mayCreate: Bool, password: String?, timeout: TimeInterval) async throws {
        guard await waitForConnection() else { throw GroupError.notConnected }
        if let status = roomStatus(room), status.isJoined {
            try database.removeGroupInvitation(room)
            return
        }
        let existing = try database.groupChat(room)
        let nickname = nickname ?? existing?.nickname ?? defaultNickname
        let group = try database.joinGroupChat(room, nickname: nickname)
        if let password { try database.updateGroupChat(room) { $0.password = password } }
        reloadKnownRooms()
        if roomStatus(room) != nil { updateRoom(room) { $0 = nil } }
        join(room, nickname: nickname, mayCreate: mayCreate, mustBeFound: !mayCreate, password: password)
        do {
            _ = try await waitForRoom(room, timeout: timeout)
        } catch {
            withdrawJoin(room)
            if existing == nil {
                try? deleteConversation(id: group.conversationId)
            } else {
                try? database.updateGroupChat(room) {
                    $0.hasLeft = existing?.hasLeft ?? false
                    $0.password = existing?.password
                }
            }
            reloadKnownRooms()
            updateRoom(room) { $0 = nil }
            throw error
        }
        try database.removeGroupInvitation(room)
        if let joined = try database.groupChat(room) { publishBookmark(joined) }
    }

    /// Joins a group we were invited to, once the user has decided to. The
    /// invitation stays if the room refuses.
    public func acceptGroupInvitation(_ room: JID) async throws {
        // The address came from a stranger's stanza: it must be a room already.
        guard try await isGroupChatRoom(room) else { throw GroupError.joinFailed(String(localized: "This group doesn't exist.")) }
        try await joinGroup(room, mayCreate: false, password: try database.groupInvitation(room)?.password)
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
    /// they're a contact we have a subscription with, and the invitation was
    /// relayed through the room: a direct one (XEP-0249) has no decline.
    static func sendsDecline(for invitation: GroupInvitation, inviter: Contact?) -> Bool {
        guard !invitation.isDirect, let inviter, inviter.hasConsent else { return false }
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
    ///
    /// A failure before the group is set up leaves nothing of it behind, here
    /// or on the server, so trying again makes one group. Once it is set up
    /// it exists: a failure to invite is reported as a warning with Retry
    /// instead, as an error would make the user create it twice.
    public func createGroup(name: String, inviting invitees: [JID]) async throws -> JID {
        guard await waitForConnection() else { throw GroupError.notConnected }
        let service = try await mucService()
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        let local = String((0..<12).map { _ in alphabet.randomElement()! })
        guard let room = JID("\(local)@\(service)") else { throw GroupError.noService }

        let group = try database.joinGroupChat(room, nickname: defaultNickname, name: name)
        reloadKnownRooms()
        join(room, nickname: defaultNickname, discover: false)
        do {
            let status = try await waitForRoom(room)
            if status.wasCreated {
                do {
                    try await configurePrivateRoom(room, name: name)
                } catch {
                    // The room stays locked until it is configured, and nobody
                    // else can enter. It is ours and empty, so it goes.
                    await destroyUnfinishedRoom(room)
                    throw error
                }
            }
        } catch {
            withdrawJoin(room)
            try? deleteConversation(id: group.conversationId)
            reloadKnownRooms()
            updateRoom(room) { $0 = nil }
            throw error
        }
        if let hasArchive = await refreshedRoomInfo(room) { updateRoom(room) { $0?.hasArchive = hasArchive } }
        if let group = try database.groupChat(room) { publishBookmark(group) }
        if !invitees.isEmpty {
            do {
                try await invite(invitees, to: room)
            } catch {
                warnOfUnsentInvitations(invitees, to: room, error)
            }
        }
        return room
    }

    private func destroyUnfinishedRoom(_ room: JID) async {
        do {
            _ = try await client.context.writer.write(iq: OutboundStanza.destroy(room, reason: nil))
        } catch {
            // The creation fails with the error that led here, which the user
            // sees. A room we couldn't remove is an empty locked one under a
            // name nobody has, and trying again makes a new one.
            logger.warning("Couldn't destroy the unfinished room \(room, privacy: .private): \(ServerError.classify(error).condition, privacy: .private)")
        }
    }

    private func warnOfUnsentInvitations(_ invitees: [JID], to room: JID, _ error: Error) {
        let lead = String(localized: "The group was created, but inviting to it failed")
        let detail = ServerError.isFromServer(error) ? ServerError.classify(error).describe(lead) : "\(lead): \(error.localizedDescription)"
        warnings.post("room-invite:\(room)", title: String(localized: "Invitations not sent"), detail: detail) { [weak self] in
            try await self?.invite(invitees, to: room)
        }
    }

    /// Adds `invitees` to the group. Owners and admins make them members and
    /// invite them directly; others ask the room to invite them.
    public func invite(_ invitees: [JID], to room: JID) async throws {
        try await invite(invitees, to: room, grace: Self.inviteGrace)
    }

    /// How long a room has to bounce a mediated invitation before it counts as accepted.
    static let inviteGrace: TimeInterval = 3

    func invite(_ invitees: [JID], to room: JID, grace: TimeInterval) async throws {
        if try await joinedStatus(room).isOwnerOrAdmin {
            // One request each: Prosody only applies the first item of a request.
            for invitee in invitees {
                _ = try await roomRequest(OutboundStanza.affiliation(.member, of: invitee, in: room))
            }
            updateRoom(room) { status in
                for invitee in invitees { status?.setAffiliation(.member, of: invitee) }
            }
        } else {
            try await askRoomToInvite(invitees, to: room, grace: grace)
        }
        // For the relayed branch this is a direct invitation too: the relayed
        // one names us only on the room's word, which clients like ours trust
        // only from a room on our own server. Ours goes out after it, so the
        // room lets them in.
        for invitee in invitees { write(OutboundStanza.invitation(to: invitee, room: room)) }
    }

    /// Sends the room's own kind of invitation, and returns once it has taken
    /// it. A room answers no invitation it accepts, so that is when it has
    /// had the stream's acknowledgement and `grace` after it without bouncing
    /// the message with an error (forbidden, say, if invitations are off).
    private func askRoomToInvite(_ invitees: [JID], to room: JID, grace: TimeInterval) async throws {
        let message = Martin.Message()
        message.to = Martin.JID(room.martin)
        let id = OutboundStanza.newId()
        message.id = id
        let x = Element(name: "x", xmlns: NS.mucUser)
        for invitee in invitees {
            x.addChild(Element(name: "invite", attributes: ["to": invitee.description]))
        }
        message.addChild(x)

        let (bounces, bounced) = AsyncStream.makeStream(of: ServerError.self)
        expectBounce(
            of: id, key: .message(id), peer: room,
            release: {},
            // The router doesn't pass on what a bounce that may pass said.
            repend: { bounced.yield(ServerError(condition: "remote-server-timeout", type: .wait)) },
            fail: { bounced.yield($0) },
        )
        let (acknowledgements, acknowledged) = AsyncStream.makeStream(of: Void.self)
        let subscription = client.module(.streamManagement).ackedStanzas
            .filter { $0.id == id }
            .sink { _ in acknowledged.yield() }
        defer {
            subscription.cancel()
            acknowledged.finish()
            bounced.finish()
        }
        guard writeAwaitingHandOver(message) else { throw GroupError.notConnected }
        if client.modulesManager.moduleOrNil(.streamManagement)?.ackEnabled == true {
            requestAcknowledgement()
            // No acknowledgement in time means a slow server, not a refusal.
            try? await withTimeout(Self.inviteAcknowledgementTimeout) {
                for await _ in acknowledgements { return }
            }
        } else {
            // Without stream management the reply to a ping, which is answered
            // after what came before it, stands in.
            await withCheckedContinuation { continuation in
                client.module(.ping).ping(Martin.JID(account.martin), timeout: Self.inviteAcknowledgementTimeout) { _ in continuation.resume() }
            }
        }
        // A bounce that came meanwhile is waiting in the stream.
        let refusal = try? await withTimeout(grace) { await bounces.first { _ in true } }
        guard isConnected else { throw GroupError.notConnected }
        if let refusal { throw refusal }
    }

    static let inviteAcknowledgementTimeout: TimeInterval = 10

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
        guard await waitForConnection() else { throw GroupError.notConnected }
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
                // There was no bookmark to remove, or the server keeps none.
                case .failure(let error) where Self.hasNoBookmarkToRemove(error):
                    continuation.resume()
                case .failure(let error):
                    self?.logger.warning("Couldn't remove bookmark for \(room, privacy: .private): \(error.localizedDescription, privacy: .private)")
                    continuation.resume(throwing: GroupError.couldntLeave)
                }
            }
        }
        try? database.updateGroupChat(room) { $0.isBookmarked = false }
    }

    private static func hasNoBookmarkToRemove(_ error: PubSubError) -> Bool {
        switch NodeRead(error) {
        case .noNode, .unsupported: true
        case .items, .failed: false
        }
    }

    func leaveRoom(_ room: JID) {
        withdrawJoin(room)
        cancelRejoin(room, resettingBackoff: true)
        updateRoom(room) { $0 = nil }
        dropDeferred(in: room)
        try? database.updateGroupChat(room) { $0.hasLeft = true }
        ShareSuggestions.remove([room])
        warnings.clear(room: room)
    }

    /// Tells the room we're gone, if we're in it or may be: a join that is
    /// still waiting can be accepted after we gave up on it, which would leave
    /// us in the room as an occupant nothing reads from.
    private func withdrawJoin(_ room: JID) {
        guard let status = roomStatus(room), status.isJoined || status.phase == .joining else { return }
        let presence = Presence()
        presence.type = .unavailable
        presence.to = room.martin.with(resource: status.nickname)
        write(presence)
    }

    /// What a room answered to a subject change.
    enum SubjectOutcome: Sendable {
        /// Its echo of a change, from the occupant who made it.
        case changed(room: JID, subject: String)
        case failed(room: JID, id: String, ServerError)
    }

    /// Tells a waiting `setSubject` how the room answered.
    private func reportSubjectOutcome(of stanza: Martin.Message, in room: JID) {
        if stanza.type == .error {
            guard let id = stanza.id else { return }
            subjectOutcomes.send(.failed(room: room, id: id, ServerError.bounce(of: stanza)))
        } else if stanza.type == .groupchat, stanza.body == nil, let subject = stanza.firstChild(name: "subject"),
                  stanza.from?.resource == roomStatus(room)?.nickname {
            subjectOutcomes.send(.changed(room: room, subject: subject.value ?? ""))
        }
    }

    /// Changes the group's subject, and returns once the room has put it up
    /// or said why not. Whether we may is the room's call: moderators always,
    /// participants if it lets them (`RoomStatus.canChangeSubject`).
    public func setSubject(_ subject: String, in room: JID) async throws {
        _ = try await joinedStatus(room)
        do {
            try await retryingPassingErrors { try await sendSubject(subject, in: room) }
        } catch let error as ServerError where ["forbidden", "not-allowed"].contains(error.condition) {
            throw GroupError.notAllowed
        }
    }

    private func sendSubject(_ subject: String, in room: JID) async throws {
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
        guard writeAwaitingHandOver(message) else { throw GroupError.notConnected }
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
        // In the order the server lists them, as a gateway can also call
        // itself a group chat service, and the first listed is the server's own.
        var passing: ServerError?
        for item in items.items {
            let info: DiscoveryModule.DiscoveryInfoResult
            do {
                info = try await disco.info(for: item.jid, node: item.node)
            } catch {
                // A component that won't say what it is isn't a group chat
                // service, unless it only failed for now: then the one we
                // want may be that one, and "doesn't host" would be untrue.
                let error = ServerError.classify(error)
                if error.isPassing { passing = passing ?? error }
                continue
            }
            if Self.isGroupChat(identities: info.identities.map { ($0.category, $0.type) }) {
                let service = item.jid.stringValue
                lock.withLock { $0.mucService = service }
                return service
            }
        }
        // The user retries; nothing is cached, so the next try asks again.
        if let passing { throw GroupError.lookupFailed(passing) }
        throw GroupError.noService
    }

    private func configurePrivateRoom(_ room: JID, name: String) async throws {
        let form = try await ownerForm(of: room)
        let offered = Set(form?.filterChildren(name: "field", xmlns: nil).compactMap { $0.getAttribute("var") } ?? [])
        let fields = Self.privateRoomFields(name: name, offered: offered)
        try await submitOwnerForm(fields, to: room)
    }

    /// Whether an owner form with these fields is Openfire's, which alone
    /// offers its own `x-muc#roomconfig_` ones.
    static func isOpenfireForm(offered: Set<String>) -> Bool {
        !offered.isDisjoint(with: ["x-muc#roomconfig_canchangenick", "x-muc#roomconfig_registration", "x-muc#roomconfig_reservednick"])
    }

    /// The owner form fields to submit for a private room, out of those the form offers.
    static func privateRoomFields(name: String, offered: Set<String>) -> [String: [String]] {
        let archiveFields = ["muc#roomconfig_enablearchiving", "mam"]
        var wanted: [String: [String]] = [
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
        ]
        // Openfire's archive only keeps what a room logs, but elsewhere (ejabberd's mod_muc_log)
        // this writes the conversation to a file a server may publish over HTTP, so it is
        // only for Openfire. Its form says so: it is the one that offers these fields.
        if Self.isOpenfireForm(offered: offered) {
            wanted["muc#roomconfig_enablelogging"] = ["1"]
        }
        return wanted.filter { offered.contains($0.key) }
    }

    /// The configuration form the room offers its owner.
    func ownerForm(of room: JID) async throws -> Element? {
        let response = try await roomRequest(OutboundStanza.configurationRequest(of: room))
        return response.firstChild(name: "query", xmlns: NS.mucOwner)?.firstChild(name: "x", xmlns: NS.dataForms)
    }

    func submitOwnerForm(_ fields: [String: [String]], to room: JID) async throws {
        _ = try await roomRequest(OutboundStanza.configuration(fields, of: room))
    }
}
