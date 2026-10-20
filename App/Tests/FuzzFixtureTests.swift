import Foundation
import GRDB
import Testing
import YapnestKit
@testable import Yapnest

/// The fuzz fixture is only worth its seeds if a seed always gives the same
/// chats, and if the seeds together cover everything the list draws.
struct FuzzFixtureTests {
    private static let seeds: ClosedRange<UInt64> = 1...40

    @Test func theSameSeedGivesTheSameChats() {
        #expect(FuzzPlan(seed: 7) == FuzzPlan(seed: 7))
        #expect(FuzzPlan(seed: 7) != FuzzPlan(seed: 8))
    }

    @Test func theSeedIsReadFromTheFixtureName() {
        #expect(FuzzFixture.seed(from: "fuzz:42") == 42)
        #expect(FuzzFixture.seed(from: "fuzz") == 1)
        #expect(FuzzFixture.seed(from: "fuzz:x") == nil)
        #expect(FuzzFixture.seed(from: "tall-newest") == nil)
    }

    @Test func sizesStayInTheirRanges() {
        var long = 0
        for seed in Self.seeds {
            let plan = FuzzPlan(seed: seed)
            let count = plan.chat.messages.count
            #expect(FuzzPlan.chatRange.contains(count) || FuzzPlan.longChatRange.contains(count), "seed \(seed): \(count) messages")
            #expect(FuzzPlan.groupRange.contains(plan.group.messages.count), "seed \(seed)")
            if FuzzPlan.longChatRange.contains(count) { long += 1 }
        }
        // Some seeds are past the first window, so older messages load.
        #expect(long > 0)
        #expect(long < Self.seeds.count / 2)
    }

    @Test func everyKindOfContentShowsUpAcrossSeeds() {
        let messages = Self.seeds.flatMap { seed in
            let plan = FuzzPlan(seed: seed)
            return plan.chat.messages + plan.group.messages
        }
        let kinds = Set(messages.map(\.kind))
        #expect(kinds == Set(FuzzMessage.Kind.allCases), "missing: \(Set(FuzzMessage.Kind.allCases).subtracting(kinds))")

        let shapes = Set(messages.compactMap(\.media).filter { $0.kind == .photo }.compactMap { media in
            media.width.flatMap { width in media.height.map { height in width == height ? "square" : width > 2 * height ? "very wide" : height > 2 * width ? "very tall" : width > height ? "landscape" : "portrait" } }
        })
        #expect(shapes == ["square", "very wide", "very tall", "landscape", "portrait"])
        #expect(Set(messages.compactMap(\.media?.state)) == [.ready, .remote, .downloadFailed])
        #expect(messages.contains { $0.preview?.imageWidth != nil && $0.kind == .linkPageImage })
        #expect(messages.contains { if case .to = $0.reply { true } else { false } })
        #expect(messages.contains { if case .missing = $0.reply { true } else { false } })
        #expect(messages.contains { $0.reactions.count > 1 })
        #expect(messages.contains { $0.reactions.contains { $0.reactor == nil } })
        #expect(messages.contains { $0.reactions.contains { $0.reactor != nil } })
        #expect(messages.contains { $0.reactions.contains { $0.isPending } })
        #expect(messages.contains { $0.edited })
        #expect(messages.contains { $0.retracted })
        #expect(messages.contains { $0.undecryptable })
        #expect(messages.contains { $0.mentionsMe })
        #expect(Set(messages.compactMap(\.status)).isSuperset(of: [.displayed, .pending, .failed]))
        #expect(messages.contains { $0.outgoing } && messages.contains { !$0.outgoing })

        let plans = Self.seeds.map(FuzzPlan.init(seed:))
        #expect(Set(plans.map(\.chat.previewsAllowed)) == [nil, true])
        // Gaps of days, for day headers, and runs of one sender in the group.
        #expect(plans.contains { plan in zip(plan.chat.messages, plan.chat.messages.dropFirst()).contains { $1.time - $0.time > 86_400 } })
        #expect(plans.contains { plan in
            zip(plan.group.messages, zip(plan.group.messages.dropFirst(), plan.group.messages.dropFirst(2))).contains { first, rest in
                !first.outgoing && first.nick == rest.0.nick && first.nick == rest.1.nick && !rest.0.outgoing && !rest.1.outgoing
            }
        })
    }

    @Test func theNewestMessageEndsWithItsMarker() {
        for seed in Self.seeds {
            let plan = FuzzPlan(seed: seed)
            let chat = plan.chat.messages.last!, group = plan.group.messages.last!
            #expect(chat.body.hasSuffix(FuzzFixture.newestMarker(seed: seed)) || chat.body.hasPrefix(FuzzFixture.newestMarker(seed: seed)), "seed \(seed)")
            #expect(group.body.hasSuffix(FuzzFixture.groupNewestMarker(seed: seed)) || group.body.hasPrefix(FuzzFixture.groupNewestMarker(seed: seed)), "seed \(seed)")
            for newest in [chat, group] {
                #expect(!newest.retracted && !newest.undecryptable && newest.media == nil, "seed \(seed)")
            }
        }
    }

    @Test func repliesPointToEarlierMessages() {
        for seed in Self.seeds {
            let plan = FuzzPlan(seed: seed)
            for messages in [plan.chat.messages, plan.group.messages] {
                for (index, message) in messages.enumerated() {
                    if case .to(let target) = message.reply { #expect(target < index, "seed \(seed) message \(index)") }
                }
            }
        }
    }

    @Test func fillWritesThePlan() throws {
        // A seed with a bit of everything that isn't too long to write.
        let seed: UInt64 = 3
        let plan = FuzzPlan(seed: seed)
        let database = try AppDatabase.inMemory()
        let directory = AccountDirectory(url: FileManager.default.temporaryDirectory.appending(path: "fuzz-\(UUID().uuidString)"))
        defer { try? FileManager.default.removeItem(at: directory.url) }
        try FuzzFixture(seed: seed).fill(database, directory: directory)

        let all = plan.chat.messages + plan.group.messages
        try database.reader.read { db in
            let chat = try #require(try Conversation.filter(Column("peer") == FuzzFixture.chatPeer).fetchOne(db))
            let group = try #require(try GroupChat.filter(Column("jid") == FuzzFixture.groupPeer).fetchOne(db))
            #expect(try Message.filter(Column("conversationId") == chat.id).fetchCount(db) == plan.chat.messages.count)
            #expect(try Message.filter(Column("conversationId") == group.conversationId).fetchCount(db) == plan.group.messages.count)

            let attachments = try Attachment.fetchAll(db)
            #expect(attachments.count == all.filter { $0.media != nil }.count)
            for attachment in attachments where attachment.state == .ready {
                let file = try #require(directory.attachments.url(for: attachment))
                #expect(FileManager.default.fileExists(atPath: file.path), "\(attachment.name) has no file")
            }
            // Every link has a stored preview, so nothing is fetched.
            for message in try Message.filter(Column("link") != nil).fetchAll(db) {
                #expect(try LinkPreview.fetchOne(db, key: message.link) != nil, "no preview for \(message.link ?? "")")
            }
            for preview in try LinkPreview.filter(Column("imageFile") != nil).fetchAll(db) {
                #expect(FileManager.default.fileExists(atPath: directory.previews.appending(path: preview.imageFile!).path))
            }
            #expect(try Reaction.fetchCount(db) == all.reduce(0) { $0 + $1.reactions.count })
            #expect(try Reaction.filter(Column("pendingId") != nil).fetchCount(db) == all.reduce(0) { $0 + $1.reactions.filter(\.isPending).count })
            #expect(try Message.filter(Column("isRetracted") == true).fetchCount(db) == all.filter(\.retracted).count)
        }
    }
}
