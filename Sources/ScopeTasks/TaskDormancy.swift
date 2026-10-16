import Foundation
import ScopeCore

/// A task left open and forgotten: nothing happened in its threads for days, or its pull request was closed without
/// being merged. The sidebar says so in a caption and, arranged by state, files it under **Dormant**.
public enum TaskDormancy: Sendable, Equatable {
    case active
    /// No thread activity for this many whole days.
    case idle(days: Int)
    /// The pull request was closed unmerged: the work did not land, the task is still holding a sandbox.
    case pullRequestClosed

    /// `idle 4d`, `PR closed`; `nil` while active.
    public var caption: String? {
        switch self {
        case .active: nil
        case .idle(let days): "idle \(days)d"
        case .pullRequestClosed: "PR closed"
        }
    }

    public var isDormant: Bool { self != .active }

    /// `lastActivity` is the latest of what the task's threads did (a turn's end, a tool run, a launch) and the
    /// task's own creation. `idleDays` of 0 or less never calls a task idle. A thread mid-turn is activity now, and a
    /// merged pull request is not dormancy: archiving it is `MergedTaskArchive`'s business.
    public static func classify(lastActivity: Date, now: Date, idleDays: Int, pullRequestState: String?,
                                threads: [ThreadState]) -> TaskDormancy {
        if threads.contains(.running) { return .active }
        if pullRequestState == "closed" { return .pullRequestClosed }
        guard idleDays > 0 else { return .active }
        let days = Int(now.timeIntervalSince(lastActivity) / 86_400)
        return days >= idleDays ? .idle(days: days) : .active
    }

    /// The latest moment worth calling activity, from the task's creation and its threads' dates.
    public static func lastActivity(createdAt: Date, threadDates: [Date?]) -> Date {
        threadDates.compactMap { $0 }.reduce(createdAt, max)
    }
}

extension SidebarGroup {
    /// Where a task goes once its dormancy is known. A dormant task leaves **Finished** and **Quiet** for
    /// **Dormant**; one that needs the user, or is working, stays where it is — that is more pressing than its age.
    public init(_ status: TaskStatus, dormancy: TaskDormancy) {
        let group = SidebarGroup(status)
        self = dormancy.isDormant && (group == .finished || group == .quiet) ? .dormant : group
    }
}
