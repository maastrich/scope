import Foundation

/// What a Claude Code transcript says that no hook does: a background command or sub-agent finishing (its
/// `<task-notification>`), the live state of background tasks, compactions, the permission mode, the MCP servers
/// still connecting or failed, the pull request the session opened.
///
/// None of this is a documented format (docs/research/claude-native.md §1.3): every record is read tolerantly — a type
/// this build does not know, a key that moved, a line that is not JSON are skipped, never thrown.
public enum ClaudeTranscriptRecord: Sendable, Equatable {
    /// A background task reported: a command finished or was killed, a Monitor saw an event, a sub-agent finished.
    case taskNotification(ClaudeTaskNotification)
    /// Claude Code's own view of a background task (`attachment` `task_status`).
    case taskStatus(ClaudeTaskStatus)
    /// A call to one of `ClaudeTranscriptTail.trackedTools`, once its result is written.
    case toolCall(ClaudeToolCall)
    /// The conversation was compacted (`system` `compact_boundary`).
    case compaction(ClaudeCompaction)
    /// The permission mode changed (`permission-mode`): `default`, `auto`, `plan`, `acceptEdits`, `bypassPermissions`.
    case permissionMode(String)
    /// MCP servers still connecting, failed or waiting for authentication (`attachment` `deferred_tools_delta`).
    case mcpServers(ClaudeMCPServerReport)
    /// A pull request the session linked (`pr-link`).
    case pullRequest(ClaudePullRequestLink)
    /// The session's running cost (`cost-state`).
    case cost(ClaudeCostState)
    /// A turn's duration and the background agents still pending at its end (`system` `turn_duration`).
    case turnDuration(ClaudeTurnDuration)
}

public struct ClaudeTaskNotification: Sendable, Equatable {
    public var taskID: String
    public var toolUseID: String?
    public var outputFile: String?
    /// `completed`, `failed`, `killed`, `stopped`; absent for a Monitor event.
    public var status: String?
    /// One line Claude Code wrote: `Background command "…" completed (exit code 0)`, `Agent "…" finished`, …
    public var summary: String?
    public var note: String?
    /// A sub-agent's report, or an MCP task's result.
    public var result: String?
    /// A Monitor event's text.
    public var event: String?
    public var taskType: String?
    /// A sub-agent's totals (`<usage>`).
    public var tokens: Int?
    public var toolUses: Int?
    public var durationMs: Int?
    /// A sub-agent run in its own worktree.
    public var worktreePath: String?
    public var worktreeBranch: String?
    public var at: Date?

    public init(taskID: String, at: Date? = nil) {
        self.taskID = taskID
        self.at = at
    }
}

public struct ClaudeTaskStatus: Sendable, Equatable {
    public var taskID: String
    /// `local_bash`, `local_agent`, …
    public var taskType: String?
    /// `running`, `completed`, …
    public var status: String?
    public var description: String?
    public var outputFile: String?
    public var deltaSummary: String?
    /// A shell task's command and the call that started it.
    public var command: String?
    public var toolUseID: String?
    public var at: Date?
}

public struct ClaudeToolCall: Sendable, Equatable {
    public var id: String
    public var name: String
    /// The call's input and its structured result (`toolUseResult`), clamped like a hook payload.
    public var input: JSONValue
    public var result: JSONValue?
    public var isError: Bool
    public var startedAt: Date?
    public var endedAt: Date?
}

public struct ClaudeCompaction: Sendable, Equatable {
    /// `auto` or `manual`.
    public var trigger: String?
    public var preTokens: Int?
    public var postTokens: Int?
    public var durationMs: Int?
    public var at: Date?
}

public struct ClaudeMCPServerReport: Sendable, Equatable {
    public struct Failure: Sendable, Equatable {
        public var name: String
        public var error: String?
        /// `CONNECTION_CLOSED`, `CONNECT_TIMEOUT`, `ENOTFOUND`, …
        public var code: String?
    }

    public var pending: [String]
    public var failed: [Failure]
    public var needsAuth: [String]
    public var at: Date?
}

public struct ClaudePullRequestLink: Sendable, Equatable {
    public var number: Int
    public var url: String?
    /// `owner/repo`.
    public var repository: String?
    public var at: Date?
}

public struct ClaudeCostState: Sendable, Equatable {
    public var totalCostUSD: Double?
    public var linesAdded: Int?
    public var linesRemoved: Int?
    public var at: Date?
}

public struct ClaudeTurnDuration: Sendable, Equatable {
    public var durationMs: Int?
    public var pendingBackgroundAgents: Int?
    public var at: Date?
}

/// Reads a session transcript incrementally — from the offset the last read stopped at, complete lines only — and
/// turns what it gained into `ClaudeTranscriptRecord`s. A value: the app keeps one per thread, copies it to read off
/// the main thread, and keeps the copy back.
public struct ClaudeTranscriptTail: Sendable, Equatable {
    /// The file this tail follows; reading another one starts it over.
    public private(set) var path: String?
    public private(set) var offset: UInt64 = 0
    /// Tool calls written but not answered yet, by id: a result names its call, never its tool.
    var pendingCalls: [String: PendingCall] = [:]
    /// Notifications already returned: Claude Code writes each one up to three times (the queue, the queued-command
    /// attachment, the message itself).
    var seenNotifications: Set<String> = []
    var seenOrder: [String] = []

    struct PendingCall: Sendable, Equatable {
        var name: String
        var input: JSONValue
        var at: Date?
    }

    public init() {}

    /// Tools whose call and result are returned as `toolCall`: the ones that start, stop or schedule background
    /// work, ask the user, or change the session's mode. `Bash` only when it ran in the background.
    public static let trackedTools: Set<String> = [
        "Agent", "Task", "Bash", "Monitor", "TaskStop", "KillShell", "ScheduleWakeup", "CronCreate", "CronDelete",
        "AskUserQuestion", "ExitPlanMode", "EnterPlanMode", "EnterWorktree", "ExitWorktree", "Skill", "Workflow",
    ]

    /// Lines are read this many bytes at a time.
    public static let chunkSize = 1 << 20
    static let pendingLimit = 500
    static let seenLimit = 2000
    /// Bounds of what a tracked call keeps of its input and result.
    static let clamp = (stringLimit: 2000, arrayLimit: 50, depth: 6)

    /// Substrings one of which every interesting line contains: the rest (most of a transcript) is skipped without
    /// being decoded.
    static let markers: [Data] = ["\"tool_use\"", "toolUseResult", "task-notification", "task_status", "compact_boundary",
                                  "permission-mode", "deferred_tools_delta", "pr-link", "cost-state", "turn_duration"]
        .map { Data($0.utf8) }

    /// Reads what `url` gained since the last read. A different file, or one shorter than the offset (rewritten),
    /// is read from its start. Throws when the file cannot be opened.
    public mutating func read(_ url: URL, chunkSize: Int = chunkSize) throws -> [ClaudeTranscriptRecord] {
        if path != url.path {
            self = ClaudeTranscriptTail()
            path = url.path
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        if size < offset { offset = 0 }
        guard offset < size else { return [] }
        try handle.seek(toOffset: offset)
        var records: [ClaudeTranscriptRecord] = []
        var pending = Data()
        while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
            pending.append(chunk)
            guard let lastNewline = pending.lastIndex(of: 0x0A) else { continue }
            let complete = pending[pending.startIndex...lastNewline]
            for line in complete.split(separator: 0x0A, omittingEmptySubsequences: true) {
                records += self.records(line)
            }
            offset += UInt64(complete.count)
            pending = Data(pending[pending.index(after: lastNewline)...])
        }
        return records
    }

    /// The records one line holds; also remembers the tracked calls it opens.
    public mutating func records(_ line: some DataProtocol) -> [ClaudeTranscriptRecord] {
        let data = Data(line)
        guard Self.markers.contains(where: { data.range(of: $0) != nil }),
              let json = JSONValue(json: data), json["isSidechain"]?.bool != true else { return [] }
        let at = json["timestamp"]?.string.flatMap(TranscriptUsage.parseDate)
        switch json["type"]?.string {
        case "assistant":
            rememberCalls(in: json, at: at)
            return []
        case "user":
            var found = answeredCalls(in: json, at: at)
            if json["origin"]?["kind"]?.string == "task-notification" || json["message"]?["content"]?.string?.contains("<task-notification>") == true,
               let text = json["message"]?["content"]?.string {
                found += notifications(in: text, at: at)
            }
            return found
        case "queue-operation":
            guard json["operation"]?.string == "enqueue", let text = json["content"]?.string else { return [] }
            return notifications(in: text, at: at)
        case "attachment":
            return attachment(json["attachment"] ?? .null, at: at)
        case "system":
            return system(json, at: at)
        case "permission-mode":
            return json["permissionMode"]?.nonEmptyString.map { [.permissionMode($0)] } ?? []
        case "pr-link":
            guard let number = json["prNumber"]?.int else { return [] }
            return [.pullRequest(ClaudePullRequestLink(number: number, url: json["prUrl"]?.nonEmptyString,
                                                       repository: json["prRepository"]?.nonEmptyString, at: at))]
        case "cost-state":
            return [.cost(ClaudeCostState(totalCostUSD: json["totalCostUSD"]?.double, linesAdded: json["totalLinesAdded"]?.int,
                                          linesRemoved: json["totalLinesRemoved"]?.int, at: at))]
        default:
            return []
        }
    }

    private mutating func rememberCalls(in json: JSONValue, at: Date?) {
        for block in json["message"]?["content"]?.array ?? [] where block["type"]?.string == "tool_use" {
            guard let id = block["id"]?.nonEmptyString, let name = block["name"]?.nonEmptyString,
                  Self.trackedTools.contains(name) else { continue }
            if pendingCalls.count >= Self.pendingLimit { pendingCalls.removeAll() }
            let input = (block["input"] ?? .null).clamped(stringLimit: Self.clamp.stringLimit, arrayLimit: Self.clamp.arrayLimit,
                                                         depth: Self.clamp.depth)
            pendingCalls[id] = PendingCall(name: name, input: input, at: at)
        }
    }

    private mutating func answeredCalls(in json: JSONValue, at: Date?) -> [ClaudeTranscriptRecord] {
        var found: [ClaudeTranscriptRecord] = []
        for block in json["message"]?["content"]?.array ?? [] where block["type"]?.string == "tool_result" {
            guard let id = block["tool_use_id"]?.nonEmptyString, let call = pendingCalls.removeValue(forKey: id) else { continue }
            let result = json["toolUseResult"].map {
                $0.clamped(stringLimit: Self.clamp.stringLimit, arrayLimit: Self.clamp.arrayLimit, depth: Self.clamp.depth)
            }
            if call.name == "Bash", call.input["run_in_background"]?.bool != true, result?["backgroundTaskId"]?.nonEmptyString == nil {
                continue
            }
            found.append(.toolCall(ClaudeToolCall(id: id, name: call.name, input: call.input, result: result,
                                                  isError: block["is_error"]?.bool ?? false, startedAt: call.at, endedAt: at)))
        }
        return found
    }

    private mutating func attachment(_ attachment: JSONValue, at: Date?) -> [ClaudeTranscriptRecord] {
        switch attachment["type"]?.string {
        case "task_status":
            guard let id = attachment["taskId"]?.nonEmptyString else { return [] }
            return [.taskStatus(ClaudeTaskStatus(taskID: id, taskType: attachment["taskType"]?.nonEmptyString,
                                                 status: attachment["status"]?.nonEmptyString,
                                                 description: attachment["description"]?.nonEmptyString,
                                                 outputFile: attachment["outputFilePath"]?.nonEmptyString,
                                                 deltaSummary: attachment["deltaSummary"]?.nonEmptyString,
                                                 command: attachment["shell"]?["command"]?.nonEmptyString,
                                                 toolUseID: attachment["shell"]?["toolUseId"]?.nonEmptyString, at: at))]
        case "queued_command":
            guard let text = attachment["prompt"]?.string, text.contains("<task-notification>") else { return [] }
            return notifications(in: text, at: at)
        case "deferred_tools_delta":
            let pending = (attachment["pendingMcpServers"]?.array ?? []).compactMap(\.nonEmptyString)
            let needsAuth = (attachment["needsAuthMcpServers"]?.array ?? []).compactMap(\.nonEmptyString)
            let failed = (attachment["failedMcpServers"]?.array ?? []).compactMap { server -> ClaudeMCPServerReport.Failure? in
                guard let name = server["name"]?.nonEmptyString else { return nil }
                return .init(name: name, error: server["error"]?.nonEmptyString, code: server["errorCode"]?.nonEmptyString)
            }
            // Most deltas are about deferred tools only; a report with no server in it says nothing about them.
            let saysSomething = attachment["pendingMcpServers"] != nil || attachment["failedMcpServers"] != nil
                || attachment["needsAuthMcpServers"] != nil
            guard saysSomething else { return [] }
            return [.mcpServers(ClaudeMCPServerReport(pending: pending, failed: failed, needsAuth: needsAuth, at: at))]
        default:
            return []
        }
    }

    private func system(_ json: JSONValue, at: Date?) -> [ClaudeTranscriptRecord] {
        switch json["subtype"]?.string {
        case "compact_boundary":
            let meta = json["compactMetadata"] ?? .null
            return [.compaction(ClaudeCompaction(trigger: meta["trigger"]?.nonEmptyString, preTokens: meta["preTokens"]?.int,
                                                 postTokens: meta["postTokens"]?.int, durationMs: meta["durationMs"]?.int, at: at))]
        case "turn_duration":
            return [.turnDuration(ClaudeTurnDuration(durationMs: json["durationMs"]?.int,
                                                     pendingBackgroundAgents: json["pendingBackgroundAgentCount"]?.int, at: at))]
        default:
            return []
        }
    }

    /// Every `<task-notification>` block in `text` not returned before.
    mutating func notifications(in text: String, at: Date?) -> [ClaudeTranscriptRecord] {
        var found: [ClaudeTranscriptRecord] = []
        var rest = Substring(text)
        while let open = rest.range(of: "<task-notification>") {
            let after = rest[open.upperBound...]
            let close = after.range(of: "</task-notification>")
            let body = close.map { after[..<$0.lowerBound] } ?? after
            rest = close.map { after[$0.upperBound...] } ?? ""
            let key = body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !seenNotifications.contains(key), let notification = Self.notification(body, at: at) else { continue }
            remember(key)
            found.append(.taskNotification(notification))
        }
        return found
    }

    private mutating func remember(_ key: String) {
        seenNotifications.insert(key)
        seenOrder.append(key)
        if seenOrder.count > Self.seenLimit {
            seenNotifications.remove(seenOrder.removeFirst())
        }
    }

    /// One notification's tags; `nil` without a `task-id`.
    static func notification(_ body: Substring, at: Date?) -> ClaudeTaskNotification? {
        guard let id = tag("task-id", in: body), !id.isEmpty else { return nil }
        var notification = ClaudeTaskNotification(taskID: id, at: at)
        notification.toolUseID = tag("tool-use-id", in: body)
        notification.outputFile = tag("output-file", in: body)
        notification.status = tag("status", in: body)
        notification.summary = tag("summary", in: body)
        notification.note = tag("note", in: body)
        notification.result = tag("result", in: body)
        notification.event = tag("event", in: body)
        notification.taskType = tag("task-type", in: body)
        if let usage = rawTag("usage", in: body) {
            notification.tokens = tag("subagent_tokens", in: usage).flatMap { Int($0) } ?? tag("total_tokens", in: usage).flatMap { Int($0) }
            notification.toolUses = tag("tool_uses", in: usage).flatMap { Int($0) }
            notification.durationMs = tag("duration_ms", in: usage).flatMap { Int($0) }
        }
        if let worktree = rawTag("worktree", in: body) {
            notification.worktreePath = tag("worktreePath", in: worktree)
            notification.worktreeBranch = tag("worktreeBranch", in: worktree)
        }
        return notification
    }

    /// The text between `<name>` and `</name>`, trimmed; `nil` when absent or empty.
    static func tag(_ name: String, in text: Substring) -> String? {
        rawTag(name, in: text).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
    }

    static func rawTag(_ name: String, in text: Substring) -> Substring? {
        guard let open = text.range(of: "<\(name)>") else { return nil }
        let after = text[open.upperBound...]
        guard let close = after.range(of: "</\(name)>") else { return nil }
        return after[..<close.lowerBound]
    }
}
