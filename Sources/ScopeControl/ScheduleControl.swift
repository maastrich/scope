import Foundation
import ScopeCore

/// `scope schedule list [--scope S]` — the schedules of one scope, or of every scope.
public struct ScheduleListParams: Codable, Sendable, Equatable {
    public var scope: String?

    public init(scope: String? = nil) {
        self.scope = scope
    }
}

/// `scope schedule run <name> [--scope S]` — fire a schedule now, whatever its rule says.
public struct ScheduleRunParams: Codable, Sendable, Equatable {
    /// The schedule's name or id.
    public var name: String
    public var scope: String?

    public init(name: String, scope: String? = nil) {
        self.name = name
        self.scope = scope
    }
}

/// One schedule as `schedule.list` describes it.
public struct ScheduleSummary: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var scope: String
    public var scopeSlug: String
    /// `daily at 09:00`
    public var rule: String
    /// `orchestrator`, `new task (claude-code · haiku)`
    public var target: String
    public var enabled: Bool
    public var prompt: String
    /// The next time it fires, when it is enabled.
    public var next: Date?
    public var lastRunAt: Date?
    /// `replied`, `noReply`, `failed`
    public var lastOutcome: String?
    public var lastSummary: String?

    public init(id: String, name: String, scope: String, scopeSlug: String, rule: String, target: String, enabled: Bool,
                prompt: String, next: Date? = nil, lastRunAt: Date? = nil, lastOutcome: String? = nil, lastSummary: String? = nil) {
        self.id = id
        self.name = name
        self.scope = scope
        self.scopeSlug = scopeSlug
        self.rule = rule
        self.target = target
        self.enabled = enabled
        self.prompt = prompt
        self.next = next
        self.lastRunAt = lastRunAt
        self.lastOutcome = lastOutcome
        self.lastSummary = lastSummary
    }

    /// `summary` of `schedule` in `scope`, the next fire time computed from `now`.
    public init(_ schedule: Schedule, scope: String, scopeSlug: String, now: Date = .now, calendar: Calendar = .current) {
        self.init(id: schedule.id, name: schedule.name, scope: scope, scopeSlug: scopeSlug,
                  rule: schedule.rule.description(calendar: calendar), target: schedule.target.description,
                  enabled: schedule.enabled, prompt: schedule.prompt,
                  next: schedule.enabled ? Scheduler.nextFire(schedule.rule, after: now, calendar: calendar) : nil,
                  lastRunAt: schedule.lastRun?.at, lastOutcome: schedule.lastRun?.outcome.rawValue,
                  lastSummary: schedule.lastRun?.summary)
    }
}

public struct ScheduleListResult: Codable, Sendable, Equatable {
    public var schedules: [ScheduleSummary]

    public init(schedules: [ScheduleSummary]) {
        self.schedules = schedules
    }
}

/// `scope task milestone add [<task>] "<title>" [--validate <command>] [--child <slug>]`.
public struct MilestoneAddParams: Codable, Sendable, Equatable {
    /// The mission, by id or slug; `nil` is the caller's own task.
    public var task: String?
    public var title: String
    /// The shell command that validates the milestone, run in its sandbox when it is marked done.
    public var validation: String?
    /// The child task doing the milestone, by id or slug, when it already exists.
    public var child: String?

    public init(task: String? = nil, title: String, validation: String? = nil, child: String? = nil) {
        self.task = task
        self.title = title
        self.validation = validation
        self.child = child
    }
}

/// `scope task milestone done [<task>] <n|title> [--child <slug>]`.
public struct MilestoneDoneParams: Codable, Sendable, Equatable {
    public var task: String?
    /// The milestone's number (1-based), id or title.
    public var milestone: String
    public var child: String?

    public init(task: String? = nil, milestone: String, child: String? = nil) {
        self.task = task
        self.milestone = milestone
        self.child = child
    }
}
