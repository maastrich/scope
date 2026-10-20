import Foundation
import ScopeCore

/// Whether a refresh that saw a task's pull request should archive the task.
///
/// A merged pull request says the work of that branch landed, not that the task is over: an orchestrator whose own
/// pull request merges may still be driving children, answering a question, or pushing a follow-up. So the merge
/// only archives a task that is visibly done with — every guard below clear — and anything Scope cannot read yet
/// (a sandbox not measured, a thread still launching) counts as not clear.
public enum MergedTaskArchive: Sendable, Equatable {
    /// Archive it now.
    case archive
    /// Merged, but something still holds the task: ask again on the next refresh.
    case hold(Hold)
    /// Nothing to do: not merged, the preference is off, or the user brought the task back after a merge.
    case keep

    public enum Hold: Sendable, Equatable {
        /// A thread is mid-turn, waiting for someone, failed on an error, still launching, cut off mid-turn by a
        /// quit, or has sub-agents running.
        case threadBusy
        /// A task launched from this one (or from one of those, all the way down) is still open.
        case openChildren
        /// A sandbox has uncommitted changes.
        case uncommitted
        /// A sandbox has commits that are on no remote and in no merged pull request.
        case unpushed
        /// A thread started a turn after the last merge: the work went on past it.
        case workedAfterMerge
        /// Something above could not be read yet.
        case unknown
    }

    /// One thread of the task, as the archive needs it.
    public struct Thread: Sendable, Equatable {
        public var state: ThreadState
        /// Sub-agents the driver reported started and not ended (`ThreadActivity.runningAgents(now:)`).
        public var runningAgents: Int
        /// Being relaunched: the driver has said nothing yet.
        public var launching: Bool
        /// The last turn ended because the process (or the app) went away mid-turn.
        public var interrupted: Bool
        /// When its latest turn started, from the saved activity: the one in progress, else the last finished.
        public var lastTurnStartedAt: Date?

        public init(state: ThreadState, runningAgents: Int = 0, launching: Bool = false, interrupted: Bool = false,
                    lastTurnStartedAt: Date? = nil) {
            self.state = state
            self.runningAgents = runningAgents
            self.launching = launching
            self.interrupted = interrupted
            self.lastTurnStartedAt = lastTurnStartedAt
        }

        var isBusy: Bool {
            if launching || interrupted || runningAgents > 0 { return true }
            switch state {
            case .running, .waiting, .failed: return true
            case .idle, .done, .exited: return false
            }
        }
    }

    /// One worktree of the task (`TaskRecord.activeSandboxes`); `nil` for what was not measured yet.
    public struct Sandbox: Sendable, Equatable {
        public var dirty: Bool?
        public var unpushed: Int?

        public init(dirty: Bool?, unpushed: Int?) {
            self.dirty = dirty
            self.unpushed = unpushed
        }
    }

    public struct PullRequest: Sendable, Equatable {
        /// GitHub's `open`, `merged`, `closed`; `nil` for one never read since it was bound, which counts as open.
        public var state: String?
        public var mergedAt: Date?

        public init(state: String?, mergedAt: Date? = nil) {
            self.state = state
            self.mergedAt = mergedAt
        }
    }

    public struct Facts: Sendable, Equatable {
        public var pullRequests: [PullRequest]
        public var threads: [Thread]
        /// Open tasks below this one (`openDescendants`).
        public var openChildren: Int
        public var sandboxes: [Sandbox]
        public var enabled: Bool
        public var keptOpenAfterMerge: Bool

        public init(pullRequests: [PullRequest], threads: [Thread] = [], openChildren: Int = 0, sandboxes: [Sandbox] = [],
                    enabled: Bool = true, keptOpenAfterMerge: Bool = false) {
            self.pullRequests = pullRequests
            self.threads = threads
            self.openChildren = openChildren
            self.sandboxes = sandboxes
            self.enabled = enabled
            self.keptOpenAfterMerge = keptOpenAfterMerge
        }

        /// When the last of the merged pull requests landed; `nil` when one of them has no date yet.
        var lastMergedAt: Date? {
            let merged = pullRequests.filter { $0.state == "merged" }
            let dates = merged.compactMap(\.mergedAt)
            return dates.count == merged.count ? dates.max() : nil
        }
    }

    /// The task archives once none of its pull requests is open and at least one merged
    /// (`PullRequestSet.aggregateState`) — a task with two waits for the second to land — and then only once nothing
    /// holds it. A closed, unmerged pull request never archives on its own: the work did not land, and someone may yet
    /// reopen it or push it elsewhere.
    public static func decide(_ facts: Facts) -> MergedTaskArchive {
        guard facts.enabled, !facts.keptOpenAfterMerge,
              PullRequestSet.aggregateState(facts.pullRequests.map(\.state)) == "merged" else { return .keep }
        if facts.threads.contains(where: \.isBusy) { return .hold(.threadBusy) }
        if facts.openChildren > 0 { return .hold(.openChildren) }
        guard let mergedAt = facts.lastMergedAt else { return .hold(.unknown) }
        // A turn's start, never its end: the turn that ran `gh pr merge` started before the merge and ends after it.
        if facts.threads.contains(where: { ($0.lastTurnStartedAt ?? .distantPast) > mergedAt }) {
            return .hold(.workedAfterMerge)
        }
        if facts.sandboxes.contains(where: { $0.dirty == true }) { return .hold(.uncommitted) }
        if facts.sandboxes.contains(where: { ($0.unpushed ?? 0) > 0 }) { return .hold(.unpushed) }
        if facts.sandboxes.contains(where: { $0.dirty == nil || $0.unpushed == nil }) { return .hold(.unknown) }
        return .archive
    }

    /// The open tasks launched from `root`, directly or through others (`TaskRecord.parentTask`). An archived task in
    /// between is walked through: its own open child still belongs to `root`'s work.
    public static func openDescendants(of root: TaskID, in tasks: [(id: TaskID, parent: TaskID?, isArchived: Bool)]) -> [TaskID] {
        var children: [TaskID: [(id: TaskID, isArchived: Bool)]] = [:]
        for task in tasks { if let parent = task.parent { children[parent, default: []].append((task.id, task.isArchived)) } }
        var seen: Set<TaskID> = [root]
        var queue = [root]
        var open: [TaskID] = []
        while let next = queue.popLast() {
            for child in children[next] ?? [] where seen.insert(child.id).inserted {
                if !child.isArchived { open.append(child.id) }
                queue.append(child.id)
            }
        }
        return open
    }
}
