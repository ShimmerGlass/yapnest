import Foundation

/// Saves drafts one after the other, and remembers the newest text per chat
/// until it's written. A chat reopened at once reads that instead of the
/// database, which the last write may not have reached yet.
public final class DraftWriter: @unchecked Sendable {
    public static let shared = DraftWriter()

    private let lock = NSLock()
    private var tail: Task<Void, Never>?
    private var latest: [JID: String] = [:]

    public init() {}

    /// The newest text not known to be stored; empty means cleared.
    public func pending(for peer: JID) -> String? {
        lock.withLock { latest[peer] }
    }

    /// The draft as the user last left it: a pending one is newer than what
    /// the database holds.
    public func current(for peer: JID, in database: AppDatabase) -> String? {
        pending(for: peer) ?? (try? database.draft(peer: peer)) ?? nil
    }

    /// Text typed that isn't being written yet.
    public func note(_ text: String, for peer: JID) {
        lock.withLock { latest[peer] = text }
    }

    /// Writes `text` after every earlier write, so an older draft can't land
    /// last. Callable from any thread, `deinit` included.
    public func save(_ text: String, for peer: JID, to database: AppDatabase) {
        lock.withLock {
            latest[peer] = text
            let previous = tail
            tail = Task.detached(priority: .utility) { [self] in
                await previous?.value
                // A failed write keeps the text, which is still the newest.
                guard (try? database.setDraft(text, peer: peer)) != nil else { return }
                // Only if nothing newer was noted since.
                lock.withLock { if latest[peer] == text { latest[peer] = nil } }
            }
        }
    }

    /// The texts belong to the account signed out of, and the next one may
    /// chat with the same addresses.
    public func forgetAll() {
        lock.withLock { latest = [:] }
    }

    /// Resolves when the writes made so far have landed.
    public func settled() async {
        let current = lock.withLock { tail }
        await current?.value
    }
}
