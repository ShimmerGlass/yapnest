import Foundation
import GRDB
import Testing
@testable import YapnestKit

extension LiveServer {
    /// Moderating and managing a group on the local dev server, where
    /// every test needs the room to advertise moderation (XEP-0425), which on Prosody
    /// is mod_muc_moderation (dev/prosody/setup.sh).
    /// Enable with `YAPNEST_INTEGRATION=1 swift test --filter GroupModerationIntegration`.
    @Suite
    struct GroupModerationIntegrationTests {
        let alice = LiveServer.jid("alice")
        let bob = LiveServer.jid("bob")
        let carol = LiveServer.jid("carol")

        private func session(_ jid: JID, device: String) throws -> XMPPSession {
            try LiveServer.makeSession(jid, resource: device, database: try OMEMOIntegrationTests.device(device))
        }

        /// A group of the owner, with `others` in it and settled.
        private func makeGroup(_ owner: XMPPSession, with others: XMPPSession...) async throws -> JID {
            let room = try await owner.createGroup(name: "Moderation \(UUID().uuidString.prefix(4))", inviting: others.map(\.account))
            for other in others {
                try await waitUntil("\(other.account) to join") { other.roomStatus(room)?.isJoined == true && other.roomStatus(room)?.isSyncing == false }
            }
            // A room without XEP-0425 never offers moderation; that is the server's gap, not a failure.
            if try await !owner.roomAdvertises("urn:xmpp:message-moderate:1", room) {
                try? await owner.leaveGroup(room)
                try Test.cancel("\(LiveServer.target.name)'s rooms don't advertise message moderation (XEP-0425)")
            }
            try await waitUntil("the owner to know the room offers moderation") { owner.roomStatus(room)?.canModerateMessages == true }
            return room
        }

        private func message(_ body: String, in session: XMPPSession) throws -> Message? {
            try session.database.reader.read { try Message.filter(Column("body") == body).fetchOne($0) }
        }

        private func message(withServerId id: String, in session: XMPPSession) throws -> Message? {
            try session.database.reader.read { try Message.filter(Column("serverId") == id).fetchOne($0) }
        }

        @Test func removingAMemberTakesThemOutOfTheRoom() async throws {
            let a = try session(alice, device: "alice-groups"), b = try session(bob, device: "bob-groups")
            try await connected(a, b, encryptionReady: true)
            defer { a.disconnect(); b.disconnect() }
            try await befriend(a, b)
            let room = try await makeGroup(a, with: b)
            try await waitUntil("the owner to see bob as a member") { a.roomStatus(room)?.members.contains(bob) == true }

            try await a.removeMember(bob, from: room)

            // Leaving the group retracts its bookmark too, so the room's state may be failed or gone.
            try await waitUntil("bob to be out of the group") { try b.database.groupChat(room)?.hasLeft == true }
            #expect(b.roomStatus(room)?.isJoined != true)
            #expect(a.roomStatus(room)?.members.contains(bob) == false)
            // A members-only room won't have him back unasked.
            await #expect(throws: (any Error).self) { try await b.joinGroup(room, mayCreate: false) }
            try await a.leaveGroup(room)
        }

        @Test func banningKeepsThemOut() async throws {
            let a = try session(alice, device: "alice-groups"), b = try session(bob, device: "bob-groups")
            try await connected(a, b, encryptionReady: true)
            defer { a.disconnect(); b.disconnect() }
            try await befriend(a, b)
            let room = try await makeGroup(a, with: b)

            try await a.banMember(bob, from: room)

            // Leaving the group retracts its bookmark too, so the room's state may be failed or gone.
            try await waitUntil("bob to be out of the group") { try b.database.groupChat(room)?.hasLeft == true }
            #expect(b.roomStatus(room)?.isJoined != true)
            await #expect(throws: (any Error).self) { try await b.joinGroup(room, mayCreate: false) }
            try await a.leaveGroup(room)
        }

        @Test func anAdminModeratesAMembersMessageForEveryone() async throws {
            let a = try session(alice, device: "alice-groups"), b = try session(bob, device: "bob-groups"), c = try session(carol, device: "carol-groups")
            try await connected(a, b, c, encryptionReady: true)
            defer { a.disconnect(); b.disconnect(); c.disconnect() }
            try await befriend(a, b, c)
            let room = try await makeGroup(a, with: b, c)
            try a.setEncrypted(false, with: room)
            try b.setEncrypted(false, with: room)

            // Carol becomes an admin, which makes her a moderator.
            try await a.setAdmin(true, member: carol, in: room)
            try await waitUntil("carol to be a moderator") { c.roomStatus(room)?.canModerateMessages == true }
            try await waitUntil("the owner to see carol as an admin") { a.roomStatus(room)?.affiliation(of: carol) == .admin }

            let text = "unwelcome \(UUID().uuidString.prefix(6))"
            try b.send(text, to: room)
            try await waitUntil("carol and alice to receive it") { try message(text, in: c) != nil && message(text, in: a) != nil }
            try await waitUntil("bob's copy to carry the room's id") { try message(text, in: b)?.serverId != nil }
            let theirs = try #require(try message(text, in: c))

            try await c.retractForEveryone(theirs)

            for (name, session) in [("alice", a), ("bob", b), ("carol", c)] {
                try await waitUntil("\(name) to see it removed") {
                    try session.database.reader.read { try Message.filter(Column("serverId") == theirs.serverId).fetchOne($0) }?.isModerated == true
                }
            }
            let stanzaId = try #require(theirs.serverId)
            let atBob = try #require(try message(withServerId: stanzaId, in: b))
            #expect(atBob.body == "")
            #expect(atBob.isRetracted)

            // An admin may not demote the owner, whatever she tries.
            await #expect(throws: GroupError.self) { try await c.removeMember(alice, from: room) }
            try await a.leaveGroup(room)
        }

        @Test func aPlainMemberHasNoModerationToOffer() async throws {
            let a = try session(alice, device: "alice-groups"), b = try session(bob, device: "bob-groups")
            try await connected(a, b, encryptionReady: true)
            defer { a.disconnect(); b.disconnect() }
            try await befriend(a, b)
            let room = try await makeGroup(a, with: b)
            #expect(b.roomStatus(room)?.canModerateMessages == false)
            await #expect(throws: GroupError.self) { try await b.removeMember(alice, from: room) }
            try await a.leaveGroup(room)
        }

        // MARK: Managing a group

        @Test func aRoomsNameAndDescriptionRoundTrip() async throws {
            let a = try session(alice, device: "alice-groups"), b = try session(bob, device: "bob-groups")
            try await connected(a, b, encryptionReady: true)
            defer { a.disconnect(); b.disconnect() }
            try await befriend(a, b)
            let room = try await makeGroup(a, with: b)

            let before = try await a.roomConfiguration(of: room)
            #expect(before.isMembersOnly == true)
            #expect(before.whoCanSeeAddresses == .anyone)
            let name = "Renamed \(UUID().uuidString.prefix(4))"
            try await a.updateRoomConfiguration(RoomConfiguration(name: name, description: "All about cake"), in: room)

            let after = try await a.roomConfiguration(of: room)
            #expect(after.name == name && after.description == "All about cake")
            // The rest of the form was kept.
            #expect(after.isMembersOnly == true && after.whoCanSeeAddresses == .anyone)
            #expect(try a.database.groupChat(room)?.displayName == name)
            // Another member learns of it from the room's notice.
            try await waitUntil("bob to see the new name") { try b.database.groupChat(room)?.displayName == name }
            try await a.leaveGroup(room)
        }

        @Test func openingAndClosingTheRoomFollowsPrivacyAndEncryption() async throws {
            let a = try session(alice, device: "alice-groups"), b = try session(bob, device: "bob-groups")
            try await connected(a, b, encryptionReady: true)
            defer { a.disconnect(); b.disconnect() }
            try await befriend(a, b)
            let room = try await makeGroup(a, with: b)
            let conversation = try #require(try a.database.groupChat(room)?.conversationId)
            #expect(try a.database.groupChat(room)?.isPrivate == true)
            #expect(try a.database.conversation(id: conversation)?.isEncrypted == true)

            try await a.updateRoomConfiguration(RoomConfiguration(isMembersOnly: false), in: room)
            #expect(try a.database.groupChat(room)?.isMembersOnly == false)
            #expect(try a.database.groupChat(room)?.isPrivate == false)
            #expect(try a.database.conversation(id: conversation)?.isEncrypted == false)
            try await waitUntil("bob to see it open") { try b.database.groupChat(room)?.isPrivate == false }

            try await a.updateRoomConfiguration(RoomConfiguration(isMembersOnly: true), in: room)
            #expect(try a.database.groupChat(room)?.isMembersOnly == true)
            #expect(try a.database.groupChat(room)?.isPrivate == true)
            try await waitUntil("bob to see it members-only again") { try b.database.groupChat(room)?.isMembersOnly == true }
            try await a.leaveGroup(room)
        }

        @Test func aSubjectIsSetAndSeenByEveryone() async throws {
            let a = try session(alice, device: "alice-groups"), b = try session(bob, device: "bob-groups")
            try await connected(a, b, encryptionReady: true)
            defer { a.disconnect(); b.disconnect() }
            try await befriend(a, b)
            let room = try await makeGroup(a, with: b)
            #expect(a.roomStatus(room)?.canChangeSubject == true)

            let subject = "Topic \(UUID().uuidString.prefix(4))"
            try await a.setSubject(subject, in: room)
            try await waitUntil("bob to see the subject") { try b.database.groupChat(room)?.subject == subject }
            #expect(try a.database.groupChat(room)?.subject == subject)

            // A participant is refused, unless the room says otherwise.
            let allowed = b.roomStatus(room)?.canChangeSubject == true
            if !allowed {
                await #expect(throws: GroupError.self) { try await b.setSubject("Hijacked", in: room) }
                #expect(try a.database.groupChat(room)?.subject == subject)
            }
            try await a.updateRoomConfiguration(RoomConfiguration(membersCanChangeSubject: true), in: room)
            try await waitUntil("bob to be allowed to change the subject") { b.roomStatus(room)?.canChangeSubject == true }
            let theirs = "Bob's topic \(UUID().uuidString.prefix(4))"
            try await b.setSubject(theirs, in: room)
            try await waitUntil("alice to see it") { try a.database.groupChat(room)?.subject == theirs }
            try await a.leaveGroup(room)
        }

        @Test func banningListsTheBannedAndUnbanningClearsThem() async throws {
            let a = try session(alice, device: "alice-groups"), b = try session(bob, device: "bob-groups")
            try await connected(a, b, encryptionReady: true)
            defer { a.disconnect(); b.disconnect() }
            try await befriend(a, b)
            let room = try await makeGroup(a, with: b)

            try await a.banMember(bob, from: room)
            try await a.refreshBanList(of: room)
            #expect(a.roomStatus(room)?.banned.contains(bob) == true)
            try await waitUntil("bob to be out") { try b.database.groupChat(room)?.hasLeft == true }

            try await a.unban(bob, in: room)
            try await a.refreshBanList(of: room)
            #expect(a.roomStatus(room)?.banned.contains(bob) != true)
            // A members-only room still wants him invited again.
            try await a.invite([bob], to: room)
            try await waitUntil("bob to be back in") { b.roomStatus(room)?.isJoined == true }
            try await a.leaveGroup(room)
        }

        @Test func ownersAreMadeAndUnmade() async throws {
            let a = try session(alice, device: "alice-groups"), b = try session(bob, device: "bob-groups")
            try await connected(a, b, encryptionReady: true)
            defer { a.disconnect(); b.disconnect() }
            try await befriend(a, b)
            let room = try await makeGroup(a, with: b)
            try await waitUntil("the owner to see bob as a member") { a.roomStatus(room)?.members.contains(bob) == true }
            // Alone, the owner can't step down.
            #expect(a.roomStatus(room)?.isLastOwner(alice) == true)
            await #expect(throws: GroupError.self) { try await a.setOwner(false, member: alice, in: room) }

            try await a.setOwner(true, member: bob, in: room)
            try await waitUntil("bob to be an owner") { b.roomStatus(room)?.affiliation == .owner }
            try await waitUntil("alice to see two owners") { a.roomStatus(room)?.isLastOwner(alice) == false }
            #expect(b.roomStatus(room)?.canEditInfo == true)

            try await a.setOwner(false, member: bob, in: room)
            try await waitUntil("bob to be an admin") { b.roomStatus(room)?.affiliation == .admin }
            #expect(b.roomStatus(room)?.canEditInfo == false)
            try await a.leaveGroup(room)
        }

        @Test func aKickedMemberLeavesTheRoomButStaysAMember() async throws {
            let a = try session(alice, device: "alice-groups"), b = try session(bob, device: "bob-groups")
            try await connected(a, b, encryptionReady: true)
            defer { a.disconnect(); b.disconnect() }
            try await befriend(a, b)
            let room = try await makeGroup(a, with: b)
            try await waitUntil("the owner to see bob present") {
                a.roomStatus(room)?.occupants.values.contains { $0.jid == bob } == true
            }
            let nickname = try #require(a.roomStatus(room)?.occupants.values.first { $0.jid == bob }?.nick)
            try await waitUntil("the owner to see bob as a member") { a.roomStatus(room)?.members.contains(bob) == true }

            try await a.kick(nickname: nickname, reason: "Testing", in: room)

            try await waitUntil("bob to be out of the room") { b.roomStatus(room)?.isJoined != true }
            #expect(try b.database.groupChat(room)?.hasLeft == false)
            #expect(a.roomStatus(room)?.members.contains(bob) == true)
            #expect(a.roomStatus(room)?.occupants[nickname] == nil)
            // Nothing keeps him from joining again.
            try await b.joinGroup(room, mayCreate: false)
            #expect(b.roomStatus(room)?.isJoined == true)
            try await a.leaveGroup(room)
        }

        @Test func aGroupsPictureIsSetAndRemoved() async throws {
            let a = try session(alice, device: "alice-groups"), b = try session(bob, device: "bob-groups")
            try await connected(a, b, encryptionReady: true)
            defer { a.disconnect(); b.disconnect() }
            try await befriend(a, b)
            let room = try await makeGroup(a, with: b)
            let hash = AvatarStore.hash(of: Self.pixel)

            do {
                try await a.setGroupAvatar(Self.pixel, in: room)
            } catch GroupError.unsupported {
                try await a.leaveGroup(room)
                try Test.cancel("\(LiveServer.target.name) keeps no vCard for rooms")
            }
            #expect(try a.database.contact(room)?.avatarHash == hash)
            #expect(a.avatars.contains(hash))
            // Others read it from the room's card.
            try await waitUntil("bob to have the picture") { try b.database.contact(room)?.avatarHash == hash && b.avatars.contains(hash) }

            try await a.setGroupAvatar(nil, in: room)
            #expect(try a.database.contact(room)?.avatarHash == nil)
            try await waitUntil("bob to lose the picture") { try b.database.contact(room)?.avatarHash == nil }
            try await a.leaveGroup(room)
        }

        @Test func destroyingAGroupEndsItForEveryone() async throws {
            let a = try session(alice, device: "alice-groups"), b = try session(bob, device: "bob-groups")
            try await connected(a, b, encryptionReady: true)
            defer { a.disconnect(); b.disconnect() }
            try await befriend(a, b)
            let room = try await makeGroup(a, with: b)

            try await a.destroyGroup(room, reason: "Done")

            #expect(try a.database.groupChat(room)?.hasLeft == true)
            try await waitUntil("bob to see it destroyed") { try b.database.groupChat(room)?.hasLeft == true }
            guard case .failed(let reason)? = b.roomStatus(room)?.phase else { Issue.record("bob's room: \(String(describing: b.roomStatus(room)))"); return }
            #expect(reason == String(localized: "This group was deleted."))
        }

        /// A one pixel PNG.
        static let pixel = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")!
    }
}
