import Foundation

extension GitClient {
    /// Commits of the worktree's `HEAD` that would be lost with it: on no remote, and in no pull request whose head
    /// is in `pullRequestHeads`. `nil` when git cannot say.
    ///
    /// The pull request heads come first: once a pull request is squash-merged, GitHub deletes its branch and the next
    /// `fetch --prune` drops `origin/<branch>`, so its commits sit on no remote any more although they all landed.
    /// A head this clone never fetched (pushed from elsewhere) is skipped rather than failing the count. Without a
    /// usable head, the branch's upstream; without one, every remote.
    public func unpushedCommits(at worktree: URL, pullRequestHeads: [String] = []) async -> Int? {
        let c = ["-C", worktree.filesystemPath]
        var heads: [String] = []
        for head in pullRequestHeads where !heads.contains(head) {
            let known = try? await run(c + ["cat-file", "-e", "\(head)^{commit}"], timeout: .seconds(30), allowFailure: true)
            if known?.succeeded == true { heads.append(head) }
        }
        func count(_ arguments: [String]) async -> Int? {
            guard let result = try? await run(c + ["rev-list", "--count"] + arguments, timeout: .seconds(30), allowFailure: true),
                  result.succeeded else { return nil }
            return Int(result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if !heads.isEmpty { return await count(["HEAD"] + heads.map { "^" + $0 }) }
        if let ahead = await count(["@{upstream}..HEAD"]) { return ahead }
        return await count(["HEAD", "--not", "--remotes"])
    }
}
