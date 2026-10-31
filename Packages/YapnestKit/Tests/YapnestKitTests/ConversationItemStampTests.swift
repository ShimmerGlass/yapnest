import Foundation
import Testing
@testable import YapnestKit

/// Equal stamps make two items equal without comparing them, so a content
/// property that changes without taking a new stamp would never be rebuilt.
struct ConversationItemStampTests {
    private func item() -> ConversationItem {
        let me = JID("me@example.org")!
        var message = Message(conversationId: 1, direction: .incoming, sender: me, body: "hi", remoteId: "1")
        message.id = 1
        return ConversationItem(message: message, reactions: [], quote: nil, preview: nil, attachment: nil)
    }

    @Test func changingAnyContentPropertyTakesANewStamp() {
        var subject = item()
        var stamp = subject.stamp

        func expectNewStamp(_ name: String, _ change: (inout ConversationItem) -> Void) {
            change(&subject)
            #expect(subject.stamp != stamp, "\(name) kept its stamp")
            stamp = subject.stamp
        }

        expectNewStamp("message") { $0.message.body = "changed" }
        expectNewStamp("reactions") { $0.reactions = [.init(emoji: "👍", senders: [], includesMe: true, isPending: false, error: nil)] }
        expectNewStamp("quote") { $0.quote = .init(author: nil, text: "quoted", messageId: nil) }
        expectNewStamp("preview") { $0.preview = LinkPreview(url: "https://example.org", kind: .none) }
        expectNewStamp("attachment") { $0.attachment = Attachment(messageId: 1, url: nil, name: "a.png", mimeType: nil, state: .pendingUpload) }
    }
}
