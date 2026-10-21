import SwiftUI
import YapnestKit

/// The Mac's window chrome, as modifiers that do nothing on iOS so the
/// views using them have one line per seam.
extension View {
    /// Who you're signed in as, with Settings, at the foot of the sidebar.
    /// iOS has the same button in the navigation bar instead.
    @ViewBuilder
    func accountFooter(name: String, seed: String, imageURL: URL?, presence: ContactPresence?, status: String?, openSettings: @escaping () -> Void) -> some View {
        if Platform.isMac {
            safeAreaInset(edge: .bottom, spacing: 0) {
                AccountFooter(name: name, seed: seed, imageURL: imageURL, presence: presence, status: status, openSettings: openSettings)
            }
        } else {
            self
        }
    }

    /// The list's search field. A drawer search field can't have a button
    /// beside it, so the Mac draws its own with New Chat next to it.
    @ViewBuilder
    func sidebarSearch(text: Binding<String>, onCompose: (() -> Void)?) -> some View {
        if Platform.isMac {
            // A plain inset has no background, so rows scroll visibly under
            // the field. A safe area bar's scroll edge effect doesn't hide
            // them on the Mac either, so the bar is drawn solid.
            safeAreaInset(edge: .top, spacing: 0) {
                SidebarSearchBar(text: text, onCompose: onCompose).background(.bar)
            }
        } else {
            searchable(text: text, placement: .navigationBarDrawer(displayMode: .automatic))
        }
    }

    /// The chat's name as the Mac window's title, for the Window menu. The
    /// title bar doesn't show it (`hidesWindowToolbar()`); the header does.
    @ViewBuilder
    func windowTitle(_ title: String) -> some View {
        if Platform.isMac { navigationTitle(title) } else { self }
    }
}

/// A toolbar button drawn as its icon, with the title for VoiceOver and, on
/// the Mac, as a tooltip.
private struct SheetIconButton: View {
    let title: LocalizedStringKey
    let systemImage: String
    let action: () -> Void

    @ViewBuilder
    var body: some View {
        let button = Button(action: action) { Label(title, systemImage: systemImage) }
            .labelStyle(.iconOnly)
        if Platform.isMac { button.help(title) } else { button }
    }
}

/// A sheet's Cancel button. On the Mac Esc closes the sheet through it. On
/// iOS 26 it is the system's close icon, as in iOS 26's own sheets: a long
/// translated title between two text buttons gets cut short. The word stays
/// as the label VoiceOver reads.
struct SheetCancelButton: View {
    let action: () -> Void

    var body: some View {
        if #available(iOS 26, *), !Platform.isMac {
            SheetIconButton(title: "Cancel", systemImage: "xmark", action: action)
                .keyboardShortcut(.cancelAction)
        } else {
            Button("Cancel", action: action)
                .keyboardShortcut(.cancelAction)
        }
    }
}

/// A sheet's confirmation button. Catalyst draws it as a prominent button
/// filled with the accent colour and picks black for the title, where the
/// message bubbles correctly use white on it. iOS 18 draws plain tinted text,
/// which must stay that way. iOS 26 shows the system's prominent checkmark
/// for the same reason as `SheetCancelButton`, and keeps the word for
/// VoiceOver.
struct SheetConfirmButton: View {
    let title: LocalizedStringKey
    let action: () -> Void

    init(_ title: LocalizedStringKey, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    @ViewBuilder
    var body: some View {
        if Platform.isMac {
            Button(title, action: action).foregroundStyle(.white)
        } else if #available(iOS 26, *) {
            Button(action: action) { Label(title, systemImage: "checkmark") }
                .labelStyle(.iconOnly)
                .buttonStyle(.glassProminent)
        } else {
            Button(title, action: action)
        }
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
private enum AppKit {
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
            AppKit.send("orderFrontCharacterPalette:", to: AppKit.object(of: "NSApplication", "sharedApplication"))
        }
    }
}
#else
enum CharacterPalette {
    static func show() {}
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
private struct AccountFooter: View {
    let name: String
    let seed: String
    let imageURL: URL?
    let presence: ContactPresence?
    /// Our status message, or else the availability or connection.
    let status: String?
    let openSettings: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                Button(action: openSettings) {
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
                .accessibilityLabel("Settings")
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

private struct SidebarSearchBar: View {
    @Binding var text: String
    let onCompose: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search", text: $text)
                    .textFieldStyle(.plain)
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
