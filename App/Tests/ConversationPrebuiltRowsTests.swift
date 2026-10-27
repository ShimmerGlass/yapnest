import Foundation
import Testing
import YapnestKit
@testable import Yapnest

/// Opening a chat builds its rows off the main actor; the rows must be the
/// ones the main actor would have made.
@MainActor
struct ConversationPrebuiltRowsTests {
    private func open(_ f: ConversationFixture, previews: LinkPreviewer? = nil) async {
        f.model.start(previews: previews)
        await eventually("the conversation never loaded") { f.model.hasLoaded }
    }

    private func fill(_ f: ConversationFixture) throws -> (link: Int64, file: Int64) {
        try f.addMany(4, read: true)
        let link = try f.add("see https://example.org/page", read: true)
        let file = try f.add("", read: true)
        try f.attach("photo.jpg", to: file, state: .remote, mimeType: "image/jpeg")
        try f.add("new 1")
        try f.add("new 2", .incoming)
        try f.add("mine", .outgoing)
        try f.database.writer.write { db in
            try LinkPreview(url: "https://example.org/page", kind: .page, title: "A page").insert(db)
        }
        try f.database.setLinkPreviews(true, peer: f.peer)
        return (link.id!, file.id!)
    }

    private func checkOpenedRows(_ f: ConversationFixture, link: Int64, file: Int64) {
        let rows = f.model.rows
        #expect(rows.count == 9)
        #expect(f.model.rowsBuiltOnMain == 0)
        #expect(rows.map(\.content) == f.model.contentsBuiltOnMainForTesting())
        #expect(rows.allSatisfy { $0.revision == 1 })
        #expect(rows.filter(\.content.layout.showsUnreadDivider).count == 1)
        #expect(rows.first { $0.id == file }?.content.attachment != nil)
        if case .page = rows.first(where: { $0.id == link })?.content.preview {} else {
            Issue.record("the link shows no preview")
        }
    }

    @Test func aChatOpensWithRowsBuiltOffTheMainActor() async throws {
        let f = try ConversationFixture()
        let ids = try fill(f)
        let previewer = LinkPreviewer(database: f.database, directory: FileManager.default.temporaryDirectory.appending(path: "prebuilt-\(UUID().uuidString)"))
        await open(f, previews: previewer)
        checkOpenedRows(f, link: ids.link, file: ids.file)
    }

    @Test func aGroupOpensWithRowsBuiltOffTheMainActor() async throws {
        let f = try ConversationFixture(kind: .groupchat)
        try f.makeGroup()
        let ids = try fill(f)
        let previewer = LinkPreviewer(database: f.database, directory: FileManager.default.temporaryDirectory.appending(path: "prebuilt-\(UUID().uuidString)"))
        await open(f, previews: previewer)
        #expect(f.model.isGroup)
        #expect(f.model.rowsBuiltOnMain == 0)
        #expect(f.model.rows.map(\.content) == f.model.contentsBuiltOnMainForTesting())
        #expect(f.model.rows.contains { $0.content.senderName != nil })
        _ = ids
    }

    @Test func aPrebuiltRowIsUsedOnlyWhileItsInputsAreTheCurrentOnes() async throws {
        let f = try ConversationFixture()
        try f.addMany(5, read: true)
        await open(f)

        let current = await f.model.rowsBuiltWithMarkedPrebuiltForTesting(stillCurrent: true)
        #expect(current.allSatisfy { $0.content.accessibilityLabel == "prebuilt" })

        let stale = await f.model.rowsBuiltWithMarkedPrebuiltForTesting(stillCurrent: false)
        #expect(stale.count == 5)
        #expect(stale.allSatisfy { $0.content.accessibilityLabel != "prebuilt" })
    }
}
