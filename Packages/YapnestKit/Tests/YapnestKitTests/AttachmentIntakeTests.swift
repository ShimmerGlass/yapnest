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
