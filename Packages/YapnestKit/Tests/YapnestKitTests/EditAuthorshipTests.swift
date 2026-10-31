import Testing
@testable import YapnestKit

/// The one check behind every correction and retraction, live or waiting
/// for its message: only the sender may change what they sent.
struct EditAuthorshipTests {
    private let alice = Author(jid: JID("alice@example.org")!)
    private let mallory = Author(jid: JID("mallory@example.org")!)
    private let room = JID("room@muc.example.org")!

    @Test func ourOwnMessagesAreOnlyOursToChange() {
        #expect(AppDatabase.mayEdit(true, by: alice, from: alice, outgoing: true, room: nil))
        // An edit from someone else can't touch a message of ours, nor ours one of theirs.
        #expect(!AppDatabase.mayEdit(true, by: alice, from: mallory, outgoing: false, room: nil))
        #expect(!AppDatabase.mayEdit(false, by: alice, from: alice, outgoing: true, room: nil))
    }

    @Test func theirMessagesAreOnlyTheirsToChange() {
        #expect(AppDatabase.mayEdit(false, by: alice, from: alice, outgoing: false, room: nil))
        #expect(!AppDatabase.mayEdit(false, by: alice, from: mallory, outgoing: false, room: nil))
    }

    @Test func inAGroupTheOccupantIdDecides() {
        let writer = Author(jid: room, nick: "al", occupantId: "x1")
        let renamed = Author(jid: room, nick: "alice", occupantId: "x1")
        let impostor = Author(jid: room, nick: "al", occupantId: "x2")
        #expect(AppDatabase.mayEdit(false, by: writer, from: renamed, outgoing: false, room: room))
        #expect(!AppDatabase.mayEdit(false, by: writer, from: impostor, outgoing: false, room: room))
    }

    @Test func aNickAloneFromTheArchiveIsNotProofInAGroup() {
        let writer = Author(jid: room, nick: "al")
        #expect(!AppDatabase.mayEdit(false, by: writer, from: Author(jid: room, nick: "al"), outgoing: false, room: room))
    }
}
