import Foundation
import GRDB
import Martin
import Testing
@testable import YapnestKit

private let me = YapnestKit.JID("me@example.org")!
private let alice = YapnestKit.JID("alice@example.org")!
private typealias Message = YapnestKit.Message

struct PeerErrorTests {
    let db: AppDatabase

    init() throws {
        db = try AppDatabase.inMemory()
    }

    private func sendMessage(status: Message.Status) throws -> Message {
        let id = try #require(try db.conversation(with: alice).id)
        return try db.insert(Message(conversationId: id, direction: .outgoing, sender: me, body: "hi", status: status, remoteId: "m1"))
    }

    private func ingestError(text: String) throws {
        let xml = """
        <message type='error' from='alice@example.org' to='me@example.org/t' id='m1'>
        <error type='cancel'><service-unavailable xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/>
        <text xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'>\(text)</text></error></message>
        """
        let stanza = Stanza.from(element: Element.from(string: xml)!) as! Martin.Message
        try db.ingest(try #require(InboundMessage(stanza, account: me, source: .live, now: Date())))
    }

    private func stored(_ message: Message) throws -> Message {
        try #require(try db.reader.read { try Message.fetchOne($0, key: message.id!) })
    }

    @Test func anErrorOnADeliveredMessageChangesNothing() throws {
        let message = try sendMessage(status: .delivered)
        try ingestError(text: "gotcha")
        let after = try stored(message)
        #expect(after.status == .delivered)
        #expect(after.error == nil)
    }

    @Test func anErrorOnASentMessageFailsItWithoutThePeersWords() throws {
        let message = try sendMessage(status: .sent)
        try ingestError(text: "Send money to evil.example")
        let after = try stored(message)
        #expect(after.status == .failed)
        #expect(after.error == String(localized: "The recipient's server refused the message."))
    }
}
