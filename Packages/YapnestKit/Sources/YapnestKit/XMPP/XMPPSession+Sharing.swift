import Foundation
@preconcurrency import Martin

/// What the share extension needs of a session, and what the app does about
/// the messages the extension left.
extension XMPPSession {
    /// Connects, and waits until the session can send. Nil if it can, else why not.
    func connectToSend(timeout: TimeInterval) async -> String? {
        connect()
        do {
            return try await withTimeout(timeout) { [self] () -> String? in
                for await value in state.values {
                    if value == .connected(isSyncing: false) { return nil }
                    if case .failed(let reason) = value { return reason }
                }
                return String(localized: "The connection ended.")
            }
        } catch {
            return String(localized: "The server didn't respond.")
        }
    }

    /// Joins the group chat and waits until it has us and our encryption has
    /// its members. Nil if it does, else why not.
    func joinToSend(_ room: JID, timeout: TimeInterval) async -> String? {
        guard let group = try? database.groupChat(room), !group.hasLeft else { return String(localized: "You're no longer in this group.") }
        join(room, nickname: group.nickname, mayCreate: false)
        switch await awaitRoom(room, timeout: timeout, until: { $0.isJoined && !$0.isSyncing }) {
        case .reached: return nil
        case .failed(let reason): return reason
        case .ended: return String(localized: "The connection ended.")
        case .timedOut, .cancelled: return GroupError.timedOut.localizedDescription
        }
    }

    /// Sends what the share extension left while this session was already
    /// connected, since it couldn't get the lock and told us by
    /// `PendingSendsSignal`. Does nothing while connecting or catching up, as
    /// the end of that sends everything pending anyway. A message already
    /// taken up by the send queue is left alone.
    public func resendPending() {
        guard policy.resendsPending, state.value == .connected(isSyncing: false) else { return }
        sendUnclaimedPending()
    }
}
