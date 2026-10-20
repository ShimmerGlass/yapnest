import Combine
import CoreGraphics
import ImageIO
import Foundation
import GRDB
import Testing
@testable import YapnestKit

/// The suites that run against a local dev server from `dev/<server>/setup.sh`
/// (Prosody unless `YAPNEST_SERVER` says otherwise, see `LiveServer.target`),
/// one after another: run together, their sessions for the same accounts
/// see each other's presence, carbons and devices. Enable with
/// `YAPNEST_INTEGRATION=1 swift test --filter LiveServer`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["YAPNEST_INTEGRATION"] == "1"), .serialized)
enum LiveServer {}

extension LiveServer {
    /// Runs against the local Prosody from `dev/prosody/setup.sh`. Enable with
    /// `YAPNEST_INTEGRATION=1 swift test --filter Integration`.
    @Suite
    struct IntegrationTests {
        let alice = LiveServer.jid("alice")
        let bob = LiveServer.jid("bob")

        /// A brand-new device. Archive tests use plaintext: OMEMO messages are
        /// only readable by devices that existed when they were sent.
        private func session(_ jid: JID) throws -> XMPPSession {
            try LiveServer.makeSession(jid, resource: "test-\(UUID().uuidString.prefix(6))", database: try AppDatabase.inMemory())
        }

        private func waitUntil(_ what: String, timeout: TimeInterval = 10, _ condition: () throws -> Bool) async throws {
            let deadline = Date().addingTimeInterval(timeout)
            while try !condition() {
                if Date() > deadline { Issue.record("Timed out waiting for \(what)"); return }
                try await Task.sleep(for: .milliseconds(100))
            }
        }

        private func connected(_ session: XMPPSession) async throws {
            session.connect()
            try await waitUntil("\(session.account) to connect and sync") { session.state.value == .connected(isSyncing: false) }
            try session.setEncrypted(false, with: session.account == alice ? bob : alice)
        }

        @Test func messageReplyAndReaction() async throws {
            let a = try session(alice), b = try session(bob)
            try await connected(a)
            try await connected(b)
            defer { a.disconnect(); b.disconnect() }

            let text = "hello \(UUID().uuidString.prefix(8))"
            let sent = try a.send(text, to: bob)

            var received: Message?
            try await waitUntil("bob to receive") {
                received = try b.database.reader.read { try Message.filter(Column("body") == text).fetchOne($0) }
                return received != nil
            }
            let original = try #require(received)
            #expect(original.direction == .incoming)
            #expect(original.sender == alice)
            #expect(original.remoteId == sent.remoteId)

            // Bob replies and reacts.
            try b.send("yes", to: alice, replyingTo: original)
            try b.toggleReaction("👍", on: original, peer: alice)

            try await waitUntil("alice to get the reply") {
                try a.database.reader.read { try Message.filter(Column("body") == "yes" && Column("replyToId") == sent.remoteId).fetchCount($0) } == 1
            }
            try await waitUntil("alice to get the reaction") {
                try a.database.reactions(on: sent, from: bob) == ["👍"]
            }

            // Bob takes it back.
            try b.toggleReaction("👍", on: original, peer: alice)
            try await waitUntil("alice to see the reaction removed") {
                try a.database.reactions(on: sent, from: bob).isEmpty
            }
        }

        @Test func correctAndRetract() async throws {
            let a = try session(alice), b = try session(bob)
            try await connected(a)
            try await connected(b)
            defer { a.disconnect(); b.disconnect() }

            let text = "teh cake \(UUID().uuidString.prefix(8))"
            let sent = try a.send(text, to: bob)
            func bobsCopy() throws -> Message? {
                try b.database.reader.read { try Message.filter(Column("remoteId") == sent.remoteId).fetchOne($0) }
            }
            func alicesCopy() throws -> Message? {
                try a.database.reader.read { try Message.fetchOne($0, key: sent.id) }
            }
            func bobsCount(_ body: String) throws -> Int {
                try b.database.reader.read { try Message.filter(Column("body") == body).fetchCount($0) }
            }
            try await waitUntil("bob to receive") { try bobsCopy() != nil }
            try await waitUntil("the server to confirm it") { try alicesCopy()?.status ?? .pending >= .sent }

            let fixed = text.replacingOccurrences(of: "teh", with: "the")
            try a.edit(try #require(try alicesCopy()), to: fixed)
            try await waitUntil("bob to see the correction") { try bobsCopy()?.body == fixed }
            #expect(try bobsCopy()?.editedAt != nil)
            #expect(try bobsCount(fixed) == 1)

            try a.retract(try #require(try alicesCopy()))
            try await waitUntil("bob to see it retracted") { try bobsCopy()?.isRetracted == true }
            #expect(try bobsCopy()?.body == "")
            #expect(try alicesCopy()?.isRetracted == true)
        }

        @Test func offlineMessageArrivesThroughArchive() async throws {
            let a = try session(alice)
            try await connected(a)
            let text = "while you were out \(UUID().uuidString.prefix(8))"
            try a.send(text, to: bob)
            try await Task.sleep(for: .milliseconds(500))
            a.disconnect()

            let b = try session(bob)
            try await connected(b)
            defer { b.disconnect() }
            try await waitUntil("bob to get it from the archive or offline storage") {
                try b.database.reader.read { try Message.filter(Column("body") == text).fetchCount($0) } == 1
            }
            let serverId = try await b.database.reader.read { try Message.filter(Column("body") == text).fetchOne($0)?.serverId }
            #expect(serverId != nil)
        }
    }
}

extension LiveServer.IntegrationTests {
    @Test func newDeviceGetsHistoryFromArchive() async throws {
        let a = try session(alice), b1 = try session(bob)
        try await connected(a)
        try await connected(b1)
        let text = "history \(UUID().uuidString.prefix(8))"
        try a.send(text, to: bob)
        try await waitUntil("first device to receive") {
            try b1.database.reader.read { try Message.filter(Column("body") == text).fetchCount($0) } == 1
        }
        a.disconnect()
        b1.disconnect()

        // A fresh database: only the archive can supply the message now.
        let b2 = try session(bob)
        try await connected(b2)
        defer { b2.disconnect() }
        let fromArchive = try await b2.database.reader.read { try Message.filter(Column("body") == text).fetchOne($0) }
        #expect(fromArchive?.serverId != nil)
        #expect(try b2.database.setting(.lastArchiveId) != nil)
    }

    @Test func blockOnOneDeviceAndUnblock() async throws {
        let phone = try session(alice), laptop = try session(alice), b = try session(bob)
        try await connected(phone)
        try await connected(laptop)
        try await connected(b)
        defer { phone.disconnect(); laptop.disconnect(); b.disconnect() }
        try await waitUntil("the blocklist to be fetched") { phone.canBlock }

        try await phone.block(bob)
        #expect(try phone.database.isBlocked(bob))
        // The server tells our other devices.
        try await waitUntil("the laptop to hear of the block") { try laptop.database.isBlocked(bob) }

        let blocked = "can you hear me \(UUID().uuidString.prefix(6))"
        try b.send(blocked, to: alice)
        let unblocked = "and now \(UUID().uuidString.prefix(6))"
        try await Task.sleep(for: .seconds(1))
        try await phone.unblock(bob)
        try await waitUntil("the laptop to hear of the unblock") { try !laptop.database.isBlocked(bob) }
        try b.send(unblocked, to: alice)
        func received(_ text: String) throws -> Bool {
            try phone.database.reader.read { try Message.filter(Column("body") == text).fetchCount($0) } > 0
        }
        try await waitUntil("the message after unblocking") { try received(unblocked) }
        #expect(try !received(blocked))
    }

    @Test func reportSpam() async throws {
        let a = try session(alice), b = try session(bob)
        try await connected(a)
        try await connected(b)
        defer { a.disconnect(); b.disconnect() }
        try await LiveServer.require("urn:xmpp:sid:0", of: a, "a report names the message by the stanza-id its server gave it")
        let spam = "buy now \(UUID().uuidString.prefix(6))"
        try b.send(spam, to: alice)
        try await waitUntil("the spam with the server's id") {
            try a.database.reader.read { try Message.filter(Column("body") == spam).fetchOne($0) }?.serverId != nil
        }
        // The dev Prosody takes reports (mod_spam_reporting); ejabberd may not.
        try await waitUntil("the blocklist to be fetched") { a.canBlock }
        // A server that takes no reports can't pass this, but must not look as if it had.
        if !a.canReport { try Test.cancel("\(LiveServer.target.name) doesn't take spam reports (XEP-0377)") }
        try await a.block(bob, reporting: .spam)
        #expect(try a.database.isBlocked(bob))
        try await a.unblock(bob)
    }

    @Test func contactRequestDeclinedThenAccepted() async throws {
        let carol = LiveServer.jid("carol")
        var phone = try session(alice)
        let c = try session(carol)
        try await connected(phone)
        try await connected(c)
        defer { phone.disconnect(); c.disconnect() }
        // Strangers to each other, whatever earlier runs left.
        try? await phone.removeContact(carol)
        try? await c.removeContact(alice)
        try await Task.sleep(for: .milliseconds(500))
        func request(on device: XMPPSession) throws -> Bool {
            try device.database.contact(carol)?.hasContactRequest == true
        }

        c.addContact(alice)
        try await waitUntil("alice to get carol's request") { try request(on: phone) }
        // Openfire turns carol's unasked `subscribed` into a roster item, so
        // the roster can't tell; what matters is that alice hasn't agreed.
        #expect(try phone.database.hasApprovedOrAdded(carol) == false)

        // The server repeats it to a device that signs in later.
        let laptop = try session(alice)
        try await connected(laptop)
        try await waitUntil("the laptop to get it too") { try request(on: laptop) }
        laptop.disconnect()

        try phone.declineContactRequest(from: carol)
        #expect(try !request(on: phone))
        try await waitUntil("carol to hear no") { try c.database.contact(alice)?.isSubscriptionPending == false }
        #expect(try c.database.contact(alice)?.seesPresence == false)

        // Answered elsewhere: not repeated on the laptop's next sign-in.
        let later = try XMPPSession(
            credentials: .init(jid: alice, password: "password", host: "127.0.0.1", port: LiveServer.target.port, disableTLS: true),
            resource: "laptop-again", database: laptop.database,
        )
        try await connected(later)
        #expect(try !request(on: later))

        // She asks again, and removes alice before alice answers, which
        // withdraws it. Prosody tells alice right away; ejabberd only stops
        // repeating it, so it goes at her next sign-in.
        c.addContact(alice)
        try await waitUntil("alice to get the second request") { try request(on: phone) }
        try await waitUntil("carol's roster to show it") { try c.database.contact(alice)?.isSubscriptionPending == true }
        try await c.removeContact(alice)
        #expect(try !c.database.isInRoster(alice))
        for _ in 0..<20 where try request(on: phone) { try await Task.sleep(for: .milliseconds(100)) }
        if try request(on: phone) {
            phone.disconnect()
            phone = try XMPPSession(
                credentials: .init(jid: alice, password: "password", host: "127.0.0.1", port: LiveServer.target.port, disableTLS: true),
                resource: "phone-again", database: phone.database,
            )
            try await connected(phone)
            #expect(try !request(on: phone))
        }

        // Third time; accepted, which adds her back.
        c.addContact(alice)
        try await waitUntil("alice to get the third request") { try request(on: phone) }
        try phone.acceptContactRequest(from: carol)
        try await waitUntil("both to see each other") {
            try phone.database.contact(carol)?.subscription == .both && c.database.contact(alice)?.subscription == .both
        }
        // The laptop hears of it from the roster.
        try await waitUntil("the laptop to see it answered") { try later.database.isInRoster(carol) && !request(on: later) }
        later.disconnect()

        try? await phone.removeContact(carol)
    }

    @Test func removeContact() async throws {
        let carol = LiveServer.jid("carol")
        let a = try session(alice), c = try session(carol)
        try await connected(a)
        try await connected(c)
        defer { a.disconnect(); c.disconnect() }
        try? await a.removeContact(carol)
        try? await c.removeContact(alice)
        try await Task.sleep(for: .milliseconds(500))

        a.addContact(carol)
        try await waitUntil("carol to get the request") { try c.database.contact(alice)?.hasContactRequest == true }
        try c.acceptContactRequest(from: alice)
        try await waitUntil("both to see each other") {
            try a.database.contact(carol)?.subscription == .both && c.database.contact(alice)?.subscription == .both
        }

        try await a.removeContact(carol)
        #expect(try !a.database.isInRoster(carol))
        // Carol keeps alice in her contacts, but neither sees the other.
        try await waitUntil("carol to lose both subscriptions") { try c.database.contact(alice)?.subscription == Contact.Subscription.none }
        #expect(try c.database.isInRoster(alice))
        #expect(try c.database.contact(alice)?.hasContactRequest == false)
        try? await c.removeContact(alice)
    }

    @Test func newDeviceTakesOurEncryptedReplyAsRead() async throws {
        let carol = LiveServer.jid("carol")
        let c = try session(carol), b = try session(bob)
        try await connected(c)
        try await connected(b)
        defer { c.disconnect() }
        try c.setEncrypted(false, with: bob)
        let question = "anyone around? \(UUID().uuidString.prefix(6))"
        try c.send(question, to: bob)
        func copy(on device: XMPPSession) throws -> Message? {
            try device.database.reader.read { try Message.filter(Column("body") == question).fetchOne($0) }
        }
        try await waitUntil("bob to get it") { try copy(on: b) != nil }
        // Answered, encrypted, without opening the chat on this device.
        try b.setEncrypted(true, with: carol)
        let reply = try b.send("me \(UUID().uuidString.prefix(6))", to: carol)
        func sent() throws -> Message? { try b.database.reader.read { try Message.fetchOne($0, key: reply.id) } }
        try await waitUntil("the reply to be sent") { try sent()?.status ?? .pending >= .sent }
        #expect(try sent()?.encryption == .omemo)
        b.disconnect()

        // A device that didn't exist then can't read the reply, but knows
        // bob answered, and so read the question.
        let laptop = try session(bob)
        try await connected(laptop)
        defer { laptop.disconnect() }
        #expect(try copy(on: laptop)?.isRead == true)
    }

    @Test func readStateFollowsToOtherDevices() async throws {
        let a = try session(alice), phone = try session(bob), laptop = try session(bob)
        try await connected(a)
        defer { a.disconnect(); phone.disconnect(); laptop.disconnect() }
        try await LiveServer.require("urn:xmpp:sid:0", of: a, "read state is published by the stanza-id its server gave the message")
        try await connected(phone)
        try await connected(laptop)
        let text = "read me \(UUID().uuidString.prefix(8))"
        try a.send(text, to: bob)
        func copy(on device: XMPPSession) throws -> Message? {
            try device.database.reader.read { try Message.filter(Column("body") == text).fetchOne($0) }
        }
        try await waitUntil("both devices to have it, with the server's id") {
            try copy(on: phone)?.serverId != nil && copy(on: laptop) != nil
        }
        // The laptop learns of the server's id from the archive, later; it's
        // offline while the phone reads.
        laptop.disconnect()
        func conversation() throws -> Conversation? {
            try phone.database.reader.read { try Conversation.filter(Column("peer") == alice).fetchOne($0) }
        }
        try phone.markRead(try #require(try conversation()))

        let later = try XMPPSession(
            credentials: .init(jid: bob, password: "password", host: "127.0.0.1", port: LiveServer.target.port, disableTLS: true),
            resource: "laptop-again", database: laptop.database,
        )
        try await connected(later)
        defer { later.disconnect() }
        try await waitUntil("the laptop to see it read") { try copy(on: later)?.isRead == true }
        // Through XEP-0490, not only the chat marker the phone sent alice.
        let serverId = try #require(try copy(on: phone)?.serverId)
        try await waitUntil("the laptop to fetch the read state") { later.lock.withLock { $0.publishedDisplayed[alice] } == serverId }
    }
}

/// Fills alice's account with a conversation from bob, for looking at the UI.
/// `YAPNEST_SEED=1 swift test --filter Seed`
@Suite(.enabled(if: ProcessInfo.processInfo.environment["YAPNEST_SEED"] == "1"))
struct Seed {
    @Test func conversationFromBob() async throws {
        let alice = LiveServer.jid("alice")
        let bob = try LiveServer.makeSession(LiveServer.jid("bob"), resource: "seed", database: try LiveServer.OMEMOIntegrationTests.device("bob-seed"))
        bob.connect()
        while bob.state.value != .connected(isSyncing: false) || !bob.isEncryptionReady { try await Task.sleep(for: .milliseconds(100)) }
        defer { bob.disconnect() }

        let first = try bob.send("Hey Alice! Are we still on for tonight?", to: alice)
        try await Task.sleep(for: .milliseconds(200))
        try bob.send("I was thinking we could try that new ramen place 🍜", to: alice)
        try await Task.sleep(for: .milliseconds(200))
        try bob.send("It's the one next to the bookshop, they have a vegetarian broth too", to: alice)
        try await Task.sleep(for: .milliseconds(200))
        try bob.send("Their menu is up: https://github.com", to: alice)
        try await Task.sleep(for: .milliseconds(200))
        try bob.send("7pm works for me", to: alice, replyingTo: first)
        try await Task.sleep(for: .milliseconds(200))
        bob.sendChatState(.composing, to: alice)
        try await Task.sleep(for: .milliseconds(500))
    }
}

/// Keeps bob online with an avatar for 15s, then busy for 15s, for looking
/// at presence in the UI. `YAPNEST_SEED=1 swift test --filter SeedPresence`
@Suite(.enabled(if: ProcessInfo.processInfo.environment["YAPNEST_SEED"] == "1"))
struct SeedPresence {
    @Test func bobOnlineThenBusy() async throws {
        let bob = try LiveServer.makeSession(LiveServer.jid("bob"), resource: "seed-presence", database: try AppDatabase.inMemory())
        bob.connect()
        while bob.state.value != .connected(isSyncing: false) { try await Task.sleep(for: .milliseconds(100)) }
        defer { bob.disconnect() }
        bob.addContact(LiveServer.jid("alice"))
        try await bob.publishAvatar(Self.avatarPNG(), mimeType: "image/png", width: 96, height: 96)
        try await Task.sleep(for: .seconds(15))
        bob.setShowForTesting(.dnd)
        try await Task.sleep(for: .seconds(15))
    }

    /// A 96×96 gradient with a white circle, drawn with Core Graphics.
    static func avatarPNG() throws -> Data {
        let size = 96
        let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                  colors: [CGColor(red: 1, green: 0.45, blue: 0.2, alpha: 1), CGColor(red: 0.85, green: 0.1, blue: 0.5, alpha: 1)] as CFArray,
                                  locations: [0, 1])!
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size, y: size), options: [])
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.9))
        context.fillEllipse(in: CGRect(x: 30, y: 30, width: 36, height: 36))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }
}

/// A group with alice, bob and carol and a short conversation, for looking
/// at groups in the app signed in as alice. Plaintext, so the app's new
/// device can read the history. `YAPNEST_SEED=1 swift test --filter SeedGroup`
@Suite(.enabled(if: ProcessInfo.processInfo.environment["YAPNEST_SEED"] == "1"))
struct SeedGroup {
    private func session(_ name: String) async throws -> XMPPSession {
        let session = try LiveServer.makeSession(JID("\(name)@localhost")!, resource: "seed-group", database: try LiveServer.OMEMOIntegrationTests.device("\(name)-seed-group"))
        session.connect()
        try await wait("\(name) to connect") { session.state.value == .connected(isSyncing: false) }
        return session
    }

    private func wait(_ what: String, _ condition: () throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(20)
        while try !condition() {
            guard Date() < deadline else { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(100))
        }
        print("seed: \(what)")
    }

    @Test func weekendPlans() async throws {
        let alice = try await session("alice"), bob = try await session("bob"), carol = try await session("carol")
        defer { alice.disconnect(); bob.disconnect(); carol.disconnect() }
        for friend in [bob, carol] {
            alice.addContact(friend.account)
            friend.addContact(alice.account)
        }
        while try !(bob.database.isInRoster(alice.account) && carol.database.isInRoster(alice.account)) {
            try await Task.sleep(for: .milliseconds(100))
        }

        print("seed: contacts ready")
        let room = try await alice.createGroup(name: "Weekend plans", inviting: [bob.account, carol.account])
        print("seed: created \(room)")
        for friend in [bob, carol] {
            do {
                try await wait("\(friend.account) to join") { friend.roomStatus(room)?.isJoined == true && friend.roomStatus(room)?.isSyncing == false }
            } catch {
                print("seed: \(friend.account) status \(String(describing: friend.roomStatus(room))) group \(String(describing: try friend.database.groupChat(room))) roster \(try friend.database.isInRoster(alice.account))")
                throw error
            }
        }
        for session in [alice, bob, carol] { try session.setEncrypted(false, with: room) }
        try await alice.setSubject("Hiking on Saturday?", in: room)

        func pause() async throws { try await Task.sleep(for: .milliseconds(300)) }
        let question = try bob.send("Who's up for the lake trail on Saturday?", to: room)
        try await pause()
        try carol.send("Me! What time?", to: room)
        try await pause()
        try alice.send("Count me in 🥾", to: room)
        try await pause()
        // Replies and reactions point at the room's id, which comes with its echo.
        var echoed: Message?
        try await wait("the echo") {
            echoed = try carol.database.reader.read { try Message.filter(Column("remoteId") == question.remoteId).fetchOne($0) }
            return echoed?.serverId != nil
        }
        try carol.send("Can we leave after 9? I'm not a morning person", to: room, replyingTo: echoed)
        try await pause()
        try bob.send("9:30 at the parking lot then", to: room)
        try await pause()
        let last = try await alice.database.reader.read { try Message.order(Column("id").desc).fetchOne($0) }
        if let last { try alice.toggleReaction("👍", on: last, peer: room) }
        try await Task.sleep(for: .seconds(1))
    }
}

extension LiveServer.IntegrationTests {
    @Test func olderHistoryComesBackReadAndSilent() async throws {
        let a = try session(alice), b = try session(bob)
        try await connected(a)
        try await connected(b)
        defer { a.disconnect(); b.disconnect() }

        let tag = UUID().uuidString.prefix(6)
        for index in 0..<6 { try a.send("older \(tag) \(index)", to: bob) }
        try await waitUntil("bob to receive them all") {
            try b.database.reader.read { try Message.filter(Column("body").like("older \(tag) %")).fetchCount($0) } == 6
        }
        // Bob's device only knows the newest two, as if it were set up later.
        let kept = try await b.database.reader.read { try Message.order(Column("timestamp").desc, Column("id").desc).limit(2).fetchAll($0) }
        try await b.database.writer.write { db in
            _ = try Message.filter(!kept.map(\.id!).contains(Column("id"))).deleteAll(db)
        }
        try b.database.markRead(conversationId: kept[0].conversationId)
        let before = try #require(try await b.database.reader.read { try Conversation.fetchOne($0, key: kept[0].conversationId) })

        nonisolated(unsafe) var announced = 0
        let subscription = b.events.sink { if case .newMessage = $0 { announced += 1 } }
        defer { subscription.cancel() }

        var pages = 0
        while try await b.loadOlderHistory(for: alice) {
            pages += 1
            #expect(pages < 100, "the archive should run out")
            if pages >= 100 { break }
        }

        let all = try await b.database.reader.read { try Message.fetchAll($0) }
        #expect(all.filter { $0.body.hasPrefix("older \(tag)") }.count == 6)
        // Everything the archive added is read, and nobody was told.
        #expect(all.allSatisfy { $0.isRead })
        #expect(announced == 0)
        let after = try #require(try await b.database.reader.read { try Conversation.fetchOne($0, key: before.id) })
        #expect(after.lastActivityAt == before.lastActivityAt)
        #expect(after.historyComplete)
        // Once complete it stops asking.
        let again = try await b.loadOlderHistory(for: alice)
        #expect(!again)
    }
}
