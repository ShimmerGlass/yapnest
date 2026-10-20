import Foundation
import Testing
import YapnestKit
@testable import Yapnest

/// What waits in the composer to go out with the next send.
@MainActor
struct PendingAttachmentsTests {
    /// A file in a folder of its own in the temporary directory, as the
    /// pickers make their copies.
    private func copy(_ name: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: name)
        try Data("x".utf8).write(to: file)
        return file
    }

    private func files(_ model: ConversationModel) -> [String] {
        model.pendingAttachments.compactMap { if case .file(let url, _) = $0.content { url.lastPathComponent } else { nil } }
    }

    @Test func attachmentsStayInTheOrderTheyWereAdded() throws {
        let f = try ConversationFixture()
        f.model.stage(try copy("one.png"), isPhoto: true)
        f.model.stageLocation(GeoLocation(latitude: 48.85, longitude: 2.35))
        f.model.stage(try copy("two.pdf"), isPhoto: false)
        #expect(f.model.pendingAttachments.count == 3)
        #expect(files(f.model) == ["one.png", "two.pdf"])
        guard case .location = f.model.pendingAttachments[1].content else {
            Issue.record("the location lost its place between the files")
            return
        }
    }

    @Test func removingOneDeletesItsCopyAndKeepsTheRestInOrder() throws {
        let f = try ConversationFixture()
        let a = try copy("a.png"), b = try copy("b.png"), c = try copy("c.png")
        for file in [a, b, c] { f.model.stage(file, isPhoto: true) }

        f.model.removePendingAttachment(f.model.pendingAttachments[1].id)
        #expect(files(f.model) == ["a.png", "c.png"])
        #expect(!FileManager.default.fileExists(atPath: b.path))
        #expect(FileManager.default.fileExists(atPath: a.path) && FileManager.default.fileExists(atPath: c.path))
        for file in [a, c] { AttachmentPicker.discardCopy(file) }
    }

    @Test func removingSomethingThatIsGoneChangesNothing() throws {
        let f = try ConversationFixture()
        let a = try copy("a.png")
        f.model.stage(a, isPhoto: true)
        f.model.removePendingAttachment(UUID())
        #expect(files(f.model) == ["a.png"])
        AttachmentPicker.discardCopy(a)
    }

    @Test func aChatThatCannotBeWrittenToTurnsAwayLocationsAndSaysWhy() throws {
        let f = try ConversationFixture()
        f.model.canSendAttachments = false
        f.model.stageLocation(GeoLocation(latitude: 1, longitude: 2))
        #expect(f.model.pendingAttachments.isEmpty)
        guard case .notice? = f.model.prompt else {
            Issue.record("the refusal wasn't explained")
            return
        }
    }

    @Test func aChatThatCannotBeWrittenToDoesNotOpenThePickers() throws {
        let f = try ConversationFixture()
        f.model.canSendAttachments = false
        f.model.openGifPicker()
        #expect(!f.model.showsGifPicker)
        f.model.canSendAttachments = true
        f.model.openGifPicker()
        #expect(f.model.showsGifPicker)
    }

    @Test func leavingTheChatDiscardsTheCopiesNobodyElseOwns() throws {
        let file = try copy("left.png")
        do {
            let f = try ConversationFixture()
            f.model.stage(file, isPhoto: true)
            #expect(FileManager.default.fileExists(atPath: file.path))
            f.reopen()
        }
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func discardingNeverDeletesAFileOutsideItsOwnFolder() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "keep-\(UUID().uuidString).txt")
        try Data("x".utf8).write(to: file)
        AttachmentPicker.discardCopy(file)
        #expect(FileManager.default.fileExists(atPath: file.path))
        try FileManager.default.removeItem(at: file)
    }
}
