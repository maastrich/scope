import Foundation

/// The branches a checkout has been on, read off its reflog: where a task's threads may have opened pull requests
/// besides the task branch — a docs branch next to the prototype's, the next branch of a stack.
public enum VisitedBranches {
    /// How far back the reflog is read; a sandbox older than that has long found its pull requests.
    public static let reflogLimit = 400
    /// How many branches a refresh asks GitHub about, beyond the current one: one `gh` call each.
    public static let limit = 6

    /// The branch names in `reflogSubjects` (`git reflog --format=%gs` lines, newest first), most recently visited
    /// first, without `current` and `excluding` (the default branch), at most `limit`. Only `checkout: moving from A
    /// to B` lines name branches; a commit sha where a branch would be is a detached head and is skipped.
    public static func parse(reflogSubjects: [String], current: String?, excluding: Set<String> = [], limit: Int = limit) -> [String] {
        var seen = Set<String>()
        var branches: [String] = []
        for line in reflogSubjects {
            guard line.hasPrefix("checkout: moving from "), let to = line.range(of: " to ", options: .backwards) else { continue }
            let from = String(line[line.index(line.startIndex, offsetBy: "checkout: moving from ".count)..<to.lowerBound])
            let target = String(line[to.upperBound...])
            for name in [target, from] where !isSHA(name) && name != current && !excluding.contains(name) && !seen.contains(name) {
                seen.insert(name)
                branches.append(name)
            }
            if branches.count >= limit { break }
        }
        return Array(branches.prefix(limit))
    }

    static func isSHA(_ name: String) -> Bool {
        name.count >= 7 && name.allSatisfy { $0.isHexDigit }
    }
}

public extension GitClient {
    /// `VisitedBranches.parse` on this checkout's reflog, `at` a worktree of it.
    func visitedBranches(at worktree: URL? = nil, current: String?, excluding: Set<String> = []) async throws -> [String] {
        var arguments: [String] = []
        if let worktree { arguments += ["-C", worktree.filesystemPath] }
        arguments += ["reflog", "show", "--format=%gs", "-n", String(VisitedBranches.reflogLimit)]
        let result = try await run(arguments, timeout: .seconds(10), allowFailure: true)
        guard result.succeeded else { return [] }
        let lines = result.stdoutText.split(separator: "\n").map(String.init)
        return VisitedBranches.parse(reflogSubjects: lines, current: current, excluding: excluding)
    }
}
