import Foundation

/// Where the app differs between iOS and the Mac (Catalyst, Mac idiom).
/// This is the one place that asks which it is for a value; code that needs
/// a Mac-only API still has to be compiled out where it uses it.
enum Platform {
    #if targetEnvironment(macCatalyst)
    static let isMac = true
    #else
    static let isMac = false
    #endif
}
