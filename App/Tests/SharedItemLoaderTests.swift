import Foundation
import Testing
import UIKit
import UniformTypeIdentifiers
import YapnestKit

@testable import Yapnest

/// The share extension's loading of what other apps hand it, which lives in
/// App/Shared so that it can be reached from here.
struct SharedItemLoaderTests {
    private func loader() throws -> SharedItemLoader {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return SharedItemLoader(folder: folder)
    }

    private func item(_ providers: NSItemProvider...) -> NSExtensionItem {
        let item = NSExtensionItem()
        item.attachments = providers
        return item
    }

    /// What another app's share sheet hands over: one item under one type.
    private func provider(_ value: NSSecureCoding, as type: UTType) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerItem(forTypeIdentifier: type.identifier) { completion, _, _ in completion?(value, nil) }
        return provider
    }

    private func square() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
    }

    @Test func aFileSharedByItsAddressIsCopiedWithItsName() async throws {
        let source = try makeTemporaryFile("report.txt")
        let provider = NSItemProvider()
        provider.registerItem(forTypeIdentifier: UTType.fileURL.identifier) { completion, _, _ in
            completion?(source as NSURL, nil)
        }
        let loader = try loader()

        let loaded = await loader.load([item(provider)])

        guard case .file(let file, let size) = try #require(loaded.first).content else { Issue.record("not a file"); return }
        #expect(file.name == "report.txt")
        #expect(file.url != source)
        #expect(file.url.path.hasPrefix(loader.folder.path))
        #expect(size == source.fileSize)
        #expect(!file.isPhoto)
    }

    @Test func aPictureWithNoFileBehindItIsTakenAsAPhoto() async throws {
        let loaded = try await loader().load([item(NSItemProvider(object: square()))])

        guard case .file(let file, _) = try #require(loaded.first).content else { Issue.record("not a file"); return }
        #expect(UIImage(contentsOfFile: file.url.path) != nil)
        #expect(file.isPhoto)
    }

    @Test func aSuggestedNameIsKept() async throws {
        let source = try makeTemporaryFile("tmp-1234.pdf")
        let provider = NSItemProvider()
        provider.registerFileRepresentation(forTypeIdentifier: UTType.pdf.identifier, fileOptions: [], visibility: .all) { completion in
            completion(source, false, nil)
            return nil
        }
        provider.suggestedName = "Quarterly report"

        let loaded = try await loader().load([item(provider)])

        guard case .file(let file, _) = try #require(loaded.first).content else { Issue.record("not a file"); return }
        #expect(file.name == "Quarterly report.pdf")
    }

    @Test func sharedTextStaysText() async throws {
        let loaded = try await loader().load([item(provider("hello there" as NSString, as: .plainText))])

        guard case .text(let text, let isLink) = try #require(loaded.first).content else { Issue.record("not text"); return }
        #expect(text == "hello there")
        #expect(!isLink)
    }

    @Test func aLinkIsTextAndDropsThePageTitleBesideIt() async throws {
        let url = try #require(URL(string: "https://example.com/page"))
        let loaded = try await loader().load([item(provider(url as NSURL, as: .url), provider("Page title" as NSString, as: .plainText))])

        #expect(loaded.count == 1)
        guard case .text(let text, let isLink) = try #require(loaded.first).content else { Issue.record("not text"); return }
        #expect(text == "https://example.com/page")
        #expect(isLink)
    }

    @Test func aFolderSharedByItsAddressIsLeftOut() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("inside".utf8).write(to: folder.appending(path: "a.txt"))
        let provider = NSItemProvider()
        provider.registerItem(forTypeIdentifier: UTType.fileURL.identifier) { completion, _, _ in completion?(folder as NSURL, nil) }
        let loader = try loader()

        let loaded = await loader.load([item(provider)])

        guard case .unsupported(let name, _) = try #require(loaded.first).content else { Issue.record("not left out"); return }
        #expect(name == folder.lastPathComponent)
        #expect(try FileManager.default.contentsOfDirectory(atPath: loader.folder.path).isEmpty)
    }

    @Test func aFileAddressSharedAsALinkIsCopiedAsAFile() async throws {
        let source = try makeTemporaryFile("notes.txt")
        let loader = try loader()

        let loaded = await loader.load([item(provider(source as NSURL, as: .url))])

        guard case .file(let file, _) = try #require(loaded.first).content else { Issue.record("sent as a link"); return }
        #expect(file.name == "notes.txt")
        #expect(file.url.path.hasPrefix(loader.folder.path))
    }

    @Test func textHandedOverAsDataIsText() async throws {
        let loaded = try await loader().load([item(provider(Data("bytes of text".utf8) as NSData, as: .plainText))])

        guard case .text(let text, _) = try #require(loaded.first).content else { Issue.record("not text"); return }
        #expect(text == "bytes of text")
    }

    @Test func textThatCantBeReadStillShowsATile() async throws {
        let loaded = try await loader().load([item(provider(Data([0xFF, 0xFE, 0xFD]) as NSData, as: .plainText))])

        guard case .unsupported = try #require(loaded.first).content else { Issue.record("dropped without a tile"); return }
    }

    @Test func aCancelledLoadCopiesNothing() async throws {
        let source = try makeTemporaryFile("late.txt")
        let late = NSItemProvider()
        late.registerItem(forTypeIdentifier: UTType.fileURL.identifier) { completion, _, _ in completion?(source as NSURL, nil) }
        let loader = try loader()
        let extensionItem = item(late)
        nonisolated(unsafe) let items = [extensionItem]
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            return await loader.load(items)
        }

        task.cancel()

        #expect(await task.value.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: loader.folder.path).isEmpty)
    }
}
