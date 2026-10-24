#if DEBUG
import Foundation
import GRDB
import YapnestKit

/// A chat, Late, whose newest messages change height after the chat opens:
/// `YAPNEST_DEV_FIXTURE=late-content`. Photos from an encrypted chat say
/// nothing of their shape until they are downloaded, and a link's preview
/// card appears when its page has been read. With `YAPNEST_DEV_HOLD_DOWNLOADS=1`
/// both wait until the frame recorder's "Release downloads" button is tapped,
/// so a test can scroll up first and then see whether the rows it reads move
/// when those below them grow.
enum LateContentFixture {
    static let peer = JID("late@fixture.test")!
    static let endMarker = "End of the late content."

    /// Tall pictures, so each grows well past the 4:3 a bubble guesses.
    private static let photos: [(name: String, width: Int, height: Int, hue: Double)] = [
        ("late-tower.png", 600, 1000, 0.55),
        ("late-portrait.png", 700, 1000, 0.10),
        ("late-poster.png", 500, 900, 0.75),
    ]

    private static let links = ["https://news.fixture.test/a", "https://news.fixture.test/b", "https://news.fixture.test/c"]

    private static var directory: AccountDirectory { AccountDirectory(account: DevFixture.account) }

    static func fill(_ database: AppDatabase) throws {
        try FileManager.default.createDirectory(at: directory.attachments.directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: directory.previews, withIntermediateDirectories: true)
        // Not in the roster, so the photos aren't fetched at once (and failed, offline).
        let conversation = try database.conversation(with: peer)
        try database.setHistoryState(peer: peer, isComplete: true, cursor: nil)
        // Previews are asked for, and offline the fetch fails without storing anything.
        try database.setLinkPreviews(true, peer: peer)

        var time = Date().addingTimeInterval(-6 * 3600)
        func add(_ body: String, outgoing: Bool = false) throws -> Message {
            time.addTimeInterval(60)
            return try database.insert(Message(
                conversationId: conversation.id!, direction: outgoing ? .outgoing : .incoming, sender: outgoing ? DevFixture.account : peer,
                body: body, timestamp: time, status: outgoing ? .displayed : nil, isRead: true, encryption: .omemo, remoteId: UUID().uuidString,
            ))
        }
        for index in 0..<60 {
            let label = String(format: "Late %04d", index)
            let body = index % 4 == 2
                ? "\(label): a longer one, about the morning train and the river, the coffee, and the birds that sing over the nests at dawn."
                : "\(label): a short line."
            _ = try add(body, outgoing: index % 3 == 1)
        }
        // The newest messages: photos and links in turn, then a last line.
        for (photo, link) in zip(photos, links) {
            var message = try add("https://files.fixture.test/\(photo.name)")
            message.link = nil
            try database.writer.write { [message] db in
                try message.update(db)
                try Attachment(messageId: message.id!, url: message.body, name: photo.name, mimeType: "image/png", size: 210_000, state: .remote).insert(db)
            }
            _ = try add("Have a look: \(link)")
        }
        _ = try add(endMarker)
    }

    /// Finishes the downloads and the previews' fetches, as if both had just come in.
    static func release(_ database: AppDatabase) {
        let directory = directory
        Task.detached {
            try? await database.writer.write { db in
                for var attachment in try Attachment.filter(Column("state") == Attachment.State.remote).fetchAll(db) {
                    guard let photo = photos.first(where: { $0.name == attachment.name }) else { continue }
                    try FuzzFixture.png(width: photo.width, height: photo.height, hue: photo.hue).write(to: directory.attachments.directory.appending(path: photo.name), options: .atomic)
                    attachment.localFile = photo.name
                    // Measured from the file, as the session does when nothing was announced.
                    attachment.width = Double(photo.width)
                    attachment.height = Double(photo.height)
                    attachment.state = .ready
                    try attachment.update(db)
                }
                for (index, link) in links.enumerated() {
                    let file = "late-card-\(index).png"
                    try FuzzFixture.png(width: 1200, height: 630, hue: Double(index) * 0.3).write(to: directory.previews.appending(path: file), options: .atomic)
                    try LinkPreview(
                        url: link, kind: .page, title: "A page worth reading, number \(index + 1)",
                        summary: "What the page says about itself, in a line or two, under its title.", siteName: "News",
                        imageFile: file, imageWidth: 1200, imageHeight: 630,
                    ).save(db)
                }
            }
        }
    }
}
#endif
