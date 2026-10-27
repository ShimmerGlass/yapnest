import Foundation
import Testing
@testable import YapnestKit

/// A session that never connects, for what runs against its database and API.
func makeSession(_ jid: JID, database: AppDatabase? = nil) throws -> XMPPSession {
    let database = try database ?? AppDatabase.inMemory()
    return try XMPPSession(credentials: .init(jid: jid, password: "x"), resource: "t", database: database, identityKeys: testIdentityKeys(for: database))
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
    /// A session for the local dev server, with TLS off so the plaintext suites keep working;
    /// the TLS suites use `makeTLSSession`, which trusts the local CA.
    static func makeSession(
        _ jid: JID, resource: String, database: AppDatabase, attachments: AttachmentStore? = nil, port: Int = LiveServer.target.port,
        callMedia: (any CallMediaFactory)? = nil, policy: XMPPSession.Policy? = nil,
    ) throws -> XMPPSession {
        let credentials = XMPPSession.Credentials(jid: jid, password: "password", host: "127.0.0.1", port: port, disableTLS: true)
        return try XMPPSession(
            credentials: credentials, resource: resource, database: database, attachments: attachments ?? .temporary(),
            policy: policy, callMedia: callMedia, identityKeys: testIdentityKeys(for: database),
        )
    }
}

/// Where a test device keeps its OMEMO identity, as the keychain keeps an
/// install's: beside a database file, so a device kept across runs stays the
/// same device rather than look like a restored backup; with the database
/// when it's in memory.
func testIdentityKeys(for database: AppDatabase) -> any IdentityKeyStore {
    let path = database.writer.path
    guard path.hasPrefix("/") else { return database.localIdentityKeys }
    return FileIdentityKeyStore(beside: URL(filePath: path))
}

/// The same for an account's folder, for an extension's session over it.
func testIdentityKeys(forAccountAt directory: URL) -> any IdentityKeyStore {
    FileIdentityKeyStore(beside: AccountDirectory(url: directory).databaseURL)
}

/// An identity in a file, standing in for the keychain, which a test process
/// can't use.
struct FileIdentityKeyStore: IdentityKeyStore {
    let url: URL

    init(beside database: URL) {
        url = URL(filePath: database.path + ".identity")
    }

    func load() throws -> StoredIdentity? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try JSONDecoder().decode(StoredIdentity.self, from: data)
    }

    func save(_ identity: StoredIdentity) throws {
        try JSONEncoder().encode(identity).write(to: url, options: .atomic)
    }
}

extension LiveServer {
    /// Turns sharing last seen on or off once the session's settings sync
    /// has read the account's node, and waits for the change to be published.
    /// The setting is the account's: written earlier, it loses to what the
    /// sync reads, and left unpublished, a later session reads it late.
    static func setSharesLastSeen(_ on: Bool, on session: XMPPSession) async throws {
        try await waitUntil("\(session.account)'s settings to sync") { session.lock.withLock { $0.settingsSync.syncCompleted } }
        try session.setSharesLastSeen(on)
        try await waitUntil("\(session.account)'s settings to be published") {
            session.lock.withLock { !$0.settingsSync.publishing && $0.settingsSync.scheduled == nil }
        }
    }

    /// Polls until `condition` holds, and records an issue if it doesn't in time.
    static func waitUntil(_ what: String, timeout: TimeInterval = 30, _ condition: () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while try await !condition() {
            if Date() > deadline { Issue.record("Timed out waiting for \(what)"); return }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Runs `body`, then deletes the account's synced settings whether it
    /// passed or not. Every new device of the account takes on what the node
    /// holds, so a setting one test changed would otherwise reach every test
    /// after it, such as Always Relay Calls holding back every call.
    static func forgettingSyncedSettings(of session: XMPPSession, _ body: () async throws -> Void) async throws {
        do {
            try await body()
        } catch {
            await forgetSyncedSettings(of: session)
            throw error
        }
        await forgetSyncedSettings(of: session)
    }

    private static func forgetSyncedSettings(of session: XMPPSession) async {
        await deleteNode(NS.settings, of: session)
    }

    /// Deletes one of the account's PEP nodes, whether or not it exists.
    static func deleteNode(_ node: String, of session: XMPPSession) async {
        await withCheckedContinuation { continuation in
            session.client.module(.pubsub).deleteNode(from: session.account.martin, node: node) { _ in continuation.resume() }
        }
    }

    /// Accepts the invitation to `room` once it arrives. Invitations wait for
    /// the user's answer, as joining shows the group our address.
    static func accept(invitationTo room: JID, on session: XMPPSession) async throws {
        try await waitUntil("\(session.account)'s invitation to \(room)") { try session.database.groupInvitation(room) != nil }
        try await session.acceptGroupInvitation(room)
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
