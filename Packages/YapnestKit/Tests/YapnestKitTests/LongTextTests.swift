import Foundation
import Testing
@testable import YapnestKit

struct LongTextTests {
    @Test func theThresholdIsEightThousandCharacters() {
        #expect(LongText.threshold == 8_000)
        #expect(!LongText.isLong(String(repeating: "a", count: 7_999)))
        #expect(!LongText.isLong(String(repeating: "a", count: 8_000)))
        #expect(LongText.isLong(String(repeating: "a", count: 8_001)))
        #expect(!LongText.isLong(""))
    }

    @Test func charactersAreCountedAsTheUserSeesThem() {
        // A family emoji is one character of 25 bytes.
        let family = "👨‍👩‍👧‍👦"
        #expect(!LongText.isLong(String(repeating: family, count: 8_000)))
        #expect(LongText.isLong(String(repeating: family, count: 8_001)))
        // Multi-byte letters over the byte count but not the character count.
        #expect(!LongText.isLong(String(repeating: "é", count: 8_000)))
        #expect(LongText.isLong(String(repeating: "é", count: 8_001)))
    }

    @Test func theFileNameHasTheTimeWithoutColons() throws {
        let utc = try #require(TimeZone(identifier: "UTC"))
        let date = Date(timeIntervalSince1970: 1_709_641_800)
        #expect(LongText.fileName(prefix: "Pasted text", date: date, timeZone: utc) == "Pasted text 2024-03-05 12.30.00.txt")
    }

    @Test func aPrefixWithPathCharactersStaysAFileName() throws {
        let utc = try #require(TimeZone(identifier: "UTC"))
        let name = LongText.fileName(prefix: "Collé/collé: texte", date: Date(timeIntervalSince1970: 0), timeZone: utc)
        #expect(!name.contains("/") && !name.contains(":"))
        #expect(name.hasSuffix("1970-01-01 00.00.00.txt"))
    }

    @Test func writesTheTextAsUTF8IntoAFolderOfItsOwn() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let text = String(repeating: "héllo 👋\n", count: 2_000)
        let a = try LongText.write(text, prefix: "Pasted text", under: root)
        let b = try LongText.write(text, prefix: "Pasted text", under: root)
        #expect(try String(contentsOf: a, encoding: .utf8) == text)
        #expect(a.pathExtension == "txt")
        #expect(a.deletingLastPathComponent() != b.deletingLastPathComponent())
        #expect(a.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL)
    }
}
