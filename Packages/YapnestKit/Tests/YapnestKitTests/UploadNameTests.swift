import Foundation
import Testing
@testable import YapnestKit

/// An encrypted file's upload slot is asked for under `freshName(keeping:)`,
/// so the upload server learns nothing from its name.
struct UploadNameTests {
    @Test func aFreshNameKeepsOnlyTheExtension() {
        let name = AttachmentStore.freshName(keeping: "Holiday photo.JPG")
        #expect(!name.contains("Holiday"))
        #expect(name.hasSuffix(".JPG"))
        let stem = String(name.dropLast(4))
        #expect(UUID(uuidString: stem) != nil)
        #expect(stem == stem.lowercased())
    }

    @Test func aFreshNameWithoutExtensionIsJustTheUUID() {
        let name = AttachmentStore.freshName(keeping: "README")
        #expect(UUID(uuidString: name) != nil)
        #expect(name == name.lowercased())
    }

    @Test func eachFreshNameIsDifferent() {
        #expect(AttachmentStore.freshName(keeping: "a.pdf") != AttachmentStore.freshName(keeping: "a.pdf"))
    }

    @Test func aFreshVoiceClipNameIsStillAVoiceClip() {
        #expect(AudioFormat.isVoiceClip(mimeType: nil, name: AttachmentStore.freshName(keeping: "Voice message.m4a")))
    }
}
