import CoreGraphics
import Foundation
import GRDB
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import YapnestKit

extension LiveServer {
    /// The share extension's sending, against the local Prosody. Enable with
    /// `YAPNEST_INTEGRATION=1 swift test --filter ShareIntegration`.
    @Suite
    struct ShareIntegrationTests {
        let alice = LiveServer.jid("alice")
        let bob = LiveServer.jid("bob")

        @Test func sharedItemsReachTheContactInOrder() async throws {
            let root = FileManager.default.temporaryDirectory.appending(path: "yapnest-share-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let credentials = XMPPSession.Credentials(jid: alice, password: "password", host: "127.0.0.1", port: LiveServer.target.port, disableTLS: true)
            let directory = root.appending(path: "alice")

            // Bob is signed in and has published his keys.
            let bobSession = try XMPPSession(
                credentials: .init(jid: bob, password: "password", host: "127.0.0.1", port: LiveServer.target.port, disableTLS: true),
                resource: "bob-share", database: try OMEMOIntegrationTests.device("bob-share"),
                attachments: AttachmentStore(directory: root.appending(path: "bob-attachments")),
            )
            bobSession.connect()
            defer { bobSession.disconnect() }
            while bobSession.state.value != .connected(isSyncing: false) || !bobSession.isEncryptionReady {
                try await Task.sleep(for: .milliseconds(50))
            }
            try await LiveServer.requireUpload(of: bobSession)

            // Alice's app has run on this device before, so her keys exist.
            let app = try XMPPSession(
                credentials: credentials, resource: "alice-app", database: try AccountDirectory(url: directory).openDatabase(),
                attachments: AccountDirectory(url: directory).attachments,
            )
            app.connect()
            while app.state.value != .connected(isSyncing: false) || !app.isEncryptionReady {
                try await Task.sleep(for: .milliseconds(50))
            }
            app.disconnect()

            let photo = root.appending(path: "photo.png")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let context = CGContext(data: nil, width: 600, height: 400, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            let output = CGImageDestinationCreateWithURL(photo as CFURL, UTType.png.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(output, context.makeImage()!, nil)
            CGImageDestinationFinalize(output)

            let sender = ShareSender(credentials: credentials, directory: directory, resource: "alice-share", lock: ProcessLock(url: root.appending(path: "lock")))
            for encrypted in [false, true] {
                try app.database.setEncrypted(encrypted, with: bob)
                let note = "shared \(encrypted) \(UUID().uuidString.prefix(6))"
                let outcome = await sender.send(ShareContent(files: [.init(url: photo, isPhoto: true)], comment: note), to: bob, timeout: 30)
                #expect(outcome == .sent)

                let sent = try await app.database.reader.read { db in
                    try Message.filter(Column("body") == note).fetchAll(db)
                }
                #expect(sent.count == 1 && sent[0].status >= .sent && sent[0].encryption == (encrypted ? .omemo : .none))
                let files = try await app.database.reader.read { db in try Attachment.filter(Column("state") == Attachment.State.ready).fetchAll(db) }
                #expect(files.count >= 1)
            }
        }

        @Test func sharedTextReachesAGroup() async throws {
            let root = FileManager.default.temporaryDirectory.appending(path: "yapnest-share-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let credentials = XMPPSession.Credentials(jid: alice, password: "password", host: "127.0.0.1", port: LiveServer.target.port, disableTLS: true)
            let directory = root.appending(path: "alice")
            let bobSession = try XMPPSession(
                credentials: .init(jid: bob, password: "password", host: "127.0.0.1", port: LiveServer.target.port, disableTLS: true),
                resource: "bob-share", database: try OMEMOIntegrationTests.device("bob-share"),
                attachments: AttachmentStore(directory: root.appending(path: "bob-attachments")),
            )
            let app = try XMPPSession(
                credentials: credentials, resource: "alice-app", database: try AccountDirectory(url: directory).openDatabase(),
                attachments: AccountDirectory(url: directory).attachments,
            )
            for session in [bobSession, app] {
                session.connect()
                while session.state.value != .connected(isSyncing: false) || !session.isEncryptionReady {
                    try await Task.sleep(for: .milliseconds(50))
                }
            }
            defer { bobSession.disconnect() }
            app.addContact(bob)
            bobSession.addContact(alice)
            while try !(app.database.isInRoster(bob) && bobSession.database.isInRoster(alice)) { try await Task.sleep(for: .milliseconds(100)) }

            let room = try await app.createGroup(name: "Share \(UUID().uuidString.prefix(4))", inviting: [bob])
            while bobSession.roomStatus(room)?.isJoined != true || bobSession.roomStatus(room)?.isSyncing != false {
                try await Task.sleep(for: .milliseconds(100))
            }
            app.disconnect()

            let sender = ShareSender(credentials: credentials, directory: directory, resource: "alice-share", lock: ProcessLock(url: root.appending(path: "lock")))
            let text = "to the group \(UUID().uuidString.prefix(6))"
            #expect(await sender.send(ShareContent(texts: [text]), to: room, timeout: 30) == .sent)

            let deadline = Date().addingTimeInterval(15)
            var received: Message?
            while received == nil, Date() < deadline {
                received = try await bobSession.database.reader.read { try Message.filter(Column("body") == text).fetchOne($0) }
                try await Task.sleep(for: .milliseconds(100))
            }
            #expect(received != nil)
        }

        /// What the extension leaves while the app is connected, because it
        /// can't get the session, goes out when the app is told.
        @Test func theRunningAppSendsWhatTheExtensionLeft() async throws {
            let root = FileManager.default.temporaryDirectory.appending(path: "yapnest-share-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let directory = root.appending(path: "alice")
            let bobSession = try XMPPSession(
                credentials: .init(jid: bob, password: "password", host: "127.0.0.1", port: LiveServer.target.port, disableTLS: true),
                resource: "bob-share", database: try OMEMOIntegrationTests.device("bob-share"),
                attachments: AttachmentStore(directory: root.appending(path: "bob-attachments")),
            )
            let app = try XMPPSession(
                credentials: .init(jid: alice, password: "password", host: "127.0.0.1", port: LiveServer.target.port, disableTLS: true),
                resource: "alice-app", database: try AccountDirectory(url: directory).openDatabase(),
                attachments: AccountDirectory(url: directory).attachments,
            )
            for session in [bobSession, app] {
                session.connect()
                while session.state.value != .connected(isSyncing: false) || !session.isEncryptionReady {
                    try await Task.sleep(for: .milliseconds(50))
                }
            }
            defer { app.disconnect(); bobSession.disconnect() }
            try app.database.setEncrypted(false, with: bob)

            let text = "left by the extension \(UUID().uuidString.prefix(6))"
            let staged = try app.outgoingMessages.stage([.text(text)], to: bob)
            try await Task.sleep(for: .milliseconds(500))
            #expect(try app.database.deliveryStates(ids: [staged[0].id!])[staged[0].id!]?.status == .pending)

            app.resendPending()
            let deadline = Date().addingTimeInterval(15)
            var received: Message?
            while received == nil, Date() < deadline {
                received = try await bobSession.database.reader.read { try Message.filter(Column("body") == text).fetchOne($0) }
                try await Task.sleep(for: .milliseconds(100))
            }
            #expect(received != nil)
        }
    }
}
