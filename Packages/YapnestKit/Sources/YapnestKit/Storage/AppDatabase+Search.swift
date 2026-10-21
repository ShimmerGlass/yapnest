import Foundation
import GRDB

/// A message that matched a search, with the excerpt to show for it.
public struct MessageSearchResult: Hashable, Sendable, Identifiable {
    public var messageId: Int64
    public var conversationId: Int64
    public var timestamp: Date
    public var direction: Message.Direction
    public var sender: JID
    public var nick: String?
    /// A few words around the match, with each matched word wrapped in
    /// `matchStart` and `matchEnd`.
    public var snippet: String

    public var id: Int64 { messageId }

    /// Private-use characters, which `InboundMessage.withoutSearchMarkers` takes out of
    /// every incoming body, so the UI can turn them into bold without parsing
    /// markup.
    public static let matchStart: Character = "\u{E000}"
    public static let matchEnd: Character = "\u{E001}"
}

extension AppDatabase {
    /// The messages containing every word of `query`, the last one as a
    /// prefix so results follow the typing, newest first. Searches one
    /// conversation, or all of them. Reads synchronously, so call it off the
    /// main thread.
    public func searchMessages(_ query: String, in conversationId: Int64? = nil, limit: Int = 50) throws -> [MessageSearchResult] {
        guard let pattern = Self.searchPattern(for: query), limit > 0 else { return [] }
        let start = String(MessageSearchResult.matchStart), end = String(MessageSearchResult.matchEnd)
        return try reader.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT message.id, message.conversationId, message.timestamp, message.direction, message.sender, message.nick,
                       snippet(messageSearch, 0, ?, ?, '…', 12) AS snippet
                FROM messageSearch
                JOIN message ON message.id = messageSearch.rowid
                WHERE messageSearch MATCH ? AND (? IS NULL OR message.conversationId = ?)
                ORDER BY message.timestamp DESC, message.id DESC
                LIMIT ?
                """, arguments: [start, end, pattern.rawPattern, conversationId, conversationId, limit])
            return rows.compactMap { row -> MessageSearchResult? in
                guard let direction = Message.Direction(rawValue: row["direction"]), let sender = JID.fromDatabaseValue(row["sender"]) else { return nil }
                return MessageSearchResult(
                    messageId: row["id"], conversationId: row["conversationId"], timestamp: row["timestamp"],
                    direction: direction, sender: sender, nick: row["nick"], snippet: row["snippet"],
                )
            }
        }
    }

    /// Every word becomes a quoted prefix, so nothing the user types can be
    /// read as FTS5 syntax. Nil when there are no words in it. Words split
    /// where the index's tokenizer would: anywhere that isn't a letter, a
    /// number or a mark on one.
    static func searchPattern(for query: String) -> FTS5Pattern? {
        var words: [String] = []
        var word = String.UnicodeScalarView()
        for scalar in query.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
                 .decimalNumber, .letterNumber, .otherNumber, .nonspacingMark, .spacingMark, .enclosingMark:
                word.append(scalar)
            default:
                if !word.isEmpty { words.append(String(word)); word = .init() }
            }
        }
        if !word.isEmpty { words.append(String(word)) }
        guard !words.isEmpty else { return nil }
        return try? FTS5Pattern(rawPattern: words.map { "\"\($0)\"*" }.joined(separator: " "))
    }
}

extension AppDatabase {
    /// The ids of the messages in `conversationId` that contain every word of
    /// `query`, newest first, kept up to date as messages arrive, are edited,
    /// retracted or deleted. Empty when the query has no words.
    public func observeSearchMatches(_ query: String, in conversationId: Int64, limit: Int) -> ValueObservation<ValueReducers.RemoveDuplicates<ValueReducers.Fetch<[Int64]>>> {
        let pattern = Self.searchPattern(for: query)
        return ValueObservation.tracking { db in
            guard let pattern, limit > 0 else { return [] }
            return try Int64.fetchAll(db, sql: """
                SELECT message.id
                FROM messageSearch
                JOIN message ON message.id = messageSearch.rowid
                WHERE messageSearch MATCH ? AND message.conversationId = ?
                ORDER BY message.timestamp DESC, message.id DESC
                LIMIT ?
                """, arguments: [pattern.rawPattern, conversationId, limit])
        }
        .removeDuplicates()
    }
}
