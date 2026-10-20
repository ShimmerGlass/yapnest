import Testing
@testable import YapnestKit

private final class Token {}

@Suite struct ScreenRulesTests {
    private func empty(
        items: Int? = 0, visible: Int = 0, results: Bool = false, searching: Bool = false,
        requests: Int? = 0, invitations: Int? = 0, search: String = "", archived: Bool = false,
    ) -> ChatListEmptyState? {
        ChatListEmptyState.choose(
            itemCount: items, visibleItemCount: visible, hasMessageResults: results, isSearchingMessages: searching,
            requestCount: requests, invitationCount: invitations, search: search, archived: archived,
        )
    }

    @Test func emptyListShowsNoChats() {
        #expect(empty() == .noChats)
        #expect(empty(archived: true) == .noArchivedChats)
    }

    @Test func nothingShowsWhileLoading() {
        #expect(empty(items: nil) == nil)
        #expect(empty(requests: nil) == nil)
        #expect(empty(invitations: nil) == nil)
    }

    @Test func requestsAndInvitationsSuppressNoChats() {
        #expect(empty(requests: 1) == nil)
        #expect(empty(invitations: 2) == nil)
    }

    @Test func noResultsOnlyWhenSearching() {
        #expect(empty(items: 3, visible: 0) == nil)
        #expect(empty(items: 3, visible: 0, search: "x") == .noResults)
        #expect(empty(items: 3, visible: 0, results: true, search: "x") == nil)
        #expect(empty(items: 3, visible: 0, searching: true, search: "x") == nil)
        #expect(empty(items: 3, visible: 2, search: "x") == nil)
    }

    @Test func bannerRule() {
        #expect(ConnectionBannerRule.action(isDown: false, isInBackground: false, isShowing: true) == .hide)
        #expect(ConnectionBannerRule.action(isDown: true, isInBackground: true, isShowing: true) == .hide)
        #expect(ConnectionBannerRule.action(isDown: true, isInBackground: false, isShowing: true) == .keepShowing)
        #expect(ConnectionBannerRule.action(isDown: true, isInBackground: false, isShowing: false) == .showAfterDelay)
    }

    @Test func pendingSignInIsTheCurrentSession() {
        let pending = Token(), other = Token()
        #expect(SessionScope.current(signedIn: nil, pendingSignIn: pending) === pending)
        #expect(SessionScope.current(signedIn: other, pendingSignIn: pending) === other)
        #expect(SessionScope.current(signedIn: Token?.none, pendingSignIn: nil) == nil)
    }

    @Test func lockWaiterWantsSignedInOrPendingSession() {
        let a = Token(), b = Token()
        #expect(SessionScope.isWanted(a, signedIn: a, pendingSignIn: nil))
        #expect(SessionScope.isWanted(a, signedIn: nil, pendingSignIn: a))
        #expect(!SessionScope.isWanted(a, signedIn: nil, pendingSignIn: nil))
        #expect(!SessionScope.isWanted(a, signedIn: b, pendingSignIn: b))
    }

    @Test func sheetCounterBalances() {
        var counter = SheetCounter()
        counter.dismissed()
        #expect(!counter.isPresenting)
        counter.presented()
        counter.presented()
        counter.dismissed()
        #expect(counter.isPresenting)
        counter.dismissed()
        #expect(!counter.isPresenting)
    }
}
