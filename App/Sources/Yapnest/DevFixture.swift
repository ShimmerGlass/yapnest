#if DEBUG
import Foundation
import GRDB
import YapnestKit

/// A ready-made account for driving the app from UI tests and scripts, set
/// with `YAPNEST_DEV_FIXTURE=<name>`. Its conversations are written straight
/// into a fresh database and the session never connects, so nothing needs a
/// server and every launch starts from the same state.
enum DevFixture: String, CaseIterable {
    /// A few short messages, then an email-like message more than two screens
    /// tall, with long unbroken links, as the newest. A row that tall can
    /// never be half on screen, which the list's bottom anchoring got wrong.
    case tallNewest = "tall-newest"
    /// More messages than the first window holds, of mixed heights and with
    /// links, so scrolling up loads older ones from the database.
    case longHistory = "long-history"
    /// A long chat of mostly tall, email-shaped messages of varied lengths,
    /// both ways, with a tall one newest. The lazy stack can't have measured
    /// them all, so its estimate of the content height is far off and swings.
    case tallHistory = "tall-history"
    /// A short chat, Reactions, on an account whose quick reactions have been
    /// learned: 🔥 and 🎉 picked most, then 😢 (a default, picked once) and 🙏 (twice), and 👍 topping the row up.
    case learnedReactions = "learned-reactions"
    /// A bot whose newest message offers replies and actions (XEP-0439), after
    /// one with an action alone, to see the buttons under the bubbles.
    case quickResponses = "quick-responses"
    /// Small chats for the UI tests of messages' menus, the composer, the chat
    /// list and the banners; see `InteractionsFixture`.
    case interactions
    /// An account whose other OMEMO devices differ in use: one used yesterday,
    /// one quiet for 120 days, one never seen sending for 200 days, one new.
    case devices
    /// An offline contact whom the user shares last seen with, two hours
    /// after they left.
    case lastSeen = "last-seen"
    /// Two groups with other people in them: one where we're the owner and
    /// a moderator, one where we're a plain member. The room's state is set
    /// by hand, as the session never connects; see `configure(_:)`.
    case moderation
    /// Seeded chats of every kind of content, set with `fuzz:<seed>`; see `FuzzFixture`.
    case fuzz
    /// Photos not downloaded yet, announced with their shapes and previews; see `PreviewsFixture`.
    case previews
    /// Realistic chats for the App Store screenshots; see `ScreenshotsFixture`.
    case screenshots
    /// Arabic and Hebrew chats beside an English one, for checking right-to-left layout; see `RTLFixture`.
    case rtl

    static let account = JID("fixture@fixture.test")!
    static let mailPeer = JID("mail@fixture.test")!
    static let historyPeer = JID("history@fixture.test")!
    static let archivePeer = JID("archive@fixture.test")!
    /// The words the newest message of `tall-history` ends with.
    static let archiveEndMarker = "End of Archive 0299."
    /// The words the tall message ends with, for finding it from a test.
    static let tallEndMarker = "End of the Nestauth notice."

    static var requested: DevFixture? {
        guard let name = ProcessInfo.processInfo.environment["YAPNEST_DEV_FIXTURE"] else { return nil }
        return FuzzFixture.seed(from: name) != nil ? .fuzz : DevFixture(rawValue: name)
    }

    /// Whether this launch runs on a fixture, which must stay offline.
    static var isActive: Bool { requested != nil }

    func fill(_ database: AppDatabase) throws {
        switch self {
        case .tallNewest: try Self.fillTallNewest(database)
        case .longHistory: try Self.fillLongHistory(database)
        case .tallHistory: try Self.fillTallHistory(database)
        case .learnedReactions: try Self.fillLearnedReactions(database)
        case .quickResponses: try Self.fillQuickResponses(database)
        case .interactions: try InteractionsFixture.fill(database)
        case .devices: try Self.fillDevices(database)
        case .lastSeen: try Self.fillLastSeen(database)
        case .moderation: try Self.fillModeration(database)
        case .fuzz: try FuzzFixture.requested?.fill(database)
        case .previews:
            try PreviewsFixture.fill(database)
            PreviewsFixture.holdDownloads(into: database)
        case .screenshots: try ScreenshotsFixture.fill(database)
        case .rtl: try RTLFixture.fill(database)
        }
    }

    /// What a fixture needs from the live session once it has the database,
    /// which is state a server would give.
    func configure(_ session: XMPPSession) {
        if self == .screenshots { ScreenshotsFixture.configure(session) }
        if self == .rtl { RTLFixture.configure(session) }
        guard self == .moderation else { return }
        session.joinForFixture(Self.ownedRoom, occupants: [
            RoomOccupant(nick: "fixture", jid: Self.account, affiliation: .owner, role: "moderator"),
            RoomOccupant(nick: "anna", jid: Self.anna, affiliation: .member),
            RoomOccupant(nick: "ben", jid: Self.ben, affiliation: .admin, role: "moderator"),
            RoomOccupant(nick: "cara", jid: Self.cara, affiliation: .owner, role: "moderator"),
        ], banned: [Self.dora])
        session.joinForFixture(Self.unnamedRoom, occupants: [
            RoomOccupant(nick: "fixture", jid: Self.account, affiliation: .owner, role: "moderator"),
            RoomOccupant(nick: "anna", jid: Self.anna, affiliation: .member),
        ])
        session.joinForFixture(Self.adminRoom, occupants: [
            RoomOccupant(nick: "fixture", jid: Self.account, affiliation: .admin, role: "moderator"),
            RoomOccupant(nick: "anna", jid: Self.anna, affiliation: .member),
            RoomOccupant(nick: "cara", jid: Self.cara, affiliation: .owner, role: "moderator"),
        ], banned: [Self.dora])
        session.joinForFixture(Self.memberRoom, occupants: [
            RoomOccupant(nick: "fixture", jid: Self.account, affiliation: .member),
            RoomOccupant(nick: "anna", jid: Self.anna, affiliation: .owner, role: "moderator"),
            RoomOccupant(nick: "ben", jid: Self.ben, affiliation: .member),
        ])
    }

    /// With `YAPNEST_DEV_INCOMING=<seconds>[,<seconds>...]`, a message from the chat
    /// named by `YAPNEST_DEV_OPEN` arrives after each delay, for watching what
    /// the open chat does with one.
    static func deliverIncoming(into database: AppDatabase) {
        let environment = ProcessInfo.processInfo.environment
        guard let delays = environment["YAPNEST_DEV_INCOMING"], let peer = environment["YAPNEST_DEV_OPEN"].flatMap(JID.init(_:)) else { return }
        for (index, delay) in delays.split(separator: ",").compactMap({ Double($0) }).enumerated() {
            Task {
                try? await Task.sleep(for: .seconds(delay))
                guard let conversation = try? database.conversation(with: peer) else { return }
                try? add(database, conversation, peer: peer, body: "A message arriving, number \(index + 1).", outgoing: false, at: Date())
            }
        }
    }

    // MARK: Content

    /// A fixed time, so day headers are the same on every run.
    private static let start = Date(timeIntervalSince1970: 1_790_000_000)

    static let reactionsPeer = JID("reactions@fixture.test")!

    static let devicesPeer = JID("nest@fixture.test")!

    static let lastSeenPeer = JID("wren@fixture.test")!

    private static func fillLastSeen(_ database: AppDatabase) throws {
        let conversation = try prepare(database, peer: lastSeenPeer, name: "Wren")
        try add(database, conversation, peer: lastSeenPeer, body: "See you at the nest.", outgoing: false, at: Date().addingTimeInterval(-3 * 3600))
        try database.setFlag(.sharesLastSeen, true)
        try database.setLastSeen(Date().addingTimeInterval(-2 * 3600), for: lastSeenPeer)
    }

    static let ownedRoom = JID("owned@groups.fixture.test")!
    static let memberRoom = JID("joined@groups.fixture.test")!
    /// One we own that has no name of its own, so it shows its address's.
    static let unnamedRoom = JID("unnamed@groups.fixture.test")!
    /// Where we are an admin, not an owner.
    static let adminRoom = JID("admin@groups.fixture.test")!
    static let anna = JID("anna@fixture.test")!
    static let ben = JID("ben@fixture.test")!
    static let cara = JID("cara@fixture.test")!
    /// Banned from the owned and the admin room.
    static let dora = JID("dora@fixture.test")!
    /// What the others say in both groups, and what we say in the owned one.
    static let othersWords = "Moderate this message."
    static let ownWords = "My own words."

    private static func fillModeration(_ database: AppDatabase) throws {
        for (room, name) in [(ownedRoom, "Owned"), (memberRoom, "Joined"), (adminRoom, "Admin"), (unnamedRoom, nil)] as [(JID, String?)] {
            let group = try database.joinGroupChat(room, nickname: "fixture", name: name)
            try database.updateGroupChat(room) { $0.isMembersOnly = true; $0.isNonAnonymous = true }
            try database.setHistoryState(peer: room, isComplete: true, cursor: nil)
            var time = Date().addingTimeInterval(-600)
            for (nick, jid, body) in [("anna", anna, othersWords), ("ben", ben, "Something else.")] {
                time = time.addingTimeInterval(60)
                _ = try database.insert(Message(
                    conversationId: group.conversationId, direction: .incoming, sender: jid, nick: nick, body: body, timestamp: time,
                    isRead: true, serverId: "\(room.localPart ?? "")-\(nick)",
                ))
            }
            if room == ownedRoom {
                _ = try database.insert(Message(
                    conversationId: group.conversationId, direction: .outgoing, sender: account, nick: "fixture", body: ownWords,
                    timestamp: time.addingTimeInterval(60), status: .displayed, isRead: true, serverId: "owned-me",
                ))
            }
        }
    }

    private static func fillDevices(_ database: AppDatabase) throws {
        let conversation = try prepare(database, peer: devicesPeer, name: "Nest")
        try add(database, conversation, peer: devicesPeer, body: "Hello from the nest.", outgoing: false, at: Date().addingTimeInterval(-60))
        let day: TimeInterval = 86400, now = Date()
        for (id, first, last) in [(101, 300.0, 1.0), (102, 300, 120), (103, 200, nil), (104, 2, nil)] as [(Int32, Double, Double?)] {
            try database.addOMEMODeviceForFixture(
                of: account, id: id, keyByte: UInt8(id),
                firstSeen: now.addingTimeInterval(-first * day), lastUsed: last.map { now.addingTimeInterval(-$0 * day) },
            )
        }
    }

    private static func fillLearnedReactions(_ database: AppDatabase) throws {
        let conversation = try prepare(database, peer: reactionsPeer, name: "Reactions")
        var time = Date().addingTimeInterval(-600)
        for (index, body) in ["Did you see the nest?", "Three eggs now!", "Long-press this one."].enumerated() {
            time = time.addingTimeInterval(60)
            try add(database, conversation, peer: reactionsPeer, body: body, outgoing: index == 1, at: time)
        }
        let now = Date()
        for (emoji, picks) in [("🔥", 4), ("🎉", 3), ("🙏", 2), ("😢", 1)] {
            for _ in 0..<picks { try database.recordReactionPick(emoji, at: now) }
        }
    }

    static let botPeer = JID("bot@fixture.test")!

    private static func fillQuickResponses(_ database: AppDatabase) throws {
        let conversation = try prepare(database, peer: botPeer, name: "Bot")
        let time = Date().addingTimeInterval(-300)
        func offer(_ body: String, _ quickResponses: QuickResponses, at time: Date) throws {
            var message = Message(conversationId: conversation.id!, direction: .incoming, sender: botPeer, body: body, timestamp: time, isRead: true)
            message.quickResponses = quickResponses
            _ = try database.insert(message)
        }
        try offer("Pull request #12 is ready.", QuickResponses(actions: [.init(id: "merge", label: "Merge Now!"), .init(id: "close", label: "Close")]), at: time)
        try offer(
            "Shall I deploy it to the nest?",
            QuickResponses(
                responses: [.init(value: "yes", label: "Sure!"), .init(value: "no", label: "Not now"), .init(value: "Ask me again tomorrow, please")],
                actions: [.init(id: "deploy", label: "Deploy"), .init(id: "rollback", label: "Roll back")],
            ),
            at: time.addingTimeInterval(60),
        )
    }

    private static func fillTallNewest(_ database: AppDatabase) throws {
        let conversation = try prepare(database, peer: mailPeer, name: "Mail")
        let short = [
            "Did the reset email come through?",
            "Not yet, I'll check the spam folder.",
            "It can take a minute.",
            "Found it, forwarding it to you now.",
            "Thanks!",
            "Here it is:",
        ]
        var time = start
        for (index, body) in short.enumerated() {
            time = time.addingTimeInterval(60)
            try add(database, conversation, peer: mailPeer, body: body, outgoing: index.isMultiple(of: 2), at: time)
        }
        try add(database, conversation, peer: mailPeer, body: tallEmail, outgoing: false, at: time.addingTimeInterval(60))
    }

    private static func fillLongHistory(_ database: AppDatabase) throws {
        let conversation = try prepare(database, peer: historyPeer, name: "History")
        // Past the first window, so the top of what opens isn't the beginning.
        let count = AppDatabase.initialWindow + 250
        var random = SeededRandom(seed: 7)
        for index in 0..<count {
            let label = String(format: "History %04d", index)
            let body = switch index % 9 {
            case 3: "\(label): \(words(14, &random)) https://example.com/\(token(30, &random))"
            case 6: "\(label): \(words(70, &random))"
            case 8: "\(label)\n\(words(25, &random))\n\n\(words(20, &random))"
            default: "\(label): \(words(Int(random.next() % 9) + 2, &random))"
            }
            try add(database, conversation, peer: historyPeer, body: body, outgoing: index % 3 == 1, at: start.addingTimeInterval(TimeInterval(index * 60)))
        }
        // Calls between the newest messages, which the first window holds.
        let calls: [(CallOutcome, Message.Direction, TimeInterval?)] = [
            (.answered, .outgoing, 151), (.missed, .incoming, nil), (.declined, .outgoing, nil), (.answered, .incoming, 9), (.busy, .outgoing, nil),
        ]
        for (offset, (outcome, direction, duration)) in calls.enumerated() {
            let at = start.addingTimeInterval(TimeInterval((count - 40 + offset * 5) * 60 + 30))
            try addCall(database, conversation, peer: historyPeer, outcome: outcome, direction: direction, duration: duration, at: at, sid: "history-call-\(offset)")
        }
    }

    /// A call row, as the session writes it: no words, and its session id as the remote id.
    static func addCall(
        _ database: AppDatabase, _ conversation: Conversation, peer: JID, outcome: CallOutcome, direction: Message.Direction,
        duration: TimeInterval?, at time: Date, sid: String,
    ) throws {
        var message = Message(
            conversationId: conversation.id!, direction: direction, sender: direction == .outgoing ? account : peer,
            body: "", timestamp: time, status: direction == .outgoing ? .displayed : nil, isRead: true, remoteId: sid,
        )
        message.callOutcome = outcome
        message.callDuration = duration
        _ = try database.insert(message)
    }

    private static func fillTallHistory(_ database: AppDatabase) throws {
        let conversation = try prepare(database, peer: archivePeer, name: "Archive")
        let count = 300
        var random = SeededRandom(seed: 99)
        for index in 0..<count {
            let label = String(format: "Archive %04d", index)
            let newest = index == count - 1
            let body: String
            if newest {
                body = tallEmail(label: label, lines: 70, links: 4, ending: archiveEndMarker, random: &random)
            } else if index % 3 == 1 {
                body = "\(label): \(words(Int(random.next() % 6) + 2, &random))"
            } else {
                // The older half is much taller than the newer, so what the stack
                // has measured near the bottom is a poor guide to the rest.
                let lines = index < count / 2 ? 60 + Int(random.next() % 90) : 8 + Int(random.next() % 40)
                body = tallEmail(label: label, lines: lines, links: 1 + Int(random.next() % 4), ending: "End of \(label).", random: &random)
            }
            try add(database, conversation, peer: archivePeer, body: body, outgoing: random.next() % 3 == 0, at: start.addingTimeInterval(TimeInterval(index * 60)))
        }
    }

    /// An email-shaped body of about `lines` paragraphs and wrapped lines,
    /// with long unbroken links.
    private static func tallEmail(label: String, lines: Int, links: Int, ending: String, random: inout SeededRandom) -> String {
        var parts = ["\(label)", "Subject: [Nestauth] Notice \(token(6, &random))", ""]
        var linksLeft = links
        for line in 0..<lines {
            if linksLeft > 0, line % max(1, lines / links) == 0 {
                linksLeft -= 1
                parts.append("https://auth.nest.test/\(token(8, &random))?token=\(token(300 + Int(random.next() % 400), &random))")
            } else {
                parts.append(words(8 + Int(random.next() % 14), &random))
            }
            if line % 4 == 3 { parts.append("") }
        }
        parts.append(ending)
        return parts.joined(separator: "\n")
    }

    /// A chat with nothing older on the server, and no link preview prompt
    /// for the addresses in its messages.
    static func completeChat(_ database: AppDatabase, _ peer: JID) throws -> Conversation {
        try database.setHistoryState(peer: peer, isComplete: true, cursor: nil)
        try database.setLinkPreviews(false, peer: peer)
        return try database.conversation(with: peer)
    }

    /// One message of a fixture chat, written by `write`. Outgoing when `from` is nil.
    struct Line {
        var minutesAgo: Double
        var from: JID?
        var body: String
        var id: String?
        var replyTo: (id: String, sender: JID, text: String)?
        var read = true
        var mention = false
        /// A picture, whose body is the address of the attachment.
        var photo = false
        var reactions: [(JID, String)] = []
    }

    /// Writes `lines` into a chat, with times relative to now. In a group,
    /// `nickname` is the account's and `nicks` the others'.
    static func write(_ database: AppDatabase, _ conversation: Conversation, nickname: String = "", nicks: [JID: String] = [:], _ lines: [Line]) throws {
        let now = Date()
        let isGroup = conversation.kind == .groupchat
        for line in lines {
            let outgoing = line.from == nil
            let sender = line.from ?? account
            var message = Message(
                conversationId: conversation.id!, direction: outgoing ? .outgoing : .incoming, sender: sender,
                nick: isGroup ? (outgoing ? nickname : nicks[sender]) : nil,
                body: line.photo ? "https://files.fixture.test/sunset.jpg" : line.body,
                timestamp: now.addingTimeInterval(-line.minutesAgo * 60), status: outgoing ? .displayed : nil, isRead: line.read,
                encryption: conversation.isEncrypted ? .omemo : .none,
                remoteId: line.id ?? UUID().uuidString,
                replyToId: line.replyTo?.id, replyToSender: line.replyTo?.sender, replyFallback: line.replyTo.map { "> " + $0.text },
                omemoDevice: conversation.isEncrypted && !outgoing ? 1 : nil, omemoTrust: conversation.isEncrypted ? .verified : nil,
            )
            message.mentionsMe = line.mention
            message.isWrittenHere = outgoing
            message = try database.insert(message)
            try database.writer.write { db in
                if line.photo {
                    try Attachment(
                        messageId: message.id!, url: message.body, name: "sunset.jpg", mimeType: "image/jpeg", size: 310_000,
                        width: 1200, height: 900, localFile: "screenshots-sunset.jpg", state: .ready,
                    ).insert(db)
                }
                for (jid, emoji) in line.reactions {
                    try Reaction(messageId: message.id!, sender: jid, nick: isGroup ? (jid == account ? nickname : nicks[jid] ?? "") : "", emoji: emoji).insert(db)
                }
            }
        }
    }

    /// A known contact, so the chat has no stranger banner, and an archive
    /// with nothing older, so nothing waits for a server.
    private static func prepare(_ database: AppDatabase, peer: JID, name: String) throws -> Conversation {
        try database.updateRosterItem(jid: peer, name: name, subscription: .both, isPending: false)
        let conversation = try database.conversation(with: peer)
        try database.setHistoryState(peer: peer, isComplete: true, cursor: nil)
        return conversation
    }

    private static func add(_ database: AppDatabase, _ conversation: Conversation, peer: JID, body: String, outgoing: Bool, at time: Date) throws {
        _ = try database.insert(Message(
            conversationId: conversation.id!, direction: outgoing ? .outgoing : .incoming, sender: outgoing ? account : peer,
            body: body, timestamp: time, status: outgoing ? .displayed : nil, isRead: true,
        ))
    }

    /// Shaped like a password reset notice, with made-up tokens.
    private static var tallEmail: String {
        var random = SeededRandom(seed: 42)
        let rule = String(repeating: "-", count: 40)
        func link(_ path: String) -> String { "https://auth.nest.test/\(path)?token=\(token(520, &random))" }
        return """
        From: "Nestauth" <auth@nest.test>
        Subject: [Nestauth] Reset your password

        A ONE-TIME LINK HAS BEEN GENERATED TO COMPLETE A REQUESTED ACTION

        Hi Fixture,

        We would like to confirm a requested action related to the security of your account at nest.test.

        Do not share this notification or the content of this notification with anyone.

        \(rule)

        If you made this request, click the validation link below.

        \(link("reset-password/step2"))

        \(rule)

        If you did NOT initiate this request, your credentials may have been compromised and you should:

         1. Revoke the validation link using the provided links below
         2. Reset your password or other login credentials
         3. Contact an Administrator

        To revoke the code, click the link below:

        \(link("revoke/reset-password"))

        \(rule)

        A copy of the request, for your records:

        \(link("requests/copy"))

        \(rule)

        This email was intended for Fixture. This event was generated due to an action from 2001:db8:5:9ee1:d4df:3c8e:6e86:c7cf. If you do not believe that your actions could have triggered this event or if you are concerned about your account's safety, please follow the explicit directions in this notification.

        \(tallEndMarker)
        """
    }

    private static let vocabulary = "the quick brown fox jumps over a lazy dog while we talk about nests twigs birds songs morning coffee trains and long afternoons by the river".split(separator: " ")

    private static func words(_ count: Int, _ random: inout SeededRandom) -> String {
        (0..<count).map { _ in String(vocabulary[Int(random.next() % UInt64(vocabulary.count))]) }.joined(separator: " ")
    }

    private static func token(_ length: Int, _ random: inout SeededRandom) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        return String((0..<length).map { _ in alphabet[Int(random.next() % UInt64(alphabet.count))] })
    }
}

/// The same numbers on every run (SplitMix64).
private struct SeededRandom {
    var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
#endif
