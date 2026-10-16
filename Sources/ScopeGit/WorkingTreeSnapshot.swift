import Foundation
import ScopeCore

/// A commit of a checkout's working tree — tracked and untracked files, ignored ones excluded — made through a private
/// index, so the checkout's own index and the shared stash are never touched. What a salvage and a checkpoint have in
/// common; both leave the branch where it was and keep the commit under a ref of their own.
public enum WorkingTreeSnapshot {
    /// Untracked files bigger than this stay out: a dump or a build output an agent left behind would otherwise sit
    /// in the user's repository for as long as the ref lives. They are named instead.
    public static let fileLimit = 50 * 1024 * 1024

    /// The tree written for a checkout.
    public struct Tree: Sendable, Equatable {
        /// The tree object's hash, which says whether anything changed since another snapshot.
        public var hash: String
        /// Untracked files left out for their size, as paths relative to the checkout.
        public var skipped: [String]

        public init(hash: String, skipped: [String]) {
            self.hash = hash
            self.skipped = skipped
        }
    }

    static let identity = ["GIT_AUTHOR_NAME": "Scope", "GIT_AUTHOR_EMAIL": "scope@localhost",
                           "GIT_COMMITTER_NAME": "Scope", "GIT_COMMITTER_EMAIL": "scope@localhost"]

    /// Stages the working tree of `checkout` into a private index and writes the tree object. Nothing in the
    /// checkout moves. `client` may belong to the base repository: every command runs with `-C <checkout>`.
    public static func writeTree(of checkout: URL, using client: GitClient) async throws -> Tree {
        let path = checkout.filesystemPath
        let index = FileManager.default.temporaryDirectory.appending(path: "scope-snapshot-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: index) }
        let environment = ["GIT_INDEX_FILE": index.path]
        try await client.run(["-C", path, "read-tree", "HEAD"], environment: environment)
        let untracked = try await client.run(["-C", path, "ls-files", "-o", "--exclude-standard", "-z"])
            .stdoutText.split(separator: "\0").map(String.init)
        let tooBig = untracked.filter { name in
            let size = (try? FileManager.default.attributesOfItem(atPath: checkout.appending(path: name).path)[.size] as? Int) ?? 0
            return size > fileLimit
        }
        try await client.run(["-C", path, "add", "-A"], environment: environment, timeout: .seconds(600))
        if !tooBig.isEmpty {
            try await client.run(["-C", path, "rm", "--cached", "-q", "--"] + tooBig, environment: environment)
        }
        let hash = try await client.run(["-C", path, "write-tree"], environment: environment)
            .stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        return Tree(hash: hash, skipped: tooBig)
    }

    /// Commits `tree` on top of `parent` (the checkout's `HEAD` by default), authored by Scope, and points `ref` at
    /// the commit. The hash of the commit.
    @discardableResult
    public static func commit(tree: String, parent: String = "HEAD", message: String, ref: String,
                              in checkout: URL, using client: GitClient) async throws -> String {
        let path = checkout.filesystemPath
        let commit = try await client.run(["-C", path, "commit-tree", tree, "-p", parent, "-m", message], environment: identity)
            .stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        try await client.run(["-C", path, "update-ref", ref, commit])
        return commit
    }

    /// `(+N, −M)` between two trees, every file summed.
    public static func counts(from old: String, to new: String, in checkout: URL, using client: GitClient) async throws -> (additions: Int, deletions: Int) {
        let result = try await client.run(["-C", checkout.filesystemPath, "diff", "--numstat", "-z", "-M", old, new])
        return DiffParser.parseNumstat(result.stdout).values.reduce((0, 0)) { total, entry in
            (total.0 + (entry.additions ?? 0), total.1 + (entry.deletions ?? 0))
        }
    }

    /// The files that differ between two trees, with their hunks (`Delta`'s parser), sorted by path.
    public static func diff(from old: String, to new: String, in checkout: URL, using client: GitClient) async throws -> [DiffFile] {
        let c = ["-C", checkout.filesystemPath]
        let patch = try await client.run(c + Delta.diffArguments + [old, new], timeout: Delta.commandTimeout)
        var files = DiffParser.parse(patch.stdoutText)
        if let stats = try? await client.run(c + Delta.diffArguments + ["--numstat", "-z", old, new], timeout: Delta.commandTimeout) {
            files = DiffParser.merge(files, numstat: DiffParser.parseNumstat(stats.stdout))
        }
        return files.sorted { $0.path < $1.path }
    }
}

extension DiffFile {
    /// The file as a unified patch, rebuilt from its parsed hunks: what the clipboard gets, and what a fenced
    /// `diff` block shows.
    public var unifiedPatch: String {
        var lines: [String] = []
        let old = status == .added ? "/dev/null" : "a/\(oldPath ?? path)"
        let new = status == .deleted ? "/dev/null" : "b/\(path)"
        lines.append("diff --git a/\(oldPath ?? path) b/\(path)")
        lines.append("--- \(old)")
        lines.append("+++ \(new)")
        for hunk in hunks {
            lines.append(hunk.header)
            for line in hunk.lines {
                switch line.kind {
                case .context: lines.append(" " + line.text)
                case .addition: lines.append("+" + line.text)
                case .deletion: lines.append("-" + line.text)
                case .noNewline: lines.append("\\ No newline at end of file")
                }
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
