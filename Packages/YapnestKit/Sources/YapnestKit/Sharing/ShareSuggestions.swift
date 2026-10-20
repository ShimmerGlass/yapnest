import Foundation
import Intents
import os

/// The chats the share sheet suggests at its top. The system learns them from
/// the send-message intents we donate, one conversation identifier per chat,
/// which the share extension reads back to preselect the chat.
public enum ShareSuggestions {
    private static let logger = Logger(subsystem: "Yapnest", category: "ShareSuggestions")

    /// One donation a minute per chat is plenty for ranking, and a busy chat
    /// would otherwise donate on every message.
    private static let interval: TimeInterval = 60
    private static let lastDonation = OSAllocatedUnfairLock(initialState: [JID: Date]())

    /// Tells the system we just sent to `peer`.
    public static func donate(to peer: JID, database: AppDatabase, avatars: AvatarStore) async {
        let now = Date()
        let due = lastDonation.withLock { last in
            if let previous = last[peer], now.timeIntervalSince(previous) < interval { return false }
            last[peer] = now
            return true
        }
        guard due else { return }
        let intent = intent(for: peer, database: database, avatars: avatars)
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .outgoing
        // What `remove` finds them by.
        interaction.groupIdentifier = peer.description
        do {
            try await interaction.donate()
        } catch {
            logger.info("Couldn't donate \(peer, privacy: .private): \(error)")
        }
    }

    /// For a chat that's gone, or that we can't write to any more.
    public static func remove(_ peers: [JID]) {
        guard !peers.isEmpty else { return }
        INInteraction.delete(with: peers.map(\.description)) { error in
            if let error { logger.info("Couldn't remove donations: \(error)") }
        }
        lastDonation.withLock { last in for peer in peers { last[peer] = nil } }
    }

    public static func removeAll() {
        INInteraction.deleteAll { _ in }
        lastDonation.withLock { $0 = [:] }
    }

    static func intent(for peer: JID, database: AppDatabase, avatars: AvatarStore) -> INSendMessageIntent {
        let contact = try? database.contact(peer)
        let group = try? database.groupChat(peer)
        let name = group?.displayName ?? contact?.displayName ?? peer.shortName
        return ConversationIntents.outgoingIntent(
            to: peer, name: name, isGroup: group != nil,
            image: ConversationIntents.image(for: contact?.avatarHash, in: avatars),
        )
    }
}
