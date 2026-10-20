extension XMPPSession {
    /// What a session may do, decided once from its mode so that no code
    /// has to ask which mode it is in. Each field is a capability the three
    /// modes differ on; the whole matrix is the three statics below.
    struct Policy: Sendable {
        /// Sends presence, so the server treats us as online and delivers live.
        var announcesPresence: Bool
        /// Receives our other devices' messages and copies of ours (XEP-0280).
        var enablesCarbons: Bool
        /// Tells the server when the app goes inactive (XEP-0352).
        var reportsClientState: Bool
        /// Reads the archive after connecting, rather than only writing.
        var catchesUpOnConnect: Bool
        /// Does what only the app needs after catching up: avatars, bookmarks,
        /// our nickname, push, and sending what's still pending.
        var syncsAccountState: Bool
        /// Removes contact requests the server no longer has.
        var prunesContactRequests: Bool
        /// Asks rooms for the history we missed when joining them.
        var readsRoomHistory: Bool
        /// Checks that the rooms we're in still have us.
        var checksRoomMembership: Bool
        /// Tells contacts when we're typing and the like.
        var sendsChatStates: Bool
        /// Registers with the push relay.
        var registersPush: Bool
        /// Fetches received images unasked.
        var fetchesImages: Bool
        /// Donates chats to the share sheet's suggestions.
        var donatesSuggestions: Bool
        /// Sends what other processes left pending while we were connected.
        var resendsPending: Bool
        /// Checks the connection is alive when the app returns or the network
        /// changes. The other modes are short-lived and have a timeout of
        /// their own.
        var verifiesLiveness: Bool

        static let app = Policy(
            announcesPresence: true, enablesCarbons: true, reportsClientState: true,
            catchesUpOnConnect: true, syncsAccountState: true, prunesContactRequests: true,
            readsRoomHistory: true, checksRoomMembership: true, sendsChatStates: true,
            registersPush: true, fetchesImages: true, donatesSuggestions: true,
            resendsPending: true, verifiesLiveness: true,
        )

        /// Catches up without telling anyone it's here, so the server keeps
        /// pushing to the app's session.
        static let notificationService = Policy(
            announcesPresence: false, enablesCarbons: false, reportsClientState: false,
            catchesUpOnConnect: true, syncsAccountState: false, prunesContactRequests: false,
            readsRoomHistory: true, checksRoomMembership: false, sendsChatStates: false,
            registersPush: false, fetchesImages: false, donatesSuggestions: false,
            resendsPending: false, verifiesLiveness: false,
        )

        /// Only writes: it skips the catch-up and the history of rooms it joins.
        static let share = Policy(
            announcesPresence: false, enablesCarbons: false, reportsClientState: false,
            catchesUpOnConnect: false, syncsAccountState: false, prunesContactRequests: false,
            readsRoomHistory: false, checksRoomMembership: false, sendsChatStates: false,
            registersPush: false, fetchesImages: false, donatesSuggestions: false,
            resendsPending: false, verifiesLiveness: false,
        )

        init(
            announcesPresence: Bool, enablesCarbons: Bool, reportsClientState: Bool,
            catchesUpOnConnect: Bool, syncsAccountState: Bool, prunesContactRequests: Bool,
            readsRoomHistory: Bool, checksRoomMembership: Bool, sendsChatStates: Bool,
            registersPush: Bool, fetchesImages: Bool, donatesSuggestions: Bool,
            resendsPending: Bool, verifiesLiveness: Bool,
        ) {
            self.announcesPresence = announcesPresence
            self.enablesCarbons = enablesCarbons
            self.reportsClientState = reportsClientState
            self.catchesUpOnConnect = catchesUpOnConnect
            self.syncsAccountState = syncsAccountState
            self.prunesContactRequests = prunesContactRequests
            self.readsRoomHistory = readsRoomHistory
            self.checksRoomMembership = checksRoomMembership
            self.sendsChatStates = sendsChatStates
            self.registersPush = registersPush
            self.fetchesImages = fetchesImages
            self.donatesSuggestions = donatesSuggestions
            self.resendsPending = resendsPending
            self.verifiesLiveness = verifiesLiveness
        }
    }
}

extension XMPPSession.Mode {
    var policy: XMPPSession.Policy {
        switch self {
        case .app: .app
        case .notificationService: .notificationService
        case .share: .share
        }
    }
}
