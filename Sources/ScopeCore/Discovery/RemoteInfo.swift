import Foundation

/// `owner/repo` extracted from a git remote URL, used for display ("acme/api") and org detection.
public struct RemoteInfo: Sendable, Equatable, Hashable {
    /// Host name without user or port; `nil` for local paths.
    public let host: String?
    /// The path component before the repo name (GitHub owner, last GitLab group, parent folder for local paths).
    public let owner: String?
    /// Repo name without a trailing `.git`.
    public let name: String

    /// `"owner/name"`, or just `"name"` when no owner could be determined.
    public var fullName: String { owner.map { "\($0)/\(name)" } ?? name }

    /// Parses the remote forms git accepts:
    ///
    /// - `git@github.com:owner/repo.git` (scp-like)
    /// - `ssh://git@github.com/owner/repo.git`, with an optional `:port`
    /// - `https://github.com/owner/repo(.git)`, with an optional `user@`
    /// - `git://github.com/owner/repo.git`
    /// - `file:///abs/path/repo` and `/abs/path/repo` (owner = parent folder name)
    ///
    /// Returns `nil` for an empty string or a URL without a usable path.
    public init?(remote: String) {
        let raw = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }

        var host: String?
        let path: Substring

        if let schemeRange = raw.range(of: "://") {
            // URL form: scheme://[user@]host[:port]/path
            let scheme = raw[..<schemeRange.lowerBound]
            let rest = raw[schemeRange.upperBound...]
            if scheme == "file" {
                path = rest
            } else if let slash = rest.firstIndex(of: "/") {
                host = Self.hostName(fromAuthority: rest[..<slash])
                path = rest[rest.index(after: slash)...]
            } else {
                return nil
            }
        } else if let colon = raw.firstIndex(of: ":"), !raw[..<colon].contains("/") {
            // scp-like: [user@]host:path
            host = Self.hostName(fromAuthority: raw[..<colon])
            path = raw[raw.index(after: colon)...]
        } else {
            // Local path.
            path = Substring(raw)
        }

        var components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard var last = components.popLast() else { return nil }
        if last.hasSuffix(".git") { last.removeLast(4) }
        guard !last.isEmpty else { return nil }
        self.host = host
        self.name = last
        self.owner = components.last
    }

    /// Strips `user@` and `:port` from an authority. Empty authority → `nil`.
    private static func hostName(fromAuthority authority: Substring) -> String? {
        var host = authority
        if let at = host.lastIndex(of: "@") { host = host[host.index(after: at)...] }
        if let colon = host.lastIndex(of: ":") { host = host[..<colon] }
        return host.isEmpty ? nil : String(host)
    }
}

/// Reads `[remote "origin"] url = …` from a git config file without spawning git.
public enum GitConfigReader {
    /// The `origin` URL declared in `<gitDirectory>/config`, or `nil` when the file or the remote is missing.
    ///
    /// For a worktree, `gitDirectory` is `<common>/worktrees/<name>` which has no `config`; the `commondir`
    /// file there is followed to the shared git directory.
    public static func originURL(gitDirectory: URL) -> String? {
        guard let text = configText(gitDirectory: gitDirectory) else { return nil }
        var inOrigin = false
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inOrigin = line.replacingOccurrences(of: " ", with: "") == "[remote\"origin\"]"
                continue
            }
            guard inOrigin else { continue }
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "url" else { continue }
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /// Contents of the effective `config`: the one in `gitDirectory`, else the one in the common directory
    /// named by `<gitDirectory>/commondir` (worktrees).
    private static func configText(gitDirectory: URL) -> String? {
        if let text = try? String(contentsOf: gitDirectory.appending(path: "config"), encoding: .utf8) {
            return text
        }
        guard let pointer = try? String(contentsOf: gitDirectory.appending(path: "commondir"), encoding: .utf8) else {
            return nil
        }
        let common = pointer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !common.isEmpty else { return nil }
        let commonURL = common.hasPrefix("/")
            ? URL(fileURLWithPath: common, isDirectory: true)
            : gitDirectory.appending(path: common).standardizedFileURL
        return try? String(contentsOf: commonURL.appending(path: "config"), encoding: .utf8)
    }
}
