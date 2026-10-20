import SwiftUI
import YapnestKit

/// Asks before blocking someone, offering to report them too where the
/// server takes reports (XEP-0377).
struct BlockConfirmation: ViewModifier {
    @Binding var isPresented: Bool
    let session: XMPPSession
    let peer: JID
    let name: String

    @State private var blocking = ServerAction()

    func body(content: Content) -> some View {
        content
            .disabled(blocking.isBusy)
            .overlay {
                if blocking.isBusy {
                    ProgressView("Blocking…")
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .confirmationDialog("Block \(name)?", isPresented: $isPresented, titleVisibility: .visible) {
                Button("Block", role: .destructive) { block(reporting: nil) }
                if session.canReport {
                    Button("Report Spam and Block", role: .destructive) { block(reporting: .spam) }
                    Button("Report Abuse and Block", role: .destructive) { block(reporting: .abuse) }
                }
            } message: {
                if session.canReport {
                    Text("They won't be able to message you or see when you're online, on any of your devices. A report also lets your server's administrators see their latest messages to you.")
                } else {
                    Text("They won't be able to message you or see when you're online, on any of your devices.")
                }
            }
            .errorAlert("Couldn't block", $blocking.error)
    }

    private func block(reporting reason: XMPPSession.ReportReason?) {
        let (session, peer) = (session, peer)
        blocking.run { try await session.block(peer, reporting: reason) }
    }
}

extension View {
    func blockConfirmation(isPresented: Binding<Bool>, session: XMPPSession, peer: JID, name: String) -> some View {
        modifier(BlockConfirmation(isPresented: isPresented, session: session, peer: peer, name: name))
    }
}
