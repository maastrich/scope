import Foundation

/// The background work of a Claude Code session: shell commands sent to the background (`Bash` with
/// `run_in_background`, or moved there on timeout), Monitors, the `/loop` wake-up and the session's crons.
///
/// Folded from every source that says something about it, none of which says everything (docs/research/claude-native.md
/// §1.2–1.3): the launch from the `PostToolUse` hook or the transcript's tool call; the end from the transcript's
/// `<task-notification>` — no hook fires when a background command finishes; the `Stop` hook's `background_tasks`
/// and `session_crons`, the authoritative list at each turn's end; `TaskStop`, which writes no notification at all.
/// Each source is applied idempotently, so the same launch seen by the hook and by the transcript makes one task, and
/// a relaunch that replays the whole transcript lands where the live session was.
///
/// Only `b…` tasks: `a…` are sub-agents and `k…` long MCP calls, which other features follow.
///
/// No clock in here: durations and a Monitor's expiry are worked out by whoever shows them, against `expiresAt`.
public struct ClaudeBackgroundWork: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable, Codable {
        case shell, monitor
    }

    public enum Status: Sendable, Equatable {
        case running
        /// Finished on its own; the exit code when Claude Code gave one (`completed (exit code 0)`).
        case completed(exitCode: Int?)
        case failed(exitCode: Int?)
        /// Stopped from inside the session: `TaskStop`, the `/tasks` dialog, low memory.
        case killed
        /// The session ended under it (Claude Code says so at the next resume), or the process is gone.
        case stopped
        /// A Monitor that reached its `timeout_ms`.
        case expired
        /// Gone from the `Stop` hook's list before any notification said how.
        case ended

        public var isRunning: Bool { self == .running }

        /// `running`, `completed`, `failed`, `killed`, `stopped`, `expired`, `ended`.
        public var name: String {
            switch self {
            case .running: "running"
            case .completed: "completed"
            case .failed: "failed"
            case .killed: "killed"
            case .stopped: "stopped"
            case .expired: "expired"
            case .ended: "ended"
            }
        }

        public var exitCode: Int? {
            switch self {
            case .completed(let code), .failed(let code): code
            default: nil
            }
        }
    }

    public struct Task: Sendable, Equatable, Identifiable {
        /// `backgroundTaskId` / `taskId`: `b` and eight characters.
        public var id: String
        public var kind: Kind
        public var command: String?
        public var description: String?
        /// Where Claude Code writes its output, when something said (`<output-file>`, `outputFilePath`).
        public var outputFile: String?
        public var toolUseID: String?
        public var status: Status
        public var startedAt: Date?
        public var endedAt: Date?
        /// A command moved to the background after running this long in the foreground (`timedOutAfterMs`).
        public var movedAfterMs: Int?
        /// A Monitor's deadline (`timeoutMs`), counted from `startedAt`.
        public var timeoutMs: Int?
        /// A Monitor's last events, oldest first, at most `ClaudeBackgroundWork.eventLimit`, each clamped.
        public var events: [String] = []
        /// Every event it reported, the dropped ones included.
        public var eventCount = 0
        /// Claude Code's last word on it: `Background command "…" completed (exit code 0)`.
        public var summary: String?
        /// Scope sent the signal that ended it (`markStopRequested`): its `failed (exit 144)` is the user's doing.
        public var stoppedFromScope = false

        public init(id: String, kind: Kind, status: Status = .running) {
            self.id = id
            self.kind = kind
            self.status = status
        }

        /// When a Monitor gives up by itself.
        public var expiresAt: Date? {
            guard kind == .monitor, let startedAt, let timeoutMs, timeoutMs > 0 else { return nil }
            return startedAt.addingTimeInterval(TimeInterval(timeoutMs) / 1000)
        }

        /// The status as of `now`: a Monitor still read as running past its deadline has expired — Claude Code's
        /// expiry notice may simply not be read yet.
        public func status(at now: Date) -> Status {
            if status == .running, let expiresAt, now >= expiresAt { return .expired }
            return status
        }
    }

    /// The `/loop` wake-up the session set (`ScheduleWakeup`): only the last one counts.
    public struct Wakeup: Sendable, Equatable {
        public var scheduledFor: Date
        public var reason: String?
        public var prompt: String?
        public var toolUseID: String?
    }

    /// A cron of the session (`CronCreate`, `session_crons`).
    public struct Cron: Sendable, Equatable, Identifiable {
        public var id: String
        /// The cron expression (`cron`, `schedule`).
        public var schedule: String?
        /// Claude Code's own wording of it (`humanSchedule`).
        public var humanSchedule: String?
        public var prompt: String?
        public var recurring: Bool?
        public var nextFireAt: Date?
    }

    /// Every task, oldest launch first; finished ones beyond `finishedLimit` are dropped, oldest first.
    public var tasks: [Task] = []
    public var wakeup: Wakeup?
    public var crons: [Cron] = []

    public init() {}

    static let eventLimit = 5
    static let finishedLimit = 20
    static let textLimit = 2000
    static let eventTextLimit = 300

    /// The tasks still running, as of `now`.
    public func running(at now: Date) -> [Task] { tasks.filter { $0.status(at: now).isRunning } }

    public var isEmpty: Bool { tasks.isEmpty && wakeup == nil && crons.isEmpty }

    public func task(_ id: String) -> Task? { tasks.first { $0.id == id } }

    /// Only `b…` ids are background shells and Monitors.
    public static func isTracked(_ id: String) -> Bool { id.hasPrefix("b") && id.count > 1 }

    // MARK: Hooks

    public mutating func apply(_ facts: ClaudeHookFacts) {
        switch facts.event {
        case "PostToolUse":
            // A sub-agent's background shells are its own: the main `Stop` list may never name them, which would leave
            // them running here for good.
            guard facts.agentID == nil, let tool = facts.toolName else { return }
            toolResult(tool, input: facts.toolInput ?? .null, result: facts.toolResponse, toolUseID: facts.toolUseID, at: facts.at)
        case "Stop":
            guard facts.agentID == nil else { return }
            if let snapshot = facts.backgroundTasks { applySnapshot(snapshot, at: facts.at) }
            if let crons = facts.sessionCrons { applyCrons(crons) }
        case "UserPromptSubmit":
            // The wake-up fired: its prompt is this turn.
            if let wakeup, facts.at >= wakeup.scheduledFor.addingTimeInterval(-1) { self.wakeup = nil }
        case "SessionEnd":
            sessionEnded(at: facts.at)
        default:
            break
        }
    }

    // MARK: Transcript

    public mutating func apply(_ records: [ClaudeTranscriptRecord]) {
        for record in records {
            switch record {
            case .toolCall(let call) where !call.isError:
                toolResult(call.name, input: call.input, result: call.result, toolUseID: call.id, at: call.endedAt ?? call.startedAt)
            case .taskStatus(let status):
                applyStatus(status)
            case .taskNotification(let notification):
                applyNotification(notification)
            default:
                break
            }
        }
    }

    /// The session is over — `SessionEnd`, or its process exited: nothing it started is running any more, whatever
    /// was last said. A Monitor past its deadline expired; the rest stopped.
    public mutating func sessionEnded(at now: Date? = nil) {
        for index in tasks.indices where tasks[index].status == .running {
            let expired = now.map { tasks[index].status(at: $0) == .expired } ?? false
            tasks[index].status = expired ? .expired : .stopped
            tasks[index].endedAt = tasks[index].endedAt ?? now
        }
        wakeup = nil
        crons = []
    }

    /// Scope is about to signal the task's process: what ends it next is the user's stop, not a failure.
    public mutating func markStopRequested(_ id: String) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[index].stoppedFromScope = true
    }

    // MARK: Folding

    private mutating func toolResult(_ tool: String, input: JSONValue, result: JSONValue?, toolUseID: String?, at: Date?) {
        switch tool {
        case "Bash":
            // A denied or failed call answers with a string and no id: nothing went to the background.
            guard let id = result?["backgroundTaskId"]?.nonEmptyString, Self.isTracked(id) else { return }
            let moved = result?["timedOutAfterMs"]?.int
            update(id, kind: .shell) { task in
                task.command = task.command ?? Self.clamp(input["command"]?.nonEmptyString)
                task.description = task.description ?? Self.clamp(input["description"]?.nonEmptyString)
                task.toolUseID = task.toolUseID ?? toolUseID
                task.outputFile = task.outputFile ?? result?["persistedOutputPath"]?.nonEmptyString
                if let moved { task.movedAfterMs = moved }
                if task.startedAt == nil, let at {
                    task.startedAt = moved.map { at.addingTimeInterval(-TimeInterval($0) / 1000) } ?? at
                }
            }
        case "Monitor":
            guard let id = result?["taskId"]?.nonEmptyString, Self.isTracked(id) else { return }
            update(id, kind: .monitor) { task in
                task.kind = .monitor
                task.command = task.command ?? Self.clamp(input["command"]?.nonEmptyString ?? input["ws"]?["url"]?.nonEmptyString)
                task.description = task.description ?? Self.clamp(input["description"]?.nonEmptyString)
                task.toolUseID = task.toolUseID ?? toolUseID
                task.timeoutMs = result?["timeoutMs"]?.int ?? input["timeout_ms"]?.int ?? task.timeoutMs
                if task.startedAt == nil { task.startedAt = at }
            }
        case "TaskStop", "KillShell":
            // No notification follows a `TaskStop`: its result is the only word on it.
            let id = result?["task_id"]?.nonEmptyString ?? input["task_id"]?.nonEmptyString ?? input["shell_id"]?.nonEmptyString
            guard let id, Self.isTracked(id), let index = tasks.firstIndex(where: { $0.id == id }) else { return }
            if tasks[index].status.isRunning {
                tasks[index].status = .killed
                tasks[index].endedAt = at
            }
            tasks[index].command = tasks[index].command ?? Self.clamp(result?["command"]?.nonEmptyString)
        case "ScheduleWakeup":
            if result?["stopped"]?.bool == true {
                wakeup = nil
            } else if let ms = result?["scheduledFor"]?.double {
                wakeup = Wakeup(scheduledFor: Date(timeIntervalSince1970: ms / 1000),
                                reason: Self.clamp(input["reason"]?.nonEmptyString), prompt: Self.clamp(input["prompt"]?.nonEmptyString),
                                toolUseID: toolUseID)
            }
        case "CronCreate":
            guard let id = result?["id"]?.nonEmptyString else { return }
            var cron = crons.first { $0.id == id } ?? Cron(id: id)
            cron.schedule = input["cron"]?.nonEmptyString ?? cron.schedule
            cron.humanSchedule = result?["humanSchedule"]?.nonEmptyString ?? cron.humanSchedule
            cron.prompt = Self.clamp(input["prompt"]?.nonEmptyString) ?? cron.prompt
            cron.recurring = result?["recurring"]?.bool ?? input["recurring"]?.bool ?? cron.recurring ?? true
            cron.nextFireAt = result?["nextFireAt"]?.double.map { Date(timeIntervalSince1970: $0 / 1000) } ?? cron.nextFireAt
            crons.removeAll { $0.id == id }
            crons.append(cron)
        case "CronDelete":
            let id = result?["id"]?.nonEmptyString ?? input["id"]?.nonEmptyString
            crons.removeAll { $0.id == id }
        default:
            break
        }
    }

    private mutating func applyStatus(_ status: ClaudeTaskStatus) {
        guard Self.isTracked(status.taskID), status.taskType == nil || status.taskType == "local_bash" else { return }
        let next: Status? = switch status.status {
        case "running", "pending": nil
        case "completed": .completed(exitCode: nil)
        case "failed": .failed(exitCode: nil)
        case "killed": .killed
        case "stopped": .stopped
        default: nil
        }
        update(status.taskID, kind: .shell) { task in
            task.command = task.command ?? Self.clamp(status.command)
            task.description = task.description ?? Self.clamp(status.description)
            task.outputFile = task.outputFile ?? status.outputFile
            task.toolUseID = task.toolUseID ?? status.toolUseID
            if task.startedAt == nil { task.startedAt = status.at }
            // A notification knows more (an exit code): a bare status never overwrites what it said.
            if let next, task.status.isRunning || task.status == .ended {
                task.status = next
                task.endedAt = task.endedAt ?? status.at
            }
        }
    }

    private mutating func applyNotification(_ notification: ClaudeTaskNotification) {
        let summary = notification.summary ?? ""
        // One notice can stand for several tasks the previous session left: `Task ids: a, b, c.`
        let ids = ([notification.taskID] + Self.listedTaskIDs(summary)).filter(Self.isTracked)
        guard !ids.isEmpty else { return }
        let isMonitor = summary.hasPrefix("Monitor")
        for (position, id) in ids.enumerated() where position == 0 || !ids[..<position].contains(id) {
            update(id, kind: isMonitor ? .monitor : .shell) { task in
                if isMonitor { task.kind = .monitor }
                task.outputFile = task.outputFile ?? notification.outputFile
                task.toolUseID = task.toolUseID ?? notification.toolUseID
                if let event = notification.event {
                    if Self.isExpiry(event) {
                        task.status = .expired
                        task.endedAt = task.endedAt ?? notification.at
                    } else if notification.status == nil {
                        task.eventCount += 1
                        task.events.append(Self.clamp(event, to: Self.eventTextLimit))
                        if task.events.count > Self.eventLimit { task.events.removeFirst(task.events.count - Self.eventLimit) }
                    }
                }
                guard let status = Self.status(of: notification) else { return }
                task.status = status
                task.endedAt = notification.at ?? task.endedAt
                task.summary = Self.clamp(notification.summary)
            }
        }
    }

    /// The `Stop` hook's list of what still runs: a task this value reads as running but the list does not name is
    /// over — how, its notification will say.
    private mutating func applySnapshot(_ snapshot: [JSONValue], at: Date) {
        var listed: Set<String> = []
        for entry in snapshot {
            guard let id = entry["id"]?.nonEmptyString, Self.isTracked(id) else { continue }
            let type = entry["type"]?.nonEmptyString
            guard type == nil || type == "shell" || type == "monitor" || type == "local_bash" else { continue }
            listed.insert(id)
            let running = entry["status"]?.nonEmptyString.map { ["running", "pending"].contains($0) } ?? true
            update(id, kind: type == "monitor" ? .monitor : .shell) { task in
                if type == "monitor" { task.kind = .monitor }
                task.command = task.command ?? Self.clamp(entry["command"]?.nonEmptyString)
                task.description = task.description ?? Self.clamp(entry["description"]?.nonEmptyString)
                if task.startedAt == nil { task.startedAt = at }
                if !running, task.status.isRunning {
                    task.status = .ended
                    task.endedAt = at
                }
            }
        }
        // `scope-hook` cuts arrays to fit the wire: a list as long as a cut may be missing tasks that still run.
        guard !ClaudeHookFacts.clamps.contains(where: { $0.arrayLimit == snapshot.count }) else { return }
        for index in tasks.indices where tasks[index].status.isRunning && !listed.contains(tasks[index].id) {
            tasks[index].status = .ended
            tasks[index].endedAt = at
        }
    }

    /// `session_crons` is every cron still set: the rest were deleted or fired their one time.
    private mutating func applyCrons(_ snapshot: [JSONValue]) {
        guard !ClaudeHookFacts.clamps.contains(where: { $0.arrayLimit == snapshot.count }) else { return }
        crons = snapshot.compactMap { entry in
            guard let id = entry["id"]?.nonEmptyString else { return nil }
            var cron = crons.first { $0.id == id } ?? Cron(id: id)
            cron.schedule = entry["schedule"]?.nonEmptyString ?? entry["cron"]?.nonEmptyString ?? cron.schedule
            cron.humanSchedule = entry["humanSchedule"]?.nonEmptyString ?? cron.humanSchedule
            cron.prompt = Self.clamp(entry["prompt"]?.nonEmptyString) ?? cron.prompt
            cron.recurring = entry["recurring"]?.bool ?? cron.recurring
            return cron
        }
    }

    /// Changes the task `id`, made first when this is the first word on it; then drops the oldest finished tasks
    /// beyond `finishedLimit`.
    private mutating func update(_ id: String, kind: Kind, _ change: (inout Task) -> Void) {
        if let index = tasks.firstIndex(where: { $0.id == id }) {
            change(&tasks[index])
        } else {
            var task = Task(id: id, kind: kind)
            change(&task)
            tasks.append(task)
        }
        let finished = tasks.filter { !$0.status.isRunning }
        if finished.count > Self.finishedLimit {
            let dropped = Set(finished.prefix(finished.count - Self.finishedLimit).map(\.id))
            tasks.removeAll { dropped.contains($0.id) }
        }
    }

    // MARK: Reading Claude Code's words

    /// The status a notification gives, `nil` for a Monitor event (which leaves the task running).
    static func status(of notification: ClaudeTaskNotification) -> Status? {
        let summary = notification.summary ?? ""
        switch notification.status {
        case "completed":
            return .completed(exitCode: exitCode(in: summary))
        case "failed":
            return .failed(exitCode: exitCode(in: summary))
        case "killed":
            return .killed
        case "stopped":
            return .stopped
        default:
            return nil
        }
    }

    /// The exit code at the end of a summary: `… completed (exit code 0)`, `… (exit code 1: No matches found)`,
    /// `… failed with exit code 2`, `Monitor "…" script failed (exit 144)`. Read from the end: the quoted command
    /// before it may say "exit code" itself.
    static func exitCode(in summary: String) -> Int? {
        for marker in ["exit code ", "(exit "] {
            guard let range = summary.range(of: marker, options: .backwards) else { continue }
            let digits = summary[range.upperBound...].prefix { $0.isNumber || $0 == "-" }
            if let code = Int(digits) { return code }
        }
        return nil
    }

    /// `Task ids: bhxdn94nf, bj2y8ts1g.` at the end of a session-end notice.
    static func listedTaskIDs(_ summary: String) -> [String] {
        guard let range = summary.range(of: "Task ids:", options: .backwards) else { return [] }
        return summary[range.upperBound...]
            .split(whereSeparator: { $0 == "," || $0 == " " || $0 == "." || $0.isNewline })
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    /// `[Monitor expired after 5s with 1 event delivered. …]`
    static func isExpiry(_ event: String) -> Bool {
        event.trimmingCharacters(in: .whitespaces).hasPrefix("[Monitor expired")
    }

    static func clamp(_ text: String?, to limit: Int = textLimit) -> String? {
        text.map { clamp($0, to: limit) }
    }

    static func clamp(_ text: String, to limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit - 1)) + "…" : text
    }

    // MARK: Output file

    /// Where Claude Code writes a background task's output when nothing said: `<tmp>/claude-<uid>/<project>/<session>/
    /// tasks/<id>.output`, the project and session read off the transcript's path
    /// (`~/.claude/projects/<project>/<session>.jsonl`). A guess: check the file exists before trusting it.
    public static func derivedOutputFile(taskID: String, transcriptPath: String, uid: UInt32,
                                         temporaryRoot: String = "/tmp") -> String? {
        let transcript = URL(fileURLWithPath: transcriptPath)
        guard transcript.pathExtension == "jsonl", isTracked(taskID), !taskID.contains("/") else { return nil }
        let session = transcript.deletingPathExtension().lastPathComponent
        let project = transcript.deletingLastPathComponent().lastPathComponent
        guard !session.isEmpty, !project.isEmpty else { return nil }
        return URL(fileURLWithPath: temporaryRoot).appendingPathComponent("claude-\(uid)")
            .appendingPathComponent(project).appendingPathComponent(session)
            .appendingPathComponent("tasks").appendingPathComponent("\(taskID).output").path
    }
}

private extension ClaudeBackgroundWork.Cron {
    init(id: String) {
        self.id = id
    }
}
