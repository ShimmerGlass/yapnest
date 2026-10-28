import Foundation

/// Something that happened in a conversation, kept in its history as a row
/// of its own with no words (see `Message.event`). It is never sent, read,
/// notified, searched or replied to; it only marks the moment.
public enum MessageEvent: Codable, Hashable, Sendable {
    /// A device of the contact appeared after we had first heard of theirs.
    /// Under blind trust it was trusted at once and gets our messages.
    case newDevice(deviceId: Int32, fingerprint: String)
    /// Someone became one of a group's people: they came in, or the room
    /// added them. Under encryption they get everything we send there.
    case joinedGroup
    /// Someone stopped being one of a group's people: they left, were
    /// removed or lost their membership. The author is who it is about.
    case leftGroup

    /// Whether this is about someone joining or leaving a group.
    public var isGroupPeople: Bool {
        switch self {
        case .joinedGroup, .leftGroup: true
        case .newDevice: false
        }
    }
}

extension Message {
    /// The row that stands for `event` in a conversation's history.
    static func eventLine(conversationId: Int64, sender: JID, nick: String? = nil, event: MessageEvent, at date: Date) -> Message {
        var line = Message(conversationId: conversationId, direction: .event, sender: sender, body: "", timestamp: date, status: .received, isRead: true)
        line.nick = nick
        line.event = event
        return line
    }
}
