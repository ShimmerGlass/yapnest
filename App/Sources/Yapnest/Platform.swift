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
}
