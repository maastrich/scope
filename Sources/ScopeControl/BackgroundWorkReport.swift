import Foundation
import ScopeAdapters

/// One piece of a thread's background work as `scope list threads`, `thread read` and `thread wait` answer it: a
/// shell command or Monitor Claude Code runs in the background, the `/loop` wake-up, a session cron.
public struct BackgroundTaskSummary: Codable, Sendable, Equatable {
    /// The task id (`b…`), the cron id, or `wakeup`.
    public var id: String
    /// `shell`, `monitor`, `wakeup`, `cron`.
    public var kind: String
    /// `running`, `completed`, `failed`, `killed`, `stopped`, `expired`, `ended`; `scheduled` for a wake-up or a cron.
    public var state: String
    /// What runs, as the agent wrote it. Untrusted.
    public var command: String?
    public var description: String?
    public var exitCode: Int?
    /// Where its output goes; read it rather than waiting on the task.
    public var outputFile: String?
    public var startedAt: Date?
    public var endedAt: Date?
    /// When a Monitor gives up, or when a wake-up or a cron fires next.
    public var at: Date?
    /// A cron's expression.
    public var schedule: String?
    /// Events a Monitor reported.
    public var events: Int?
    /// The user stopped it from Scope.
    public var stoppedFromScope: Bool?

    public init(id: String, kind: String, state: String, command: String? = nil, description: String? = nil, exitCode: Int? = nil,
                outputFile: String? = nil, startedAt: Date? = nil, endedAt: Date? = nil, at: Date? = nil, schedule: String? = nil,
                events: Int? = nil, stoppedFromScope: Bool? = nil) {
        self.id = id
        self.kind = kind
        self.state = state
        self.command = command
        self.description = description
        self.exitCode = exitCode
        self.outputFile = outputFile
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.at = at
        self.schedule = schedule
        self.events = events
        self.stoppedFromScope = stoppedFromScope
    }

    public var isRunning: Bool { state == "running" }
}

/// What the answers say of a thread's background work (`ClaudeBackgroundWork`).
///
/// Reported, never waited on: a dev server or a 30-minute Monitor runs as long as it is let, and a `thread wait` held
/// on it would run to its deadline every time. The thread is settled when its turn is; these say what it left running.
public enum BackgroundWorkReport {
    /// Finished tasks listed after the running ones, most recent first.
    public static let recentLimit = 5

    /// Running tasks first (oldest first), then the `recentLimit` latest finished, then the wake-up and the crons;
    /// `nil` when there is nothing.
    public static func entries(_ work: ClaudeBackgroundWork, now: Date, recentLimit: Int = recentLimit,
                               outputFile: (ClaudeBackgroundWork.Task) -> String? = { $0.outputFile }) -> [BackgroundTaskSummary]? {
        let running = work.tasks.filter { $0.status(at: now).isRunning }
        let finished = work.tasks.filter { !$0.status(at: now).isRunning }
            .sorted { ($0.endedAt ?? .distantPast) > ($1.endedAt ?? .distantPast) }
            .prefix(recentLimit)
        var entries = (running + finished).map { task in
            let status = task.status(at: now)
            return BackgroundTaskSummary(
                id: task.id, kind: task.kind.rawValue, state: status.name, command: task.command.map(ThreadTranscript.defused),
                description: task.description.map(ThreadTranscript.defused), exitCode: status.exitCode, outputFile: outputFile(task),
                startedAt: task.startedAt, endedAt: task.endedAt, at: task.expiresAt,
                events: task.kind == .monitor && task.eventCount > 0 ? task.eventCount : nil,
                stoppedFromScope: task.stoppedFromScope ? true : nil)
        }
        if let wakeup = work.wakeup {
            entries.append(BackgroundTaskSummary(id: "wakeup", kind: "wakeup", state: "scheduled",
                                                 description: wakeup.reason.map(ThreadTranscript.defused), at: wakeup.scheduledFor))
        }
        for cron in work.crons {
            entries.append(BackgroundTaskSummary(id: cron.id, kind: "cron", state: "scheduled",
                                                 description: cron.prompt.map(ThreadTranscript.defused), at: cron.nextFireAt,
                                                 schedule: cron.humanSchedule ?? cron.schedule))
        }
        return entries.isEmpty ? nil : entries
    }

    /// `2 running in the background: b1a2b3c4d npm run dev (shell, 12m), b9f8e7d6c tail -f log (monitor, 3m)` — the
    /// line the CLI prints under a thread; `nil` when nothing runs or is scheduled.
    public static func line(_ entries: [BackgroundTaskSummary]?, now: Date) -> String? {
        guard let entries else { return nil }
        let running = entries.filter(\.isRunning)
        let scheduled = entries.filter { $0.state == "scheduled" }
        var parts: [String] = []
        if !running.isEmpty {
            let items = running.map { entry in
                var item = entry.id
                if let what = entry.command ?? entry.description { item += " " + String(what.prefix(60)) }
                var detail = [entry.kind]
                if let started = entry.startedAt { detail.append(duration(now.timeIntervalSince(started))) }
                return item + " (" + detail.joined(separator: ", ") + ")"
            }
            parts.append("\(running.count) running in the background: " + items.joined(separator: ", "))
        }
        if !scheduled.isEmpty {
            let items = scheduled.map { entry -> String in
                let when = entry.kind == "wakeup" ? entry.at.map { "wake-up in " + duration($0.timeIntervalSince(now)) } ?? "wake-up"
                    : "cron " + (entry.schedule ?? entry.id)
                return when
            }
            parts.append("scheduled: " + items.joined(separator: ", "))
        }
        return parts.isEmpty ? nil : parts.joined(separator: "; ")
    }

    /// `45s`, `12m`, `2h05`.
    public static func duration(_ seconds: TimeInterval) -> String {
        let seconds = max(Int(seconds.rounded()), 0)
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        return String(format: "%dh%02d", seconds / 3600, (seconds % 3600) / 60)
    }
}
