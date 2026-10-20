#if DEBUG
import Foundation
import GRDB
import UIKit
import YapnestKit

/// Small chats for the UI tests of what a person does with a message, the
/// composer, the chat list and a chat's banners: `YAPNEST_DEV_FIXTURE=interactions`.
/// Each chat holds only what its tests need, so a bubble's text names it.
enum InteractionsFixture {
    static let nest = JID("nest@fixture.test")!
    static let quotes = JID("quotes@fixture.test")!
    static let unread = JID("unread@fixture.test")!
    static let request = JID("robin@fixture.test")!
    static let blocked = JID("blocked@fixture.test")!
    static let long = JID("long@fixture.test")!
    static let wordy = JID("wordy@fixture.test")!
    static let emoji = JID("emoji@fixture.test")!
    static let calls = JID("calls@fixture.test")!

    /// A message long enough to be cut short behind "Show more": 30 lines,
    /// the first "Line 01 of a message that runs on." and the last "Line 30
    /// is where it finally ends.", which only the whole message shows.
    static let longBody: String = (1...30).map { index in
        index == 30 ? "Line 30 is where it finally ends." : String(format: "Line %02d of a message that runs on.", index)
    }.joined(separator: "\n")
    static let styling = JID("styling@fixture.test")!
    static let stylingNewest = "Styling ends here."

    /// The words the first message of the Quotes chat is made of, and what
    /// the last one, a reply to it, says.
    static let quotedWords = "The original words."
    static let replyWords = "Replying to the start."
    static let fillerCount = 40

    static func fill(_ database: AppDatabase, directory: AccountDirectory = AccountDirectory(account: DevFixture.account)) throws {
        let files = directory.attachments.directory
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        try fillNest(database, files: files)
        try fillQuotes(database)
        try fillUnread(database)
        try fillRequest(database)
        try fillBlocked(database)
        try fillLong(database)
        try fillWordy(database)
        try fillEmoji(database)
        try fillCalls(database)
        try fillStyling(database)
    }

    private static let account = DevFixture.account

    private static func chat(_ database: AppDatabase, _ peer: JID, _ name: String) throws -> Conversation {
        try database.updateRosterItem(jid: peer, name: name, subscription: .both, isPending: false)
        let conversation = try database.conversation(with: peer)
        try database.setHistoryState(peer: peer, isComplete: true, cursor: nil)
        return conversation
    }

    @discardableResult
    private static func add(
        _ database: AppDatabase, _ conversation: Conversation, from peer: JID, _ body: String, outgoing: Bool = false, read: Bool = true,
        at time: Date, remoteId: String = UUID().uuidString, status: Message.Status? = nil, replyTo: (id: String, sender: JID, text: String)? = nil,
    ) throws -> Message {
        try database.insert(Message(
            conversationId: conversation.id!, direction: outgoing ? .outgoing : .incoming, sender: outgoing ? account : peer,
            body: body, timestamp: time, status: outgoing ? status ?? .displayed : nil, isRead: read, remoteId: remoteId,
            replyToId: replyTo?.id, replyToSender: replyTo?.sender, replyFallback: replyTo.map { "> " + $0.text },
        ))
    }

    private static func fillNest(_ database: AppDatabase, files: URL) throws {
        let conversation = try chat(database, nest, "Nest")
        var time = Date().addingTimeInterval(-3600)
        func next() -> Date { time.addTimeInterval(60); return time }

        let link = try add(database, conversation, from: nest, "Morning! Notes are at https://example.com/nest-notes", at: next())
        // A stored preview, an empty one, so nothing is fetched.
        try database.writer.write { db in
            try LinkPreview(url: link.link ?? "https://example.com/nest-notes", kind: .none, fetchedAt: Date(timeIntervalSince1970: 1_790_000_000)).save(db)
        }

        let photo = try add(database, conversation, from: nest, "https://files.fixture.test/twig.png", at: next())
        try png(width: 200, height: 120).write(to: files.appending(path: "interactions-twig.png"), options: .atomic)
        let file = try add(database, conversation, from: nest, "https://files.fixture.test/eggs.txt", at: next())
        try Data("Three eggs, one nest.\n".utf8).write(to: files.appending(path: "interactions-eggs.txt"), options: .atomic)
        try database.writer.write { db in
            for (message, name, type, localFile, size) in [
                (photo, "twig.png", "image/png", "interactions-twig.png", Int64(4000)),
                (file, "eggs.txt", "text/plain", "interactions-eggs.txt", Int64(22)),
            ] {
                try Attachment(
                    messageId: message.id!, url: message.body, name: name, mimeType: type, size: size,
                    width: type == "image/png" ? 200 : nil, height: type == "image/png" ? 120 : nil, localFile: localFile, state: .ready,
                ).insert(db)
            }
        }

        try add(database, conversation, from: nest, "React to this one.", at: next())
        try add(database, conversation, from: nest, "Copy me please.", outgoing: true, at: next())
        // Not yet sent, as the account is offline: editing or deleting it
        // then needs no server, which one that was sent would.
        try add(database, conversation, from: nest, "Edit me please.", outgoing: true, at: next(), status: .pending)
        try add(database, conversation, from: nest, "Delete me please.", outgoing: true, at: next(), status: .pending)
        try add(database, conversation, from: nest, "Sent already.", outgoing: true, at: next())
        let reacted = try add(database, conversation, from: nest, "Already reacted to.", at: next())
        try database.writer.write { db in
            try Reaction(messageId: reacted.id!, sender: account, emoji: "👍").insert(db)
        }
    }

    private static func fillQuotes(_ database: AppDatabase) throws {
        let conversation = try chat(database, quotes, "Quotes")
        var time = Date().addingTimeInterval(-7200)
        func next() -> Date { time.addTimeInterval(60); return time }
        try add(database, conversation, from: quotes, quotedWords, at: next(), remoteId: "quoted-start")
        for index in 1...fillerCount {
            try add(database, conversation, from: quotes, String(format: "Filler %02d to push the start off screen.", index), outgoing: index.isMultiple(of: 3), at: next())
        }
        try add(
            database, conversation, from: quotes, replyWords, outgoing: true, at: next(),
            replyTo: (id: "quoted-start", sender: quotes, text: quotedWords),
        )
    }

    /// Strikethrough, nested spans and preformatted blocks of every shape.
    private static func fillStyling(_ database: AppDatabase) throws {
        let conversation = try chat(database, styling, "Styling")
        var time = Date().addingTimeInterval(-5400)
        let wide = (1...12).map { "argument\($0)" }.joined(separator: ", ")
        let longBlock = (1...40).map { "block line \($0)" }.joined(separator: "\n")
        let bodies = [
            "Some ~struck out~ words, *bold _bold italic_ bold* and ~_struck italic_~.",
            "Run this:\n```swift\nlet nest = Nest()\nnest.hatch()\n```\nThen wait.",
            "Wide:\n```\nfunc build(\(wide)) -> Twig { Twig(\(wide)) }\n```",
            "Unclosed:\n```\nstill code *not bold* ~not struck~\nlast line of code",
            "> quoted intro\n> ```\n> quoted code\n> ```\n> quoted outro\nreply after the quote",
            "A long one:\n```\n\(longBlock)\n```\nAfter the long block.",
            stylingNewest,
        ]
        for (index, body) in bodies.enumerated() {
            time.addTimeInterval(60)
            try add(database, conversation, from: styling, body, outgoing: index.isMultiple(of: 3), at: time)
        }
    }

    private static func fillUnread(_ database: AppDatabase) throws {
        let conversation = try chat(database, unread, "Unread")
        var time = Date().addingTimeInterval(-1800)
        for body in ["First unread.", "Second unread.", "Third unread."] {
            time.addTimeInterval(60)
            try add(database, conversation, from: unread, body, read: false, at: time)
        }
    }

    /// Someone not in the roster who asked to see our presence.
    private static func fillRequest(_ database: AppDatabase) throws {
        let conversation = try database.conversation(with: request)
        try database.writer.write { db in
            try Contact(jid: request, subscription: .none, subscriptionRequestedAt: Date(), requestedNickname: "Robin").save(db)
        }
        try add(database, conversation, from: request, "Hi, may I add you?", at: Date().addingTimeInterval(-900))
    }

    private static func fillBlocked(_ database: AppDatabase) throws {
        let conversation = try chat(database, blocked, "Blocked")
        try add(database, conversation, from: blocked, "You blocked me.", at: Date().addingTimeInterval(-2400))
        try database.writer.write { db in
            var contact = try Contact.fetchOne(db, key: blocked) ?? Contact(jid: blocked)
            contact.isBlocked = true
            try contact.save(db)
        }
    }

    /// A short message, then a long one as the newest.
    private static func fillLong(_ database: AppDatabase) throws {
        let conversation = try chat(database, long, "Long")
        var time = Date().addingTimeInterval(-600)
        func next() -> Date { time.addTimeInterval(60); return time }
        try add(database, conversation, from: long, "Just a short one.", at: next())
        try add(database, conversation, from: long, longBody, at: next())
    }

    /// A long message with others after it, so it grows above the newest.
    /// Emoji alone in each direction, which are drawn without a bubble, and
    /// one as a reply, which keeps its bubble.
    private static func fillEmoji(_ database: AppDatabase) throws {
        let conversation = try chat(database, emoji, "Emoji")
        var time = Date().addingTimeInterval(-600)
        func next() -> Date { time.addTimeInterval(60); return time }
        try add(database, conversation, from: emoji, "Words to reply to.", at: next(), remoteId: "emoji-words")
        try add(database, conversation, from: emoji, "🪺🐣", at: next())
        try add(database, conversation, from: emoji, "🥚", outgoing: true, at: next())
        try add(database, conversation, from: emoji, "🐦", outgoing: true, at: next(), replyTo: (id: "emoji-words", sender: emoji, text: "Words to reply to."))
    }

    /// A call of each outcome, among words, so the rows can be told apart and
    /// the last one is a call, as the chat list's preview shows.
    private static func fillCalls(_ database: AppDatabase) throws {
        let conversation = try chat(database, calls, "Calls")
        var time = Date().addingTimeInterval(-900)
        func next() -> Date { time.addTimeInterval(60); return time }
        try add(database, conversation, from: calls, "Words before the calls.", at: next())
        let kinds: [(CallOutcome, Message.Direction, TimeInterval?)] = [
            (.answered, .outgoing, 151), (.answered, .incoming, 42), (.missed, .incoming, nil), (.declined, .outgoing, nil),
            (.cancelled, .outgoing, nil), (.busy, .outgoing, nil), (.failed, .incoming, nil),
        ]
        for (index, (outcome, direction, duration)) in kinds.enumerated() {
            try DevFixture.addCall(database, conversation, peer: calls, outcome: outcome, direction: direction, duration: duration, at: next(), sid: "calls-\(index)")
        }
    }

    private static func fillWordy(_ database: AppDatabase) throws {
        let conversation = try chat(database, wordy, "Wordy")
        var time = Date().addingTimeInterval(-500)
        func next() -> Date { time.addTimeInterval(60); return time }
        try add(database, conversation, from: wordy, longBody, outgoing: true, at: next())
        try add(database, conversation, from: wordy, "Short and sweet.", at: next())
        try add(database, conversation, from: wordy, "Wordy newest.", at: next())
    }

    private static func png(width: Int, height: Int) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).pngData { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }
}
#endif
