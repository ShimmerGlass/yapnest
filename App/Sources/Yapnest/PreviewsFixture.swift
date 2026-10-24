#if DEBUG
import Foundation
import GRDB
import os
import UIKit
import YapnestKit

/// A chat of photos that haven't been downloaded, as senders that announce
/// their files' shapes and previews leave them: `YAPNEST_DEV_FIXTURE=previews`.
/// With `YAPNEST_DEV_HOLD_DOWNLOADS=1` the downloads wait until the
/// recorder's "Release downloads" button is tapped, and then finish as if
/// they had come in, for checking that no row changes size when they do. A
/// test releases them when it is ready, so no clock decides what it sees.
enum PreviewsFixture {
    static let peer = JID("previews@fixture.test")!
    static let endMarker = "End of the previews."

    /// Shapes that matter: the common ones, one that is clamped to the
    /// tallest and one to the widest a bubble goes.
    private static let photos: [(name: String, width: Int, height: Int, hue: Double)] = [
        ("landscape.png", 1200, 800, 0.05),
        ("portrait.png", 600, 900, 0.35),
        ("panorama.png", 1600, 300, 0.60),
        ("tower.png", 300, 1500, 0.80),
        ("square.png", 500, 500, 0.15),
    ]

    private static var files: URL {
        AccountDirectory(account: DevFixture.account).attachments.directory
    }

    static func fill(_ database: AppDatabase) throws {
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        // Not in the roster: photos from a contact would be fetched at once
        // (and fail, offline), and these are meant to wait.
        let conversation = try database.conversation(with: peer)
        try database.setHistoryState(peer: peer, isComplete: true, cursor: nil)

        var time = Date().addingTimeInterval(-3600)
        func add(_ body: String) throws -> Message {
            time.addTimeInterval(60)
            return try database.insert(Message(
                conversationId: conversation.id!, direction: .incoming, sender: peer, body: body, timestamp: time, isRead: true, remoteId: UUID().uuidString,
            ))
        }
        _ = try add("Photos from the trip.")
        for photo in photos {
            let message = try add("https://files.fixture.test/\(photo.name)")
            // A few pixels of colour is all a preview holds.
            let thumbnail = FuzzFixture.png(width: 4, height: 3, hue: photo.hue)
            try database.writer.write { db in
                try Attachment(
                    messageId: message.id!, url: message.body, name: photo.name, mimeType: "image/png", size: 480_000,
                    width: Double(photo.width), height: Double(photo.height), thumbnail: thumbnail, state: .remote,
                ).insert(db)
            }
        }
        _ = try add(endMarker)
    }

    /// Holds the downloads until `releaseDownloads()`, if `YAPNEST_DEV_HOLD_DOWNLOADS`
    /// asks. `finish` is what the release does; another fixture can hold its own.
    static func holdDownloads(into database: AppDatabase, finish: @escaping @Sendable (AppDatabase) -> Void = finishDownloads) {
        guard ProcessInfo.processInfo.environment["YAPNEST_DEV_HOLD_DOWNLOADS"] == "1" else { return }
        held.withLock { $0 = (database, finish) }
    }

    /// Whether downloads are being held, which is when the release button is drawn.
    static var isHolding: Bool { ProcessInfo.processInfo.environment["YAPNEST_DEV_HOLD_DOWNLOADS"] == "1" }

    private static let held = OSAllocatedUnfairLock<(database: AppDatabase, finish: @Sendable (AppDatabase) -> Void)?>(initialState: nil)

    /// Finishes every held download.
    static func releaseDownloads() {
        guard let held = held.withLock({ state in defer { state = nil }; return state }) else { return }
        held.finish(held.database)
    }

    private static func finishDownloads(_ database: AppDatabase) {
        Task.detached {
            try? await database.writer.write { db in
                for var attachment in try Attachment.filter(Column("state") == Attachment.State.remote).fetchAll(db) {
                    guard let photo = photos.first(where: { $0.name == attachment.name }) else { continue }
                    let file = "previews-\(photo.name)"
                    try FuzzFixture.png(width: photo.width, height: photo.height, hue: photo.hue).write(to: files.appending(path: file), options: .atomic)
                    attachment.localFile = file
                    // The downloaded file is measured, as the session does.
                    attachment.width = Double(photo.width)
                    attachment.height = Double(photo.height)
                    attachment.thumbnail = nil
                    attachment.state = .ready
                    try attachment.update(db)
                }
            }
        }
    }
}
#endif
