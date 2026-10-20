import Foundation

/// What the chat list draws over an empty list.
public enum ChatListEmptyState: Equatable, Sendable {
    case noArchivedChats
    case noChats
    case noResults

    /// Nil counts as not loaded yet, when nothing should show: the screen
    /// would otherwise flash an empty state over what's about to appear.
    public static func choose(
        itemCount: Int?,
        visibleItemCount: Int,
        hasMessageResults: Bool,
        isSearchingMessages: Bool,
        requestCount: Int?,
        invitationCount: Int?,
        search: String,
        archived: Bool,
    ) -> ChatListEmptyState? {
        guard let itemCount else { return nil }
        if itemCount == 0 {
            if archived { return .noArchivedChats }
            // Requests and invitations are content too.
            return requestCount == 0 && invitationCount == 0 ? .noChats : nil
        }
        if !search.isEmpty, visibleItemCount == 0, !hasMessageResults, !isSearchingMessages { return .noResults }
        return nil
    }
}

/// When the chat list's offline banner appears.
public enum ConnectionBannerRule {
    public enum Action: Equatable, Sendable {
        case hide
        case keepShowing
        /// Show it if the connection is still down after the grace period.
        case showAfterDelay
    }

    /// A drop after leaving the app reconnects in a moment, so it never
    /// shows the banner; a restart of the watch that changes nothing leaves
    /// a showing banner alone.
    public static func action(isDown: Bool, isInBackground: Bool, isShowing: Bool) -> Action {
        guard isDown, !isInBackground else { return .hide }
        return isShowing ? .keepShowing : .showAfterDelay
    }
}

/// Which session the app's scene-phase and lock handling applies to.
public enum SessionScope {
    /// A sign-in in progress counts as the session until it finishes, as it
    /// holds the lock and the database as well.
    public static func current<S: AnyObject>(signedIn: S?, pendingSignIn: S?) -> S? {
        signedIn ?? pendingSignIn
    }

    /// Whether a task waiting for the process lock on behalf of `session`
    /// should still go ahead.
    public static func isWanted<S: AnyObject>(_ session: S, signedIn: S?, pendingSignIn: S?) -> Bool {
        signedIn === session || pendingSignIn === session
    }
}

/// How many of a chat's own sheets are up, which may be presented by SwiftUI
/// or UIKit and dismissed by any path. Dismissals beyond the presentations
/// are ignored, so a stray one can't hide a sheet that's up.
public struct SheetCounter: Equatable, Sendable {
    public private(set) var count = 0
    public init() {}
    public var isPresenting: Bool { count > 0 }
    public mutating func presented() { count += 1 }
    public mutating func dismissed() { count = max(0, count - 1) }
}
