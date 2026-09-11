import Foundation
import ScopeCore

/// The git directories a task's Delta must watch besides the task root.
///
/// A sandbox is a worktree: its `index` and `HEAD` live in `<base>/.git/worktrees/<name>`, and its branch in the
/// base checkout's shared `refs/` and `packed-refs` — all outside the task root. A commit touches no file of the
/// working tree and a push only moves `refs/remotes/`, so watching the task root alone left the Delta counts stale
/// after either, whoever made them (an agent, or the user in their own terminal).
public struct TaskGitWatch: Sendable, Equatable {
    /// Worktree-private git directories (`<common>/worktrees/<name>`), canonical paths.
    public var gitDirectories: [String]
    /// Shared git directories of the base checkouts, canonical paths. What FSEvents is pointed at.
    public var commonDirectories: [String]
    /// The task's branches, as they appear under `refs/heads/`.
    public var branches: [String]

    public init(gitDirectories: [String], commonDirectories: [String], branches: [String]) {
        self.gitDirectories = gitDirectories
        self.commonDirectories = commonDirectories
        self.branches = branches
    }

    /// Reads each sandbox's `.git` file and its `commondir` without spawning git. A sandbox that is not a
    /// worktree (no `.git`, or a plain clone) contributes its own `.git` directory as both.
    public static func resolve(sandboxes: [URL], branches: [String]) -> TaskGitWatch {
        var gitDirectories: [String] = []
        var commonDirectories: [String] = []
        for sandbox in sandboxes {
            guard let kind = RepoDiscovery.gitKind(at: sandbox) else { continue }
            let gitDirectory: URL
            switch kind {
            case .directory:
                gitDirectory = sandbox.appending(path: ".git", directoryHint: .isDirectory)
            case .file(let gitdir):
                gitDirectory = gitdir.hasPrefix("/")
                    ? URL(fileURLWithPath: gitdir, isDirectory: true)
                    : sandbox.appending(path: gitdir, directoryHint: .isDirectory)
            }
            var commonDirectory = gitDirectory
            if let text = try? String(contentsOf: gitDirectory.appending(path: "commondir"), encoding: .utf8) {
                let common = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !common.isEmpty {
                    commonDirectory = common.hasPrefix("/")
                        ? URL(fileURLWithPath: common, isDirectory: true)
                        : gitDirectory.appending(path: common, directoryHint: .isDirectory)
                }
            }
            gitDirectories.append(canonical(gitDirectory))
            let common = canonical(commonDirectory)
            if !commonDirectories.contains(common) { commonDirectories.append(common) }
        }
        return TaskGitWatch(gitDirectories: gitDirectories, commonDirectories: commonDirectories,
                            branches: Array(Set(branches)).sorted())
    }

    /// Folders to hand to FSEvents besides the task root. The worktree directories live inside them.
    public var watchedDirectories: [URL] {
        commonDirectories.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// Whether a change at `path` can move the Delta: `nil` when the path is not under a watched git directory
    /// (the caller's own rules apply), otherwise `true` for this task's `index` / `HEAD`, its branches, the packed
    /// refs and the remote-tracking refs, and `false` for the rest (objects, logs, other worktrees).
    public func relevance(of path: String) -> Bool? {
        guard let common = commonDirectories.first(where: { path.hasPrefix($0 + "/") }) else { return nil }
        for gitDirectory in gitDirectories where path.hasPrefix(gitDirectory + "/") {
            let inside = path.dropFirst(gitDirectory.count + 1)
            return inside == "index" || inside == "HEAD"
        }
        let inside = String(path.dropFirst(common.count + 1))
        if inside == "packed-refs" || inside.hasPrefix("refs/remotes/") { return true }
        return branches.contains { inside == "refs/heads/\($0)" || inside == "refs/heads/\($0).lock" }
    }

    /// `realpath(3)`: FSEvents reports `/private/var/…` where `URL` may say `/var/…`.
    static func canonical(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
