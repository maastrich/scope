import Foundation

/// Finds the `scope` command line tool the app ships and the folder it lives in.
///
/// The app embeds it beside `scope-hook` at `Scope.app/Contents/Helpers/scope`. That folder goes first on
/// the `PATH` of every thread, so an agent running inside Scope can call `scope` — and reach the MCP server
/// with `scope mcp` — without anything being installed or configured. For the user's own terminal, the app
/// offers to symlink it (see `CLIInstaller`).
public enum ScopeCLILocator {
    /// File name of the tool.
    public static let name = "scope"
    /// Where the app bundle embeds the helpers.
    public static let helpersSubpath = "Contents/Helpers"

    /// `<bundle>/Contents/Helpers` when it exists; `nil` outside an app bundle (SwiftPM build, tests).
    public static func helpersDirectory(in bundleURL: URL?) -> String? {
        guard let bundleURL else { return nil }
        let path = bundleURL.appending(path: helpersSubpath, directoryHint: .isDirectory).path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        return path
    }

    /// `<bundle>/Contents/Helpers/scope` when it is there and executable.
    public static func embedded(in bundleURL: URL?) -> String? {
        guard let directory = helpersDirectory(in: bundleURL) else { return nil }
        let path = directory + "/" + name
        return ExecutableResolver.isExecutableFile(path) ? path : nil
    }
}
