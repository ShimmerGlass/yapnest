import Foundation

/// What the sends of owed changes (bookmarks, profile, roster changes, blocks)
/// have in common: how a refusal reaches the Retry that asked, and the loop
/// over a stored queue.
extension XMPPSession {
    /// The server refused what `key`'s warning is about, for good. Kept until
    /// the user's Retry asks, so it can show the answer in place.
    func recordRefusal(_ key: String, _ error: Error) {
        lock.withLock { $0.refusals[key] = error }
    }

    /// The server took what `key`'s warning was about.
    func settleWarning(_ key: String) {
        lock.withLock { _ = $0.refusals.removeValue(forKey: key) }
        warnings.clear(key)
    }

    /// A Retry: owes the change again, waits for the run that sends it, and
    /// throws the server's refusal if there is one, so the Retry spins until
    /// the server has answered and shows the outcome in place. Offline the
    /// run sends nothing: the change stays queued and the Retry returns.
    func retryOwed(
        _ key: String,
        owe: () async throws -> Void,
        run: () -> Task<Void, Never>?,
    ) async throws {
        lock.withLock { _ = $0.refusals.removeValue(forKey: key) }
        try await owe()
        await run()?.value
        if let refusal = lock.withLock({ $0.refusals.removeValue(forKey: key) }) { throw refusal }
    }

    /// What to do with a change the server refused for good.
    enum RefusedChange {
        /// It is dropped and the user is told.
        case warn
        /// It is dropped, but was no longer the user's to retry.
        case skip
        /// It couldn't be dropped; nothing more is sent now.
        case stop
    }

    /// Sends a stored queue's changes one at a time, oldest first, while
    /// `ready`. `claim` takes the next one and marks it in flight under
    /// `queueLock`, so an undo or a replacement can't touch it after it was
    /// chosen; the mark is cleared when it has been dealt with. A change that
    /// fails with an error that can pass stays queued for the next connect.
    func drainQueue<Change>(
        queueLock: NSLock,
        ready: () -> Bool,
        next: () throws -> Change?,
        afterChosen: () -> Void,
        markInFlight: (Change?) -> Void,
        deliver: (Change) async throws -> Void,
        isRefusal: (Error) -> Bool,
        refuse: (Change) -> RefusedChange,
        warn: (Change, Error) -> Void,
        logFailure: (Change, Error) -> Void,
    ) async {
        while isConnected, ready() {
            let change: Change?
            do {
                change = try queueLock.withLock {
                    let change = try next()
                    afterChosen()
                    markInFlight(change)
                    return change
                }
            } catch {
                logger.error("Failed to read a queue of changes to send: \(error)")
                return
            }
            defer { markInFlight(nil) }
            guard let change else { return }
            do {
                try await deliver(change)
            } catch {
                logFailure(change, error)
                // Whatever passes by itself stays queued for the next connect.
                guard isRefusal(error) else { return }
                switch refuse(change) {
                case .warn: warn(change, error)
                case .skip: continue
                case .stop: return
                }
            }
        }
    }
}
