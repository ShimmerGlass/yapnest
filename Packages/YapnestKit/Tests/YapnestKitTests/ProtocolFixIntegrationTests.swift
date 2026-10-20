import Combine
import Foundation
import GRDB
import Martin
import Synchronization
import Testing
@testable import YapnestKit

extension XMPPSession {
    /// Whether the room's disco info lists `feature`.
    func roomAdvertises(_ feature: String, _ room: YapnestKit.JID) async throws -> Bool {
        try await client.module(.disco).info(for: Martin.JID(room.martin), node: nil).features.contains(feature)
    }

    /// Whether the server itself (its domain, where Openfire lists carbons)
    /// or the account (where Prosody does) lists `feature`.
    func serverAdvertises(_ feature: String) async throws -> Bool {
        if try await advertises([feature]) { return true }
        return try await client.module(.disco).info(for: Martin.JID(account.domain), node: nil).features.contains(feature)
    }
}

/// An `<iq>` as it went by on the wire, read back from a proxy's record.
private struct WireIq {
    let attributes: [String: String]
    let xml: String

    var id: String? { attributes["id"] }
    var type: String? { attributes["type"] }

    /// Every iq in `traffic`. Servers and Martin differ in the quotes they
    /// write attributes with, so both are read.
    static func all(in traffic: String) -> [WireIq] {
        let pattern = #"<iq\b([^>]*?)(?:/>|>(.*?)</iq>)"#
        let regex = try! NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
        let range = NSRange(traffic.startIndex..., in: traffic)
        return regex.matches(in: traffic, range: range).map { match in
            let whole = (traffic as NSString).substring(with: match.range)
            let tag = (traffic as NSString).substring(with: match.range(at: 1))
            return WireIq(attributes: Self.attributes(of: tag), xml: whole)
        }
    }

    /// The attributes written in a tag's text.
    static func attributes(of tag: String) -> [String: String] {
        let regex = try! NSRegularExpression(pattern: #"([\w:-]+)\s*=\s*(['"])(.*?)\2"#)
        var result: [String: String] = [:]
        for match in regex.matches(in: tag, range: NSRange(tag.startIndex..., in: tag)) {
            result[(tag as NSString).substring(with: match.range(at: 1))] = (tag as NSString).substring(with: match.range(at: 3))
        }
        return result
    }

    /// The attributes of the first `<name …>` tag inside this iq.
    func element(_ name: String) -> [String: String]? {
        let regex = try! NSRegularExpression(pattern: "<\(name)(?=[\\s/>])([^>]*)>")
        guard let match = regex.firstMatch(in: xml, range: NSRange(xml.startIndex..., in: xml)) else { return nil }
        return Self.attributes(of: (xml as NSString).substring(with: match.range(at: 1)))
    }
}

/// What a session hears of a contact's chat states.
private final class ChatStates: Sendable {
    private let heard = Mutex<[(YapnestKit.JID, InboundMessage.ChatState)]>([])
    private let token = Mutex<AnyCancellable?>(nil)

    init(_ session: XMPPSession) {
        token.withLock { $0 = session.events.sink { [self] event in
            if case .chatState(let peer, let state) = event { heard.withLock { $0.append((peer, state)) } }
        } }
    }

    func has(_ state: InboundMessage.ChatState, from peer: YapnestKit.JID) -> Bool {
        heard.withLock { $0.contains { $0.0 == peer && $0.1 == state } }
    }
}

extension LiveServer {
    /// Fixes made in the vendored Martin and in the code around it that no
    /// other suite would notice losing: each goes through YapnestKit's API
    /// against a real server, and where the wire is what matters, through a
    /// proxy that records it. Where the server lacks the feature a test is
    /// about, the test is cancelled with the reason.
    /// `YAPNEST_INTEGRATION=1 swift test --filter ProtocolFixIntegration`
    @Suite
    struct ProtocolFixIntegrationTests {
        let alice = LiveServer.jid("alice")
        let bob = LiveServer.jid("bob")
        let carol = LiveServer.jid("carol")

        private func fresh(_ jid: YapnestKit.JID, port: Int = LiveServer.target.port) throws -> XMPPSession {
            try LiveServer.makeSession(jid, resource: "fix-\(UUID().uuidString.prefix(6))", database: try AppDatabase.inMemory(), port: port)
        }

        private func message(_ body: String, in session: XMPPSession) throws -> YapnestKit.Message? {
            try session.database.reader.read { try YapnestKit.Message.filter(Column("body") == body).fetchOne($0) }
        }

        /// Sends `text` and waits for the recipient to have it, so a series
        /// of them arrives in the order it was written.
        private func say(_ text: String, from sender: XMPPSession, to recipient: XMPPSession) async throws {
            try sender.send(text, to: recipient.account)
            try await LiveServer.waitUntil("\(recipient.account) to receive \(text)") { try message(text, in: recipient) != nil }
        }

        // MARK: Archive

        /// A query for one contact's chat brings back only what they said
        /// (the `with` of XEP-0313), not what another contact wrote to us.
        @Test func archiveQueryWithAContactReturnsOnlyThem() async throws {
            let a = try fresh(alice), b = try fresh(bob), c = try fresh(carol)
            try await LiveServer.connected(a, b, c)
            defer { a.disconnect(); b.disconnect(); c.disconnect() }
            try await LiveServer.require("urn:xmpp:mam:2", of: a, "the test is about the archive's answer to a query")
            try b.setEncrypted(false, with: alice)
            try c.setEncrypted(false, with: alice)

            let tag = UUID().uuidString.prefix(6)
            // Interleaved, so one page of the archive holds both contacts' messages.
            try await say("\(tag) bob 1", from: b, to: a)
            try await say("\(tag) carol 1", from: c, to: a)
            try await say("\(tag) bob 2", from: b, to: a)
            try await say("\(tag) carol 2", from: c, to: a)
            try await say("\(tag) bob 3", from: b, to: a)

            // Alice's device forgets all but the newest, as one that was reinstalled would.
            let kept = try #require(try message("\(tag) bob 3", in: a))
            try await a.database.writer.write { db in
                _ = try YapnestKit.Message.filter(Column("id") != kept.id).deleteAll(db)
            }

            func restored() throws -> Bool {
                try message("\(tag) bob 1", in: a) != nil && message("\(tag) bob 2", in: a) != nil
            }
            var pages = 0
            while try !restored(), pages < 20 {
                guard try await a.loadOlderHistory(for: bob) else { break }
                pages += 1
            }
            if try !restored(), try await !a.advertises(["urn:xmpp:sid:0"]) {
                try Test.cancel("\(LiveServer.target.name) gives its archived messages no stanza-id, so the history can't be matched to the chat")
            }
            #expect(try restored(), "bob's earlier messages should have come back from the archive")
            #expect(try message("\(tag) carol 1", in: a) == nil)
            #expect(try message("\(tag) carol 2", in: a) == nil)
        }

        // MARK: Contacts

        /// A request its sender takes back goes from the receiver's list
        /// while they are connected, without a reconnect to learn of it.
        @Test func aWithdrawnRequestDisappearsWithoutReconnecting() async throws {
            let a = try fresh(alice), c = try fresh(carol)
            try await LiveServer.connected(a, c)
            defer { a.disconnect(); c.disconnect() }
            try? await a.removeContact(carol)
            try? await c.removeContact(alice)
            try await Task.sleep(for: .milliseconds(500))
            defer { Task { try? await a.removeContact(carol); try? await c.removeContact(alice) } }
            func requested() throws -> Bool { try a.database.contact(carol)?.hasContactRequest == true }

            c.addContact(alice)
            try await LiveServer.waitUntil("alice to get the request") { try requested() }
            try await LiveServer.waitUntil("carol's roster to show it pending") { try c.database.contact(alice)?.isSubscriptionPending == true }

            try await c.removeContact(alice)
            for _ in 0..<50 where try requested() { try await Task.sleep(for: .milliseconds(100)) }
            if try requested(), LiveServer.target.name == "ejabberd" {
                try Test.cancel("ejabberd only stops repeating a withdrawn request, so it goes at the receiver's next sign-in")
            }
            #expect(try !requested(), "the withdrawn request should be gone within 5 s")
        }

        // MARK: Blocking

        /// Blocking on one device makes the server push the list to the
        /// others, and a push is an iq set that has to be answered.
        @Test func blocklistPushIsAcknowledged() async throws {
            let proxy = try await FreezableProxy(to: UInt16(LiveServer.target.port))
            defer { proxy.stop() }
            let phone = try fresh(alice), laptop = try fresh(alice, port: proxy.port)
            try await LiveServer.connected(phone, laptop)
            defer { phone.disconnect(); laptop.disconnect() }
            try await LiveServer.waitUntil("the blocklists to be fetched") { phone.canBlock && laptop.canBlock }
            try? await phone.unblock(bob)
            defer { Task { try? await phone.unblock(bob) } }

            func push(_ kind: String) -> WireIq? {
                WireIq.all(in: proxy.serverTraffic).first { $0.type == "set" && $0.element(kind) != nil && $0.xml.contains("urn:xmpp:blocking") }
            }
            func acknowledged(_ push: WireIq) -> Bool {
                WireIq.all(in: proxy.clientTraffic).contains { $0.type == "result" && $0.id == push.id }
            }

            try await phone.block(bob)
            try await LiveServer.waitUntil("the server to push the block to the laptop") { push("block") != nil }
            let block = try #require(push("block"), "no block push reached the second device")
            try await LiveServer.waitUntil("the laptop to answer the push", timeout: 10) { acknowledged(block) }
            #expect(acknowledged(block), "the push \(block.id ?? "?") wasn't answered with a result")

            try await phone.unblock(bob)
            try await LiveServer.waitUntil("the server to push the unblock to the laptop") { push("unblock") != nil }
            let unblock = try #require(push("unblock"))
            try await LiveServer.waitUntil("the laptop to answer the push", timeout: 10) { acknowledged(unblock) }
            #expect(acknowledged(unblock), "the push \(unblock.id ?? "?") wasn't answered with a result")
        }

        /// A spam report names each message by the id the account's server
        /// gave it, in XEP-0359's namespace, and the server takes it.
        @Test func spamReportNamesTheStanzaId() async throws {
            let proxy = try await FreezableProxy(to: UInt16(LiveServer.target.port))
            defer { proxy.stop() }
            let a = try fresh(alice, port: proxy.port), b = try fresh(bob)
            try await LiveServer.connected(a, b)
            defer { a.disconnect(); b.disconnect() }
            try await LiveServer.require("urn:xmpp:sid:0", of: a, "a report names the message by the stanza-id its server gave it")
            try b.setEncrypted(false, with: alice)
            let spam = "buy now \(UUID().uuidString.prefix(6))"
            try b.send(spam, to: alice)
            try await LiveServer.waitUntil("the spam with the server's id") { try message(spam, in: a)?.serverId != nil }
            let serverId = try #require(try message(spam, in: a)?.serverId)
            try await LiveServer.waitUntil("the blocklist to be fetched") { a.canBlock }
            if !a.canReport { try Test.cancel("\(LiveServer.target.name) doesn't take spam reports (XEP-0377)") }
            try await a.block(bob, reporting: .spam)
            // Lifted before the checks, which read traffic already recorded: a
            // deferred Task loses to the disconnect, and the block then stays
            // to drop bob's messages in every later test.
            try await a.unblock(bob)

            let block = WireIq.all(in: proxy.clientTraffic).first { $0.type == "set" && $0.element("report") != nil }
            let request = try #require(block, "no block iq with a report was sent")
            let stanzaIds = request.xml.components(separatedBy: "<stanza-id").dropFirst().map { WireIq.attributes(of: String($0.prefix { $0 != ">" })) }
            let named = try #require(stanzaIds.first { $0["id"] == serverId }, "the report names \(stanzaIds), not the server's id \(serverId)")
            #expect(named["xmlns"] == "urn:xmpp:sid:0")
            #expect(named["by"] == alice.description)
            #expect(WireIq.all(in: proxy.serverTraffic).contains { $0.type == "result" && $0.id == request.id }, "the server didn't answer the report with a result")
        }

        // MARK: Groups

        /// A room that is closed to the user says so, rather than that
        /// joining failed. ejabberd writes the `<text>` before the condition
        /// in its error, which an error read from the first child gets wrong.
        @Test func joiningAMembersOnlyRoomSaysWhy() async throws {
            let a = try fresh(alice), b = try fresh(bob)
            try await LiveServer.connected(a, b)
            defer { a.disconnect(); b.disconnect() }
            let room = try await a.createGroup(name: "Closed \(UUID().uuidString.prefix(4))", inviting: [])
            defer { Task { try? await a.leaveGroup(room) } }

            do {
                try await b.joinGroup(room, mayCreate: false)
                Issue.record("bob joined a members-only room he isn't a member of")
            } catch GroupError.joinFailed(let reason) {
                #expect(reason.contains("Only members"), "the reason should say the group is for members, not: \(reason)")
            }
            #expect(try b.database.groupChat(room) == nil)
        }

        /// A declined invitation goes through the room to the inviter, who
        /// receives the room's relay of it. On the dev servers a room vouches
        /// for every inviter, so a real invitation is never held to be
        /// declined; the held one is stored by hand, as a foreign server's
        /// would be.
        @Test func declineReachesTheInviter() async throws {
            let proxy = try await FreezableProxy(to: UInt16(LiveServer.target.port))
            defer { proxy.stop() }
            let a = try fresh(alice, port: proxy.port), b = try fresh(bob)
            try await LiveServer.connected(a, b)
            defer { a.disconnect(); b.disconnect() }
            try await LiveServer.befriend(a, b)
            let room = try await a.createGroup(name: "Decline \(UUID().uuidString.prefix(4))", inviting: [])
            defer { Task { try? await a.leaveGroup(room) } }

            try b.database.recordGroupInvitation(room: room, inviter: alice, reason: nil)
            try b.declineGroupInvitation(room)

            func relayed() -> Bool {
                let traffic = proxy.serverTraffic.replacingOccurrences(of: "\"", with: "'")
                return traffic.contains("<decline") && traffic.contains("from='\(bob.description)")
            }
            try await LiveServer.waitUntil("the room to relay the decline to alice", timeout: 10) { relayed() }
            #expect(relayed(), "alice never heard bob decline; she saw: \(proxy.serverTraffic.suffix(1500))")
        }

        // MARK: Plaintext chats

        /// Without encryption, the sender's message is marked delivered when
        /// the contact's receipt comes, and the sender's other device gets a
        /// carbon of it.
        @Test func plaintextReceiptAndCarbon() async throws {
            let phone = try fresh(alice), laptop = try fresh(alice), b = try fresh(bob)
            try await LiveServer.connected(phone, laptop, b)
            defer { phone.disconnect(); laptop.disconnect(); b.disconnect() }
            try await LiveServer.befriend(phone, b)
            try phone.setEncrypted(false, with: bob)
            try b.setEncrypted(false, with: alice)

            let text = "read receipt please \(UUID().uuidString.prefix(6))"
            try phone.send(text, to: bob)

            try await LiveServer.waitUntil("bob to receive it") { try message(text, in: b) != nil }
            try await LiveServer.waitUntil("the phone's copy to be marked delivered") { try message(text, in: phone)?.status ?? .pending >= .delivered }
            #expect(try message(text, in: phone)?.encryption == YapnestKit.Message.Encryption.none)
            if try await !phone.serverAdvertises("urn:xmpp:carbons:2") {
                try Test.cancel("\(LiveServer.target.name) doesn't advertise carbons (urn:xmpp:carbons:2); the receipt was checked, the carbon wasn't")
            }
            try await LiveServer.waitUntil("the laptop to get a carbon") { try message(text, in: laptop) != nil }
            let carbon = try #require(try message(text, in: laptop))
            #expect(carbon.direction == .outgoing)
            #expect(carbon.sender == alice)
        }

        /// A contact who uses chat states hears that we are typing quickly.
        @Test func typingReachesAnActiveContact() async throws {
            let a = try fresh(alice), b = try fresh(bob)
            try await LiveServer.connected(a, b)
            defer { a.disconnect(); b.disconnect() }
            try await LiveServer.befriend(a, b)
            try a.setEncrypted(false, with: bob)
            try b.setEncrypted(false, with: alice)
            // We only tell contacts who have shown they send chat states themselves.
            try await say("are you there \(UUID().uuidString.prefix(6))", from: b, to: a)
            let heard = ChatStates(b)

            a.sendChatState(.composing, to: bob)

            try await LiveServer.waitUntil("bob to hear alice typing", timeout: 2) { heard.has(.composing, from: alice) }
            #expect(heard.has(.composing, from: alice))
        }
    }
}
