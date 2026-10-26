import SwiftUI

/// Where the app differs between iOS and the Mac (Catalyst, Mac idiom).
/// This is the one place that asks which it is for a value; code that needs
/// a Mac-only API still has to be compiled out where it uses it.
enum Platform {
    #if targetEnvironment(macCatalyst)
    static let isMac = true
    #else
    static let isMac = false
    #endif

    /// Whether the message list is turned upside down, with each row turned
    /// back, so the newest message is where the scroll view rests. The
    /// software keyboard moves the list's room on iOS, which a list anchored to
    /// its far end follows badly. The Mac has no keyboard to follow, and a
    /// flipped scroll view would invert its scroll wheel.
    static let flipsMessageList = !isMac

    /// The Mac has no suspension to wait out, so its session stays connected
    /// in the background.
    static let staysConnected = isMac

    /// The title bar can't hold a picture, so the Mac has none, and a chat's
    /// own header takes the top of the window, as in Messages.
    static let usesChatHeader = isMac

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
        guard let app = (NSClassFromString("NSApplication") as? NSObject.Type)?.value(forKey: "sharedApplication") as? NSObject,
              let state = app.value(forKey: "occlusionState") as? UInt else { return true }
        // NSApplication.OcclusionState.visible
        return state & (1 << 1) != 0
        #else
        true
        #endif
    }

    /// Posted when `isWindowVisible` may have changed. iOS never posts it.
    static let windowVisibilityDidChange = Notification.Name("NSApplicationDidChangeOcclusionStateNotification")

    /// The page of the system's settings where `pane` ("Privacy_Microphone")
    /// is switched on or off. The Mac has panes of its own; elsewhere it is
    /// the app's page.
    static func privacySettingsURL(_ pane: String) -> URL? {
        URL(string: isMac ? "x-apple.systempreferences:com.apple.preference.security?\(pane)" : UIApplication.openSettingsURLString)
    }
}
