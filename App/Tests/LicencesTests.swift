import Foundation
import Testing

@testable import Yapnest

/// Every library the app builds on has to be credited with its licence. The
/// source tree is found from this file's path, which works because the tests
/// run on the Mac that built them.
@Suite struct LicencesTests {
    private static let root = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private struct Resolved: Decodable {
        struct Pin: Decodable { let identity: String }
        let pins: [Pin]
    }

    /// The packages the app resolves, and the vendored libraries (which are
    /// local packages, so no Package.resolved lists them).
    private static func expectedIDs() throws -> Set<String> {
        let fileManager = FileManager.default
        var resolvedFiles: [URL] = []
        for folder in ["Packages", "Vendor"] {
            let directory = root.appending(path: folder)
            for entry in try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                let file = entry.appending(path: "Package.resolved")
                if fileManager.fileExists(atPath: file.path) { resolvedFiles.append(file) }
            }
        }
        var ids = Set<String>()
        for file in resolvedFiles {
            ids.formUnion(try JSONDecoder().decode(Resolved.self, from: Data(contentsOf: file)).pins.map(\.identity))
        }
        let vendor = root.appending(path: "Vendor")
        for entry in try fileManager.contentsOfDirectory(at: vendor, includingPropertiesForKeys: [.isDirectoryKey]) {
            if (try entry.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true {
                ids.insert(entry.lastPathComponent.lowercased())
            }
        }
        return ids
    }

    @Test func sourceTreeIsFound() throws {
        let ids = try Self.expectedIDs()
        // A wrong root would make the checks below vacuous.
        #expect(ids.isSuperset(of: ["martin", "martinomemo", "grdb.swift"]))
    }

    @Test func manifestListsEveryPackageAndVendoredLibrary() throws {
        let manifest = try #require(OpenSourceLicences.load(), "No Licences folder in the app: run dev/licences.py")
        let listed = Set(manifest.libraries.map(\.id))
        let missing = try Self.expectedIDs().subtracting(listed)
        #expect(missing.isEmpty, "Not in App/Licences/manifest.json: \(missing.sorted()). Run dev/licences.py.")
    }

    @Test func everyLicenceTextIsBundled() throws {
        let manifest = try #require(OpenSourceLicences.load())
        #expect(!manifest.libraries.isEmpty)
        let files = manifest.libraries.map(\.file) + [manifest.yapnest.file]
        for file in files {
            let text = OpenSourceLicences.text(of: file)
            #expect(text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false, "\(file) is missing or empty")
        }
    }

    @Test func vendoredLibrariesAreMarkedModified() throws {
        let manifest = try #require(OpenSourceLicences.load())
        for library in manifest.libraries where ["martin", "martinomemo"].contains(library.id) {
            #expect(library.modified)
        }
    }
}
