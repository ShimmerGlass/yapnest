import Foundation
import GRDB

/// Each starred GIF is a synced item of its own, `gif:<id>`, holding the
/// whole GIF as JSON (KLIPY has no lookup by id that we use, so the grid
/// draws without a request). Unstarring is a tombstone rather than a
/// removal, so that unstarring on one device and starring again on another
/// are settled by the later of the two. Order is by the entry's version.
extension AppDatabase {
    /// The most GIFs kept. A star is a deliberate act, so this is only a bound
    /// on the stored value, not something people should reach.
    static let gifFavoritesCapacity = 200

    /// The starred GIFs, newest first.
    func gifFavorites() -> [Gif] {
        (try? reader.read { try Self.gifFavorites($0) }) ?? []
    }

    /// Stars a GIF, or moves it to the front if it already is. Read and
    /// written in one transaction so two writers can't lose each other's.
    public func addGifFavorite(_ gif: Gif) throws {
        try writer.write { db in
            try Self.adoptLegacyGifFavorites(db, by: try Self.syncDeviceId(db) ?? "")
            try Self.touch(db, item: Self.gifItem(gif.id), key: Self.gifKey, value: Self.encodeGif(gif))
            // Over the cap, the oldest are unstarred as well, not only
            // hidden, or the next sync would bring them back.
            for item in try Self.gifItemsOverCapacity(db) {
                try Self.touch(db, item: item, key: Self.gifKey, value: nil)
            }
        }
    }

    public func removeGifFavorite(id: String) throws {
        try writer.write { db in
            try Self.adoptLegacyGifFavorites(db, by: try Self.syncDeviceId(db) ?? "")
            let starred = try Self.syncedEntries(db, item: Self.gifItem(id)).contains { $0.key == Self.gifKey && $0.value != nil }
            if starred { try Self.touch(db, item: Self.gifItem(id), key: Self.gifKey, value: nil) }
        }
    }

    public func observeGifFavorites() -> ValueObservation<ValueReducers.RemoveDuplicates<ValueReducers.Fetch<[Gif]>>> {
        ValueObservation.tracking { db in try Self.gifFavorites(db) }
            .removeDuplicates()
    }

    private static func gifFavorites(_ db: Database) throws -> [Gif] {
        // Until the first write takes them in, the stars from before sync.
        if let legacy = try setting(db, .gifFavorites) { return decodeLegacyGifFavorites(legacy) }
        return try starredGifs(db).prefix(gifFavoritesCapacity).map(\.gif)
    }

    /// Starred GIFs, newest star first.
    private static func starredGifs(_ db: Database) throws -> [(gif: Gif, version: SettingsVersion)] {
        try starredGifRows(db).compactMap { row in decodeGif(row.value).map { ($0, row.version) } }
    }

    /// The starred GIFs past the capacity, oldest star last. Their values
    /// aren't decoded, as only the item is wanted.
    private static func gifItemsOverCapacity(_ db: Database) throws -> [String] {
        try starredGifRows(db).dropFirst(gifFavoritesCapacity).map(\.item)
    }

    /// Every star, newest first: by version, and the device only to break a tie.
    private static func starredGifRows(_ db: Database) throws -> [(item: String, value: String, version: SettingsVersion, by: String)] {
        try Row.fetchAll(db, sql: #"SELECT item, value, version, "by" FROM syncedEntry WHERE item LIKE 'gif:%' AND key = ? AND value IS NOT NULL"#, arguments: [gifKey])
            .compactMap { row in
                SettingsVersion(row["version"] as String).map { (row["item"] as String, row["value"] as String, $0, row["by"] as String) }
            }
            .sorted { ($0.version, $0.by) > ($1.version, $1.by) }
    }

    /// Takes the stars kept before sync into entries, oldest at the lowest
    /// version, which any real one beats, and marks them to be published.
    /// Done by whichever of the first write and `seedSyncedSettingsIfNeeded`
    /// comes first.
    static func adoptLegacyGifFavorites(_ db: Database, by deviceId: String) throws {
        guard let raw = try setting(db, .gifFavorites) else { return }
        let gifs = decodeLegacyGifFavorites(raw)
        for (index, gif) in gifs.enumerated() {
            let entry = SettingsEntry(key: gifKey, value: encodeGif(gif), version: SettingsVersion(ms: 0, counter: gifs.count - index), by: deviceId)
            try insertIfAbsent(db, item: gifItem(gif.id), entry)
        }
        try setSetting(db, .gifFavorites, nil)
    }

    private static func encodeGif(_ gif: Gif) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(gif)).map { String(decoding: $0, as: UTF8.self) }
    }

    private static func decodeGif(_ json: String) -> Gif? {
        json.data(using: .utf8).flatMap { try? JSONDecoder().decode(Gif.self, from: $0) }
    }

    /// An unreadable value reads as no favorites rather than failing the picker.
    private static func decodeLegacyGifFavorites(_ raw: String) -> [Gif] {
        raw.data(using: .utf8).flatMap { try? JSONDecoder().decode([Gif].self, from: $0) } ?? []
    }
}
