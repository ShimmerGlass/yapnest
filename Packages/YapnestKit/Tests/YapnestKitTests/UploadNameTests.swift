import Foundation
import Testing
@testable import YapnestKit

struct UploadNameTests {
    @Test func encryptedKeepsOnlyTheExtension() {
        let name = UploadName.slotName(for: "Holiday photo.JPG", encrypted: true)
        #expect(!name.contains("Holiday"))
        #expect(name.hasSuffix(".JPG"))
        let stem = String(name.dropLast(4))
        #expect(UUID(uuidString: stem) != nil)
        #expect(stem == stem.lowercased())
    }

    @Test func encryptedWithoutExtensionIsJustTheUUID() {
        let name = UploadName.slotName(for: "README", encrypted: true)
        #expect(UUID(uuidString: name) != nil)
        #expect(name == name.lowercased())
    }

    @Test func eachEncryptedUploadGetsADifferentName() {
        #expect(UploadName.slotName(for: "a.pdf", encrypted: true) != UploadName.slotName(for: "a.pdf", encrypted: true))
    }

    @Test func plainUploadKeepsTheName() {
        #expect(UploadName.slotName(for: "Holiday photo.jpg", encrypted: false) == "Holiday photo.jpg")
    }

    @Test func randomVoiceClipNameIsStillAVoiceClip() {
        let name = UploadName.slotName(for: "Voice message.m4a", encrypted: true)
        #expect(AudioFormat.isVoiceClip(mimeType: nil, name: name))
    }
}
