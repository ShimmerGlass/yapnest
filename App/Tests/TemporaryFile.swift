import Foundation

/// A file in a folder of its own in the temporary directory, as the pickers
/// make their copies.
func makeTemporaryFile(_ name: String) throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let file = folder.appending(path: name)
    try Data("contents of \(name)".utf8).write(to: file)
    return file
}
