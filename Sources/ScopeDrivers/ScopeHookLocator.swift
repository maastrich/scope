import Foundation

/// Finds the `scope-hook` binary a driver's hooks must call.
///
/// The app embeds it at `Scope.app/Contents/Helpers/scope-hook`; when that is absent (SwiftPM build,
/// tests) the login-shell PATH is searched, and as a last resort the bare name is used so the hook still
/// works for a user who put `scope-hook` on their own PATH later.
public enum ScopeHookLocator {
    /// File name of the helper.
    public static let name = "scope-hook"
    /// Where the app bundle embeds it, relative to the bundle root.
    public static let bundleSubpath = "Contents/Helpers/scope-hook"

    /// The absolute path when it can be found, else the bare name.
    /// - Parameters:
    ///   - bundleURL: the running app bundle (`Bundle.main.bundleURL`); `nil` outside an app.
    ///   - searchPATH: the login-shell PATH (`ResolvedShellEnvironment.path`).
    public static func locate(bundleURL: URL?, searchPATH: String) -> String {
        embedded(in: bundleURL) ?? ExecutableResolver.resolve(name, path: searchPATH, shell: "/bin/sh") ?? name
    }

    /// `<bundle>/Contents/Helpers/scope-hook` when it exists and is executable.
    public static func embedded(in bundleURL: URL?) -> String? {
        guard let bundleURL else { return nil }
        let path = bundleURL.appending(path: bundleSubpath).path
        return ExecutableResolver.isExecutableFile(path) ? path : nil
    }
}
