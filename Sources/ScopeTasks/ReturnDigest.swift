import Foundation
import ScopeCore
import ScopeGit

/// What moved in a scope while its owner looked elsewhere: the strip at the top of the sidebar on the way back
/// ("Since 11:40 — 2 turns finished · 1 question for you · PR merged on token-refresh").
///
/// Turns carry their own dates, so they are counted after `since`. A pull request's state and checks do not: they
/// are compared with the snapshot `ScopeVisits` took when the owner left (`PullRequestSnapshot`), so checks that were
/// already failing then are not news now.
public struct ReturnDigest: Sendable, Equatable {
    /// What a fragment reveals when clicked.
    public enum Target: Sendable, Equatable, Hashable {
        case thread(ThreadID)
        case task(TaskID)
        /// The task is archived, so it has no row left: the pull request itself.
        case url(URL)
    }

    public struct Fragment: Sendable, Equatable, Identifiable {
        /// Declaration order is display order: what waits on the owner first, good news last.
        public enum Kind: String, Sendable, CaseIterable, Comparable {
            case questions
            case checksFailing = "checks-failing"
            case turnsFailed = "turns-failed"
            case merged
            case turnsFinished = "turns-finished"
            case closed
            case opened
            case checksPassing = "checks-passing"

            public static func < (lhs: Kind, rhs: Kind) -> Bool {
                allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
            }
        }

        public var kind: Kind
        public var count: Int
        public var text: String
        public var target: Target?

        public var id: Kind { kind }

        public init(kind: Kind, count: Int, text: String, target: Target?) {
            self.kind = kind
            self.count = count
            self.text = text
            self.target = target
        }
    }

    /// Fragments shown; the rest are counted in `overflow`.
    public static let fragmentLimit = 4

    public var since: Date
    public var fragments: [Fragment]
    /// Fragments left out past `fragmentLimit`.
    public var overflow: Int

    public init(since: Date, fragments: [Fragment], overflow: Int = 0) {
        self.since = since
        self.fragments = fragments
        self.overflow = overflow
    }

    /// One thread of the scope, as the digest needs it.
    public struct ThreadFacts: Sendable, Equatable {
        public var id: ThreadID
        /// When each turn that finished cleanly ended.
        public var finishedTurns: [Date]
        /// When each turn that failed ended.
        public var failedTurns: [Date]
        /// When the thread started waiting for the owner, if it is waiting now (a question or a permission).
        public var waitingSince: Date?

        public init(id: ThreadID, finishedTurns: [Date] = [], failedTurns: [Date] = [], waitingSince: Date? = nil) {
            self.id = id
            self.finishedTurns = finishedTurns
            self.failedTurns = failedTurns
            self.waitingSince = waitingSince
        }
    }

    /// One task of the scope, archived ones included: auto-archiving on merge must not hide the merge.
    public struct TaskFacts: Sendable, Equatable {
        public var id: TaskID
        public var name: String
        public var isArchived: Bool
        /// The bound pull requests now, empty when the task has none.
        public var pullRequests: [PullRequestSnapshot]

        public init(id: TaskID, name: String, isArchived: Bool = false, pullRequests: [PullRequestSnapshot] = []) {
            self.id = id
            self.name = name
            self.isArchived = isArchived
            self.pullRequests = pullRequests
        }
    }

    /// The digest of what changed after `since`, `nil` when nothing did.
    ///
    /// - Parameters:
    ///   - seen: each task's pull requests as they were when the owner left, by task id. A task missing from it had
    ///     no pull request then (or did not exist yet); a pull request missing from its list is new.
    public static func make(since: Date, threads: [ThreadFacts], tasks: [TaskFacts],
                            seen: [TaskID: [PullRequestSnapshot]]) -> ReturnDigest? {
        var fragments: [Fragment] = []

        let questions = threads.compactMap { thread in thread.waitingSince.flatMap { $0 > since ? (thread.id, $0) : nil } }
            .sorted { $0.1 < $1.1 }
        if let longest = questions.first {
            fragments.append(Fragment(kind: .questions, count: questions.count,
                                      text: questions.count == 1 ? "1 question for you" : "\(questions.count) questions for you",
                                      target: .thread(longest.0)))
        }
        fragments += turns(threads.map { ($0.id, $0.failedTurns) }, after: since, kind: .turnsFailed, verb: "failed")
        fragments += turns(threads.map { ($0.id, $0.finishedTurns) }, after: since, kind: .turnsFinished, verb: "finished")

        // One entry per task and kind, whichever of its pull requests moved; the target is the first that did.
        var changes: [Fragment.Kind: [(task: TaskFacts, pullRequest: PullRequestSnapshot)]] = [:]
        for task in tasks {
            let before = seen[task.id] ?? []
            for now in task.pullRequests {
                for kind in pullRequestChanges(from: before.first { $0.url == now.url }, to: now, number: now.number)
                where !(changes[kind] ?? []).contains(where: { $0.task.id == task.id }) {
                    changes[kind, default: []].append((task, now))
                }
            }
        }
        for (kind, moved) in changes {
            let sorted = moved.sorted { $0.task.name.localizedStandardCompare($1.task.name) == .orderedAscending }
            fragments.append(Fragment(kind: kind, count: sorted.count, text: phrase(kind, sorted.map(\.task)),
                                      target: target(of: sorted[0].task, pullRequest: sorted[0].pullRequest)))
        }

        guard !fragments.isEmpty else { return nil }
        fragments.sort { $0.kind < $1.kind }
        let shown = Array(fragments.prefix(fragmentLimit))
        return ReturnDigest(since: since, fragments: shown, overflow: fragments.count - shown.count)
    }

    /// What happened to a pull request between the two snapshots. A snapshot of another pull request is no snapshot.
    static func pullRequestChanges(from before: PullRequestSnapshot?, to now: PullRequestSnapshot,
                                   number: Int) -> [Fragment.Kind] {
        let before = before?.url == now.url ? before : nil
        switch now.state {
        case .merged:
            return before?.state == .open ? [.merged] : []
        case .closed:
            return before?.state == .open ? [.closed] : []
        case .open:
            var kinds: [Fragment.Kind] = before == nil ? [.opened] : []
            if now.checks == .failing, before?.checks != .failing {
                kinds.append(.checksFailing)
            } else if now.checks == .passing, let was = before?.checks, was == .failing || was == .pending {
                kinds.append(.checksPassing)
            }
            return kinds
        }
    }

    /// Turns ending after `since`, counted across threads; the fragment opens the thread of the latest.
    private static func turns(_ ends: [(ThreadID, [Date])], after since: Date, kind: Fragment.Kind,
                              verb: String) -> [Fragment] {
        let recent = ends.flatMap { id, dates in dates.filter { $0 > since }.map { (id, $0) } }
        guard let latest = recent.max(by: { $0.1 < $1.1 }) else { return [] }
        let text = recent.count == 1 ? "1 turn \(verb)" : "\(recent.count) turns \(verb)"
        return [Fragment(kind: kind, count: recent.count, text: text, target: .thread(latest.0))]
    }

    private static func phrase(_ kind: Fragment.Kind, _ tasks: [TaskFacts]) -> String {
        let on = tasks.count == 1 ? tasks[0].name : "\(tasks.count) tasks"
        let pr = tasks.count == 1 ? "PR" : "PRs"
        switch kind {
        case .merged: return "\(pr) merged on \(on)"
        case .closed: return "\(pr) closed on \(on)"
        case .opened: return "\(pr) opened on \(on)"
        case .checksFailing: return "checks failing on \(on)"
        case .checksPassing: return "checks passing on \(on)"
        case .questions, .turnsFailed, .turnsFinished: return ""
        }
    }

    private static func target(of task: TaskFacts, pullRequest: PullRequestSnapshot) -> Target? {
        task.isArchived ? .url(pullRequest.url) : .task(task.id)
    }
}

/// A task's pull request as the app knew it at one moment: what `ReturnDigest` compares across an absence.
public struct PullRequestSnapshot: Codable, Sendable, Equatable {
    public var number: Int
    public var url: URL
    public var state: PullRequest.State
    /// `nil` when nobody asked GitHub for the checks yet: unknown is not a change.
    public var checks: PullRequest.Checks?

    public init(number: Int, url: URL, state: PullRequest.State, checks: PullRequest.Checks? = nil) {
        self.number = number
        self.url = url
        self.state = state
        self.checks = checks
    }
}
