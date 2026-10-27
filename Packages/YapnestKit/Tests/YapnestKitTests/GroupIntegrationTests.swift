import Foundation
import GRDB
import os
import class Martin.Presence
import Testing
@testable import YapnestKit

extension LiveServer {
    /// Group chats on the local dev server (`YAPNEST_SERVER`). Enable with
    /// `YAPNEST_INTEGRATION=1 swift test --filter GroupIntegration`.
    @Suite
    struct GroupIntegrationTests {
        let alice = LiveServer.jid("alice")
        let bob = LiveServer.jid("bob")

        /// OMEMO devices persist across runs (see `OMEMOIntegrationTests`), and
        /// so does the database of a device that keeps its groups.
        private func session(_ jid: JID, device: String, fresh: Bool = false) throws -> XMPPSession {
            try LiveServer.makeSession(jid, resource: device, database: fresh ? try AppDatabase.inMemory() : try OMEMOIntegrationTests.device(device))
        }

        private func waitUntil(_ what: String, timeout: TimeInterval = 15, _ condition: () async throws -> Bool) async throws {
            let deadline = Date().addingTimeInterval(timeout)
            while try await !condition() {
                if Date() > deadline { Issue.record("Timed out waiting for \(what)"); return }
                try await Task.sleep(for: .milliseconds(100))
            }
        }

        /// Connects the devices and waits until each has heard the others
        /// announce themselves: until then, they don't encrypt for each other.
        private func connected(_ sessions: XMPPSession...) async throws {
            for session in sessions {
                session.connect()
                try await waitUntil("\(session.account) to connect, sync and publish its device") {
                    session.state.value == .connected(isSyncing: false) && session.isEncryptionReady
                }
            }
            for session in sessions {
                for other in sessions where other !== session {
                    let device = Int32(bitPattern: other.omemoDeviceId)
                    try await waitUntil("\(session.account) to hear of \(other.account)'s device") {
                        // Without a cached list, sending fetches a fresh one.
                        let known = session.announcedDevices(of: other.account)
                        return known.isEmpty ? other.account != session.account : known.contains(device)
                    }
                }
            }
        }

        /// Invitations are only accepted from contacts.
        private func befriend(_ a: XMPPSession, _ b: XMPPSession) async throws {
            a.addContact(b.account)
            b.addContact(a.account)
            try await waitUntil("each other in the roster") {
                try a.database.isInRoster(b.account) && b.database.isInRoster(a.account)
            }
        }

        private func message(_ body: String, in session: XMPPSession) throws -> Message? {
            try session.database.reader.read { try Message.filter(Column("body") == body).fetchOne($0) }
        }

        @Test func olderRoomHistoryComesBackRead() async throws {
            let a = try session(alice, device: "alice-groups"), b = try session(bob, device: "bob-groups")
            try await connected(a, b)
            defer { a.disconnect(); b.disconnect() }
            try await befriend(a, b)

            let room = try await a.createGroup(name: "Old news \(UUID().uuidString.prefix(4))", inviting: [bob])
            try await LiveServer.accept(invitationTo: room, on: b)
            try await waitUntil("bob to join") { b.roomStatus(room)?.isJoined == true && b.roomStatus(room)?.isSyncing == false }
            try a.setEncrypted(false, with: room)
            let tag = UUID().uuidString.prefix(6)
            for index in 0..<5 { try a.send("room \(tag) \(index)", to: room) }
            try await waitUntil("bob to receive them") {
                try b.database.reader.read { try Message.filter(Column("body").like("room \(tag) %")).fetchCount($0) } == 5
            }

            let kept = try await b.database.reader.read { try Message.order(Column("timestamp").desc, Column("id").desc).limit(2).fetchAll($0) }
            try await b.database.writer.write { db in
                _ = try Message.filter(!kept.map(\.id!).contains(Column("id"))).deleteAll(db)
            }
            // A wait that timed out leaves nothing here, and indexing it would crash
            // the test process, ending every suite still to run.
            let newest = try #require(kept.first)
            try b.database.markRead(conversationId: newest.conversationId)
            let before = try #require(try await b.database.reader.read { try Conversation.fetchOne($0, key: newest.conversationId) })

            var pages = 0
            while try await b.loadOlderHistory(for: room) {
                pages += 1
                if pages >= 20 { break }
            }
            let all = try await b.database.reader.read { try Message.fetchAll($0) }
            #expect(all.filter { $0.body.hasPrefix("room \(tag)") }.count == 5)
            #expect(all.allSatisfy { $0.isRead })
            let after = try #require(try await b.database.reader.read { try Conversation.fetchOne($0, key: before.id) })
            #expect(after.lastActivityAt == before.lastActivityAt)
            #expect(after.historyComplete)
        }

        @Test func createInviteAndTalk() async throws {
            let a = try session(alice, device: "alice-groups"), b = try session(bob, device: "bob-groups")
            try await connected(a, b)
            defer { a.disconnect(); b.disconnect() }
            try await befriend(a, b)

            let room = try await a.createGroup(name: "Cake club \(UUID().uuidString.prefix(4))", inviting: [bob])
            let group = try #require(try a.database.groupChat(room))
            #expect(group.isPrivate)
            #expect(try a.database.conversation(id: group.conversationId)?.isEncrypted == true)
            // Only a server that has XEP-0402 bookmarks takes the group's.
            if try await a.advertises(["urn:xmpp:bookmarks:1#compat", "urn:xmpp:bookmarks:1#compat-pep"]) {
                #expect(group.isBookmarked)
            }

            // Bob accepts his contact's invitation.
            try await LiveServer.accept(invitationTo: room, on: b)
            try await waitUntil("bob to join") { b.roomStatus(room)?.isJoined == true && b.roomStatus(room)?.isSyncing == false }
            try await waitUntil("alice to see bob as a member") { a.groupRecipients(room) == [bob] }

            // Plaintext first.
            try a.setEncrypted(false, with: room)
            let text = "plain cake \(UUID().uuidString.prefix(6))"
            let sent = try a.send(text, to: room)
            var received: Message?
            try await waitUntil("bob to receive") {
                received = try message(text, in: b)
                return received != nil
            }
            let original = try #require(received)
            #expect(original.sender == alice)
            #expect(original.nick == "alice")
            #expect(original.serverId != nil)
            // Prosody vouches for occupant ids (XEP-0421); a room that doesn't advertise them has none to check.
            if try await a.roomAdvertises("urn:xmpp:occupant-id:0", room) {
                #expect(try b.database.groupChat(room)?.hasOccupantIds == true)
                #expect(original.occupantId != nil)
                #expect(b.roomStatus(room)?.occupantId != nil)
            }
            try await waitUntil("alice to get the room's echo") { try message(text, in: a)?.serverId != nil }
            #expect(try message(text, in: a)?.id == sent.id)

            try b.setEncrypted(false, with: room)
            try b.send("count me in", to: room, replyingTo: original)
            try b.toggleReaction("🎂", on: original, peer: room)
            try await waitUntil("alice to get the reply") {
                try a.database.reader.read { try Message.filter(Column("body") == "count me in" && Column("replyToId") == original.serverId).fetchCount($0) } == 1
            }
            let mine = try #require(try message(text, in: a))
            try await waitUntil("alice to get the reaction") { try a.database.reactions(on: mine, from: bob) == ["🎂"] }

            // Naming her mentions her (XEP-0372).
            let shoutOut = "thanks Alice \(UUID().uuidString.prefix(6))"
            try b.send(shoutOut, to: room)
            try await waitUntil("alice to be mentioned") { try message(shoutOut, in: a)?.mentionsMe == true }
            #expect(try message(shoutOut, in: b)?.mentionsMe == false)

            // Encrypted, for every member's devices.
            try a.setEncrypted(true, with: room)
            let secret = "secret cake \(UUID().uuidString.prefix(6))"
            let encrypted = try a.send(secret, to: room)
            #expect(encrypted.encryption == .omemo)
            try await waitUntil("bob to decrypt") { try message(secret, in: b)?.encryption == .omemo }
            try await waitUntil("alice's own message confirmed by the echo") { try message(secret, in: a)?.serverId != nil }
            let copies = try await a.database.reader.read { try Message.filter(Column("body") == secret).fetchCount($0) }
            #expect(copies == 1)

            // Corrected, still encrypted, then taken back.
            let fixed = secret + " (fixed)"
            try a.edit(try #require(try message(secret, in: a)), to: fixed)
            try await waitUntil("bob to see the correction") { try message(fixed, in: b)?.editedAt != nil }
            #expect(try message(secret, in: b) == nil)
            let bobsCopy = try #require(try message(fixed, in: b))
            try a.retract(try #require(try message(fixed, in: a)))
            func bobsRetracted() throws -> Bool {
                try b.database.reader.read { try Message.fetchOne($0, key: bobsCopy.id) }?.isRetracted == true
            }
            try await waitUntil("bob to see it retracted") { try bobsRetracted() }

            try await a.leaveGroup(room)
            try await b.leaveGroup(room)
            #expect(try a.database.groupChat(room)?.hasLeft == true)
        }

        @Test func otherDeviceFollowsBookmarksAndArchive() async throws {
            let a = try session(alice, device: "alice-groups")
            try await connected(a)
            defer { a.disconnect() }
            // A server without XEP-0402 mirroring (Openfire) is read through the old bookmarks.
            let room = try await a.createGroup(name: "Notes", inviting: [])
            try a.setEncrypted(false, with: room)
            let text = "before the laptop \(UUID().uuidString.prefix(6))"
            try a.send(text, to: room)
            try await waitUntil("the room to archive it") { try message(text, in: a)?.serverId != nil }

            // A brand-new device finds the group in the bookmarks, joins it and
            // fetches its history.
            let laptop = try session(alice, device: "laptop-\(UUID().uuidString.prefix(4))", fresh: true)
            laptop.connect()
            defer { laptop.disconnect() }
            try await waitUntil("the laptop to join") { laptop.roomStatus(room)?.isJoined == true }
            try await waitUntil("the laptop to get the history") { try message(text, in: laptop) != nil }
            let copy = try #require(try message(text, in: laptop))
            #expect(copy.direction == .outgoing)
            #expect(try laptop.database.groupChat(room)?.name == "Notes")

            // Leaving on one device leaves on the other.
            try await a.leaveGroup(room)
            try await waitUntil("the laptop to leave too") { try laptop.database.groupChat(room)?.hasLeft == true }
            #expect(laptop.roomStatus(room) == nil)
        }

        @Test func newDeviceGetsGroupReadState() async throws {
            let a = try session(alice, device: "alice-groups"), b = try session(bob, device: "bob-groups")
            try await connected(a, b)
            defer { a.disconnect(); b.disconnect() }
            try await LiveServer.require("urn:xmpp:bookmarks:1#compat", "urn:xmpp:bookmarks:1#compat-pep", of: a, "a new device finds its groups in the XEP-0402 bookmarks")
            try await befriend(a, b)
            let room = try await a.createGroup(name: "Read club \(UUID().uuidString.prefix(4))", inviting: [bob])
            try await LiveServer.accept(invitationTo: room, on: b)
            try await waitUntil("bob to join") { b.roomStatus(room)?.isJoined == true && b.roomStatus(room)?.isSyncing == false }
            try a.setEncrypted(false, with: room)
            let read = "read this \(UUID().uuidString.prefix(6))"
            try a.send(read, to: room)
            try await waitUntil("bob to get it with the room's id") { try message(read, in: b)?.serverId != nil }
            func conversation() throws -> Conversation? { try b.database.reader.read { try Conversation.filter(Column("peer") == room).fetchOne($0) } }
            let conversation = try #require(try conversation())
            try b.markRead(conversation)
            try await waitUntil("bob's read state to be published") { b.lock.withLock { $0.publishedDisplayed[room] } != nil }
            let unread = "not yet \(UUID().uuidString.prefix(6))"
            try a.send(unread, to: room)
            try await waitUntil("the room to archive it") { try message(unread, in: a)?.serverId != nil }

            // The laptop learns how far bob read before it has the group's
            // history, which only comes once it joins.
            let laptop = try session(bob, device: "laptop-\(UUID().uuidString.prefix(4))", fresh: true)
            laptop.connect()
            defer { laptop.disconnect() }
            // The read states are read once the account's own sync ends, which
            // with a long history can be after the group's catch-up.
            try await waitUntil("the laptop to get the history and finish its sync") {
                try message(unread, in: laptop) != nil && laptop.roomStatus(room)?.isSyncing == false
                    && laptop.state.value == .connected(isSyncing: false)
            }
            #expect(try message(read, in: laptop)?.isRead == true)
            #expect(try message(unread, in: laptop)?.isRead == false)

            try await a.leaveGroup(room)
            try await b.leaveGroup(room)
        }

        @Test func selfPingRejoinsAfterBeingDropped() async throws {
            let a = try session(alice, device: "alice-groups")
            try await connected(a)
            defer { a.disconnect() }
            let room = try await a.createGroup(name: "Ghost town", inviting: [])
            let nickname = try #require(a.roomStatus(room)?.nickname)

            // Out of the room while the session still thinks it's in, as when
            // a room restarts and the news is lost.
            let leave = Martin.Presence()
            leave.type = .unavailable
            leave.to = room.martin.with(resource: nickname)
            a.write(leave)
            try await waitUntil("the room to confirm we left") { a.roomStatus(room)?.isJoined == false }
            a.updateRoom(room) { $0 = RoomStatus(phase: .joined, nickname: nickname) }

            a.selfPingRooms()
            // The ping finds us gone; we rejoin and the room greets us again.
            try await waitUntil("the session to notice and rejoin") {
                a.roomStatus(room)?.isJoined == true && a.roomStatus(room)?.occupants[nickname] != nil
            }
            try await a.leaveGroup(room)
        }

        @Test func invitesSeveralAtOnce() async throws {
            let a = try session(alice, device: "alice-groups"), b = try session(bob, device: "bob-groups")
            let c = try session(LiveServer.jid("carol"), device: "carol-groups")
            try await connected(a, b, c)
            defer { a.disconnect(); b.disconnect(); c.disconnect() }
            try await befriend(a, b)
            try await befriend(a, c)

            // Each needs membership of its own: Prosody applies one item per request.
            let room = try await a.createGroup(name: "Three", inviting: [bob, LiveServer.jid("carol")])
            try await LiveServer.accept(invitationTo: room, on: b)
            try await LiveServer.accept(invitationTo: room, on: c)
            try await waitUntil("bob to join") { b.roomStatus(room)?.isJoined == true }
            try await waitUntil("carol to join") { c.roomStatus(room)?.isJoined == true }
            try await a.leaveGroup(room)
            try await b.leaveGroup(room)
            try await c.leaveGroup(room)
        }

        @Test func strangersCantAddUs() async throws {
            // carol has never been in bob's roster.
            let carol = try session(LiveServer.jid("carol"), device: "carol", fresh: true), b = try session(bob, device: "bob-groups")
            carol.connect()
            try await connected(b)
            defer { carol.disconnect(); b.disconnect() }
            try await waitUntil("carol to connect") { carol.state.value == .connected(isSyncing: false) }

            let room = try await carol.createGroup(name: "Spam", inviting: [bob])
            try await Task.sleep(for: .seconds(2))
            #expect(try b.database.groupChat(room) == nil)
            try await carol.leaveGroup(room)
        }

        /// On the dev servers the room can vouch for every inviter, so a real
        /// invitation is joined at once and never waits to be declined; the
        /// held one is stored by hand, as a foreign server's would be.
        @Test func decliningAnInvitationReachesTheInviter() async throws {
            let a = try session(alice, device: "alice-groups"), b = try session(bob, device: "bob-groups")
            try await connected(a, b)
            defer { a.disconnect(); b.disconnect() }
            try await befriend(a, b)
            let room = try await a.createGroup(name: "Decline \(UUID().uuidString.prefix(4))", inviting: [])

            try b.database.recordGroupInvitation(room: room, inviter: a.account, reason: nil)
            try b.declineGroupInvitation(room)
            #expect(try b.database.groupInvitation(room) == nil)
            // Alice has nothing to show for it, and must not take it for an
            // invitation of her own.
            try await Task.sleep(for: .seconds(2))
            #expect(try a.database.groupInvitation(room) == nil)
            try await a.leaveGroup(room)
        }

        /// Answering an invitation to an address that isn't a room must not
        /// create one: joining a room that doesn't exist makes it.
        @Test func acceptingAnInvitationToNoRoomCreatesNothing() async throws {
            let a = try session(alice, device: "alice-groups")
            try await connected(a)
            defer { a.disconnect() }
            let room = JID("nobody-\(UUID().uuidString.prefix(8).lowercased())@\(LiveServer.target.conference)")!

            await #expect(throws: (any Error).self) { try await a.acceptGroupInvitation(room) }
            #expect(try a.database.groupChat(room) == nil)
            #expect(a.roomStatus(room) == nil)
            #expect(await !a.existsOnServer(room), "the room was created on the server")
        }
    }
}
