import Combine
import Foundation

/// Something that went wrong on the account and that the user should hear of
/// (a setting that couldn't be saved, say), shown above the chat list.
public struct AccountWarning: Identifiable, Sendable {
    /// Names what failed, such as "profile", so a repeat replaces the earlier one.
    public let key: String
    /// A few words, for the row on the chat list.
    public var title: String
    /// What the sheet shows: the server's reason, from `ServerError.describe`.
    public var detail: String
    /// Tries the action again. Nil when trying again wouldn't help.
    public var retry: (@Sendable () async throws -> Void)?
    /// The lead of `detail`, kept so that a failed retry says the same.
    var friendly: String?
    /// What the sheet offers beside Dismiss.
    public enum Action: Sendable {
        /// Run `retry`.
        case retry
        /// Open the account's devices.
        case openDevices
    }

    public var action: Action?
    /// Remembers the dismissal beyond this session. The warning goes when
    /// whoever posted it clears it, once that is done.
    var onDismiss: (@Sendable () -> Void)?

    public var id: String { key }
}

/// The account's warnings, in memory for the session: a new session redoes
/// its own work and posts again what still fails.
public final class AccountWarnings: @unchecked Sendable {
    private let subject = CurrentValueSubject<[AccountWarning], Never>([])
    private let lock = NSLock()

    public init() {}

    public var current: [AccountWarning] { subject.value }

    /// The list now, then every change.
    public var updates: AsyncPublisher<CurrentValueSubject<[AccountWarning], Never>> {
        subject.values
    }

    /// Shows a warning, or replaces the one with the same `key` where it is.
    ///
    ///     session.warnings.post("profile", title: "Profile not saved", detail: error.describe("Your profile wasn't saved")) {
    ///         try await session.publishProfile()
    ///         session.warnings.clear("profile")
    ///     }
    public func post(_ key: String, title: String, detail: String, retry: (@Sendable () async throws -> Void)? = nil) {
        post(AccountWarning(key: key, title: title, detail: detail, retry: retry, action: retry == nil ? nil : .retry))
    }

    private func post(_ warning: AccountWarning) {
        let key = warning.key
        lock.withLock {
            var list = subject.value
            if let index = list.firstIndex(where: { $0.key == key }) { list[index] = warning } else { list.append(warning) }
            subject.send(list)
        }
    }

    /// The same, with the detail from the error: the server's own reason
    /// after `friendly`, such as "Your profile wasn't saved". An error of our
    /// own, such as being offline, says what it is instead.
    public func post(_ key: String, title: String, friendly: String, error: Error, retry: (@Sendable () async throws -> Void)? = nil) {
        post(AccountWarning(key: key, title: title, detail: ServerError.userMessage(for: error, friendly: friendly), retry: retry, friendly: friendly, action: retry == nil ? nil : .retry))
    }

    /// Removes what a room posted, such as "room-history:cake@rooms.example.org",
    /// once the user has left it and can no longer act on it.
    public func clear(room: JID) {
        lock.withLock {
            let list = subject.value
            let kept = list.filter { !$0.key.hasSuffix(":\(room)") }
            if kept.count != list.count { subject.send(kept) }
        }
    }

    /// Posts a warning the user can dismiss for good: `onDismiss` records
    /// that, and the poster clears the warning once it has.
    public func post(_ key: String, title: String, detail: String, action: AccountWarning.Action, onDismiss: @escaping @Sendable () -> Void) {
        post(AccountWarning(key: key, title: title, detail: detail, retry: nil, action: action, onDismiss: onDismiss))
    }

    /// The user's Dismiss: a warning that keeps its dismissal elsewhere has
    /// that told, and otherwise goes at once.
    public func dismiss(_ key: String) {
        if let onDismiss = current.first(where: { $0.key == key })?.onDismiss { onDismiss() } else { clear(key) }
    }

    /// Removes the warning with `key`, when its action has succeeded. Does nothing if there is none.
    public func clear(_ key: String) {
        lock.withLock {
            let list = subject.value
            guard list.contains(where: { $0.key == key }) else { return }
            subject.send(list.filter { $0.key != key })
        }
    }

    /// What `attempt` did.
    enum AttemptOutcome: Sendable {
        /// The work succeeded, and the warning is cleared.
        case succeeded
        /// It failed when the result was no longer wanted, so nothing was said.
        case abandoned
        /// It failed with an error that can pass, and the caller chose to leave it.
        case passed(Error)
        /// It failed, and `shouldPost` declined to warn.
        case declined(Error)
        /// It failed, and the warning with its Retry is shown.
        case posted(Error)
    }

    /// What `attempt` does with an error that can pass by itself.
    enum PassingErrors: Sendable {
        /// Warn like any other: for work that already retried it, so what is
        /// left outlasted the attempts.
        case post
        /// Return it: something else (the next connect, a resumed stream)
        /// tries again, and a warning would be about something that may be gone.
        case leave
    }

    /// Runs `work`, the usual shape of an action that nobody waits on: a
    /// success clears the warning at `key`, and a failure shows it with a
    /// Retry, unless `stillWanted` says the result no longer matters (the
    /// connection that started it is gone, and the next one redoes it). Ask
    /// the same question the retries do, `XMPPSession.attemptIsCurrent`.
    ///
    /// `retry` is what the Retry runs, `work` itself when it isn't given; give
    /// it for work that has retries of its own, which a user waiting on a
    /// button shouldn't sit through. `shouldPost` can decline a failure that
    /// is expected, such as a room's refusal to list its members.
    @discardableResult
    func attempt(
        _ key: String, title: String, friendly: String,
        stillWanted: @Sendable () -> Bool,
        passingErrors: PassingErrors = .post,
        retry: (@Sendable () async throws -> Void)? = nil,
        shouldPost: @Sendable (Error) -> Bool = { _ in true },
        _ work: @escaping @Sendable () async throws -> Void,
    ) async -> AttemptOutcome {
        do {
            try await work()
            clear(key)
            return .succeeded
        } catch {
            guard stillWanted() else { return .abandoned }
            if passingErrors == .leave, ServerError.classify(error).isPassing { return .passed(error) }
            guard shouldPost(error) else { return .declined(error) }
            post(key, title: title, friendly: friendly, error: error, retry: retry ?? work)
            return .posted(error)
        }
    }

    /// Runs the warning's retry. A success clears it; a failure replaces its
    /// detail with the new outcome. Returns whether it's gone.
    @discardableResult
    public func retry(_ key: String) async -> Bool {
        guard let warning = current.first(where: { $0.key == key }), let retry = warning.retry else { return false }
        do {
            try await retry()
            clear(key)
            return true
        } catch {
            // The poster's closure may have posted its own outcome meanwhile.
            guard current.first(where: { $0.key == key }) != nil else { return true }
            post(key, title: warning.title, friendly: warning.friendly ?? warning.title, error: error, retry: retry)
            return false
        }
    }
}
