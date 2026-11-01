import Foundation
import GRDB
@preconcurrency import Martin
import Testing
@testable import YapnestKit

private let me = YapnestKit.JID("me@example.org")!
private let alice = YapnestKit.JID("alice@example.org")!
private let spammer = YapnestKit.JID("spam@example.net")!
private let stranger = YapnestKit.JID("stranger@example.net")!
private let room = YapnestKit.JID("cake@rooms.example.org")!

/// A new session and a resumed stream send the same outboxes: one left out
/// of the resume would wait for the next new session.
struct ResumeOutboxTests {
    let db: AppDatabase
    let session: XMPPSession
    let wire = FakeWire()

    init() throws {
        db = try AppDatabase.inMemory()
        session = try makeSession(me, database: db)
        session.lock.withLock { $0.retryBackoff = 0 }
        try db.updateRosterItem(jid: alice, name: "Alice", subscription: .both, isPending: false)
        try db.recordContactRequest(from: stranger, nickname: "Stranger")
        try db.joinGroupChat(room, nickname: "me", name: "Cake", isBookmarked: true)
        session.reloadKnownRooms()
    }

    /// Owes each outbox something, offline.
    private func seed() async throws {
        let chat = try db.conversation(with: alice)
        try db.insert(YapnestKit.Message(conversationId: chat.id!, direction: .outgoing, sender: me, body: "hi", status: .pending, remoteId: "m1"))
        try db.insert(YapnestKit.Message(
            conversationId: chat.id!, direction: .incoming, sender: alice, body: "yo", timestamp: Date(timeIntervalSince1970: 1), serverId: "s1",
        ))
        try await session.block(spammer)
        try await session.acceptContactRequest(from: stranger)
        try session.setNotify(.never, in: room)
        try await session.setNickname("Ada")
        try session.markRead(chat)
    }

    private func written(containing text: String) -> Bool {
        wire.written.contains { $0.element.stringValue.contains(text) }
    }

    private func wasSent(_ outbox: XMPPSession.Outbox) -> Bool {
        switch outbox {
        case .messages: wire.messages.contains { $0.id == "m1" }
        case .blocks: written(containing: "urn:xmpp:blocking")
        case .rosterChanges: wire.written.contains { ($0 as? Iq)?.type == .set && $0.element.stringValue.contains("jabber:iq:roster") }
        case .bookmarks: written(containing: NS.legacyBookmarks) || written(containing: NS.bookmarks)
        case .profile: written(containing: NS.nick)
        case .readStates: written(containing: NS.mds)
        }
    }

    @Test func aResumedStreamSendsEveryOutbox() async throws {
        try await seed()
        wire.answer { iq in
            iq.element.stringValue.contains(NS.legacyBookmarks) ? FakeWire.error(to: iq) : FakeWire.result(to: iq)
        }
        session.connectForTesting(wire)

        session.resumeWork()

        for outbox in XMPPSession.Outbox.allCases {
            #expect(await eventually(timeout: 40) { wasSent(outbox) }, "\(outbox)")
        }
        session.cancelAllRejoins()
    }

    @Test func anExtensionsResumedStreamSendsNone() async throws {
        let quiet = try makeSession(me, database: db, mode: .notificationService)
        try await seed()
        quiet.connectForTesting(wire)

        quiet.resumeWork()

        _ = await eventually(timeout: 0.5) { false }
        for outbox in XMPPSession.Outbox.allCases { #expect(!wasSent(outbox), "\(outbox)") }
    }
}
