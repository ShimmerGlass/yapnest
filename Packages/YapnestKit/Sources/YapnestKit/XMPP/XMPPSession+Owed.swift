import Foundation

/// What the sends of the roster change and block queues have in common: the
/// loop over a stored queue.
extension XMPPSession {
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
