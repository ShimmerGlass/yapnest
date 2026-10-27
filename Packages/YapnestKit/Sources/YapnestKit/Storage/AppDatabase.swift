import Foundation
import GRDB
import os

/// The account's database. One database per account.
public final class AppDatabase: Sendable {
    public let writer: any DatabaseWriter
    /// The OMEMO identity of a session over this database when it's in
    /// memory: see `XMPPSession.identityKeys(for:in:)`.
    let localIdentityKeys = MemoryIdentityKeyStore()

    public init(_ writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    public var reader: any DatabaseReader { writer }

    private let insecureLinks = OSAllocatedUnfairLock(initialState: false)

    /// Whether plain `http://` file links count as files: only for the
    /// development servers, which the session says it is talking to.
    var allowsInsecureLinks: Bool {
        get { insecureLinks.withLock { $0 } }
        set { insecureLinks.withLock { $0 = newValue } }
    }

    private static let logger = Logger(subsystem: "Yapnest", category: "Database")

    /// Runs `body` for each value of `observation` until the task is
    /// cancelled. Only the newest value is kept, so a burst of changes redraws
    /// once. A failure is logged under `label`, since nobody awaits the task.
    public func forEachValue<Reducer: ValueReducer>(
        of observation: ValueObservation<Reducer>,
        _ label: String,
        isolation: isolated (any Actor)? = #isolation,
        _ body: (Reducer.Value) async -> Void,
    ) async where Reducer.Value: Sendable {
        do {
            for try await value in observation.values(in: reader, bufferingPolicy: .bufferingNewest(1)) {
                await body(value)
            }
        } catch {
            Self.logger.error("\(label, privacy: .public) observation failed: \(error)")
        }
    }

    /// Opens (or creates) the database file at `url`.
    public static func open(at url: URL) throws -> AppDatabase {
        try FileManager.default.createProtectedDirectory(at: url.deletingLastPathComponent())
        var config = Configuration()
        config.foreignKeysEnabled = true
        // Another connection to the file (a session being torn down, later
        // the notification extension) may hold the lock for a moment.
        config.busyMode = .timeout(5)
        // iOS kills a suspended app that holds a lock on a file in the shared
        // container; `suspend()` makes the database let go first.
        config.observesSuspensionNotifications = true
        #if DEBUG
        config.prepareDatabase { db in
            // GRDB runs a statement on the thread that asked for it, so this
            // catches a read or write made from the main thread.
            db.trace { _ in AppDatabase.checkNotOnMainThread() }
        }
        #endif
        let pool = try DatabasePool(path: url.path, configuration: config)
        // Files made before their folder had it keep what they had.
        for suffix in ["", "-wal", "-shm"] { FileProtection.apply(to: URL(filePath: url.path + suffix)) }
        return try AppDatabase(pool)
    }

    private struct MainThreadCheck {
        var isOn = false
        var handler: (@Sendable () -> Void)?
    }

    private static let mainThreadCheck = OSAllocatedUnfairLock(initialState: MainThreadCheck())

    /// Debug aid: when on, a statement run on the main thread is a bug, since
    /// the database must not hold up the UI. Off by default, as many tests
    /// use the database from the main actor; the app and its extensions turn
    /// it on in debug builds.
    public static var trapsMainThreadAccess: Bool {
        get { mainThreadCheck.withLock { $0.isOn } }
        set { mainThreadCheck.withLock { $0.isOn = newValue } }
    }

    /// What happens on such a statement; traps when unset. Tests replace it.
    static var mainThreadAccessHandler: (@Sendable () -> Void)? {
        get { mainThreadCheck.withLock { $0.handler } }
        set { mainThreadCheck.withLock { $0.handler = newValue } }
    }

    private static func checkNotOnMainThread() {
        let (isOn, handler) = mainThreadCheck.withLock { ($0.isOn, $0.handler) }
        guard isOn, Thread.isMainThread else { return }
        if let handler { handler() } else { preconditionFailure("Database access on the main thread") }
    }

    /// Releases every database's file locks, before the app is suspended:
    /// accesses fail until `resume()`.
    public static func suspend() {
        NotificationCenter.default.post(name: Database.suspendNotification, object: nil)
    }

    public static func resume() {
        NotificationCenter.default.post(name: Database.resumeNotification, object: nil)
    }

    /// An in-memory database, for tests and previews.
    public static func inMemory() throws -> AppDatabase {
        try AppDatabase(DatabaseQueue())
    }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        #if DEBUG
        migrator.eraseDatabaseOnSchemaChange = true
        #endif

        migrator.registerMigration("v1") { db in
            try db.create(table: "contact") { t in
                t.primaryKey("jid", .text)
                t.column("name", .text)
                t.column("subscription", .text).notNull().defaults(to: "none")
                t.column("isSubscriptionPending", .boolean).notNull().defaults(to: false)
                t.column("isInRoster", .boolean).notNull().defaults(to: false)
                t.column("isBlocked", .boolean).notNull().defaults(to: false)
            }

            try db.create(table: "conversation") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("peer", .text).notNull().unique()
                t.column("kind", .text).notNull()
                t.column("lastActivityAt", .datetime).notNull().indexed()
                t.column("isPinned", .boolean).notNull().defaults(to: false)
                t.column("isArchived", .boolean).notNull().defaults(to: false)
                t.column("draft", .text)
                t.column("isEncrypted", .boolean).notNull().defaults(to: true)
            }

            try db.create(table: "message") { t in
                t.autoIncrementedPrimaryKey("id")
                t.belongsTo("conversation", onDelete: .cascade).notNull()
                t.column("direction", .text).notNull()
                t.column("sender", .text).notNull()
                t.column("body", .text).notNull()
                t.column("timestamp", .datetime).notNull()
                t.column("status", .text).notNull()
                t.column("isRead", .boolean).notNull()
                t.column("encryption", .text).notNull()
                t.column("remoteId", .text)
                t.column("originId", .text)
                t.column("serverId", .text)
                t.column("replyToId", .text)
                t.column("replyToSender", .text)
                t.column("replyFallback", .text)
            }
            try db.create(index: "message_on_conversation_timestamp", on: "message", columns: ["conversationId", "timestamp"])
            try db.create(index: "message_on_conversation_remoteId", on: "message", columns: ["conversationId", "remoteId"])
            try db.create(index: "message_on_conversation_originId", on: "message", columns: ["conversationId", "originId"])
            try db.create(index: "message_on_serverId", on: "message", columns: ["serverId"])
            try db.create(index: "message_unread", on: "message", columns: ["conversationId", "isRead"])

            try db.create(table: "reaction") { t in
                t.belongsTo("message", onDelete: .cascade).notNull()
                t.column("sender", .text).notNull()
                t.column("emoji", .text).notNull()
                t.primaryKey(["messageId", "sender", "emoji"])
            }

            try db.create(table: "setting") { t in
                t.primaryKey("key", .text)
                t.column("value", .text).notNull()
            }
        }

        migrator.registerMigration("v2-omemo") { db in
            try db.alter(table: "message") { t in
                t.add(column: "error", .text)
            }

            // Our own one-time and signed prekeys. Used one-time prekeys are only
            // marked deleted until the archive catch-up ends, since several
            // archived messages may have been built from the same prekey.
            try db.create(table: "omemoPreKey") { t in
                t.primaryKey("id", .integer)
                t.column("data", .blob).notNull()
                t.column("isDeleted", .boolean).notNull().defaults(to: false)
            }
            try db.create(table: "omemoSignedPreKey") { t in
                t.primaryKey("id", .integer)
                t.column("data", .blob).notNull()
            }
            // Signal sessions and identity keys per (bare JID, device id),
            // including our own other devices.
            try db.create(table: "omemoSession") { t in
                t.column("name", .text).notNull()
                t.column("deviceId", .integer).notNull()
                t.column("data", .blob).notNull()
                t.primaryKey(["name", "deviceId"])
            }
            try db.create(table: "omemoIdentity") { t in
                t.column("name", .text).notNull()
                t.column("deviceId", .integer).notNull()
                t.column("key", .blob).notNull()
                t.column("status", .integer).notNull()
                t.primaryKey(["name", "deviceId"])
            }
        }

        migrator.registerMigration("v3-avatars") { db in
            try db.alter(table: "contact") { t in
                t.add(column: "avatarHash", .text)
            }
        }

        migrator.registerMigration("v4-message-trust") { db in
            try db.alter(table: "message") { t in
                t.add(column: "omemoDevice", .integer)
                t.add(column: "omemoTrust", .text)
            }
        }

        migrator.registerMigration("v5-link-previews") { db in
            try db.alter(table: "conversation") { t in
                t.add(column: "linkPreviews", .boolean)
            }
            try db.alter(table: "message") { t in
                t.add(column: "link", .text)
            }
            let rows = try Row.fetchAll(db, sql: "SELECT id, body FROM message WHERE body LIKE '%https://%' AND encryption != 'omemoUndecryptable'")
            for row in rows {
                guard let link = LinkDetector.previewLink(in: row["body"]) else { continue }
                try db.execute(sql: "UPDATE message SET link = ? WHERE id = ?", arguments: [link.absoluteString, row["id"] as Int64])
            }
            try db.create(table: "linkPreview") { t in
                t.primaryKey("url", .text)
                t.column("kind", .text).notNull()
                t.column("title", .text)
                t.column("summary", .text)
                t.column("siteName", .text)
                t.column("imageFile", .text)
                t.column("imageWidth", .double)
                t.column("imageHeight", .double)
                t.column("fetchedAt", .datetime).notNull()
            }
        }

        migrator.registerMigration("v6-attachments") { db in
            try db.create(table: "attachment") { t in
                t.primaryKey("messageId", .integer).references("message", onDelete: .cascade)
                t.column("url", .text)
                t.column("name", .text).notNull()
                t.column("mimeType", .text)
                t.column("size", .integer)
                t.column("width", .double)
                t.column("height", .double)
                t.column("localFile", .text)
                t.column("state", .text).notNull()
            }
        }

        migrator.registerMigration("v7-groups") { db in
            try db.create(table: "groupChat") { t in
                t.primaryKey("conversationId", .integer).references("conversation", onDelete: .cascade)
                t.column("jid", .text).notNull().unique()
                t.column("nickname", .text).notNull()
                t.column("name", .text)
                t.column("subject", .text)
                t.column("hasLeft", .boolean).notNull().defaults(to: false)
                t.column("isBookmarked", .boolean).notNull().defaults(to: false)
                t.column("isMembersOnly", .boolean).notNull().defaults(to: false)
                t.column("isNonAnonymous", .boolean).notNull().defaults(to: false)
                t.column("lastArchiveId", .text)
            }
            try db.alter(table: "message") { t in
                t.add(column: "nick", .text)
            }
            // The nickname joins the key: occupants of anonymous rooms all
            // react as the room.
            try db.create(table: "newReaction") { t in
                t.belongsTo("message", onDelete: .cascade).notNull()
                t.column("sender", .text).notNull()
                t.column("nick", .text).notNull().defaults(to: "")
                t.column("emoji", .text).notNull()
                t.primaryKey(["messageId", "sender", "nick", "emoji"])
            }
            try db.execute(sql: "INSERT INTO newReaction (messageId, sender, emoji) SELECT messageId, sender, emoji FROM reaction")
            try db.drop(table: "reaction")
            try db.rename(table: "newReaction", to: "reaction")
        }

        migrator.registerMigration("v8-group-notify") { db in
            try db.alter(table: "groupChat") { t in
                t.add(column: "notify", .text).notNull().defaults(to: GroupChat.Notify.always.rawValue)
            }
        }

        migrator.registerMigration("v9-occupant-id") { db in
            try db.alter(table: "groupChat") { t in
                t.add(column: "hasOccupantIds", .boolean).notNull().defaults(to: false)
            }
            try db.alter(table: "message") { t in
                t.add(column: "occupantId", .text)
            }
            try db.alter(table: "reaction") { t in
                t.add(column: "occupantId", .text)
            }
        }

        migrator.registerMigration("v10-corrections-retractions") { db in
            try db.alter(table: "message") { t in
                t.add(column: "editedAt", .datetime)
                t.add(column: "isRetracted", .boolean).notNull().defaults(to: false)
            }
        }

        migrator.registerMigration("v11-mentions") { db in
            try db.alter(table: "message") { t in
                t.add(column: "mentionsMe", .boolean).notNull().defaults(to: false)
            }
        }

        migrator.registerMigration("v12-contact-requests") { db in
            try db.alter(table: "contact") { t in
                t.add(column: "subscriptionRequestedAt", .datetime)
                t.add(column: "requestedNickname", .text)
            }
        }

        migrator.registerMigration("v13-markers") { db in
            // Unknown for what's already stored: no marker for those.
            try db.alter(table: "message") { t in
                t.add(column: "isMarkable", .boolean).notNull().defaults(to: false)
            }
        }

        migrator.registerMigration("v14-group-invitations") { db in
            try db.create(table: "groupInvitation") { t in
                t.primaryKey("room", .text)
                t.column("inviter", .text).notNull()
                t.column("reason", .text)
                t.column("receivedAt", .datetime).notNull()
            }
        }

        migrator.registerMigration("v15-nicknames") { db in
            try db.alter(table: "contact") { t in
                t.add(column: "nickname", .text)
            }
        }

        migrator.registerMigration("v16-older-history") { db in
            try db.alter(table: "conversation") { t in
                t.add(column: "historyComplete", .boolean).notNull().defaults(to: false)
                t.add(column: "historyCursor", .text)
            }
        }

        migrator.registerMigration("v17-revisions") { db in
            // A message's revision goes up whenever it, or a reaction,
            // attachment or link preview that shows with it, changes, so the
            // conversation observation can find what to rebuild without
            // reading every row of its window.
            try db.alter(table: "message") { t in
                t.add(column: "rev", .integer).notNull().defaults(to: 0)
            }
            try db.execute(sql: "CREATE INDEX message_on_link ON message(link) WHERE link IS NOT NULL")
            try db.execute(sql: """
                CREATE TRIGGER message_revision AFTER UPDATE ON message WHEN NEW.rev = OLD.rev
                BEGIN UPDATE message SET rev = rev + 1 WHERE id = NEW.id; END
                """)
            for table in ["reaction", "attachment"] {
                try db.execute(sql: """
                    CREATE TRIGGER \(table)_inserted_revision AFTER INSERT ON \(table)
                    BEGIN UPDATE message SET rev = rev + 1 WHERE id = NEW.messageId; END
                    """)
                try db.execute(sql: """
                    CREATE TRIGGER \(table)_updated_revision AFTER UPDATE ON \(table)
                    BEGIN UPDATE message SET rev = rev + 1 WHERE id IN (OLD.messageId, NEW.messageId); END
                    """)
                try db.execute(sql: """
                    CREATE TRIGGER \(table)_deleted_revision AFTER DELETE ON \(table)
                    BEGIN UPDATE message SET rev = rev + 1 WHERE id = OLD.messageId; END
                    """)
            }
            for (event, url) in [("INSERT", "NEW.url"), ("UPDATE", "NEW.url"), ("DELETE", "OLD.url")] {
                try db.execute(sql: """
                    CREATE TRIGGER linkPreview_\(event.lowercased())_revision AFTER \(event) ON linkPreview
                    BEGIN UPDATE message SET rev = rev + 1 WHERE link = \(url); END
                    """)
            }
        }

        migrator.registerMigration("v18-message-search") { db in
            // The index holds no text of its own: it reads bodies from the
            // message table, so a body is stored once. That means every
            // removal must hand FTS5 exactly what was indexed, which is why
            // each trigger tests the same eligibility on the old row.
            try db.execute(sql: """
                CREATE VIRTUAL TABLE messageSearch USING fts5(
                    body, content='message', content_rowid='id', tokenize='unicode61 remove_diacritics 2'
                )
                """)
            try db.execute(sql: """
                INSERT INTO messageSearch(rowid, body)
                SELECT id, body FROM message WHERE \(Self.searchable("message"))
                """)
            try db.execute(sql: """
                CREATE TRIGGER messageSearch_inserted AFTER INSERT ON message
                WHEN \(Self.searchable("NEW"))
                BEGIN INSERT INTO messageSearch(rowid, body) VALUES (NEW.id, NEW.body); END
                """)
            try db.execute(sql: """
                CREATE TRIGGER messageSearch_updated AFTER UPDATE OF body, encryption, isRetracted ON message
                BEGIN
                    INSERT INTO messageSearch(messageSearch, rowid, body) SELECT 'delete', OLD.id, OLD.body WHERE \(Self.searchable("OLD"));
                    INSERT INTO messageSearch(rowid, body) SELECT NEW.id, NEW.body WHERE \(Self.searchable("NEW"));
                END
                """)
            // Before, not after: deleting a message cascades to its
            // attachment first, which would change what "indexed" meant.
            try db.execute(sql: """
                CREATE TRIGGER messageSearch_deleted BEFORE DELETE ON message
                WHEN \(Self.searchable("OLD"))
                BEGIN INSERT INTO messageSearch(messageSearch, rowid, body) VALUES ('delete', OLD.id, OLD.body); END
                """)
            // The file's row usually arrives just after its message.
            try db.execute(sql: """
                CREATE TRIGGER messageSearch_attached AFTER INSERT ON attachment
                BEGIN
                    INSERT INTO messageSearch(messageSearch, rowid, body)
                    SELECT 'delete', id, body FROM message
                    WHERE id = NEW.messageId AND \(Self.searchable("message", attachment: false));
                END
                """)
            try db.execute(sql: """
                CREATE TRIGGER messageSearch_detached AFTER DELETE ON attachment
                BEGIN
                    INSERT INTO messageSearch(rowid, body)
                    SELECT id, body FROM message
                    WHERE id = OLD.messageId AND \(Self.searchable("message"));
                END
                """)
        }

        migrator.registerMigration("v19-pending-reactions") { db in
            // The server's acknowledgement (XEP-0198) clears it. Updating a
            // row bumps the message's revision, so the chip redraws.
            try db.alter(table: "reaction") { t in
                t.add(column: "pendingId", .text)
            }
            try db.execute(sql: "CREATE INDEX reaction_on_pendingId ON reaction(pendingId) WHERE pendingId IS NOT NULL")
        }

        migrator.registerMigration("v20-added-by-user") { db in
            // Kept apart from the roster, which the server can fill with
            // people the user never added.
            try db.alter(table: "contact") { t in
                t.add(column: "isAddedByUser", .boolean).notNull().defaults(to: false)
            }
        }

        migrator.registerMigration("v21-omemo-device-usage") { db in
            // When we first knew of a device and when it last sent us
            // anything, to tell devices still in use from abandoned ones.
            try db.alter(table: "omemoIdentity") { t in
                t.add(column: "firstSeen", .datetime)
                t.add(column: "lastUsed", .datetime)
            }
            // Devices from before this can't say when they appeared, so a
            // device with no stored message starts its grace period now. One
            // with stored messages gets the day of its last (below), and is
            // inactive at once if that was over 90 days ago.
            try db.execute(sql: "UPDATE omemoIdentity SET firstSeen = ?", arguments: [Date()])
            // The stored messages know when each device last wrote.
            try db.execute(sql: """
                UPDATE omemoIdentity SET lastUsed = (
                    SELECT MAX(timestamp) FROM message
                    WHERE message.sender = omemoIdentity.name AND message.omemoDevice = omemoIdentity.deviceId)
                """)
        }

        migrator.registerMigration("v22-roster-groups") { db in
            try db.alter(table: "contact") { t in
                t.add(column: "rosterGroups", .text).notNull().defaults(to: "[]")
            }
            // The roster we hold has no groups. Forgetting its version makes
            // the next sign-in fetch every item again, with them.
            try db.execute(sql: "DELETE FROM setting WHERE key = 'rosterVersion'")
        }

        migrator.registerMigration("v23-last-seen") { db in
            try db.alter(table: "contact") { t in
                t.add(column: "lastSeenAt", .datetime)
            }
        }

        migrator.registerMigration("v25-moderated-messages") { db in
            // Taken away by a moderator (XEP-0425), not by its author: the
            // tombstone says so. The message is retracted all the same.
            try db.alter(table: "message") { t in
                t.add(column: "isModerated", .boolean).notNull().defaults(to: false)
            }
        }

        migrator.registerMigration("v26-attachment-thumbnail") { db in
            // The tiny preview a sender announced for a file not downloaded yet.
            try db.alter(table: "attachment") { t in
                t.add(column: "thumbnail", .blob)
            }
            // What a file's announcement said, for the message that carries
            // its link, which Dino sends apart. Not tied to a conversation,
            // as the first announcement from someone comes before there is one.
            try db.create(table: "fileAnnouncement") { t in
                t.primaryKey("key", .text)
                t.column("receivedAt", .datetime).notNull()
                t.column("mediaType", .text)
                t.column("size", .integer)
                t.column("width", .integer)
                t.column("height", .integer)
                t.column("thumbnail", .blob)
            }
        }

        migrator.registerMigration("v27-message-written-here") { db in
            // Whether this device wrote a message, as opposed to a room saying
            // we did. Earlier outgoing messages can't be told apart, and
            // taking them all as ours keeps the previews and images of what
            // the user sent from other devices.
            try db.alter(table: "message") { t in
                t.add(column: "isWrittenHere", .boolean).notNull().defaults(to: false)
            }
            try db.execute(sql: "UPDATE message SET isWrittenHere = 1 WHERE direction = 'outgoing'")
        }

        migrator.registerMigration("v28-notification-sound") { db in
            // Null is the system's sound; see `NotificationSound`.
            try db.alter(table: "conversation") { t in
                t.add(column: "notificationSound", .text)
            }
        }

        migrator.registerMigration("v29-calls") { db in
            // A call is a row of its own in the conversation, with no body.
            try db.alter(table: "message") { t in
                t.add(column: "callOutcome", .text)
                t.add(column: "callDuration", .double)
                t.add(column: "callAnsweredAt", .datetime)
            }
        }

        migrator.registerMigration("v30-call-remote-id") { db in
            // For a call message without a peer, which names the call alone.
            try db.execute(sql: "CREATE INDEX message_on_call_remoteId ON message(remoteId) WHERE callOutcome IS NOT NULL")
        }

        migrator.registerMigration("v31-call-video") { db in
            try db.alter(table: "message") { t in
                t.add(column: "callIsVideo", .boolean).notNull().defaults(to: false)
            }
        }

        migrator.registerMigration("v32-message-editedAt") { db in
            // Every notification claim looks for messages edited since the
            // last one, which without this reads the whole table.
            try db.execute(sql: "CREATE INDEX message_on_editedAt ON message(editedAt) WHERE editedAt IS NOT NULL")
        }

        migrator.registerMigration("v33-message-quickResponses") { db in
            // JSON, with the actions already chosen inside it. Changing it
            // goes through the revision trigger like any other update.
            try db.alter(table: "message") { t in
                t.add(column: "quickResponses", .text)
            }
        }

        migrator.registerMigration("v34-synced-settings") { db in
            // The state of every synced setting: see `AppDatabase+SyncedSettings`.
            try db.create(table: "syncedEntry") { t in
                t.column("item", .text).notNull()
                t.column("key", .text).notNull()
                t.column("value", .text)
                t.column("version", .text).notNull()
                t.column("by", .text).notNull()
                t.primaryKey(["item", "key"])
            }
            try db.create(table: "syncedItemDirty") { t in
                t.primaryKey("item", .text)
            }
            try db.create(table: "remoteUsage") { t in
                t.primaryKey("deviceId", .text)
                t.column("json", .text).notNull()
            }
            try db.alter(table: "conversation") { t in
                t.add(column: "archivedAt", .datetime)
            }
            // A chat archived before the time was kept counts as archived
            // as of its last activity, so a newer message still brings it back.
            try db.execute(sql: "UPDATE conversation SET archivedAt = lastActivityAt WHERE isArchived")
        }

        migrator.registerMigration("v35-attachment-duration") { db in
            // How long a sound plays, announced by the sender or measured by us.
            try db.alter(table: "attachment") { t in
                t.add(column: "duration", .double)
            }
            try db.alter(table: "fileAnnouncement") { t in
                t.add(column: "length", .double)
            }
        }

        migrator.registerMigration("v36-pending-edit") { db in
            // A retraction or correction that named a message we don't have
            // yet, as when the archive's newer page comes before the older
            // one. It waits for the message, and is applied if the author fits.
            try db.create(table: "pendingEdit") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("conversationId", .integer).notNull().references("conversation", onDelete: .cascade)
                t.column("ref", .text).notNull()
                t.column("kind", .text).notNull()
                t.column("outgoing", .boolean).notNull()
                t.column("sender", .text).notNull()
                t.column("nick", .text)
                t.column("occupantId", .text)
                t.column("encryption", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("editedAt", .datetime).notNull()
                // The message that stands in for a correction's original.
                t.column("standInId", .integer).references("message", onDelete: .cascade)
            }
            try db.create(index: "pendingEdit_on_ref", on: "pendingEdit", columns: ["conversationId", "ref"])
            try db.create(index: "pendingEdit_on_createdAt", on: "pendingEdit", columns: ["createdAt"])
        }

        migrator.registerMigration("v37-pending-message-action") { db in
            // Our correction or retraction of a message already sent, until the
            // server acknowledges its stanza. A new session sends it again.
            try db.alter(table: "message") { t in
                t.add(column: "actionPendingId", .text)
            }
            try db.execute(sql: "CREATE INDEX message_on_actionPendingId ON message(actionPendingId) WHERE actionPendingId IS NOT NULL")
        }

        migrator.registerMigration("v38-action-errors") { db in
            // Why a correction, a retraction or our reactions never reached the
            // other side, once the server (or the give-up) said so. Nothing
            // else records it: by then the stanza was acknowledged and its
            // pending id is gone.
            try db.alter(table: "message") { t in
                t.add(column: "actionError", .text)
            }
            try db.alter(table: "reaction") { t in
                t.add(column: "error", .text)
            }
        }

        migrator.registerMigration("v39-room-passwords") { db in
            // A room's password came with the invitation and lived in memory
            // only, so a new session joined without it and was refused for good.
            try db.alter(table: "groupChat") { t in
                t.add(column: "password", .text)
            }
            try db.alter(table: "groupInvitation") { t in
                t.add(column: "password", .text)
            }
        }

        migrator.registerMigration("v40-notification-interval") { db in
            try db.alter(table: "conversation") { t in
                t.add(column: "notificationInterval", .integer)
                t.add(column: "lastLoudNotificationAt", .datetime)
            }
        }

        migrator.registerMigration("v41-invitation-origin") { db in
            // Held invitations were all relayed by the room, which the default
            // says; whether it can vouch for the inviter follows from the JIDs.
            try db.alter(table: "groupInvitation") { t in
                t.add(column: "isDirect", .boolean).notNull().defaults(to: false)
            }
        }

        migrator.registerMigration("v42-invitation-notified") { db in
            // Invitations held before this were never notified about, and
            // shouldn't be now, long after.
            try db.alter(table: "groupInvitation") { t in
                t.add(column: "isNotified", .boolean).notNull().defaults(to: true)
            }
        }

        migrator.registerMigration("v43-auto-download-attempts") { db in
            try db.alter(table: "attachment") { t in
                t.add(column: "autoDownloadAttempts", .integer).notNull().defaults(to: 0)
            }
        }

        migrator.registerMigration("v44-device-notices") { db in
            // A row that marks something that happened in the chat, such as a
            // contact's new device, instead of a message: see `MessageEvent`.
            try db.alter(table: "message") { t in
                t.add(column: "event", .text)
            }
            // The devices a JID's first device list held, so later ones can
            // be told from them; the marker says a list was seen at all,
            // as it may have been empty.
            try db.create(table: "deviceListSeen") { t in
                t.primaryKey("name", .text)
            }
            try db.create(table: "baselineDevice") { t in
                t.column("name", .text).notNull()
                t.column("deviceId", .integer).notNull()
                t.primaryKey(["name", "deviceId"])
            }
            // Our own account's new devices, for the chat list's warning. The
            // row stays once dismissed, so a device is announced once.
            try db.create(table: "deviceNotice") { t in
                t.primaryKey("deviceId", .integer)
                t.column("fingerprint", .text).notNull()
                t.column("firstSeen", .datetime).notNull()
                t.column("isDismissed", .boolean).notNull().defaults(to: false)
            }
        }

        migrator.registerMigration("v45-presence-session") { db in
            // Which stay of a nickname's holder wrote a message, in rooms with
            // no addresses or occupant ids, so that whoever takes the nickname
            // later can't edit what its earlier holder wrote.
            try db.alter(table: "message") { t in
                t.add(column: "presenceSession", .integer)
            }
            try db.alter(table: "pendingEdit") { t in
                t.add(column: "presenceSession", .integer)
            }
        }

        return migrator
    }

    /// SQL for a message that is not an event row: what "a message in the
    /// chat" means for the preview, the newest and oldest, and whether a chat
    /// has any. Events are rows, but nobody said them.
    static let isNotEvent = "message.event IS NULL"

    /// SQL for whether the message row `row` belongs in the search index:
    /// readable text that is still there, and not a file or place, which
    /// are bodies that are only a URI. An `aesgcm://` link carries the
    /// file's key, so it is kept out whether or not its attachment is stored yet.
    private static func searchable(_ row: String, attachment: Bool = true) -> String {
        let whitespace = "' ' || char(9, 10, 13)"
        return """
            (\(row).encryption <> 'omemoUndecryptable' AND NOT \(row).isRetracted
             AND trim(\(row).body, \(whitespace)) <> ''
             AND ltrim(\(row).body) NOT LIKE 'aesgcm://%'
             AND NOT (ltrim(\(row).body) LIKE 'geo:%' AND trim(\(row).body, \(whitespace)) NOT GLOB '*[ ' || char(9, 10, 13) || ']*')
             \(attachment ? "AND NOT EXISTS (SELECT 1 FROM attachment WHERE attachment.messageId = \(row).id)" : ""))
            """
    }
}

extension DerivableRequest<Message> {
    /// Without the rows that only mark something that happened: see `AppDatabase.isNotEvent`.
    func excludingEvents() -> Self { filter(Column("event") == nil) }
}
