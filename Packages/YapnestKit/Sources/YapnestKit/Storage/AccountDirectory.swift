import Foundation

/// Where one account's files are. The app, the notification extension and the
/// share extension all open the same ones, so the names live here.
public struct AccountDirectory: Sendable {
    public var url: URL

    public init(url: URL) {
        self.url = url
    }

    public init(account: JID) {
        self.init(url: SharedContainer.directory(for: account))
    }

    public var databaseURL: URL { url.appending(path: "db.sqlite") }

    public func openDatabase() throws -> AppDatabase {
        let database = try AppDatabase.open(at: databaseURL)
        BackupPolicy.apply(also: [url])
        return database
    }

    public var avatars: AvatarStore { AvatarStore(directory: url.appending(path: "avatars")) }
    public var attachments: AttachmentStore { AttachmentStore(directory: url.appending(path: "attachments")) }
    public var previews: URL { url.appending(path: "previews") }
}

extension XMPPSession {
    /// A session over `directory`'s avatars and files, signed to its own
    /// device's fast token, with the device's OMEMO identity from the keychain
    /// unless given another (`identityKeys(for:in:)`). Callers open the
    /// database themselves when they need it as well.
    public convenience init(
        credentials: Credentials, resource: String, directory: AccountDirectory, database: AppDatabase,
        mode: Mode = .app, pushRelay: JID = XMPPSession.defaultPushRelay,
        callMedia: (any CallMediaFactory)? = nil, identityKeys: (any IdentityKeyStore)? = nil,
    ) throws {
        try self.init(
            credentials: credentials, resource: resource, database: database,
            avatars: directory.avatars, attachments: directory.attachments,
            mode: mode, pushRelay: pushRelay,
            fastTokens: KeychainFastTokenStore(client: Self.userAgentId(account: credentials.jid, resource: resource)),
            callMedia: callMedia,
            identityKeys: identityKeys,
        )
    }
}
