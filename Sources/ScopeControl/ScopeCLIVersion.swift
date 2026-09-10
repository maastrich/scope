import Foundation

/// What `scope --version` prints, and what the app records as the client of a request.
///
/// The tool ships inside the app bundle at `Scope.app/Contents/Helpers/scope`, and the version of Scope is
/// the version of its command line: rather than stamping a number at build time (the release pipeline puts
/// it in the bundle, not in the tool), the binary reads it from the `Info.plist` three levels up. Outside a
/// bundle — a `swift build`, a copy somewhere else — it is `dev`.
public enum ScopeCLIVersion {
    public static let current: String = resolve()

    /// `SCOPE_CLI_VERSION` wins (tests, packaging experiments), then the enclosing app bundle.
    public static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment,
                        executable: String = CommandLine.arguments.first ?? "") -> String {
        if let override = environment["SCOPE_CLI_VERSION"], !override.isEmpty { return override }
        return bundleVersion(forExecutableAt: executable) ?? "dev"
    }

    /// `<…>/Scope.app/Contents/Helpers/scope` → `<…>/Scope.app/Contents/Info.plist`.
    public static func bundleVersion(forExecutableAt path: String) -> String? {
        guard !path.isEmpty else { return nil }
        let executable = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let helpers = executable.deletingLastPathComponent()
        guard helpers.lastPathComponent == "Helpers" else { return nil }
        let plist = helpers.deletingLastPathComponent().appending(path: "Info.plist", directoryHint: .notDirectory)
        guard let data = try? Data(contentsOf: plist),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let version = info["CFBundleShortVersionString"] as? String, !version.isEmpty
        else { return nil }
        return version
    }
}
