import Foundation
import GRDB
import Testing
import YapnestKit
@testable import Yapnest

/// A shrink that writes a small file, for as long as `holds` says, and says what it was asked.
private final class FakeShrinker: @unchecked Sendable {
    private let lock = NSLock()
    private var _sources: [URL] = []
    private var _holds = false
    private var _failure: Error?
    private var _folders: [URL] = []

    var sources: [URL] { lock.withLock { _sources } }
    var folders: [URL] { lock.withLock { _folders } }
    var holds: Bool {
        get { lock.withLock { _holds } }
        set { lock.withLock { _holds = newValue } }
    }
    var failure: Error? {
        get { lock.withLock { _failure } }
        set { lock.withLock { _failure = newValue } }
    }

    func shrink(_ source: URL, _ folder: URL, _ limit: Int64, _ progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        lock.withLock {
            _sources.append(source)
            _folders.append(folder)
        }
        progress(0.5)
        while holds { try await Task.sleep(for: .milliseconds(10)) }
        if let failure { throw failure }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let result = folder.appending(path: "clip.txt")
        try Data("small".utf8).write(to: result)
        return result
    }
}

@MainActor
struct VideoShrinkOfferTests {
    private func fixture(limit: Int64? = 5, shrinker: FakeShrinker = FakeShrinker()) throws -> (ConversationFixture, FakeShrinker) {
        let f = try ConversationFixture()
        f.model.uploadLimitLookup = { _, _ in limit }
        f.model.shrinkVideo = { source, folder, limit, progress in try await shrinker.shrink(source, folder, limit, progress) }
        return (f, shrinker)
    }

    private func isOffered(_ model: ConversationModel) -> Bool {
        if case .videoTooLarge? = model.prompt { true } else { false }
    }

    private func answerSmaller(_ f: ConversationFixture) { f.model.sendSmallerVideos() }

    private func names(_ model: ConversationModel) -> [String] {
        model.pendingAttachments.compactMap { if case .file(let url, _) = $0.content { url.lastPathComponent } else { nil } }
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    @Test func aVideoOverTheLimitRaisesThePrompt() async throws {
        let (f, _) = try fixture()
        let video = try makeTemporaryFile("clip.mov")
        defer { AttachmentPicker.discardCopy(video) }
        f.model.stage(video, isPhoto: false)
        await eventually("the offer") { isOffered(f.model) }
        #expect(f.model.prompt == .videoTooLarge(limit: 5))
    }

    @Test func nothingElseRaisesIt() async throws {
        let small = try fixture(limit: 1000), unknown = try fixture(limit: nil), photo = try fixture(), file = try fixture()
        let files = [try makeTemporaryFile("a.mov"), try makeTemporaryFile("b.mov"), try makeTemporaryFile("c.jpg"), try makeTemporaryFile("d.pdf")]
        defer { files.forEach(AttachmentPicker.discardCopy) }
        small.0.model.stage(files[0], isPhoto: false)
        unknown.0.model.stage(files[1], isPhoto: false)
        photo.0.model.stage(files[2], isPhoto: true)
        file.0.model.stage(files[3], isPhoto: false)
        let models: [ConversationModel] = [small, unknown, photo, file].map { $0.0.model }
        #expect(await stays { models.allSatisfy { $0.prompt == nil } })
    }

    @Test func twoVideosShareOnePromptAndBothAreShrunk() async throws {
        let (f, shrinker) = try fixture()
        let a = try makeTemporaryFile("a.mov"), b = try makeTemporaryFile("b.mp4")
        f.model.stage(a, isPhoto: false)
        await eventually("the offer") { isOffered(f.model) }
        f.model.stage(b, isPhoto: false)
        await eventually("both waiting") { f.model.oversizedVideos.count == 2 }
        #expect(isOffered(f.model))
        answerSmaller(f)
        await eventually("both shrunk") { names(f.model) == ["clip.txt", "clip.txt"] }
        #expect(Set(shrinker.sources) == [a, b])
        #expect(f.model.prompt == nil)
        for case .file(let url, _) in f.model.pendingAttachments.map(\.content) { AttachmentPicker.discardCopy(url) }
    }

    @Test func keepingTheOriginalLeavesItAloneAndShrinksNothing() async throws {
        let (f, shrinker) = try fixture()
        let video = try makeTemporaryFile("clip.mov")
        defer { AttachmentPicker.discardCopy(video) }
        f.model.stage(video, isPhoto: false)
        await eventually("the offer") { isOffered(f.model) }
        f.model.keepOriginalVideos()
        #expect(f.model.prompt == nil)
        #expect(f.model.oversizedVideos.isEmpty)
        #expect(await stays { shrinker.sources.isEmpty && names(f.model) == ["clip.mov"] })
        #expect(exists(video))
    }

    /// SwiftUI clears the prompt as the alert closes, which may come before the button's action.
    @Test func theAnswerCountsWhenTheAlertClosedBeforeIt() async throws {
        let (f, shrinker) = try fixture()
        let video = try makeTemporaryFile("clip.mov")
        defer { AttachmentPicker.discardCopy(video) }
        f.model.stage(video, isPhoto: false)
        await eventually("the offer") { isOffered(f.model) }
        f.model.prompt = nil
        #expect(!isOffered(f.model))
        answerSmaller(f)
        await eventually("the shrink") { shrinker.sources == [video] }
    }

    @Test func aShrinkReplacesTheFileInPlaceAndDiscardsTheOriginal() async throws {
        let (f, _) = try fixture()
        let first = try makeTemporaryFile("first.png"), video = try makeTemporaryFile("clip.mov"), last = try makeTemporaryFile("last.pdf")
        for (file, photo) in [(first, true), (video, false), (last, false)] { f.model.stage(file, isPhoto: photo) }
        let ids = f.model.pendingAttachments.map(\.id)
        await eventually("the offer") { isOffered(f.model) }
        f.model.shrinkVideo = { source, folder, limit, progress in
            progress(0.5)
            try await Task.sleep(for: .milliseconds(100))
            return try await FakeShrinker().shrink(source, folder, limit, progress)
        }
        answerSmaller(f)
        await eventually("progress") { f.model.shrinks[ids[1]]?.progress == 0.5 }
        await eventually("the swap") { names(f.model) == ["first.png", "clip.txt", "last.pdf"] }
        #expect(f.model.pendingAttachments.map(\.id) == ids)
        #expect(!exists(video))
        #expect(f.model.shrinks.isEmpty)
        for case .file(let url, _) in f.model.pendingAttachments.map(\.content) { AttachmentPicker.discardCopy(url) }
    }

    @Test func aFailedShrinkKeepsTheOriginalAndSaysSo() async throws {
        let shrinker = FakeShrinker()
        shrinker.failure = VideoShrink.Failure.stillTooLarge
        let (f, _) = try fixture(shrinker: shrinker)
        let video = try makeTemporaryFile("clip.mov")
        defer { AttachmentPicker.discardCopy(video) }
        f.model.stage(video, isPhoto: false)
        await eventually("the offer") { isOffered(f.model) }
        answerSmaller(f)
        await eventually("the notice") { if case .notice? = f.model.prompt { true } else { false } }
        guard case .notice(let title, let message)? = f.model.prompt else { return }
        #expect(title == "Couldn't make the video smaller")
        #expect(message == VideoShrink.Failure.stillTooLarge.localizedDescription)
        #expect(names(f.model) == ["clip.mov"])
        #expect(exists(video))
        #expect(f.model.shrinks.isEmpty)
    }

    @Test func removingTheVideoDuringTheShrinkStopsItAndLeavesNothing() async throws {
        let shrinker = FakeShrinker()
        shrinker.holds = true
        let (f, _) = try fixture(shrinker: shrinker)
        let video = try makeTemporaryFile("clip.mov")
        f.model.stage(video, isPhoto: false)
        await eventually("the offer") { isOffered(f.model) }
        answerSmaller(f)
        await eventually("started") { shrinker.sources.count == 1 }
        let folder = try #require(shrinker.folders.first)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        f.model.removePendingAttachment(f.model.pendingAttachments[0].id)
        await eventually("the folder is gone") { !exists(folder) }
        #expect(f.model.pendingAttachments.isEmpty)
        #expect(f.model.shrinks.isEmpty)
        #expect(!exists(video))
        // A result that arrives after the removal is not staged.
        shrinker.holds = false
        #expect(await stays { f.model.pendingAttachments.isEmpty && !exists(folder) })
    }

    @Test func aShrinkThatFinishesAfterTheRemovalIsDiscarded() async throws {
        let shrinker = FakeShrinker()
        let (f, _) = try fixture(shrinker: shrinker)
        let video = try makeTemporaryFile("clip.mov")
        f.model.stage(video, isPhoto: false)
        await eventually("the offer") { isOffered(f.model) }
        // Ignores cancellation, as a shrink that was already done would.
        f.model.shrinkVideo = { source, folder, limit, progress in
            let result = try await shrinker.shrink(source, folder, limit, progress)
            try? await Task.sleep(for: .milliseconds(150))
            return result
        }
        answerSmaller(f)
        await eventually("the shrink") { !shrinker.folders.isEmpty }
        let folder = try #require(shrinker.folders.first)
        f.model.removePendingAttachment(f.model.pendingAttachments[0].id)
        await eventually("its copy is gone") { !exists(folder) }
        #expect(await stays { f.model.pendingAttachments.isEmpty })
    }

    /// Taken along, the wait would hold every later message back with nothing on screen.
    @Test func sendingDuringAShrinkWaitsForItAndKeepsWhatIsStaged() async throws {
        let shrinker = FakeShrinker()
        shrinker.holds = true
        let (f, _) = try fixture(shrinker: shrinker)
        let video = try makeTemporaryFile("clip.mov")
        defer { AttachmentPicker.discardCopy(video) }
        f.model.stage(video, isPhoto: false)
        await eventually("the offer") { isOffered(f.model) }
        answerSmaller(f)
        await eventually("started") { shrinker.sources.count == 1 }
        f.model.send("look")
        #expect(f.model.prompt == .notice(title: "Still making the video smaller", message: "Send again once it's done, or remove the video to send without it."))
        #expect(names(f.model) == ["clip.mov"])
        #expect(f.model.shrinks.count == 1)
        #expect(await stays { (try? f.database.reader.read { try YapnestKit.Message.fetchCount($0) }) == 0 })
        shrinker.holds = false
        await eventually("the smaller copy") { names(f.model) == ["clip.txt"] }
    }

    @Test func sendingWithoutAnsweringKeepsTheOriginals() async throws {
        let (f, shrinker) = try fixture()
        let video = try makeTemporaryFile("clip.txt")
        f.model.stage(video, isPhoto: false)
        let other = try makeTemporaryFile("clip.mov")
        f.model.stage(other, isPhoto: false)
        await eventually("the offer") { isOffered(f.model) }
        f.model.send("")
        #expect(f.model.prompt == nil)
        #expect(f.model.oversizedVideos.isEmpty)
        #expect(await stays { shrinker.sources.isEmpty })
        await eventually("settled") { f.model.preparingAttachments == 0 }
    }

    @Test func anotherPromptIsNotReplacedAndTheVideoIsOfferedWithTheNextOne() async throws {
        let (f, shrinker) = try fixture()
        f.model.prompt = .quoteNotFound
        let video = try makeTemporaryFile("clip.mov")
        f.model.stage(video, isPhoto: false)
        await eventually("waiting") { f.model.oversizedVideos.count == 1 }
        #expect(await stays { f.model.prompt == .quoteNotFound })
        f.model.prompt = nil
        #expect(f.model.prompt == nil)
        let next = try makeTemporaryFile("next.mov")
        f.model.stage(next, isPhoto: false)
        await eventually("the offer") { isOffered(f.model) }
        answerSmaller(f)
        await eventually("both shrunk") { Set(shrinker.sources) == [video, next] }
        await eventually("settled") { f.model.shrinks.isEmpty }
        for item in f.model.pendingAttachments { f.model.removePendingAttachment(item.id) }
    }

    @Test func leavingTheChatStopsTheShrinkAndRemovesItsFolder() async throws {
        let shrinker = FakeShrinker()
        shrinker.holds = true
        var fixture: ConversationFixture? = try ConversationFixture()
        weak var model = fixture?.model
        let folder: URL
        do {
            let f = try #require(fixture)
            f.model.uploadLimitLookup = { _, _ in 5 }
            f.model.shrinkVideo = { source, folder, limit, progress in try await shrinker.shrink(source, folder, limit, progress) }
            f.model.stage(try makeTemporaryFile("clip.mov"), isPhoto: false)
            await eventually("the offer") { isOffered(f.model) }
            f.model.sendSmallerVideos()
            await eventually("started") { shrinker.sources.count == 1 }
            folder = try #require(shrinker.folders.first)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        fixture = nil
        await eventually("the model goes") { model == nil }
        await eventually("the folder is gone") { !exists(folder) }
    }
}
