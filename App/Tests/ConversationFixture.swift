import Foundation
import GRDB
import SwiftUI
import Testing
import UIKit
import YapnestKit
@testable import Yapnest

/// Polls until `condition` holds, on the main actor so the model's own work
/// can run in between. Fails the test when it doesn't hold in time.
@MainActor
func eventually(
    _ message: @autoclosure () -> String = "condition not reached",
    timeout: Duration = .seconds(8),
    sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: () -> Bool,
) async {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        if ContinuousClock.now > deadline {
            Issue.record(Comment(rawValue: message()), sourceLocation: sourceLocation)
            return
        }
        try? await Task.sleep(for: .milliseconds(10))
    }
}

/// Holds for as long as `duration`: for "nothing happens" checks, where
/// waiting is the only way to see it.
@MainActor
func stays(for duration: Duration = .milliseconds(400), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + duration
    while ContinuousClock.now < deadline {
        if !condition() { return false }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return true
}

/// One conversation in an in-memory database, behind a session that never
/// connects.
@MainActor
final class ConversationFixture {
    let me = JID("me@example.com")!
    let peer: JID
    let database: AppDatabase
    let session: XMPPSession
    let conversation: Conversation
    private(set) var model: ConversationModel!
    private var clock: Date
    /// Which way up the model's list is: the iOS one by default, the Mac's with `false`.
    let isFlipped: Bool
    /// The model's scroll requests so far, set by a test once it has opened the list.
    var scrollRequestsAtOpen = 0

    /// Every test gets its own peer, as the draft writer is shared by the process.
    init(openingAt: Int64? = nil, kind: Conversation.Kind = .chat, isFlipped: Bool = Platform.flipsMessageList) throws {
        self.isFlipped = isFlipped
        peer = JID("peer-\(UUID().uuidString.lowercased())@example.com")!
        database = try AppDatabase.inMemory()
        session = try XMPPSession(credentials: .init(jid: me, password: "x"), resource: "t", database: database)
        conversation = try database.conversation(with: peer, kind: kind)
        // A fixed past time at noon, so day boundaries don't depend on when the test runs.
        clock = Calendar.current.date(bySettingHour: 12, month: 3, day: 5, year: 2024)
        model = ConversationModel(session: session, peer: peer, openingAt: openingAt, isFlipped: isFlipped)
    }

    /// Replaces the model, as when the chat is opened again.
    func reopen(openingAt: Int64? = nil) {
        model = ConversationModel(session: session, peer: peer, openingAt: openingAt, isFlipped: isFlipped)
    }

    /// A new message a minute after the last one made here, unless given a time.
    @discardableResult
    func add(
        _ body: String = "message",
        _ direction: Message.Direction = .incoming,
        at date: Date? = nil,
        read: Bool? = nil,
        status: Message.Status? = nil,
        remoteId: String? = nil,
    ) throws -> Message {
        let timestamp = date ?? clock.addingTimeInterval(60)
        clock = max(clock, timestamp)
        let message = Message(
            conversationId: conversation.id!, direction: direction, sender: direction == .incoming ? peer : me,
            body: body, timestamp: timestamp, status: status, isRead: read, remoteId: remoteId,
        )
        return try database.insert(message)
    }

    /// Many messages in one write; a message per minute, oldest first.
    @discardableResult
    func addMany(_ count: Int, _ direction: Message.Direction = .incoming, read: Bool = true) throws -> [Message] {
        var made: [Message] = []
        try database.writer.write { db in
            for index in 0..<count {
                clock = clock.addingTimeInterval(60)
                var message = Message(
                    conversationId: conversation.id!, direction: direction, sender: direction == .incoming ? peer : me,
                    body: "message \(index)", timestamp: clock, isRead: read,
                )
                try message.insert(db)
                made.append(message)
            }
        }
        return made
    }

    /// A file on `message`, as an upload or a download leaves it.
    func attach(_ name: String, to message: Message, state: YapnestKit.Attachment.State = .pendingUpload, mimeType: String? = nil) throws {
        try database.writer.write { db in
            try YapnestKit.Attachment(messageId: message.id!, url: nil, name: name, mimeType: mimeType, state: state).insert(db)
        }
    }

    /// Makes the chat a group chat we are in, before the model starts.
    func makeGroup() throws {
        try database.writer.write { db in
            try GroupChat(conversationId: conversation.id!, jid: peer, nickname: "me").insert(db)
        }
    }

    func start() async {
        model.start(previews: nil)
        await eventually("the conversation never loaded") { model.hasLoaded }
    }

    func start(waitingForPosition: Bool) async {
        await start()
        if waitingForPosition { await eventually("the list was never positioned") { model.isPositioned } }
    }

    var rowIDs: [Int64] { model.rows.map(\.id) }
}

extension Calendar {
    func date(bySettingHour hour: Int, month: Int, day: Int, year: Int) -> Date {
        date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }
}

extension ScrollPosition {
    /// The id the list was told to show, if it was told one.
    var messageID: Int64? { viewID as? Int64 }
}

/// A scroll view's report, with the list `distance` points short of its newest
/// message. Flipped, that is the start of the scroll view and the bars' inset
/// is its bottom one, as `MessageList` lays it out.
func geometry(flipped: Bool = Platform.flipsMessageList, distanceFromBottom distance: CGFloat, container: CGFloat = 800, content: CGFloat = 20_000, insetTop: CGFloat = 0) -> ScrollGeometry {
    ScrollGeometry(
        contentOffset: CGPoint(x: 0, y: flipped ? distance : content - container - insetTop - distance),
        contentSize: CGSize(width: 400, height: content),
        contentInsets: flipped ? .init(top: 0, leading: 0, bottom: insetTop, trailing: 0) : .init(top: insetTop, leading: 0, bottom: 0, trailing: 0),
        containerSize: CGSize(width: 400, height: container),
    )
}
