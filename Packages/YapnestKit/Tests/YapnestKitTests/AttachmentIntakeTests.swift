import Testing
import UniformTypeIdentifiers
@testable import YapnestKit

struct AttachmentIntakeTests {
    @Test func classifiesItems() {
        #expect(AttachmentIntake.kind(of: [UTType.png.identifier]) == .image)
        #expect(AttachmentIntake.kind(of: [UTType.html.identifier, UTType.plainText.identifier, UTType.jpeg.identifier]) == .image)
        #expect(AttachmentIntake.kind(of: [UTType.utf8PlainText.identifier]) == .text)
        #expect(AttachmentIntake.kind(of: [UTType.url.identifier, UTType.plainText.identifier]) == .text)
        #expect(AttachmentIntake.kind(of: [UTType.fileURL.identifier, UTType.plainText.identifier]) == .file)
        #expect(AttachmentIntake.kind(of: [UTType.pdf.identifier]) == .file)
        #expect(AttachmentIntake.kind(of: [UTType.vCard.identifier]) == .file)
        #expect(AttachmentIntake.kind(of: [UTType.vCard.identifier, UTType.plainText.identifier]) == .file)
        #expect(AttachmentIntake.kind(of: [UTType.quickTimeMovie.identifier]) == .file)
        #expect(AttachmentIntake.kind(of: ["not.a.type"]) == .other)
    }

    private func openInPlaceTextFile() -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerFileRepresentation(
            forTypeIdentifier: UTType.plainText.identifier, fileOptions: [.openInPlace], visibility: .all
        ) { completion in
            completion(URL(fileURLWithPath: "/tmp/notes.txt"), true, nil)
            return nil
        }
        return provider
    }

    @Test func providersTellDraggedFilesFromDraggedText() {
        #expect(AttachmentIntake.kind(of: openInPlaceTextFile()) == .file)
        #expect(AttachmentIntake.kind(of: NSItemProvider(contentsOf: URL(fileURLWithPath: "/tmp/notes.txt"))!) == .file)

        // A name doesn't make words a file, as a dragged link has one too.
        let words = NSItemProvider(object: "some words" as NSString)
        words.suggestedName = "A page"
        #expect(AttachmentIntake.kind(of: words) == .text)

        let selection = NSItemProvider()
        selection.registerDataRepresentation(forTypeIdentifier: UTType.plainText.identifier, visibility: .all) { completion in
            completion(Data("words".utf8), nil)
            return nil
        }
        #expect(AttachmentIntake.kind(of: selection) == .text)
    }

    @Test func attachmentsLeaveTextAlone() {
        let file = openInPlaceTextFile()
        let words = NSItemProvider(object: "words" as NSString)
        let found = AttachmentIntake.attachments(in: [words, file])
        #expect(found.count == 1)
        #expect(found.first?.provider === file)
        #expect(found.first?.kind == .file)
        #expect(AttachmentIntake.containsAttachment([words, file]))
        #expect(!AttachmentIntake.containsAttachment([words]))
    }

    @Test func offersText() {
        #expect(AttachmentIntake.offersText([UTType.png.identifier, UTType.html.identifier]))
        #expect(!AttachmentIntake.offersText([UTType.png.identifier]))
        #expect(!AttachmentIntake.offersText([UTType.fileURL.identifier]))
    }

    @Test func recognizesLabels() {
        #expect(AttachmentIntake.isLabel(""))
        #expect(AttachmentIntake.isLabel("  https://example.com/a/b.png \n"))
        #expect(AttachmentIntake.isLabel("IMG 1234.png"))
        #expect(!AttachmentIntake.isLabel("Look at this photo from the trip"))
        #expect(!AttachmentIntake.isLabel("First line\nsecond line.png"))
        #expect(!AttachmentIntake.isLabel("See you at 5."))
    }
}
