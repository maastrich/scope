import Foundation
import ScopeCore

/// A usable git executable and where it came from.
public struct GitInstallation: Sendable, Hashable {
    /// How the executable was chosen.
    public enum Source: String, Sendable, Hashable {
        /// The path set by the user in Preferences.
        case override
        /// `/usr/bin/git`, backed by the Xcode Command Line Tools.
        case commandLineTools
        /// A Homebrew git (`/opt/homebrew/bin/git` on Apple silicon, `/usr/local/bin/git` on Intel).
        case homebrew
    }

    /// Absolute path of the executable.
    public let path: String
    public let source: Source

    public init(path: String, source: Source) {
        self.path = path
        self.source = source
    }
}

/// No usable git executable was found. `title` and `detail` are ready to become a `Problem`.
public struct GitLocatorError: Error, Sendable, Hashable, CustomStringConvertible {
    /// Every path that was considered, in order.
    public let searched: [String]
    /// Set when the user override was given but is not an executable file.
    public let unusableOverride: String?

    public init(searched: [String], unusableOverride: String? = nil) {
        self.searched = searched
        self.unusableOverride = unusableOverride
    }

    public var title: String { "git is not available" }

    public var detail: String {
        var lines: [String] = []
        if let unusableOverride {
            lines.append("The git path set in Settings is not an executable file: \(unusableOverride)")
        }
        lines.append("None of these locations has a usable git:")
        lines.append(contentsOf: searched.map { "  \($0)" })
        lines.append("Install the Xcode Command Line Tools (xcode-select --install) or Homebrew git, or set the git path in Settings.")
        return lines.joined(separator: "\n")
    }

    public var description: String {
        "\(title): searched \(searched.joined(separator: ", "))"
    }
}

/// Finds the git executable Scope should use.
///
/// Order:
/// 1. the user override, when set and executable (an explicit choice always wins);
/// 2. `/usr/bin/git`, only when `xcode-select -p` succeeds — without the Command Line Tools
///    that path is a stub which pops the CLT install dialog on every invocation;
/// 3. Homebrew git (`/opt/homebrew/bin/git`, then `/usr/local/bin/git`).
///
/// Everything is configurable so tests can point the locator at stub paths.
public struct GitLocator: Sendable {
    /// The system git shipped with the Command Line Tools.
    public static let systemGit = "/usr/bin/git"
    /// Homebrew prefixes, Apple silicon first.
    public static let homebrewGits = ["/opt/homebrew/bin/git", "/usr/local/bin/git"]

    public var systemGitPath: String
    public var homebrewPaths: [String]
    public var xcodeSelectPath: String
    /// `xcode-select -p` is instantaneous; a longer run means something is very wrong.
    public var probeTimeout: Duration

    public init(
        systemGitPath: String = GitLocator.systemGit,
        homebrewPaths: [String] = GitLocator.homebrewGits,
        xcodeSelectPath: String = "/usr/bin/xcode-select",
        probeTimeout: Duration = .seconds(5)
    ) {
        self.systemGitPath = systemGitPath
        self.homebrewPaths = homebrewPaths
        self.xcodeSelectPath = xcodeSelectPath
        self.probeTimeout = probeTimeout
    }

    /// Resolves the git executable to use.
    ///
    /// - Parameter override: the path from Preferences, `~` allowed; ignored when empty or not executable.
    /// - Throws: `GitLocatorError` when nothing usable exists; surface it as a `Problem`.
    public func locate(override: String? = nil) async throws -> GitInstallation {
        var searched: [String] = []
        var unusableOverride: String?

        let trimmed = override?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty {
            let expanded = NSString(string: trimmed).expandingTildeInPath
            searched.append(expanded)
            if Self.isExecutable(expanded) {
                return GitInstallation(path: expanded, source: .override)
            }
            unusableOverride = expanded
        }

        searched.append(systemGitPath)
        if Self.isExecutable(systemGitPath), await commandLineToolsInstalled() {
            return GitInstallation(path: systemGitPath, source: .commandLineTools)
        }

        for candidate in homebrewPaths {
            searched.append(candidate)
            if Self.isExecutable(candidate) {
                return GitInstallation(path: candidate, source: .homebrew)
            }
        }

        let error = GitLocatorError(searched: searched, unusableOverride: unusableOverride)
        Log.git.error("\(error.description, privacy: .public)")
        throw error
    }

    /// `true` when `xcode-select -p` exits 0, i.e. an active developer directory (CLT or Xcode) exists.
    public func commandLineToolsInstalled() async -> Bool {
        guard Self.isExecutable(xcodeSelectPath) else { return false }
        do {
            let result = try await Subprocess.run(
                executable: xcodeSelectPath, arguments: ["-p"], timeout: probeTimeout
            )
            return result.succeeded
        } catch {
            return false
        }
    }

    /// `true` for an existing, executable, non-directory path.
    public static func isExecutable(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return false
        }
        return FileManager.default.isExecutableFile(atPath: path)
    }
}
