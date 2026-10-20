import Foundation
import GRDB
import Martin
import Testing
@testable import YapnestKit

/// Keeps the `<action-selected>` stanzas that reach a session, which it has no
/// use for itself.
private final class ActionRecorder: XmppModuleBase, XmppModule {
    static let ID = "test-action-recorder"
    let criteria = Criteria.name("message")
    let features = [String]()
    private let lock = NSLock()
    private var _stanzas: [Martin.Message] = []
    var stanzas: [Martin.Message] { lock.withLock { _stanzas } }
    func process(stanza: Stanza) throws {
        if let message = stanza as? Martin.Message, message.firstChild(name: "action-selected", xmlns: "urn:xmpp:tmp:quick-response") != nil { lock.withLock { _stanzas.append(message) } }
    }
}

extension LiveServer {
    /// Quick Response (XEP-0439) between two accounts: a message with replies
    /// and an action is kept, and choosing the action reaches the sender.
    /// `YAPNEST_INTEGRATION=1 YAPNEST_SERVER=ejabberd swift test --filter QuickResponseIntegration`
    struct QuickResponseIntegrationTests {
        let ns = "urn:xmpp:tmp:quick-response"

        @Test func choosingAnActionReachesTheSender() async throws {
            let a = try await LiveServer.connectedSession(LiveServer.jid("alice"), resource: "quick")
            let b = try await LiveServer.connectedSession(LiveServer.jid("bob"), resource: "quick")
            defer { a.disconnect(); b.disconnect() }
            let recorder = a.client.modulesManager.register(ActionRecorder())

            let text = "merge? \(UUID().uuidString.prefix(8))"
            let offer = Martin.Message()
            offer.to = Martin.JID(LiveServer.jid("bob").martin)
            offer.type = .chat
            offer.id = UUID().uuidString.lowercased()
            offer.body = text
            offer.addChild(Element(name: "response", attributes: ["xmlns": ns, "value": "yes", "label": "Sure!"]))
            offer.addChild(Element(name: "response", attributes: ["xmlns": ns, "value": "no"]))
            offer.addChild(Element(name: "action", attributes: ["xmlns": ns, "id": "merge", "label": "Merge Now!"]))
            a.client.context.writer.write(offer)

            var received: YapnestKit.Message?
            try await LiveServer.waitUntil("bob to receive the offer") {
                received = try b.database.reader.read { try YapnestKit.Message.filter(Column("body") == text).fetchOne($0) }
                return received != nil
            }
            let message = try #require(received)
            let stored = try #require(message.quickResponses)
            #expect(stored.responses == [.init(value: "yes", label: "Sure!"), .init(value: "no", label: nil)])
            #expect(stored.actions == [.init(id: "merge", label: "Merge Now!")])

            try b.chooseAction("merge", on: message)

            try await LiveServer.waitUntil("alice to get the chosen action") {
                recorder.stanzas.contains { $0.firstChild(name: "action-selected", xmlns: ns)?.getAttribute("id") == "merge" }
            }
            let chosen = try #require(recorder.stanzas.first { $0.firstChild(name: "action-selected", xmlns: ns) != nil })
            #expect(chosen.body == nil)
            let messageId = try #require(message.id)
            let recorded = try await b.database.reader.read { db in try YapnestKit.Message.fetchOne(db, key: messageId)?.quickResponses?.chosen }
            #expect(recorded == ["merge"])
        }
    }
}
