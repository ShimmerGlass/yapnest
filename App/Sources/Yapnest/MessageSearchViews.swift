import SwiftUI
import YapnestKit

/// A message found by searching, under the chat it's in.
struct MessageSearchRow: View {
    let result: MessageSearchResult
    let item: ChatListItem
    let avatarURL: URL?

    var body: some View {
        HStack(spacing: 12) {
            AvatarView(name: item.title, seed: item.conversation.peer.description, imageURL: avatarURL, isGroup: item.groupChat != nil)
                .frame(width: 40, height: 40)
                .padding(.vertical, 10)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(item.title)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text(result.timestamp.chatListFormatted())
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Text(SearchSnippet.attributed(result.snippet, author: author))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    /// Who wrote it, where that isn't clear from the chat.
    private var author: String? {
        if result.direction == .outgoing { return String(localized: "You") }
        return item.groupChat == nil ? nil : (result.nick ?? result.sender.shortName)
    }
}

enum SearchSnippet {
    /// The excerpt with its matched words bold, and the author before it.
    static func attributed(_ snippet: String, author: String? = nil) -> AttributedString {
        var text = AttributedString()
        if let author {
            let name = AttributedString(author + ": ")
            text += name
        }
        var bold = false
        var run = ""
        func flush() {
            guard !run.isEmpty else { return }
            var part = AttributedString(run)
            if bold { part.inlinePresentationIntent = .stronglyEmphasized; part.foregroundColor = .primary }
            text += part
            run = ""
        }
        for character in snippet {
            switch character {
            case MessageSearchResult.matchStart: flush(); bold = true
            case MessageSearchResult.matchEnd: flush(); bold = false
            case "\n": run.append(" ")
            default: run.append(character)
            }
        }
        flush()
        return text
    }
}
