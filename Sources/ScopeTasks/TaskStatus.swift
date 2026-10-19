import Foundation
import ScopeCore
import ScopeGit

/// Everything the sidebar knows about a task that could make it worth a look, reduced to plain values so the
/// decision is testable without the app.
public struct TaskFacts: Sendable, Equatable {
    /// The display states of the task's threads (exited ones included; they count for nothing).
    public var threads: [ThreadState]
    /// `+N` against the merge-base, summed over the task's repositories.
    public var additions: Int
    public var deletions: Int
    /// At least one sandbox has uncommitted changes.
    public var isDirty: Bool
    public var setup: SetupState
    /// The bound pull requests, in the task's order (`PullRequestSet.ordered`); empty without one.
    public var pullRequests: [PullRequestFacts]

    public init(threads: [ThreadState] = [], additions: Int = 0, deletions: Int = 0, isDirty: Bool = false,
                setup: SetupState = .notRun, pullRequests: [PullRequestFacts] = []) {
        self.threads = threads
        self.additions = additions
        self.deletions = deletions
        self.isDirty = isDirty
        self.setup = setup
        self.pullRequests = pullRequests
    }

    /// The pull request the status speaks for: the most pressing open one, else the first (`TaskStatus.decisive`).
    public var pullRequest: PullRequestFacts? { TaskStatus.decisive(pullRequests) }
}

/// What is known about one pull request of a task. `checks` and `mergeable` are live facts from `gh`, absent until
/// something asked; `isDraft` likewise. `state` is GitHub's last word, `open` until it says otherwise.
public struct PullRequestFacts: Sendable, Equatable {
    public var number: Int
    public var isDraft: Bool
    public var checks: PullRequest.Checks
    public var mergeable: PullRequest.Mergeable
    public var state: PullRequest.State

    public init(number: Int, isDraft: Bool = false, checks: PullRequest.Checks = .none, mergeable: PullRequest.Mergeable = .unknown,
                state: PullRequest.State = .open) {
        self.number = number
        self.isDraft = isDraft
        self.checks = checks
        self.mergeable = mergeable
        self.state = state
    }

    /// What this pull request alone would make the task's status, when it is open; `nil` once merged or closed.
    public var status: TaskStatus? {
        guard state == .open else { return nil }
        if mergeable == .conflicting { return .conflicted }
        switch checks {
        case .failing: return .checksFailing
        case .pending: return .checksRunning
        case .passing: return .checksPassed
        case .none: break
        }
        return isDraft ? .draft : .pullRequestOpen
    }
}

/// The one thing a sidebar row says about a task.
///
/// A task can be several things at once — a thread waiting, checks failing, uncommitted changes — and a row that
/// says all of them says none. `resolve` picks the most pressing by a fixed ladder: what blocks on you first, then
/// what is moving, then what the pull request says, then the state of the branch.
public enum TaskStatus: Sendable, Equatable, Hashable {
    /// A thread asked a question or a permission.
    case waiting(WaitReason)
    /// A thread's turn stopped on an error the driver reported (rate limit, billing, overloaded API).
    case failed
    case running
    case setupRunning
    case setupFailed
    /// A turn ended and its result is there to read.
    case done
    /// The pull request no longer merges cleanly.
    case conflicted
    case checksFailing
    case checksRunning
    case checksPassed
    case draft
    case pullRequestOpen
    /// Every pull request of the task is merged or closed, and at least one merged: the work landed, the task is
    /// only waiting to be archived.
    case merged
    /// Commits or uncommitted work on the branch, no pull request yet.
    case changed
    case clean

    /// The ladder, most pressing first. `waiting` stands for both reasons.
    public static let precedence: [TaskStatus] = [
        .waiting(.input), .failed, .running, .setupRunning, .setupFailed, .done, .conflicted, .checksFailing,
        .checksRunning, .checksPassed, .draft, .pullRequestOpen, .merged, .changed, .clean,
    ]

    /// With several pull requests, the one whose state is the most pressing on the ladder decides: an open one
    /// before a settled one, red checks before green. Ties keep the task's order. `nil` for none.
    public static func decisive(_ facts: [PullRequestFacts]) -> PullRequestFacts? {
        let open = facts.filter { $0.state == .open }
        guard !open.isEmpty else { return facts.first(where: { $0.state == .merged }) ?? facts.first }
        return open.min { lhs, rhs in
            rank(lhs.status ?? .pullRequestOpen) < rank(rhs.status ?? .pullRequestOpen)
        }
    }

    private static func rank(_ status: TaskStatus) -> Int {
        precedence.firstIndex(of: status) ?? precedence.count
    }

    public static func resolve(_ facts: TaskFacts) -> TaskStatus {
        if let waiting = facts.threads.first(where: \.needsAttention), case .waiting(let reason) = waiting {
            return .waiting(reason)
        }
        if facts.threads.contains(.failed) { return .failed }
        if facts.threads.contains(.running) { return .running }
        if facts.setup == .running { return .setupRunning }
        if facts.setup == .failed { return .setupFailed }
        if facts.threads.contains(.done) { return .done }
        if let pr = facts.pullRequest {
            if let status = pr.status { return status }
            if facts.pullRequests.contains(where: { $0.state == .merged }) { return .merged }
            // Closed without a merge: the pull request says nothing more; the branch does (`TaskDormancy` says "PR closed").
        }
        if facts.additions + facts.deletions > 0 || facts.isDirty { return .changed }
        return .clean
    }

    /// One or two words, for a caption or an accessibility value.
    public var label: String {
        switch self {
        case .waiting(.permission): "Needs permission"
        case .waiting(.input): "Needs you"
        case .failed: "Failed"
        case .running: "Running"
        case .setupRunning: "Setting up"
        case .setupFailed: "Setup failed"
        case .done: "Done"
        case .conflicted: "Conflicts"
        case .checksFailing: "Checks failing"
        case .checksRunning: "Checks running"
        case .checksPassed: "Checks passed"
        case .draft: "Draft PR"
        case .pullRequestOpen: "PR open"
        case .merged: "PR merged"
        case .changed: "Changed"
        case .clean: "Clean"
        }
    }

    /// One sentence: the status and what backs it, for the hover card and VoiceOver.
    public static func summary(_ status: TaskStatus, facts: TaskFacts) -> String {
        let live = facts.threads.filter(\.isAlive).count
        let threads = live == 1 ? "its thread" : "one of its \(live) threads"
        let pr = facts.pullRequest.map { "#\($0.number)" } ?? "the pull request"
        let head: String = switch status {
        case .waiting(.permission): "Waiting for your permission in \(threads)"
        case .waiting(.input): "Waiting for your answer in \(threads)"
        case .failed: "A turn stopped on an error in \(threads)"
        case .running: "An agent is working in \(threads)"
        case .setupRunning: "The setup command is running in the sandbox"
        case .setupFailed: "The setup command failed; the log is in the Problem Center"
        case .done: "A turn ended in \(threads) and its result is ready"
        case .conflicted: "\(pr) has conflicts with its base branch"
        case .checksFailing: "Checks are failing on \(pr)"
        case .checksRunning: "Checks are running on \(pr)"
        case .checksPassed: "Checks passed on \(pr)"
        case .draft: "\(pr) is a draft"
        case .pullRequestOpen: "\(pr) is open"
        case .merged: facts.pullRequests.count > 1 ? "Every pull request is merged or closed" : "\(pr) is merged"
        case .changed: "The branch has changes and no pull request yet"
        case .clean: "Nothing changed on the branch yet"
        }
        var tail: [String] = []
        if let caption = PullRequestSet.caption(facts.pullRequests) { tail.append(caption) }
        if facts.additions + facts.deletions > 0 { tail.append("+\(facts.additions) −\(facts.deletions)") }
        if facts.isDirty { tail.append("uncommitted work") }
        return tail.isEmpty ? head + "." : head + "; " + tail.joined(separator: ", ") + "."
    }
}

/// The four groups of the sidebar arranged by state, most pressing first.
public enum SidebarGroup: Int, Sendable, CaseIterable, Comparable {
    case needsYou, working, finished, quiet
    /// Forgotten: idle for days, or its pull request closed unmerged (`TaskDormancy`). Tasks only.
    case dormant

    public var title: String {
        switch self {
        case .needsYou: "Needs you"
        case .working: "Working"
        case .finished: "Finished, not read"
        case .quiet: "Quiet"
        case .dormant: "Dormant"
        }
    }

    public static func < (lhs: SidebarGroup, rhs: SidebarGroup) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Where a task goes: anything the user has to act on first, then what runs without them.
    public init(_ status: TaskStatus) {
        switch status {
        case .waiting, .failed, .setupFailed, .conflicted, .checksFailing: self = .needsYou
        case .running, .setupRunning, .checksRunning: self = .working
        case .done, .checksPassed, .merged: self = .finished
        case .draft, .pullRequestOpen, .changed, .clean: self = .quiet
        }
    }

    /// Where a loose thread goes.
    public init(_ state: ThreadState) {
        switch state {
        case .waiting, .failed: self = .needsYou
        case .running: self = .working
        case .done: self = .finished
        case .idle, .exited: self = .quiet
        }
    }
}
