import SwiftUI
import YapnestKit

extension View {
    /// The alerts and sheets the conversation raises: failures, the choice
    /// about link previews, deleting a message, who reacted.
    func conversationPrompts(_ model: ConversationModel) -> some View {
        modifier(ConversationPrompts(model: model))
    }
}

private struct ConversationPrompts: ViewModifier {
    let model: ConversationModel

    private var alert: (title: String, message: String)? {
        switch model.prompt {
        case .error(let message): (String(localized: "Something went wrong"), message)
        case .notice(let title, let message): (title, message)
        case .linkPreviews:
            (String(localized: "Show link previews in this chat?"),
             String(localized: "Previews are loaded by your phone, so a linked site can see your IP address and that you received its link. You can change this in Chat Settings."))
        case .failure(let id): (String(localized: "Message not sent"), model.failureText(of: id))
        case .quoteNotFound:
            (String(localized: "Message not found"), String(localized: "The message that was quoted may be too old, or have been deleted."))
        case .confirmRetraction, .confirmModeration, .reactions, nil: nil
        }
    }

    private var dialog: ConversationModel.Prompt? {
        switch model.prompt {
        case .confirmRetraction, .confirmModeration, .reactions: model.prompt
        default: nil
        }
    }

    func body(content: Content) -> some View {
        content
            .alert(alert?.title ?? "", isPresented: Binding(get: { alert != nil }, set: { if !$0 { model.prompt = nil } })) {
                alertButtons
            } message: {
                Text(alert?.message ?? "")
            }
            .confirmationDialog(
                "",
                // Not once the choice has raised an alert of its own: the dialog goes
                // after that, and mustn't take the alert with it.
                isPresented: Binding(get: { dialog != nil }, set: { if !$0, dialog != nil { model.prompt = nil } }),
                titleVisibility: .hidden,
            ) {
                dialogButtons
            } message: {
                if case .confirmRetraction = dialog {
                    Text("This message will be deleted for everyone in the chat. Apps that don't support deleting may still show it.")
                } else if case .confirmModeration = dialog {
                    Text("This message will be removed for everyone in the group, and will say a moderator removed it.")
                }
            }
    }

    @ViewBuilder
    private var alertButtons: some View {
        switch model.prompt {
        case .linkPreviews:
            Button("Always Show") { model.setLinkPreviews(true) }
            Button("Never Show") { model.setLinkPreviews(false) }
            Button("Not Now", role: .cancel) {}
        case .failure(let id):
            Button("Try Again") { model.retry(id) }
            Button("Cancel", role: .cancel) {}
        default:
            Button("OK", role: .cancel) {}
        }
    }

    @ViewBuilder
    private var dialogButtons: some View {
        switch dialog {
        case .confirmRetraction(let id):
            Button("Delete for Everyone", role: .destructive) { model.retract(id) }
            Button("Cancel", role: .cancel) {}
        case .confirmModeration(let id):
            Button("Remove for Everyone", role: .destructive) { model.removeForEveryone(id) }
            Button("Cancel", role: .cancel) {}
        case .reactions(let id):
            ForEach(model.reactionChoices(for: id), id: \.emoji) { choice in
                Button(choice.includesMe ? "\(choice.emoji)  \(choice.names) — tap to remove" : "\(choice.emoji)  \(choice.names)", role: choice.includesMe ? .destructive : nil) {
                    model.react(choice.emoji, to: id)
                }
            }
            Button("Close", role: .cancel) {}
        default:
            EmptyView()
        }
    }
}
