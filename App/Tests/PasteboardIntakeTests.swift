import Foundation
import Testing
import UIKit
import YapnestKit

/// What the pasteboard hands the composer for a copied file and for copied
/// words, which decides whether pasting attaches or types.
@MainActor
struct PasteboardIntakeTests {
    private func withBoard(_ body: (UIPasteboard) throws -> Void) throws {
        let name = UIPasteboard.Name(UUID().uuidString)
        let board = try #require(UIPasteboard(name: name, create: true))
        defer { UIPasteboard.remove(withName: name) }
        try body(board)
    }

    @Test func aCopiedTextFileIsAttached() throws {
        try withBoard { board in
            board.itemProviders = [try #require(NSItemProvider(contentsOf: try makeTemporaryFile("notes.txt")))]
            let providers = board.itemProviders
            #expect(providers.count == 1)
            let found = AttachmentIntake.attachments(in: providers)
            #expect(found.map(\.kind) == [.file], "types: \(providers.map(\.registeredTypeIdentifiers))")
        }
    }

    @Test func copiedWordsAreTyped() throws {
        try withBoard { board in
            board.string = "some words"
            #expect(!AttachmentIntake.containsAttachment(board.itemProviders))
        }
    }
}
