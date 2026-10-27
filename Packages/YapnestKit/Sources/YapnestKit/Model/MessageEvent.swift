import Foundation

/// Something that happened in a conversation, kept in its history as a row
/// of its own with no words (see `Message.event`). It is never sent, read,
/// notified, searched or replied to; it only marks the moment.
public enum MessageEvent: Codable, Hashable, Sendable {
    /// A device of the contact appeared after we had first heard of theirs.
    /// Under blind trust it was trusted at once and gets our messages.
    case newDevice(deviceId: Int32, fingerprint: String)
}
