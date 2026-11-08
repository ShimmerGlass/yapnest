import Foundation
import UserNotifications

/// A call offered while the app wasn't running, which the notification extension heard of and told the
/// caller it is ringing for. It goes to the app as the payload of a VoIP push (CallKit hands the
/// dictionary over as it was given), so everything in it is checked on the way back in.
public struct IncomingCall: Sendable, Equatable {
    public var sid: String
    public var peer: JID
    public var name: String
    public var isVideo: Bool

    /// Long enough for any name a contact has, short enough that a forged payload can't fill a call screen.
    static let maxNameLength = 256

    public init(sid: String, peer: JID, name: String, isVideo: Bool) {
        self.sid = sid
        self.peer = peer
        self.name = name
        self.isVideo = isVideo
    }

    public var payload: [AnyHashable: Any] {
        ["sid": sid, "peer": peer.description, "name": name, "video": isVideo]
    }

    public init?(payload: [AnyHashable: Any]) {
        guard let sid = payload["sid"] as? String, !sid.isEmpty, sid.count <= CallSignal.maxSessionIdLength,
              let address = payload["peer"] as? String, let peer = JID(address), peer.description == address,
              let name = payload["name"] as? String, name.count <= Self.maxNameLength,
              let isVideo = payload["video"] as? Bool else { return nil }
        self.init(sid: sid, peer: peer, name: name, isVideo: isVideo)
    }

    /// The loud notification for a call that CallKit didn't take, or on the Mac. Its `peerKey` is what a
    /// chat message's has, so tapping it opens the chat.
    public var notificationContent: UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = name
        content.body = isVideo ? String(localized: "Incoming video call") : String(localized: "Incoming call")
        content.sound = .default
        content.threadIdentifier = peer.description
        content.userInfo = [MessageNotification.peerKey: peer.description]
        return content
    }

    public var requestIdentifier: String { "call-\(sid)" }
}
