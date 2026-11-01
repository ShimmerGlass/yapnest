import Foundation
import Testing
import YapnestKit
@testable import Yapnest

/// What waits in the composer to go out with the next send.
@MainActor
struct PendingAttachmentsTests {
    private func files(_ model: ConversationModel) -> [String] {
        model.pendingAttachments.compactMap { if case .file(let url, _) = $0.content { url.lastPathComponent } else { nil } }
    }

    @Test func attachmentsStayInTheOrderTheyWereAdded() throws {
        let f = try ConversationFixture()
        f.model.stage(try makeTemporaryFile("one.png"), isPhoto: true)
        f.model.stageLocation(GeoLocation(latitude: 48.85, longitude: 2.35))
        f.model.stage(try makeTemporaryFile("two.pdf"), isPhoto: false)
        #expect(f.model.pendingAttachments.count == 3)
        #expect(files(f.model) == ["one.png", "two.pdf"])
        guard case .location = f.model.pendingAttachments[1].content else {
            Issue.record("the location lost its place between the files")
            return
        }
    }

    @Test func removingOneDeletesItsCopyAndKeepsTheRestInOrder() throws {
        let f = try ConversationFixture()
        let a = try makeTemporaryFile("a.png"), b = try makeTemporaryFile("b.png"), c = try makeTemporaryFile("c.png")
        for file in [a, b, c] { f.model.stage(file, isPhoto: true) }

        f.model.removePendingAttachment(f.model.pendingAttachments[1].id)
        #expect(files(f.model) == ["a.png", "c.png"])
        #expect(!FileManager.default.fileExists(atPath: b.path))
        #expect(FileManager.default.fileExists(atPath: a.path) && FileManager.default.fileExists(atPath: c.path))
        for file in [a, c] { AttachmentPicker.discardCopy(file) }
    }

    @Test func removingSomethingThatIsGoneChangesNothing() throws {
        let f = try ConversationFixture()
        let a = try makeTemporaryFile("a.png")
        f.model.stage(a, isPhoto: true)
        f.model.removePendingAttachment(UUID())
        #expect(files(f.model) == ["a.png"])
        AttachmentPicker.discardCopy(a)
    }

    @Test func theCameraWithoutAccessSaysSoInsteadOfOpeningBlack() async throws {
        let f = try ConversationFixture()
        let picker = AttachmentPicker(model: f.model)
        picker.cameraAvailable = { true }
        picker.cameraAccess = { false }
        picker.attach(from: .camera)
        for _ in 0..<100 where f.model.prompt == nil { try await Task.sleep(for: .milliseconds(10)) }
        guard case .notice(let title, _)? = f.model.prompt else {
            Issue.record("the missing access wasn't explained")
            return
        }
        #expect(title == "No access to the camera")
    }

    // The hint went into the field's placeholder, which a draft hides.
    @Test func aVoiceMessageThatWasTooShortIsToldWhateverTheFieldHolds() throws {
        let f = try ConversationFixture()
        f.model.textChanged("a draft")

        f.model.voiceWasTooShort()

        guard case .notice(let title, _)? = f.model.prompt else {
            Issue.record("nothing was shown")
            return
        }
        #expect(title == "Voice message too short")
    }

    // Opening a file on the Mac works on a copy under its own name, and each
    // one stayed in the temporary directory.
    @Test func copiesMadeToOpenAFileOnTheMacAreRemovedOnceTheyAreOld() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "copies-\(UUID().uuidString)")
        let old = folder.appending(path: "old"), recent = folder.appending(path: "recent")
        for copy in [old, recent] { try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true) }
        try FileManager.default.setAttributes([.creationDate: Date().addingTimeInterval(-3 * 24 * 3600)], ofItemAtPath: old.path)

        MacFileActions.removeOldCopies(in: folder)

        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: recent.path))
        try? FileManager.default.removeItem(at: folder)
    }

    /// On the Mac the chat's window closing leaves the permission prompt up;
    /// the picker held its model `unowned`, so answering it afterwards crashed.
    @Test func aChatClosedWhileTheCameraPromptIsUpIsLeftAlone() async throws {
        var fixture: ConversationFixture? = try ConversationFixture()
        weak var model = fixture?.model
        let picker = AttachmentPicker(model: try #require(fixture).model)
        var answer: CheckedContinuation<Bool, Never>?
        picker.cameraAvailable = { true }
        picker.cameraAccess = { await withCheckedContinuation { answer = $0 } }
        picker.attach(from: .camera)
        for _ in 0..<100 where answer == nil { try await Task.sleep(for: .milliseconds(10)) }

        fixture = nil
        for _ in 0..<100 where model != nil { try await Task.sleep(for: .milliseconds(10)) }
        try #require(model == nil, "the model is still held, so the picker's reference isn't tested")
        answer?.resume(returning: false)
        try await Task.sleep(for: .milliseconds(100))
    }

    /// The system's camera picker logs nothing, so a black one has to be
    /// told apart by what was found before it opened.
    @Test func theCameraLeavesWhatItFoundInTheLog() async throws {
        let f = try ConversationFixture()
        let picker = AttachmentPicker(model: f.model)
        picker.cameraAvailable = { true }
        picker.cameraAccess = { false }
        let (asked, refused) = (try logged("Composer camera asked for available=true"), try logged("Composer camera access allowed=false"))
        picker.attach(from: .camera)
        for _ in 0..<100 where f.model.prompt == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(try logged("Composer camera asked for available=true") > asked)
        #expect(try logged("Composer camera access allowed=false") > refused)
    }

    /// How often `line` is in the exported log. The log outlives a test run
    /// and other tests write to it, so a test compares counts.
    private func logged(_ line: String) throws -> Int {
        let text = try String(contentsOf: DiagnosticsExport.make(), encoding: .utf8)
        return text.components(separatedBy: line).count - 1
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
        let file = try makeTemporaryFile("left.png")
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

    @Test func aSharedContactIsNamedSafely() {
        #expect(AttachmentPicker.vCardName("AC/DC") == "AC-DC")
        #expect(AttachmentPicker.vCardName("AC\\DC") == "AC-DC")
        #expect(AttachmentPicker.vCardName("Mom\u{202E}fcv.exe") == "Momfcv.exe", "an override can't reorder the name")
        #expect(AttachmentPicker.vCardName("..hidden") == "hidden")
        #expect(AttachmentPicker.vCardName("") == "Contact")
    }
}
