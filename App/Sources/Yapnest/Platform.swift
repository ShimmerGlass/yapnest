import SwiftUI

extension EnvironmentValues {
    /// `Platform.usesDesktopLayout` for the window a view is in, set at the
    /// root from its size class. The Mac's title bar can't hold a picture, so
    /// there a chat's header takes the top of the window, as in Messages.
    @Entry var desktopLayout = Platform.isMac
}

/// The rest of `Platform` (`isMac` is in `App/Shared`, for the share extension).
extension Platform {
    /// An iPad, whose window can turn wide or narrow while the app runs.
    @MainActor static let isPad = UIDevice.current.userInterfaceIdiom == .pad

    /// Whether the message list is turned upside down, with each row turned
    /// back, so the newest message is where the scroll view rests. The
    /// software keyboard moves the list's room on iOS, which a list anchored to
    /// its far end follows badly. The Mac has no keyboard to follow, and a
    /// flipped scroll view would invert its scroll wheel.
    static let flipsMessageList = !isMac

    /// The Mac has no suspension to wait out, so its session stays connected
    /// in the background.
    static let staysConnected = isMac

    /// Whether the layout is the Mac's: the chat list always beside the open
    /// chat, the chat's own header in place of the navigation bar, and the
    /// account at the foot of the sidebar. An iPad has it while its window is
    /// wide; a narrow one (Slide Over, a slim Split View) keeps the phone's stack.
    static func usesDesktopLayout(isMac: Bool, isPad: Bool, sizeClass: UserInterfaceSizeClass?) -> Bool {
        isMac || (isPad && sizeClass == .regular)
    }

    /// Whether the chat's header goes in the title bar's band, beside the
    /// window buttons. macOS 15 draws that band over the window's content,
    /// opaque and with a line under it, which cut the header in half, so
    /// there the header starts below it.
    static var headerInTitlebar: Bool {
        if #available(iOS 26, *) { isMac } else { false }
    }

    /// Whether any of the app's windows can be seen. On the Mac the app can
    /// stay active with its window out of sight: the screen locked or asleep,
    /// the window on another Space or covered whole. UIKit says nothing of
    /// that, so this asks AppKit's occlusion state. iOS has its own window
    /// in front whenever the app is active.
    static var isWindowVisible: Bool {
        #if targetEnvironment(macCatalyst)
        guard let app = AppKit.application,
              let state = app.value(forKey: "occlusionState") as? UInt else { return true }
        // NSApplication.OcclusionState.visible
        return state & (1 << 1) != 0
        #else
        true
        #endif
    }

    /// Posted when `isWindowVisible` may have changed. iOS never posts it.
    static let windowVisibilityDidChange = Notification.Name("NSApplicationDidChangeOcclusionStateNotification")

    /// Whether the app is the one in front on the Mac, its window the one
    /// that has focus. UIKit's scene doesn't resign active when another app
    /// is clicked, so this asks AppKit. Always true elsewhere.
    static var isAppFocused: Bool {
        #if targetEnvironment(macCatalyst)
        (AppKit.application?.value(forKey: "active") as? Bool) ?? true
        #else
        true
        #endif
    }

    /// Posted by AppKit when the Mac app comes to the front, and when it
    /// leaves it. iOS never posts them.
    static let appDidGainFocus = Notification.Name("NSApplicationDidBecomeActiveNotification")
    static let appDidLoseFocus = Notification.Name("NSApplicationDidResignActiveNotification")

    /// The page of the system's settings where `pane` ("Privacy_Microphone")
    /// is switched on or off. The Mac has panes of its own; elsewhere it is
    /// the app's page.
    static func privacySettingsURL(_ pane: String) -> URL? {
        URL(string: isMac ? "x-apple.systempreferences:com.apple.preference.security?\(pane)" : UIApplication.openSettingsURLString)
    }
}
