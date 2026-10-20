import Foundation
import ImageIO
import Intents
import UniformTypeIdentifiers
import UserNotifications
import os

/// The send-message intents the system learns chats from: donated for the
/// share sheet's suggestions, and attached to notifications so they show the
/// sender's picture. Both use the peer's address as the conversation
/// identifier, so what the system knows about a chat is one thing.
public enum ConversationIntents {
    private static let logger = Logger(subsystem: "Yapnest", category: "ConversationIntents")

    /// The notification extension has little memory, and the system draws
    /// these small; a full-size avatar would only cost us.
    static let thumbnailPixels = 192

    /// Who and what a notification's intent names, chosen before any
    /// system type is involved.
    struct IncomingPlan: Equatable {
        var peer: JID
        /// The group's name; nil in a chat with one person.
        var groupName: String?
        var senderHandle: String
        var senderName: String
        var senderImage: Data?
        var groupImage: Data?
    }

    /// Nil when there's no picture to show, which leaves the notification as
    /// it was: iOS would otherwise draw initials in its place.
    static func incomingPlan(for notification: MessageNotification, peerImage: Data?, senderImage: Data?) -> IncomingPlan? {
        let peer = notification.peer
        guard notification.isGroup else {
            // A chat with one person: the peer is the sender.
            guard let peerImage else { return nil }
            return IncomingPlan(
                peer: peer, groupName: nil, senderHandle: peer.description,
                senderName: notification.title, senderImage: peerImage, groupImage: nil,
            )
        }
        // The group's picture is the one shown large; without it, the
        // sender's stands in, so the group isn't drawn with initials.
        guard let groupImage = peerImage ?? senderImage else { return nil }
        let name = notification.subtitle ?? notification.title
        return IncomingPlan(
            peer: peer, groupName: notification.title,
            senderHandle: notification.senderJID?.description ?? "\(peer)/\(name)",
            senderName: name, senderImage: senderImage, groupImage: groupImage,
        )
    }

    static func incomingIntent(for notification: MessageNotification, avatars: AvatarStore) -> INSendMessageIntent? {
        let plan = incomingPlan(
            for: notification,
            peerImage: image(for: notification.peerAvatarHash, in: avatars),
            senderImage: image(for: notification.senderAvatarHash, in: avatars),
        )
        guard let plan else { return nil }
        let sender = person(handle: plan.senderHandle, name: plan.senderName, image: plan.senderImage.map { INImage(imageData: $0) })
        let intent = INSendMessageIntent(
            recipients: nil, outgoingMessageType: .outgoingMessageText, content: nil,
            speakableGroupName: plan.groupName.map { INSpeakableString(spokenPhrase: $0) },
            conversationIdentifier: plan.peer.description, serviceName: nil, sender: sender, attachments: nil,
        )
        setGroupImage(plan.groupImage.map { INImage(imageData: $0) }, on: intent)
        return intent
    }

    /// For a chat we write to, in the share sheet.
    static func outgoingIntent(to peer: JID, name: String, isGroup: Bool, image: Data?) -> INSendMessageIntent {
        let image = image.map { INImage(imageData: $0) }
        let intent = INSendMessageIntent(
            recipients: [person(handle: peer.description, name: name, image: image)],
            outgoingMessageType: .outgoingMessageText, content: nil,
            speakableGroupName: isGroup ? INSpeakableString(spokenPhrase: name) : nil,
            conversationIdentifier: peer.description, serviceName: nil, sender: nil, attachments: nil,
        )
        if isGroup { setGroupImage(image, on: intent) }
        return intent
    }

    private static func person(handle: String, name: String, image: INImage?) -> INPerson {
        INPerson(
            personHandle: INPersonHandle(value: handle, type: .unknown),
            nameComponents: nil, displayName: name, image: image, contactIdentifier: nil, customIdentifier: handle,
        )
    }

    private static func setGroupImage(_ image: INImage?, on intent: INSendMessageIntent) {
        // Unavailable in the macOS package builds that run the tests.
        #if os(iOS)
        if let image { intent.setImage(image, forParameterNamed: \INSendMessageIntent.speakableGroupName) }
        #endif
    }

    /// The avatar's thumbnail, if we have the file.
    static func image(for hash: String?, in avatars: AvatarStore) -> Data? {
        guard let hash, avatars.contains(hash), let data = try? Data(contentsOf: avatars.url(for: hash)) else { return nil }
        return thumbnail(of: data)
    }

    static func thumbnail(of data: Data, pixels: Int = thumbnailPixels) -> Data? {
        // Decoding only the thumbnail keeps a large avatar from being
        // expanded in full, which the notification extension couldn't afford.
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = AvatarStore.thumbnail(of: source, pixels: pixels)
        else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }

    /// Tells the system it's an incoming message from this chat, which is
    /// what makes it draw the notification with the intent's pictures.
    static func donate(_ intent: INSendMessageIntent, peer: JID, direction: INInteractionDirection) async {
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = direction
        // What `ShareSuggestions.remove` finds them by.
        interaction.groupIdentifier = peer.description
        do {
            try await interaction.donate()
        } catch {
            logger.info("Couldn't donate \(peer, privacy: .private): \(error)")
        }
    }
}

extension MessageNotification {
    /// Changes the text of the delivered notifications of corrected messages,
    /// without a sound or a banner. A message whose notification was dismissed
    /// or never shown is left alone: an edit isn't news.
    public static func replaceDelivered(_ edited: [MessageNotification], badge: Int?, avatars: AvatarStore) async {
        guard !edited.isEmpty else { return }
        let center = UNUserNotificationCenter.current()
        let delivered = await center.deliveredNotifications().map { (identifier: $0.request.identifier, userInfo: $0.request.content.userInfo) }
        for (notification, identifier) in deliveredIdentifiers(replacing: edited, among: delivered) {
            let content = await notification.content(badge: badge, avatars: avatars)
            let silent = (content.mutableCopy() as? UNMutableNotificationContent) ?? notification.content(badge: badge)
            silent.sound = nil
            silent.interruptionLevel = .passive
            try? await center.add(UNNotificationRequest(identifier: identifier, content: silent, trigger: nil))
        }
    }

    /// For each corrected message that has a delivered notification, the
    /// identifier that notification has. The first one of a push is delivered
    /// under the push's identifier and found by the message id in its
    /// `userInfo`; ones from before that was recorded, and the ones this app
    /// posts, are under `requestIdentifier`.
    static func deliveredIdentifiers(
        replacing edited: [MessageNotification], among delivered: [(identifier: String, userInfo: [AnyHashable: Any])],
    ) -> [(MessageNotification, String)] {
        edited.compactMap { notification in
            let match = delivered.first { ($0.userInfo[messageIdKey] as? Int64) == notification.messageId }
                ?? delivered.first { $0.identifier == notification.requestIdentifier }
            return match.map { (notification, $0.identifier) }
        }
    }

    /// The content with the sender's or group's picture, as a communication
    /// notification. Without a picture, or if the system refuses, it's the
    /// plain content, which shows the app's icon.
    public func content(badge: Int?, avatars: AvatarStore) async -> UNNotificationContent {
        let plain = content(badge: badge)
        guard let intent = ConversationIntents.incomingIntent(for: self, avatars: avatars) else { return plain }
        await ConversationIntents.donate(intent, peer: peer, direction: .incoming)
        return (try? plain.updating(from: intent)) ?? plain
    }

    public func request(badge: Int?, avatars: AvatarStore) async -> UNNotificationRequest {
        UNNotificationRequest(identifier: requestIdentifier, content: await content(badge: badge, avatars: avatars), trigger: nil)
    }
}
