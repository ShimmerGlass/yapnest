import Foundation
import Testing
@testable import YapnestKit

/// A session that never connects, for what runs against its database and API.
func makeSession(_ jid: JID, database: AppDatabase? = nil) throws -> XMPPSession {
    try XMPPSession(credentials: .init(jid: jid, password: "x"), resource: "t", database: try database ?? AppDatabase.inMemory())
}

extension LiveServer {
    /// The dev server the suites run against, chosen with `YAPNEST_SERVER`:
    /// `prosody` (the default), `ejabberd`, `snikket`, `openfire` or
    /// `openfire-bare` (Openfire without the push and upload plugins). All
    /// serve `localhost` with the accounts alice, bob and carol.
    /// `YAPNEST_SERVER_PORT` and `YAPNEST_SERVER_HTTP_PORT` override the client
    /// and upload ports, for a server that was started on others.
    struct Target {
        let name: String
        /// The client-to-server port on 127.0.0.1.
        let port: Int
        /// The domain of the group chat service.
        let conference: String
        /// What the URLs of uploaded files start with.
        var uploadPrefix: String { "http://localhost:\(httpPort)/" }
        private let httpPort: Int

        init(name: String) {
            self.name = name
            let (port, httpPort, conference) = switch name {
            case "prosody", "ejabberd": (5222, 5280, "conference.localhost")
            case "snikket": (25222, 25280, "groups.localhost")
            case "openfire", "openfire-bare": (35222, 35280, "conference.localhost")
            default: fatalError("YAPNEST_SERVER must be prosody, ejabberd, snikket, openfire or openfire-bare, not \(name)")
            }
            let env = ProcessInfo.processInfo.environment
            self.port = env["YAPNEST_SERVER_PORT"].flatMap { Int($0) } ?? port
            self.httpPort = env["YAPNEST_SERVER_HTTP_PORT"].flatMap { Int($0) } ?? httpPort
            self.conference = conference
        }
    }

    static let target = Target(name: ProcessInfo.processInfo.environment["YAPNEST_SERVER"] ?? "prosody")

    /// Where the tests keep the databases of their devices between runs. Each
    /// server has its own: a device's database remembers how far it read the
    /// server's archive, and another server's archive has no such place.
    static var stateDirectory: URL {
        FileManager.default.temporaryDirectory.appending(path: "yapnest-integration/\(target.name)-\(target.port)")
    }

    /// A test account on the dev server.
    static func jid(_ user: String) -> JID { JID("\(user)@localhost")! }
}

extension LiveServer {
    /// A session for the local dev server, with TLS off since its certificate is self-signed.
    static func makeSession(
        _ jid: JID, resource: String, database: AppDatabase, attachments: AttachmentStore? = nil, port: Int = LiveServer.target.port,
        callMedia: (any CallMediaFactory)? = nil,
    ) throws -> XMPPSession {
        let credentials = XMPPSession.Credentials(jid: jid, password: "password", host: "127.0.0.1", port: port, disableTLS: true)
        guard let attachments else { return try XMPPSession(credentials: credentials, resource: resource, database: database, callMedia: callMedia) }
        return try XMPPSession(credentials: credentials, resource: resource, database: database, attachments: attachments, callMedia: callMedia)
    }
}

extension LiveServer {
    /// Polls until `condition` holds, and records an issue if it doesn't in time.
    static func waitUntil(_ what: String, timeout: TimeInterval = 30, _ condition: () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while try await !condition() {
            if Date() > deadline { Issue.record("Timed out waiting for \(what)"); return }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Connects the sessions one after the other and waits for each to finish
    /// syncing, and with `encryptionReady` to have published its OMEMO device.
    static func connected(_ sessions: XMPPSession..., encryptionReady: Bool = false, timeout: TimeInterval = 30) async throws {
        for session in sessions {
            session.connect()
            try await waitUntil("\(session.account) to connect and sync", timeout: timeout) {
                session.state.value == .connected(isSyncing: false) && (!encryptionReady || session.isEncryptionReady)
            }
        }
    }

    /// A connected session of `jid` with a database of its own, on a device
    /// named after `resource`, so one account can be on several at once.
    static func connectedSession(_ jid: JID, resource: String) async throws -> XMPPSession {
        let session = try makeSession(jid, resource: "\(resource)-\(UUID().uuidString.prefix(6))", database: try AppDatabase.inMemory())
        try await connected(session)
        return session
    }

    /// Makes `owner` and each of `others` contacts of one another, as
    /// invitations are only accepted from contacts.
    static func befriend(_ owner: XMPPSession, _ others: XMPPSession...) async throws {
        for other in others {
            owner.addContact(other.account)
            other.addContact(owner.account)
            try await waitUntil("\(other.account) and \(owner.account) in each other's roster") {
                try owner.database.isInRoster(other.account) && other.database.isInRoster(owner.account)
            }
        }
    }
}
