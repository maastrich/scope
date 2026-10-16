import Foundation
import ScopeCore
import ScopeGit

/// Where a task stands against the default branch, every repository folded into one: what the Pull Request section,
/// the hover card and `scope list tasks` show, and what `FollowMain.decide` reads.
public struct TaskLag: Sendable, Equatable {
    /// The measure of each active repository, by its path relative to the scope root.
    public var repos: [String: BranchLag]

    public init(repos: [String: BranchLag] = [:]) {
        self.repos = repos
    }

    /// The largest lag among the repositories: how far main moved since the task forked.
    public var behind: Int { repos.values.map(\.behind).max() ?? 0 }
    /// Paths in conflict over every repository.
    public var conflicts: Int { repos.values.reduce(0) { $0 + $1.conflicts.count } }
    public var isBehind: Bool { behind > 0 }
    public var hasConflicts: Bool { conflicts > 0 }
    /// `false` when any repository could not run the dry merge: a clean report then means nothing.
    public var conflictsKnown: Bool { repos.values.allSatisfy(\.conflictsKnown) }
    /// `repo:sha` for every repository, sorted: one string naming where main stands, stable across measures.
    public var upstreamHead: String {
        repos.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value.upstreamHead)" }.joined(separator: " ")
    }
    /// `origin/main` when every repository agrees, the first otherwise.
    public var upstream: String { repos.sorted { $0.key < $1.key }.first?.value.upstream ?? "origin/main" }
    /// The pull requests merged into main since the task forked, over every repository.
    public var mergedPullRequests: [Int] {
        var numbers: [Int] = []
        for lag in repos.sorted(by: { $0.key < $1.key }).map(\.value) {
            for number in lag.mergedPullRequests where !numbers.contains(number) { numbers.append(number) }
        }
        return numbers
    }
    /// The conflicted paths, prefixed by the repository when the task has several.
    public var conflictedPaths: [String] {
        repos.sorted { $0.key < $1.key }.flatMap { repo, lag in
            lag.conflicts.map { repos.count > 1 && repo != "." ? "\(repo)/\($0)" : $0 }
        }
    }

    /// `behind main by 4 · conflicts in 2 files`, `behind main by 4`, `up to date with main`; `nil` with no measure.
    public var caption: String? {
        guard !repos.isEmpty else { return nil }
        let branch = upstream.split(separator: "/", maxSplits: 1).last.map(String.init) ?? upstream
        guard isBehind else { return "up to date with \(branch)" }
        var parts = ["behind \(branch) by \(behind)"]
        if hasConflicts { parts.append("conflicts in \(conflicts) file\(conflicts == 1 ? "" : "s")") }
        else if !conflictsKnown { parts.append("conflicts unknown") }
        return parts.joined(separator: " · ")
    }
}

/// What Scope does for one task when main has moved: the decision alone, from plain values, so every branch of it
/// is under test without git or GitHub.
public enum FollowMain: Sendable, Equatable {
    /// Nothing: up to date, held, already acted on for this head, or the preference says never.
    case leave(String)
    /// Tell the task's thread that main moved and ask it to rebase.
    case askAgent
    /// Rebase the sandbox and push with lease.
    case rebase

    public struct Facts: Sendable, Equatable {
        public var lag: TaskLag?
        /// GitHub's word on the pull request, when the task has one that is open; `nil` without.
        public var pullRequestMergeable: PullRequest.Mergeable?
        /// The pull request is merged or closed: the branch is history, nothing follows main any more.
        public var pullRequestSettled: Bool
        public var holdBranch: Bool
        /// A thread of the task is mid-turn: the sandbox is someone's desk right now.
        public var threadRunning: Bool
        /// `TaskRecord.followedMainHead`.
        public var actedOnHead: String?

        public init(lag: TaskLag?, pullRequestMergeable: PullRequest.Mergeable? = nil, pullRequestSettled: Bool = false,
                    holdBranch: Bool = false, threadRunning: Bool = false, actedOnHead: String? = nil) {
            self.lag = lag
            self.pullRequestMergeable = pullRequestMergeable
            self.pullRequestSettled = pullRequestSettled
            self.holdBranch = holdBranch
            self.threadRunning = threadRunning
            self.actedOnHead = actedOnHead
        }
    }

    /// The background decision. `onDemand` is `scope task rebase` and the context menu: the preference and the
    /// "once per head" memory step aside, the hold does not — the user set it, the user lifts it.
    public static func decide(_ facts: Facts, mode: FollowMainMode, onDemand: Bool = false) -> FollowMain {
        if facts.holdBranch { return .leave("the branch is held: Don't rebase automatically") }
        if facts.pullRequestSettled { return .leave("its pull request is merged or closed") }
        if !onDemand, mode == .never { return .leave("Settings ▸ Tasks ▸ When main moves is Never") }
        let behind = facts.lag?.isBehind ?? false
        let conflicts = (facts.lag?.hasConflicts ?? false) || facts.pullRequestMergeable == .conflicting
        guard behind || conflicts else { return .leave("up to date with main") }
        if !onDemand, let head = facts.lag?.upstreamHead, head == facts.actedOnHead {
            return .leave("already acted on this head of main")
        }
        if conflicts { return .askAgent }
        // Behind, no conflict known. A dry merge that could not run is treated as a conflict: the agent can tell.
        if facts.lag?.conflictsKnown == false { return .askAgent }
        switch mode {
        case .rebaseWhenClean, .never:
            return facts.threadRunning ? .leave("a thread is at work in the task") : .rebase
        case .askAgent:
            // On demand, a clean lag is rebased whatever the preference: that is what was asked for.
            return onDemand ? (facts.threadRunning ? .leave("a thread is at work in the task") : .rebase)
                            : .leave("behind without conflicts: the agent rebases when it pushes")
        }
    }
}

/// What a task's thread is told when main moved: pure text, under test.
public enum FollowMainPrompts {
    /// `main moved (4 commits, merged: #12, #15). Rebase on origin/main, …`
    public static func mainMoved(lag: TaskLag, conflictsFromGitHub: Bool = false) -> String {
        let base = lag.upstream
        let branch = base.split(separator: "/", maxSplits: 1).last.map(String.init) ?? base
        var head = "\(branch) moved"
        var details: [String] = []
        if lag.isBehind { details.append("\(lag.behind) commit\(lag.behind == 1 ? "" : "s")") }
        let merged = lag.mergedPullRequests
        if !merged.isEmpty { details.append("merged: " + merged.map { "#\($0)" }.joined(separator: ", ")) }
        if !details.isEmpty { head += " (" + details.joined(separator: ", ") + ")" }
        var text = head + ". "
        let paths = lag.conflictedPaths
        if !paths.isEmpty {
            text += "Rebasing conflicts in " + paths.prefix(8).joined(separator: ", ")
                + (paths.count > 8 ? " and \(paths.count - 8) more" : "") + ". "
        } else if conflictsFromGitHub {
            text += "GitHub reports the pull request as conflicting. "
        }
        text += """
        Rebase on \(base), keep both sides where they do not overlap, regenerate anything generated, re-run the test \
        suites you touched one at a time, rebuild, push with `--force-with-lease`, and reply when the branch is mergeable.
        """
        return text
    }

    /// The first line of what Scope types on its own: the agent knows it is not the user, and whom to answer.
    public static let header = "[Scope: automatic message from Scope itself, not the user; reply here when done]"

    /// `mainMoved` under its header, ready to type.
    public static func envelope(_ text: String) -> String { "\(header)\n\(text)" }
}
