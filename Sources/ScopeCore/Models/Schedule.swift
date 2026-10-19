import Foundation

/// When a schedule fires: every hour, every day, on weekdays, or once a week — at a minute, at a time, or on a
/// weekday at a time. Clock times are wall-clock in the user's calendar, so a daily 09:00 stays 09:00 across a
/// daylight-saving change (`Scheduler` asks `Calendar` for the next match rather than adding seconds).
public struct ScheduleRule: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case hourly, daily, weekdays, weekly

        public var title: String {
            switch self {
            case .hourly: "Every hour"
            case .daily: "Every day"
            case .weekdays: "On weekdays"
            case .weekly: "Once a week"
            }
        }
    }

    public var kind: Kind
    /// 0–23; unused by `hourly`.
    public var hour: Int
    /// 0–59.
    public var minute: Int
    /// `Calendar`'s weekday, 1 (Sunday) to 7 (Saturday); used by `weekly` only.
    public var weekday: Int

    public init(kind: Kind, hour: Int = 9, minute: Int = 0, weekday: Int = 2) {
        self.kind = kind
        self.hour = min(max(hour, 0), 23)
        self.minute = min(max(minute, 0), 59)
        self.weekday = min(max(weekday, 1), 7)
    }

    public static func hourly(minute: Int) -> ScheduleRule { ScheduleRule(kind: .hourly, minute: minute) }
    public static func daily(hour: Int, minute: Int = 0) -> ScheduleRule { ScheduleRule(kind: .daily, hour: hour, minute: minute) }
    public static func weekdays(hour: Int, minute: Int = 0) -> ScheduleRule { ScheduleRule(kind: .weekdays, hour: hour, minute: minute) }
    public static func weekly(weekday: Int, hour: Int, minute: Int = 0) -> ScheduleRule {
        ScheduleRule(kind: .weekly, hour: hour, minute: minute, weekday: weekday)
    }

    private enum CodingKeys: String, CodingKey { case kind, hour, minute, weekday }

    // Lenient: a hand-edited rule missing a field gets the default rather than failing the whole config.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = (try? container.decodeIfPresent(Kind.self, forKey: .kind)) ?? nil
        self.init(kind: kind ?? .daily,
                  hour: (try? container.decodeIfPresent(Int.self, forKey: .hour)) ?? 9,
                  minute: (try? container.decodeIfPresent(Int.self, forKey: .minute)) ?? 0,
                  weekday: (try? container.decodeIfPresent(Int.self, forKey: .weekday)) ?? 2)
    }

    /// `09:00`
    public var clock: String { String(format: "%02d:%02d", hour, minute) }

    /// `every hour at :05`, `daily at 09:00`, `weekdays at 09:00`, `weekly on Monday at 09:00`.
    public func description(calendar: Calendar = .current) -> String {
        switch kind {
        case .hourly: "every hour at :" + String(format: "%02d", minute)
        case .daily: "daily at \(clock)"
        case .weekdays: "weekdays at \(clock)"
        case .weekly: "weekly on \(ScheduleRule.weekdayName(weekday, calendar: calendar)) at \(clock)"
        }
    }

    public static func weekdayName(_ weekday: Int, calendar: Calendar = .current) -> String {
        let names = calendar.weekdaySymbols
        let index = min(max(weekday, 1), 7) - 1
        return index < names.count ? names[index] : "day \(weekday)"
    }
}

/// Where a schedule's prompt goes: the scope's orchestrator thread, or a new task with its own driver and model.
public struct ScheduleTarget: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case orchestrator
        case newTask

        public var title: String {
            switch self {
            case .orchestrator: "The orchestrator"
            case .newTask: "A new task"
            }
        }
    }

    public var kind: Kind
    /// `newTask` only: the driver of the task's first thread; `nil` is the default driver from Settings.
    public var driver: String?
    /// `newTask` only: the model of that thread; `nil` is the usual default.
    public var model: String?

    public init(kind: Kind, driver: String? = nil, model: String? = nil) {
        self.kind = kind
        self.driver = driver.flatMap { $0.isEmpty ? nil : $0 }
        self.model = model.flatMap { $0.isEmpty ? nil : $0 }
    }

    public static let orchestrator = ScheduleTarget(kind: .orchestrator)

    private enum CodingKeys: String, CodingKey { case kind, driver, model }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(kind: ((try? container.decodeIfPresent(Kind.self, forKey: .kind)) ?? nil) ?? .orchestrator,
                  driver: (try? container.decodeIfPresent(String.self, forKey: .driver)) ?? nil,
                  model: (try? container.decodeIfPresent(String.self, forKey: .model)) ?? nil)
    }

    public var description: String {
        switch kind {
        case .orchestrator: "orchestrator"
        case .newTask: "new task" + (driver.map { " (\($0)" + (model.map { " · \($0)" } ?? "") + ")" } ?? (model.map { " (\($0))" } ?? ""))
        }
    }
}

/// What the last run of a schedule did, kept on the schedule so Settings and the Inbox can say so.
public struct ScheduleRun: Codable, Sendable, Hashable {
    public enum Outcome: String, Codable, Sendable {
        /// The prompt went out and the agent answered; `summary` is the first line of the reply.
        case replied
        /// The prompt went out; no reply arrived before Scope stopped waiting.
        case noReply
        /// The prompt never went: no orchestrator, the task could not be created, …
        case failed
    }

    /// When the run started: what the scheduler compares the rule's occurrences against.
    public var at: Date
    public var outcome: Outcome
    /// The first line of the reply, or what went wrong.
    public var summary: String?
    /// The thread the prompt went to, when one did.
    public var thread: String?
    /// The task created for the run, when the target is a new task.
    public var task: String?

    public init(at: Date, outcome: Outcome, summary: String? = nil, thread: String? = nil, task: String? = nil) {
        self.at = at
        self.outcome = outcome
        self.summary = summary
        self.thread = thread
        self.task = task
    }
}

/// A prompt Scope sends on its own, on a rule, to a scope's orchestrator or into a new task (spec §4.11). Lives in the
/// scope's declaration in `config.json`.
public struct Schedule: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var rule: ScheduleRule
    public var prompt: String
    public var target: ScheduleTarget
    /// A paused schedule keeps its place and its last run, and never fires.
    public var enabled: Bool
    public var lastRun: ScheduleRun?

    public init(id: String = Schedule.newID(), name: String, rule: ScheduleRule, prompt: String,
                target: ScheduleTarget = .orchestrator, enabled: Bool = true, lastRun: ScheduleRun? = nil) {
        self.id = id
        self.name = name
        self.rule = rule
        self.prompt = prompt
        self.target = target
        self.enabled = enabled
        self.lastRun = lastRun
    }

    /// 8 hex characters: enough to tell schedules apart in one config, short enough to read in a log.
    public static func newID() -> String {
        String(format: "%08x", UInt32.random(in: 0...UInt32.max))
    }

    private enum CodingKeys: String, CodingKey { case id, name, rule, prompt, target, enabled, lastRun }

    // Lenient: the name and the prompt are what a schedule cannot do without.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decodeIfPresent(String.self, forKey: .id)).flatMap { $0 } ?? Schedule.newID()
        name = try container.decode(String.self, forKey: .name)
        rule = (try? container.decodeIfPresent(ScheduleRule.self, forKey: .rule)).flatMap { $0 } ?? .daily(hour: 9)
        prompt = try container.decode(String.self, forKey: .prompt)
        target = (try? container.decodeIfPresent(ScheduleTarget.self, forKey: .target)).flatMap { $0 } ?? .orchestrator
        enabled = (try? container.decodeIfPresent(Bool.self, forKey: .enabled)).flatMap { $0 } ?? true
        lastRun = (try? container.decodeIfPresent(ScheduleRun.self, forKey: .lastRun)).flatMap { $0 }
    }

    /// The prompt as the agent receives it: one line saying it is scheduled, and that the first line of the answer is
    /// what the user reads in the Inbox, then the prompt itself.
    public var envelope: String {
        "[Scope: scheduled prompt “\(name)” — answer it completely; the first line of your answer is what the user "
            + "reads in the Inbox]\n\(prompt)"
    }

    /// Whether `query` names this schedule: its id, or its name whatever the case.
    public func matches(_ query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return id == trimmed || name.caseInsensitiveCompare(trimmed) == .orderedSame
    }

    /// The two schedules offered when one is created, both paused: a morning look at the pull requests whose checks
    /// are red, an evening summary of the day. Fresh ids every call.
    public static func examples() -> [Schedule] {
        [
            Schedule(
                name: "Morning: PRs with red checks",
                rule: .weekdays(hour: 9, minute: 0),
                prompt: """
                List the open pull requests of this scope whose checks are failing (`gh pr list` then `gh pr checks` on \
                each). For each one, say which check fails and which task owns it (`scope list tasks`). When the task has a \
                running thread, send it the failing check's log with `scope thread send`; otherwise say what should be \
                done. End with one line per pull request.
                """,
                target: .orchestrator,
                enabled: false
            ),
            Schedule(
                name: "Evening: summarize today",
                rule: .daily(hour: 18, minute: 30),
                prompt: """
                Run `scope summary today` and write the day up for me: what was finished or merged, what is waiting on \
                me, what is still open and worth a look tomorrow. Short, one section per scope.
                """,
                target: .orchestrator,
                enabled: false
            ),
        ]
    }
}

/// When schedules fire. Pure: the app hands in the clock and the schedules, and gets back what to run now.
///
/// A rule's occurrences come from `Calendar.nextDate`, matching wall-clock components, so a daily 09:00 fires at 09:00
/// the day the clocks change too (a time that does not exist that day fires at the next existing one). The app
/// watches from `watchedSince` (its launch): an occurrence older than that is history, except once at launch when
/// catch-up is on — a daily, weekday or weekly occurrence missed in the last `catchUpWindow` fires then, so the
/// morning prompt still runs when the Mac wakes at 10:00. Hourly rules never catch up: the next hour is near enough.
public enum Scheduler {
    public static let catchUpWindow: TimeInterval = 24 * 3600

    /// The next occurrence of `rule` strictly after `date`.
    public static func nextFire(_ rule: ScheduleRule, after date: Date, calendar: Calendar = .current) -> Date? {
        occurrence(rule, from: date, direction: .forward, calendar: calendar)
    }

    /// The last occurrence of `rule` strictly before `date`.
    public static func previousFire(_ rule: ScheduleRule, before date: Date, calendar: Calendar = .current) -> Date? {
        occurrence(rule, from: date, direction: .backward, calendar: calendar)
    }

    private static func occurrence(_ rule: ScheduleRule, from date: Date, direction: Calendar.SearchDirection,
                                   calendar: Calendar) -> Date? {
        var components = DateComponents()
        components.minute = rule.minute
        components.second = 0
        switch rule.kind {
        case .hourly:
            break
        case .daily, .weekdays:
            components.hour = rule.hour
        case .weekly:
            components.hour = rule.hour
            components.weekday = rule.weekday
        }
        var cursor = date
        // Weekdays: the daily match, skipping Saturday and Sunday; seven tries cover any week.
        for _ in 0..<8 {
            guard let found = calendar.nextDate(after: cursor, matching: components, matchingPolicy: .nextTime,
                                                repeatedTimePolicy: .first, direction: direction) else { return nil }
            guard rule.kind == .weekdays else { return found }
            let weekday = calendar.component(.weekday, from: found)
            if weekday != 1 && weekday != 7 { return found }
            cursor = found
        }
        return nil
    }

    /// The schedules to fire at `now`: enabled, with an occurrence since the app started watching (or, catching up,
    /// within the last day) that no run has covered yet.
    public static func due(_ schedules: [Schedule], now: Date, watchedSince: Date, catchUp: Bool,
                           calendar: Calendar = .current) -> [Schedule] {
        schedules.filter { schedule in
            guard schedule.enabled, let last = previousFire(schedule.rule, before: now, calendar: calendar) else { return false }
            var floor = watchedSince
            if catchUp, schedule.rule.kind != .hourly { floor = min(floor, now.addingTimeInterval(-catchUpWindow)) }
            guard last >= floor else { return false }
            if let ran = schedule.lastRun?.at, last <= ran { return false }
            return true
        }
    }
}
