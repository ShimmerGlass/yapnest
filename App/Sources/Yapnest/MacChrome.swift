import SwiftUI
import YapnestKit

/// The Mac's window chrome, as modifiers so the views using them have one
/// line per seam. Those of the desktop layout serve a wide iPad window too;
/// the rest do nothing on iOS.
extension View {
    /// Who you're signed in as, with Profile and Settings, at the foot of the
    /// sidebar, under the call bar while there is one: across the top of the
    /// window it spanned the chat too, which has its own header there. The
    /// phone's layout has buttons for them in a bar at the foot of the chat
    /// list instead.
    func accountFooter(name: String, seed: String, imageURL: URL?, presence: ContactPresence?, status: String?, call: some View, openProfile: @escaping () -> Void, openSettings: @escaping () -> Void) -> some View {
        modifier(AccountFooterModifier(footer: AccountFooter(name: name, seed: seed, imageURL: imageURL, presence: presence, status: status, call: call, openProfile: openProfile, openSettings: openSettings)))
    }

    /// The list's search field. A drawer search field can't have a button
    /// beside it, so the desktop layout draws its own with New Chat next to it.
    func sidebarSearch(text: Binding<String>, onCompose: (() -> Void)?, focus: FocusState<Bool>.Binding? = nil) -> some View {
        modifier(SidebarSearchModifier(text: text, onCompose: onCompose, focus: focus))
    }

    /// The chat's name as the Mac window's title, for the Window menu. The
    /// title bar doesn't show it (`hidesWindowToolbar()`); the header does.
    @ViewBuilder
    func windowTitle(_ title: String) -> some View {
        if Platform.isMac { navigationTitle(title) } else { self }
    }
}

/// The only button of a sheet that has nothing to cancel, in the confirming
/// place (a checkmark on iOS 26, like `SheetConfirmButton`, and on the Mac,
/// to match the phone). It is also what Esc presses.
struct SheetDoneButton: View {
    @Environment(\.dismiss) private var dismiss
    /// Set on a screen pushed in the sheet, where `dismiss` would only go back.
    var close: DismissAction?

    var body: some View {
        if Platform.isMac {
            SheetIconButton(title: "Done", systemImage: "checkmark") { (close ?? dismiss)() }
                .keyboardShortcut(.cancelAction)
        } else {
            SheetConfirmButton("Done") { (close ?? dismiss)() }
                .keyboardShortcut(.cancelAction)
        }
    }
}

extension EnvironmentValues {
    /// Closes the sheet whose navigation stack a screen is pushed in.
    @Entry var closeSheet: DismissAction?
}

extension View {
    /// On a sheet's navigation stack: its pushed screens show the sheet's
    /// Done button too (`sheetDoneButton()`), so closing doesn't take going
    /// back first. A sheet presented from inside inherits this, so one whose
    /// stack pushes those screens needs it as well.
    func closableFromPushedScreens() -> some View {
        modifier(SheetCloser())
    }

    /// The sheet's Done button, on a screen that can be pushed in a sheet set
    /// up with `closableFromPushedScreens()`. Nothing anywhere else.
    func sheetDoneButton(isShown: Bool = true) -> some View {
        modifier(PushedSheetDone(isShown: isShown))
    }
}

private struct SheetCloser: ViewModifier {
    /// Read outside the stack, so it closes the sheet rather than going back.
    @Environment(\.dismiss) private var dismiss

    func body(content: Content) -> some View {
        content.environment(\.closeSheet, dismiss)
    }
}

private struct PushedSheetDone: ViewModifier {
    let isShown: Bool
    @Environment(\.closeSheet) private var closeSheet

    func body(content: Content) -> some View {
        content.toolbar {
            if isShown, let closeSheet {
                ToolbarItem(placement: .confirmationAction) {
                    SheetDoneButton(close: closeSheet)
                }
            }
        }
    }
}

/// A sheet's Edit button: a pencil on iOS 26, where the toolbar's buttons are
/// icons (see `SheetCancelButton`), and on the Mac to match; the word on iOS 18.
struct SheetEditButton: View {
    let action: () -> Void

    private static var iconToolbar: Bool {
        if #available(iOS 26, *) { true } else { false }
    }

    var body: some View {
        if Platform.isMac || Self.iconToolbar {
            SheetIconButton(title: "Edit", systemImage: "pencil", action: action)
        } else {
            Button("Edit", action: action)
        }
    }
}

#if targetEnvironment(macCatalyst)
/// What UIKit and SwiftUI have no way to ask of AppKit on Catalyst, reached
/// through the ObjC runtime.
enum AppKit {
    /// The shared NSApplication.
    static var application: NSObject? {
        object(of: "NSApplication", "sharedApplication")
    }

    /// What the AppKit class `className` returns for a selector that takes
    /// nothing and returns an object. Never use it for a void selector.
    static func object(of className: String, _ selector: String) -> NSObject? {
        (NSClassFromString(className) as AnyObject?)?
            .perform(NSSelectorFromString(selector))?.takeUnretainedValue() as? NSObject
    }

    /// Calls a selector that returns void. `perform` would hand back whatever
    /// was left in the return register, so the result is never read.
    static func send(_ selector: String, to target: AnyObject?) {
        guard let target else { return }
        _ = target.perform(NSSelectorFromString(selector))
    }
}

/// The Dock icon's badge, which UIKit only sets to a number.
enum DockBadge {
    /// Discord's dot, for what's unread but doesn't notify. Set after the
    /// badge count, which replaces the label.
    @MainActor static func showDot(_ dot: Bool) {
        let tile = AppKit.application?.value(forKey: "dockTile") as? NSObject
        tile?.perform(NSSelectorFromString("setBadgeLabel:"), with: dot ? "•" : nil)
    }
}

/// Closing the window hides the app, as Hide Yapnest does, where UIKit quits
/// an app that has one window: the session stays connected and notifies, and
/// the Dock icon or a notification brings the same window back.
@MainActor
enum WindowClose {
    private static var observer: (any NSObjectProtocol)?

    /// AppKit's window doesn't exist yet when the app has launched or its
    /// first view appears, so this waits for it to become the main one.
    static func hidesApp() {
        guard observer == nil else { return }
        let becameMain = Notification.Name("NSWindowDidBecomeMainNotification")
        observer = NotificationCenter.default.addObserver(forName: becameMain, object: nil, queue: nil) { note in
            nonisolated(unsafe) let window = note.object as? NSObject
            // Posted on the main thread.
            MainActor.assumeIsolated { answerClose(of: window) }
        }
    }

    /// The red button and File > Close both ask the window's delegate, which
    /// is UIKit's, whether it may close. Quit doesn't, so it still quits.
    private static func answerClose(of window: NSObject?) {
        let shouldClose = NSSelectorFromString("windowShouldClose:")
        guard let delegate = window?.value(forKey: "delegate") as? NSObject, delegate.responds(to: shouldClose),
              let delegateClass = object_getClass(delegate) else { return }
        let hide: @convention(block) (AnyObject, AnyObject?) -> Bool = { _, _ in
            _ = AppKit.application?.perform(NSSelectorFromString("hide:"), with: nil)
            return false
        }
        class_replaceMethod(delegateClass, shouldClose, imp_implementationWithBlock(hide), "B@:@")
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
}

/// AppKit's cursors.
enum MacCursor {
    nonisolated(unsafe) static let pointingHand = cursor("pointingHandCursor")
    nonisolated(unsafe) static let arrow = cursor("arrowCursor")

    private static func cursor(_ name: String) -> NSObject? {
        AppKit.object(of: "NSCursor", name)
    }

    static func set(_ cursor: NSObject?) {
        AppKit.send("set", to: cursor)
    }

    /// Pushes and pops nest, so every push needs its pop.
    static func push(_ cursor: NSObject?) {
        AppKit.send("push", to: cursor)
    }

    static func pop() {
        AppKit.send("pop", to: NSClassFromString("NSCursor"))
    }
}

/// The Mac's character viewer, which fills the field that has focus.
enum CharacterPalette {
    /// Does nothing off the Mac.
    static func show() {
        // UIKit doesn't pass this on, so ask AppKit, as Edit › Emoji &
        // Symbols does, once focus has settled on the field it fills.
        DispatchQueue.main.async {
            AppKit.send("orderFrontCharacterPalette:", to: AppKit.application)
        }
    }
}
#else
enum CharacterPalette {
    static func show() {}
}

/// iOS draws a badge as a number only, so there's no dot on the home screen.
enum DockBadge {
    static func showDot(_ dot: Bool) {}
}
#endif

extension View {
    /// The Mac's pointing hand over something clickable that doesn't look
    /// like a button, such as a chat's header. Nothing elsewhere.
    func pointingHandCursor() -> some View {
        onContinuousHover { phase in
            #if targetEnvironment(macCatalyst)
            // Set on every move, as AppKit puts the arrow back as the pointer
            // crosses other views' tracking areas.
            if case .active = phase { MacCursor.set(MacCursor.pointingHand) } else { MacCursor.set(MacCursor.arrow) }
            #endif
        }
    }
}

/// Like Mac apps that keep the account at the foot of the sidebar.
private struct AccountFooter<Call: View>: View {
    let name: String
    let seed: String
    let imageURL: URL?
    let presence: ContactPresence?
    /// Our status message, or else the availability or connection.
    let status: String?
    let call: Call
    let openProfile: () -> Void
    let openSettings: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            call.padding(.top, 8)
            HStack(spacing: 8) {
                Button(action: openProfile) {
                    HStack(spacing: 8) {
                        AvatarView(name: name, seed: seed, imageURL: imageURL, presence: presence)
                            .frame(width: 34, height: 34)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(name)
                                .lineLimit(1)
                            if let status {
                                Text(status)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Profile")
                Button("Settings", systemImage: "gearshape", action: openSettings)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .background(.bar)
    }
}

private struct AccountFooterModifier<Footer: View>: ViewModifier {
    let footer: Footer
    @Environment(\.desktopLayout) private var desktopLayout

    @ViewBuilder
    func body(content: Content) -> some View {
        if desktopLayout {
            content.safeAreaInset(edge: .bottom, spacing: 0) { footer }
        } else {
            content
        }
    }
}

private struct SidebarSearchModifier: ViewModifier {
    @Binding var text: String
    let onCompose: (() -> Void)?
    let focus: FocusState<Bool>.Binding?
    @Environment(\.desktopLayout) private var desktopLayout

    @ViewBuilder
    func body(content: Content) -> some View {
        if desktopLayout {
            // A plain inset has no background, so rows scroll visibly under
            // the field. A safe area bar's scroll edge effect doesn't hide
            // them on the Mac either, so the bar is drawn solid.
            content.safeAreaInset(edge: .top, spacing: 0) {
                SidebarSearchBar(text: $text, onCompose: onCompose, focus: focus).background(.bar)
            }
        } else {
            content
                .searchable(text: $text, placement: .navigationBarDrawer(displayMode: .automatic))
                .modifier(SearchFocus(focus: focus))
        }
    }
}

/// Focuses the drawer's search field from the caller's state, where there is one.
private struct SearchFocus: ViewModifier {
    let focus: FocusState<Bool>.Binding?

    func body(content: Content) -> some View {
        if let focus { content.searchFocused(focus) } else { content }
    }
}

private struct FieldFocus: ViewModifier {
    let focus: FocusState<Bool>.Binding?

    func body(content: Content) -> some View {
        if let focus { content.focused(focus) } else { content }
    }
}

private struct SidebarSearchBar: View {
    @Binding var text: String
    let onCompose: (() -> Void)?
    let focus: FocusState<Bool>.Binding?

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search", text: $text)
                    .textFieldStyle(.plain)
                    .modifier(FieldFocus(focus: focus))
                if !text.isEmpty {
                    Button("Clear", systemImage: "xmark.circle.fill") { text = "" }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            if let onCompose {
                Button("New Chat", systemImage: "square.and.pencil", action: onCompose)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .font(.title3)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

extension View {
    /// The row with a form's avatar at the top of Settings and a chat's settings.
    func avatarHeaderRow() -> some View {
        // A Mac form row hugs its content, so the picture would touch the row's top.
        padding(.vertical, Platform.isMac ? 8 : 0)
    }

    /// Keeps the Mac window from shrinking until the chat list and a
    /// conversation no longer fit side by side. iOS has no windows to size.
    @ViewBuilder
    func minimumWindowSize(_ size: CGSize) -> some View {
        #if targetEnvironment(macCatalyst)
        onAppear {
            for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
                scene.sizeRestrictions?.minimumSize = size
            }
        }
        #else
        self
        #endif
    }

    /// Takes the title bar's toolbar and title away, so the sidebar and the
    /// chat run to the top of the window, as in Messages, and the chat's
    /// header sits in the band the window buttons share. The compact style
    /// keeps that band short: the default one takes the top 52 points, where
    /// the pointer never reaches the app, which left the header's name with
    /// no pointing hand. It also hides the sidebar button while the chat list
    /// is collapsed, so the Mac's list can't be (`ChatListView`).
    @ViewBuilder
    func hidesWindowToolbar() -> some View {
        #if targetEnvironment(macCatalyst)
        onAppear {
            for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
                scene.titlebar?.titleVisibility = .hidden
                scene.titlebar?.toolbar = nil
                scene.titlebar?.toolbarStyle = .unifiedCompact
                // On macOS 15 the header sits under the band rather than in
                // it (`Platform.headerInTitlebar`), and reads as one bar
                // with it without the line between them.
                if !Platform.headerInTitlebar { scene.titlebar?.separatorStyle = .none }
            }
        }
        #else
        self
        #endif
    }

    /// Keeps the Mac windows looking active when they aren't key. The
    /// inactive appearance fades the accent colour and the chat list, which
    /// makes a window beside the one being typed in look disabled.
    @ViewBuilder
    func alwaysActiveAppearance() -> some View {
        #if targetEnvironment(macCatalyst)
        onAppear {
            for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
                for window in scene.windows {
                    window.traitOverrides.activeAppearance = .active
                }
            }
        }
        #else
        self
        #endif
    }
}
