import Foundation

/// Which app this binary is. A Debug build is a different app from the installed one — its own bundle id, name,
/// home and socket — and the few places that must behave differently ask here rather than each growing an
/// `#if DEBUG` of their own.
enum BuildFlavor {
    #if DEBUG
    static let isDebug = true
    #else
    static let isDebug = false
    #endif

    /// `Scope`, or `Scope Debug`: what the Dock and the app switcher already call this build. Anything else the
    /// app names itself in (a window title, the answer to `scope ping`) uses it, so a Debug build never
    /// presents itself as the installed copy.
    static let displayName: String = (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
        .flatMap { $0.isEmpty ? nil : $0 } ?? (isDebug ? "Scope Debug" : "Scope")
}
