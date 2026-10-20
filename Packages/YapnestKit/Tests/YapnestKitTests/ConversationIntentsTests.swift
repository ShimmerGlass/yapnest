import Foundation
import Intents
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import YapnestKit

struct ConversationIntentsTests {
    let alice = JID("alice@example.org")!
    let room = JID("room@muc.example.org")!
    let picture = Data([1])
    let other = Data([2])

    private func direct() -> MessageNotification {
        MessageNotification(messageId: 1, peer: alice, title: "Alice", body: "hi", timestamp: Date())
    }

    private func group(sender: JID? = JID("bob@example.org")) -> MessageNotification {
        MessageNotification(
            messageId: 2, peer: room, title: "Lunch", subtitle: "Bob", body: "hi", timestamp: Date(),
            isGroup: true, senderJID: sender,
        )
    }

    @Test func directChatUsesThePeersPicture() {
        let plan = ConversationIntents.incomingPlan(for: direct(), peerImage: picture, senderImage: nil)
        #expect(plan?.groupName == nil)
        #expect(plan?.senderName == "Alice")
        #expect(plan?.senderHandle == "alice@example.org")
        #expect(plan?.senderImage == picture)
    }

    @Test func noPictureLeavesThePlainNotification() {
        #expect(ConversationIntents.incomingPlan(for: direct(), peerImage: nil, senderImage: nil) == nil)
        #expect(ConversationIntents.incomingPlan(for: group(), peerImage: nil, senderImage: nil) == nil)
    }

    @Test func groupShowsItsPictureWithTheSendersAsBadge() {
        let plan = ConversationIntents.incomingPlan(for: group(), peerImage: picture, senderImage: other)
        #expect(plan?.groupName == "Lunch")
        #expect(plan?.groupImage == picture)
        #expect(plan?.senderImage == other)
        #expect(plan?.senderName == "Bob")
        #expect(plan?.senderHandle == "bob@example.org")
    }

    @Test func groupWithoutPictureUsesTheSenders() {
        let plan = ConversationIntents.incomingPlan(for: group(), peerImage: nil, senderImage: other)
        #expect(plan?.groupImage == other)
    }

    @Test func groupWithOnlyItsOwnPictureHasNoBadge() {
        let plan = ConversationIntents.incomingPlan(for: group(sender: nil), peerImage: picture, senderImage: nil)
        #expect(plan?.groupImage == picture)
        #expect(plan?.senderImage == nil)
        #expect(plan?.senderHandle == "room@muc.example.org/Bob")
    }

    @Test func thumbnailsAreDownscaled() throws {
        let big = try pngData(pixels: 1000)
        let small = try #require(ConversationIntents.thumbnail(of: big))
        let source = try #require(CGImageSourceCreateWithData(small as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(max(image.width, image.height) == ConversationIntents.thumbnailPixels)
        #expect(ConversationIntents.thumbnail(of: Data([0, 1, 2])) == nil)
    }

    @Test func thumbnailOfNonImageDataIsNil() {
        #expect(ConversationIntents.thumbnail(of: Data()) == nil)
        #expect(ConversationIntents.thumbnail(of: Data("not an image, just text".utf8)) == nil)
    }

    @Test func smallPictureIsNotEnlarged() throws {
        let thumb = try #require(ConversationIntents.thumbnail(of: try pngData(pixels: 40)))
        let source = try #require(CGImageSourceCreateWithData(thumb as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(max(image.width, image.height) == 40)
    }

    // The outgoing intent is the one donated for the share sheet's suggestions.
    // Its group picture is set through an API the macOS test build doesn't have
    // (`#if os(iOS)`), so only the parts common to both platforms are checked.
    @Test func outgoingIntentToAPersonNamesThemAsRecipient() throws {
        let intent = ConversationIntents.outgoingIntent(to: alice, name: "Alice", isGroup: false, image: nil)
        let recipient = try #require(intent.recipients?.first)
        #expect(intent.recipients?.count == 1)
        #expect(recipient.personHandle?.value == "alice@example.org")
        #expect(recipient.displayName == "Alice")
        #expect(intent.speakableGroupName == nil)
        #expect(intent.conversationIdentifier == "alice@example.org")
        #expect(intent.sender == nil)
    }

    @Test func outgoingIntentToAGroupNamesTheGroup() {
        let intent = ConversationIntents.outgoingIntent(to: room, name: "Lunch", isGroup: true, image: picture)
        #expect(intent.speakableGroupName?.spokenPhrase == "Lunch")
        #expect(intent.conversationIdentifier == "room@muc.example.org")
        #expect(intent.recipients?.first?.personHandle?.value == "room@muc.example.org")
    }

    private func avatars(_ images: [(hash: String, data: Data)]) throws -> AvatarStore {
        let store = AvatarStore.temporary()
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        for (hash, data) in images { try data.write(to: store.url(for: hash)) }
        return store
    }

    private let peerHash = String(repeating: "a", count: 40)
    private let senderHash = String(repeating: "b", count: 40)

    @Test func incomingGroupIntentWithoutASenderPicture() throws {
        var notification = group()
        notification.peerAvatarHash = peerHash
        notification.senderAvatarHash = senderHash // named, but no file in the store
        let store = try avatars([(peerHash, try pngData(pixels: 300))])
        let intent = try #require(ConversationIntents.incomingIntent(for: notification, avatars: store))
        #expect(intent.speakableGroupName?.spokenPhrase == "Lunch")
        #expect(intent.conversationIdentifier == "room@muc.example.org")
        #expect(intent.sender?.personHandle?.value == "bob@example.org")
        #expect(intent.sender?.displayName == "Bob")
        #expect(intent.sender?.image == nil)
    }

    @Test func incomingDirectIntentIsFromThePeer() throws {
        var notification = direct()
        notification.peerAvatarHash = peerHash
        let store = try avatars([(peerHash, try pngData(pixels: 300))])
        let intent = try #require(ConversationIntents.incomingIntent(for: notification, avatars: store))
        #expect(intent.speakableGroupName == nil)
        #expect(intent.sender?.displayName == "Alice")
        #expect(intent.sender?.image != nil)
    }

    @Test func incomingIntentIsNilWhenNoPictureCanBeRead() throws {
        var notification = group()
        notification.peerAvatarHash = peerHash
        notification.senderAvatarHash = "not-a-hash"
        // The group's file is there but isn't an image.
        let store = try avatars([(peerHash, Data("junk".utf8))])
        #expect(ConversationIntents.incomingIntent(for: notification, avatars: store) == nil)
        #expect(ConversationIntents.incomingIntent(for: direct(), avatars: store) == nil)
    }

    @Test func avatarImageNeedsAValidHashAndAFile() throws {
        let store = try avatars([(peerHash, try pngData(pixels: 300))])
        #expect(ConversationIntents.image(for: peerHash, in: store) != nil)
        #expect(ConversationIntents.image(for: senderHash, in: store) == nil)
        #expect(ConversationIntents.image(for: "../escape", in: store) == nil)
        #expect(ConversationIntents.image(for: nil, in: store) == nil)
    }

    // Donating and attaching the intent to the content needs an app process
    // the system knows, so only the fall back to plain content is exercised.
    @Test func contentWithoutAPictureIsThePlainContent() async throws {
        let notification = group()
        let content = await notification.content(badge: 3, avatars: AvatarStore.temporary())
        #expect(content.title == "Lunch" && content.subtitle == "Bob" && content.body == "hi")
        #expect(content.badge == 3)
        #expect(content.threadIdentifier == "room@muc.example.org")
        #expect(content.userInfo[MessageNotification.peerKey] as? String == "room@muc.example.org")
    }

    @Test func contentWithAPictureKeepsTheTextWhateverTheSystemDoes() async throws {
        var notification = direct()
        notification.peerAvatarHash = peerHash
        let store = try avatars([(peerHash, try pngData(pixels: 300))])
        let content = await notification.content(badge: nil, avatars: store)
        #expect(content.title == "Alice" && content.body == "hi")
        #expect(content.badge == nil)
        #expect(content.threadIdentifier == "alice@example.org")
    }

    @Test func requestIsNamedAfterTheMessage() async {
        let request = await direct().request(badge: nil, avatars: AvatarStore.temporary())
        #expect(request.identifier == "message-1")
        #expect(request.trigger == nil)
    }

    private func pngData(pixels: Int) throws -> Data {
        let context = try #require(CGContext(
            data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
        ))
        let image = try #require(context.makeImage())
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }
}

struct DeliveredNotificationMatchTests {
    private func notification(_ id: Int64) -> MessageNotification {
        MessageNotification(messageId: id, peer: JID("alice@example.org")!, title: "Alice", body: "hi", timestamp: Date())
    }

    @Test func aNotificationUnderThePushIdentifierIsFoundByItsMessageId() {
        let delivered: [(identifier: String, userInfo: [AnyHashable: Any])] = [
            (identifier: "apns-1", userInfo: [MessageNotification.messageIdKey: Int64(7)]),
            (identifier: "apns-2", userInfo: [MessageNotification.messageIdKey: Int64(8)]),
        ]
        let found = MessageNotification.deliveredIdentifiers(replacing: [notification(7)], among: delivered)
        #expect(found.map(\.1) == ["apns-1"])
    }

    @Test func aNotificationUnderTheMessageIdentifierIsFound() {
        let delivered: [(identifier: String, userInfo: [AnyHashable: Any])] = [(identifier: "message-7", userInfo: [:])]
        #expect(MessageNotification.deliveredIdentifiers(replacing: [notification(7)], among: delivered).map(\.1) == ["message-7"])
    }

    @Test func aMessageWithNoDeliveredNotificationIsLeftOut() {
        let delivered: [(identifier: String, userInfo: [AnyHashable: Any])] = [
            (identifier: "message-8", userInfo: [MessageNotification.messageIdKey: Int64(8)]),
        ]
        #expect(MessageNotification.deliveredIdentifiers(replacing: [notification(7)], among: delivered).isEmpty)
    }

    @Test func theContentCarriesTheMessageId() {
        let content = notification(7).content(badge: nil)
        #expect(content.userInfo[MessageNotification.messageIdKey] as? Int64 == 7)
    }
}

struct SessionStateLogNameTests {
    @Test func aFailedStateNamesItsCaseWithoutItsText() {
        let name = XMPPSession.State.failed("secret text").caseName
        #expect(name == "failed")
        #expect(!name.contains("secret"))
        #expect(XMPPSession.State.disconnected(error: "secret text").caseName == "disconnected")
    }
}
