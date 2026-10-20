import Foundation
import Testing
@testable import YapnestKit

struct SafeFileNameTests {
    @Test func keepsOrdinaryNames() {
        #expect(SafeFileName.make("Holiday photo (1).jpg") == "Holiday photo (1).jpg")
        #expect(SafeFileName.make("日本語.pdf") == "日本語.pdf")
    }

    @Test func keepsOnlyTheLastComponent() {
        #expect(SafeFileName.make("../../etc/passwd") == "passwd")
        #expect(SafeFileName.make("a/b/c.txt") == "c.txt")
        #expect(SafeFileName.make("C:\\Users\\me\\x.doc") == "x.doc")
        #expect(SafeFileName.make("dir/") == "dir")
    }

    @Test func replacesTroublesomeCharacters() {
        #expect(SafeFileName.make("a:b.txt") == "a-b.txt")
        #expect(SafeFileName.make("a\0b\n.txt") == "a-b-.txt")
    }

    @Test func dropsLeadingDotsAndBlanks() {
        #expect(SafeFileName.make("..hidden") == "hidden")
        #expect(SafeFileName.make("  .. x.txt  ") == "x.txt")
    }

    @Test func fallsBackWhenNothingIsLeft() {
        for name in ["", "..", ".", "a/..", "/", "   ", "..."] {
            #expect(SafeFileName.make(name) == "File", "\(name)")
        }
        #expect(SafeFileName.make("", fallback: "Contact") == "Contact")
    }

    @Test func capsLengthKeepingTheExtension() {
        let long = String(repeating: "a", count: 300) + ".jpeg"
        let result = SafeFileName.make(long)
        #expect(result.count == SafeFileName.maxLength)
        #expect(result.hasSuffix(".jpeg"))
        #expect(SafeFileName.make(String(repeating: "b", count: 300)).count == SafeFileName.maxLength)
    }

    @Test func copiesStayInsideTheirFolder() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "safename-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "source.txt")
        try Data("x".utf8).write(to: source)
        let copy = try FileManager.default.copyIntoUniqueFolder(source, named: "../../escape/a:b.txt", under: root)
        #expect(copy.lastPathComponent == "a-b.txt")
        #expect(copy.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL)
        #expect(FileManager.default.fileExists(atPath: copy.path))
    }
}
