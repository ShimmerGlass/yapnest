import Foundation
import Testing
import UIKit
import YapnestKit
@testable import Yapnest

/// Pasting past `LongText.threshold` characters attaches a text file rather
/// than filling the field.
@MainActor
struct LongPasteTests {
    private func withBoard(_ body: (UIPasteboard) async throws -> Void) async throws {
        let name = UIPasteboard.Name(UUID().uuidString)
        let board = try #require(UIPasteboard(name: name, create: true))
        defer { UIPasteboard.remove(withName: name) }
        try await body(board)
    }

    private final class Pasted {
        var texts: [String] = []
        var attachments = 0
    }

    private func makeField(pasting board: UIPasteboard) -> (ComposerTextView, Pasted) {
        let field = ComposerTextView()
        field.pasteboard = board
        let pasted = Pasted()
        field.onPasteLongText = { pasted.texts.append($0); return true }
        field.onPasteAttachments = { pasted.attachments += $0.count }
        return (field, pasted)
    }

    @Test func aLongPasteIsOfferedAsAFileAndLeavesTheFieldEmpty() async throws {
        try await withBoard { board in
            let text = String(repeating: "word ", count: LongText.threshold)
            board.string = text
            let (field, pasted) = makeField(pasting: board)
            field.paste(nil)
            #expect(pasted.texts == [text])
            #expect(pasted.attachments == 0)
            #expect(field.text.isEmpty)
        }
    }

    @Test func aShortPasteIsLeftToTheTextView() async throws {
        try await withBoard { board in
            board.string = "a few words"
            let (field, pasted) = makeField(pasting: board)
            field.paste(nil)
            // What the text view then types is UIKit's own paste, which a
            // view outside a window and the app's own prompt don't let a test see.
            #expect(pasted.texts.isEmpty && pasted.attachments == 0)
        }
    }

    @Test func aFileWithItsOwnLongContentsIsOfferedAsTheFileOnly() async throws {
        try await withBoard { board in
            let file = try makeTemporaryFile("notes.pdf")
            let text = String(repeating: "x", count: LongText.threshold + 1)
            board.items = [["public.file-url": file.absoluteString, "public.utf8-plain-text": text]]
            let (field, pasted) = makeField(pasting: board)
            field.paste(nil)
            #expect(pasted.texts.isEmpty)
            #expect(pasted.attachments == 1)
            #expect(field.text.isEmpty)
        }
    }

    @Test func aPictureBesideLongWrittenTextIsOfferedAsTheTextFileOnly() async throws {
        try await withBoard { board in
            let png = try #require(UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).pngData { _ in })
            let text = String(repeating: "word ", count: LongText.threshold)
            board.items = [["public.png": png, "public.utf8-plain-text": text]]
            let (field, pasted) = makeField(pasting: board)
            field.paste(nil)
            await eventually("the text is offered") { !pasted.texts.isEmpty }
            #expect(pasted.texts == [text])
            #expect(pasted.attachments == 0)
            #expect(field.text.isEmpty)
        }
    }

    @Test func aLongPasteTheBarTurnsDownIsTyped() async throws {
        try await withBoard { board in
            board.string = String(repeating: "word ", count: LongText.threshold)
            let (field, _) = makeField(pasting: board)
            field.onPasteLongText = { _ in false }
            #expect(!field.redirectsLongText(board.string ?? ""))
        }
    }

    @Test func undoingAndRedoingLongTextPutsItBack() throws {
        let bar = ConversationInputBar(frame: CGRect(x: 0, y: 0, width: 400, height: 100))
        var offered = 0
        bar.onLongText = { _ in offered += 1; return true }
        let field = UITextView()
        let manager = try #require(field.undoManager)
        let long = String(repeating: "x", count: LongText.threshold + 1)
        var results: [Bool] = []
                class Host: NSObject { var run: () -> Void = {}; @objc func fire() { run() } }
        let host = Host()
        host.run = { results.append(bar.textView(field, shouldChangeTextIn: NSRange(location: 0, length: 0), replacementText: long)) }
        manager.beginUndoGrouping()
        manager.registerUndo(withTarget: host, selector: #selector(Host.fire), object: nil)
        manager.endUndoGrouping()
        manager.undo()
        #expect(results == [true])
        #expect(offered == 0)
        #expect(!bar.textView(field, shouldChangeTextIn: NSRange(location: 0, length: 0), replacementText: long))
    }

    @Test func longTextWhileEditingIsLeftToTheField() async throws {
        let f = try ConversationFixture()
        let mine = try f.add("typo here", .outgoing)
        await f.start()
        f.model.setOnScreen(true)
        let long = String(repeating: "x", count: LongText.threshold + 1)
        #expect(f.model.offerLongText(long))
        f.model.startEditing(mine.id!)
        #expect(!f.model.offerLongText(long))
        #expect(f.model.pendingAttachments.count <= 1)
        await eventually("only the first was staged") { f.model.pendingAttachments.count == 1 }
    }

    @Test func aLongTextThatArrivesBySomeOtherWayIsRedirected() throws {
        let bar = ConversationInputBar(frame: CGRect(x: 0, y: 0, width: 400, height: 100))
        var offered: [String] = []
        bar.onLongText = { offered.append($0); return true }
        let field = UITextView()
        let long = String(repeating: "x", count: LongText.threshold + 1)
        #expect(!bar.textView(field, shouldChangeTextIn: NSRange(location: 0, length: 0), replacementText: long))
        #expect(bar.textView(field, shouldChangeTextIn: NSRange(location: 0, length: 0), replacementText: "hi"))
        #expect(offered == [long])
    }

    @Test func offeredLongTextIsStagedAsOneNamedTextFile() async throws {
        let f = try ConversationFixture()
        let text = String(repeating: "word ", count: LongText.threshold)
        f.model.offerLongText(text)
        await eventually("the file is staged") { !f.model.pendingAttachments.isEmpty }
        #expect(f.model.pendingAttachments.count == 1)
        guard case .file(let url, let isPhoto) = f.model.pendingAttachments[0].content else {
            Issue.record("expected a file")
            return
        }
        #expect(!isPhoto)
        #expect(url.lastPathComponent.hasPrefix("Pasted text ") && url.pathExtension == "txt")
        #expect(try String(contentsOf: url, encoding: .utf8) == text)
        f.model.removePendingAttachment(f.model.pendingAttachments[0].id)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}
