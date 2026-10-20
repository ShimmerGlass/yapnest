import Foundation

/// Text too long to type into a message: pasted, dropped or shared past
/// `threshold`, it goes out as a text file instead. A wall of text fills the
/// composer and the chat, and slows down both.
public enum LongText {
    /// In characters as the user sees them, so an emoji counts once.
    public static let threshold = 8_000

    public static func isLong(_ text: String) -> Bool {
        // A string with this few bytes can't have that many characters, and
        // the walk stops at the threshold instead of counting a huge paste.
        guard text.utf8.count > threshold,
              let limit = text.index(text.startIndex, offsetBy: threshold, limitedBy: text.endIndex)
        else { return false }
        return limit < text.endIndex
    }

    /// "Pasted text 2024-03-05 12.30.00.txt": the time has dots because a colon
    /// isn't allowed in a file name on every system that will receive it.
    public static func fileName(prefix: String = String(localized: "Pasted text"), date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return SafeFileName.make("\(prefix) \(formatter.string(from: date)).txt")
    }

    /// Writes the text as UTF-8 into a new folder under `folder`, as the
    /// other staged copies are, so removing the file's folder cleans up.
    public static func write(_ text: String, prefix: String = String(localized: "Pasted text"), date: Date = Date(), under folder: URL) throws -> URL {
        let directory = folder.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: fileName(prefix: prefix, date: date), directoryHint: .notDirectory)
        try Data(text.utf8).write(to: file)
        return file
    }
}
