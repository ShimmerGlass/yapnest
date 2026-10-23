import SwiftUI
import UserNotifications
import YapnestKit

@main
struct YapnestApp: App {
    @UIApplicationDelegateAdaptor private var delegate: AppDelegate
    @Environment(\.scenePhase) private var scenePhase

    init() {
        #if DEBUG
        AppDatabase.trapsMainThreadAccess = true
        #endif
    }

    var body: some Scene {
        WindowGroup {
            // Stacked rather than a safe area inset: an inset leaves the
            // navigation bar's title where it was, under the call bar.
            VStack(spacing: 0) {
                if let session = delegate.model.session, let state = delegate.model.calls.callBar {
                    CallBar(session: session, controller: delegate.model.calls, state: state)
                }
                Group {
                    switch delegate.model.phase {
                    case .loading:
                        if delegate.model.loadingIsSlow { ProgressView() } else { Color.clear }
                    case .signedOut:
                        LoginView()
                    case .signedIn(let session):
                        // In the chat list's place, not over it: a sheet there
                        // would keep out the list's own, such as the
                        // confirmation for a link opened before signing in,
                        // which waits in `pendingLink` until the list is shown.
                        if delegate.model.showsWelcome {
                            WelcomeView(session: session)
                        } else {
                            ChatListView(session: session, opening: delegate.model.requestedConversation)
                        }
                    }
                }
            }
            .environment(delegate.model)
            // Taps on `xmpp:` links in messages stay in the app, whether or
            // not the system hands them back.
            .environment(\.openURL, OpenURLAction { url in
                guard url.scheme?.lowercased() == "xmpp" else { return .systemAction }
                delegate.model.open(link: url)
                return .handled
            })
            .onOpenURL { delegate.model.open(link: $0) }
            .diagnosticsErrorAlert(delegate.diagnostics)
            .errorAlert("Couldn't open the link", Bindable(delegate.model).linkProblem)
            .errorAlert("Couldn't place the call", Bindable(delegate.model.calls).error)
            .fullScreenCover(isPresented: Binding(get: { delegate.model.calls.showsCallView }, set: { _ in })) {
                if let session = delegate.model.session, let state = delegate.model.calls.screen {
                    CallView(session: session, controller: delegate.model.calls, state: state)
                }
            }
            .task {
                if !AppModel.isHostingTests { delegate.model.start() }
            }
            .onChange(of: scenePhase) { _, phase in
                delegate.model.scenePhaseChanged(active: phase == .active, background: phase == .background)
            }
            // Room for the chat list beside a conversation.
            .minimumWindowSize(CGSize(width: 760, height: 520))
            .hidesWindowToolbar()
            .alwaysActiveAppearance()
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { delegate.model.requestedSheet = .settings }
                    .keyboardShortcut(",")
                    .disabled(delegate.model.session == nil || delegate.model.hasConversationSheet)
            }
            CommandGroup(after: .help) {
                Button("Export Logs…") { Task { await delegate.diagnostics.start() } }
                    .disabled(delegate.diagnostics.isExporting)
            }
            CommandGroup(after: .textEditing) {
                Button("Find in Chat") { delegate.model.chatSearchRequests += 1 }
                    .keyboardShortcut("f")
                    .disabled(delegate.model.session == nil || delegate.model.hasConversationSheet)
                Button("Edit Last Message") { delegate.model.editLastRequests += 1 }
                    .keyboardShortcut("e")
                    .disabled(delegate.model.session == nil || delegate.model.hasConversationSheet)
            }
            CommandGroup(replacing: .newItem) {
                Button("New Chat") { delegate.model.requestedSheet = .compose }
                    .keyboardShortcut("n")
                    .disabled(delegate.model.session == nil || delegate.model.hasConversationSheet)
            }
        }
    }
}

/// Receives what only an app delegate gets: the push token, and taps on
/// notifications.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    @MainActor let model = AppModel()
    @MainActor let diagnostics = DiagnosticsExporter()

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        model.receivedPushToken(deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        DiagLog.error(.push, "No push token", .error(error))
    }

    /// The app posts its own notifications whenever it isn't active, which
    /// includes being merely inactive (app switcher, Notification Center, a
    /// call banner) and, on the Mac, another app being in front; the system
    /// would still hold those back as "foreground", so show them. When the
    /// app is active the user is looking at it, and anything arriving is a
    /// push that raced the connection: the app has the message already.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // Delegate callbacks come on the main thread.
        let active = MainActor.assumeIsolated { model.isActive }
        completionHandler(active ? [] : [.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let peer = (response.notification.request.content.userInfo[MessageNotification.peerKey] as? String).flatMap(JID.init(_:))
        // Delegate callbacks come on the main thread.
        MainActor.assumeIsolated {
            if let peer { model.open(peer) }
        }
        completionHandler()
    }
}
