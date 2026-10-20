import Foundation

/// The sub-agents a Claude Code session launched (the `Agent` tool, `Task` before it), each with what it is, how it
/// stands and what it cost — folded from every place Claude Code says something about one:
///
/// - the `Agent` call, from its `PostToolUse` hook and from the transcript (`ClaudeToolCall`): type, description,
///   model, background or not, and `agentId` in its result — at once for a background launch (`async_launched`), at
///   the end for a foreground one (`completed`, with its totals);
/// - the `SubagentStart` / `SubagentStop` hooks: `agent_type`, `agent_transcript_path`, `last_assistant_message`.
///   Claude Code runs agents of its own that report a `SubagentStop` with an empty `agent_type`: those are not the
///   session's sub-agents and are ignored;
/// - the `<task-notification>` a background sub-agent's end writes to the transcript: its status, report and totals;
/// - `agent-<id>.meta.json` beside the sub-agent's own transcript, read by the app (`apply(_:agentID:transcriptPath:)`).
///
/// The `agentId` of the call's result, the `agent_id` of the hooks and the file name are one id (docs/research/
/// claude-native.md §1.3). Facts that name only the call (`tool_use_id`) start an entry of their own, merged into the
/// agent's once something names both, so the order in which hooks and transcript arrive does not matter.
///
/// No sub-agent outlives its process: one still running when the session ends, or found running in a transcript read
/// back by a later process (`epoch`), is `interrupted`.
public struct ClaudeSubagents: Sendable, Equatable {
    public enum State: String, Sendable, Codable, CaseIterable {
        case running
        case completed
        case failed
        /// Stopped by the agent (`TaskStop`) or by the user.
        case stopped
        /// The session ended before the sub-agent reported: it runs no more, and how it would have ended is unknown.
        case interrupted

        public var isRunning: Bool { self == .running }
    }

    public struct Agent: Sendable, Equatable, Identifiable {
        /// `agentId` once known, `tool:<tool_use_id>` until then.
        public var id: String
        public var agentID: String?
        /// The `Agent` call that launched it.
        public var toolUseID: String?
        /// `subagent_type` / `agent_type`: `general-purpose`, `Explore`, `fork`, a custom agent's name.
        public var type: String?
        public var description: String?
        /// The model it ran on: the call's `resolvedModel`, else what it asked for (`haiku`), `inherit` left out.
        public var model: String?
        /// Launched in the background (`run_in_background`, `async_launched`): it reports with a notification.
        public var background: Bool?
        public var state: State
        public var startedAt: Date?
        public var endedAt: Date?
        /// What Claude Code measured (`duration_ms`, `totalDurationMs`); `duration(now:)` falls back on the clock.
        public var durationMs: Int?
        public var tokens: Int?
        public var toolUses: Int?
        /// The start of its report: the notification's `result`, the call's text, or its last message.
        public var result: String?
        /// Its own transcript (`agent_transcript_path`, or found beside its `meta.json`).
        public var transcriptPath: String?
        /// `isolation: worktree`: the worktree it ran in, once known.
        public var isolation: String?
        public var worktreePath: String?
        public var worktreeBranch: String?
        /// `spawnDepth` from its `meta.json`: 1 for a sub-agent of the session, 2 for one of its sub-agents, …
        public var depth: Int?
        /// The sub-agent that launched it, when a hook said (`agent_id` on the `Agent` call's own `PostToolUse`).
        public var parentID: String?
        public var isFork: Bool = false
        /// Its `meta.json` was read.
        public var hasMeta: Bool = false

        public init(id: String, state: State = .running, startedAt: Date? = nil) {
            self.id = id
            self.state = state
            self.startedAt = startedAt
        }

        /// Its state as a reader should see it: running, once the thread's process is gone, is `interrupted`.
        public func state(alive: Bool) -> State {
            state.isRunning && !alive ? .interrupted : state
        }

        /// How long it ran: what Claude Code measured, else from its start to its end or to `now` while it runs.
        public func duration(now: Date) -> TimeInterval? {
            if let durationMs { return TimeInterval(durationMs) / 1000 }
            guard let startedAt else { return nil }
            guard let end = endedAt ?? (state.isRunning ? now : nil) else { return nil }
            return max(0, end.timeIntervalSince(startedAt))
        }

        /// Fills what `self` does not know from `other`; the more final state wins.
        mutating func absorb(_ other: Agent) {
            agentID = agentID ?? other.agentID
            toolUseID = toolUseID ?? other.toolUseID
            type = type ?? other.type
            description = description ?? other.description
            model = model ?? other.model
            background = background ?? other.background
            if state.isRunning { state = other.state }
            startedAt = [startedAt, other.startedAt].compactMap { $0 }.min()
            endedAt = endedAt ?? other.endedAt
            durationMs = durationMs ?? other.durationMs
            tokens = tokens ?? other.tokens
            toolUses = toolUses ?? other.toolUses
            result = result ?? other.result
            transcriptPath = transcriptPath ?? other.transcriptPath
            isolation = isolation ?? other.isolation
            worktreePath = worktreePath ?? other.worktreePath
            worktreeBranch = worktreeBranch ?? other.worktreeBranch
            depth = depth ?? other.depth
            parentID = parentID ?? other.parentID
            isFork = isFork || other.isFork
            hasMeta = hasMeta || other.hasMeta
            if let agentID { id = agentID }
        }
    }

    /// Oldest launch first, at most `limit`.
    public private(set) var agents: [Agent] = []
    /// When the running process began (its last `SessionStart` that was not a compaction): a sub-agent started before
    /// it and never reported is not running any more, whatever the transcript read back says.
    public private(set) var epoch: Date?

    public init() {}

    /// Entries kept: the finished ones go first, oldest first.
    public static let limit = 50
    /// Characters of a report kept.
    public static let resultLimit = 2000
    /// The tools that launch a sub-agent: `Task` is the name before Claude Code 2.1.
    public static let tools: Set<String> = ["Agent", "Task"]

    public var running: [Agent] { agents.filter(\.state.isRunning) }

    public func agent(_ id: String) -> Agent? {
        agents.first { $0.id == id || $0.agentID == id }
    }

    /// Agent ids whose `meta.json` was not read yet.
    public var agentsWithoutMeta: [String] {
        agents.filter { !$0.hasMeta }.compactMap(\.agentID)
    }

    // MARK: Hooks

    public mutating func apply(_ facts: ClaudeHookFacts) {
        switch facts.event {
        case "SessionStart":
            guard facts.body["source"]?.string != "compact" else { return }
            epoch = facts.at
        case "SessionEnd":
            for index in agents.indices where agents[index].state.isRunning {
                agents[index].state = .interrupted
                agents[index].endedAt = agents[index].endedAt ?? facts.at
            }
        case "SubagentStart":
            guard let id = facts.agentID, let type = facts.agentType else { return }
            let index = entry(agentID: id, toolUseID: nil, at: facts.at)
            agents[index].type = agents[index].type ?? type
        case "SubagentStop":
            guard let id = facts.agentID, let type = facts.agentType else { return }
            let index = entry(agentID: id, toolUseID: nil, at: nil)
            agents[index].type = agents[index].type ?? type
            agents[index].transcriptPath = facts.agentTranscriptPath ?? agents[index].transcriptPath
            if agents[index].result == nil, let message = facts.body["last_assistant_message"]?.nonEmptyString {
                agents[index].result = Self.excerpt(message)
            }
            if agents[index].state.isRunning || agents[index].state == .interrupted {
                agents[index].state = .completed
                agents[index].endedAt = agents[index].endedAt ?? facts.at
            }
        case "PostToolUse":
            guard let name = facts.toolName, Self.tools.contains(name), let call = facts.toolUseID else { return }
            launched(call: call, input: facts.toolInput ?? .null, result: facts.toolResponse, isError: false,
                     startedAt: facts.at, endedAt: facts.at, parent: facts.agentID)
        default:
            return
        }
        settle()
    }

    // MARK: Transcript

    public mutating func apply(_ records: [ClaudeTranscriptRecord]) {
        var changed = false
        for record in records {
            switch record {
            case .toolCall(let call) where Self.tools.contains(call.name):
                launched(call: call.id, input: call.input, result: call.result, isError: call.isError,
                         startedAt: call.startedAt, endedAt: call.endedAt, parent: nil)
                changed = true
            case .taskNotification(let notification):
                changed = reported(notification) || changed
            case .taskStatus(let status) where status.taskType == "local_agent":
                guard let index = known(agentID: status.taskID, toolUseID: nil) else { continue }
                if agents[index].description == nil { agents[index].description = status.description }
                if status.status == "completed", agents[index].state.isRunning {
                    agents[index].state = .completed
                    agents[index].endedAt = agents[index].endedAt ?? status.at
                }
                changed = true
            default:
                continue
            }
        }
        if changed { settle() }
    }

    // MARK: meta.json

    /// What `agent-<id>.meta.json` says, found beside the transcript at `transcriptPath`.
    public mutating func apply(_ meta: ClaudeSubagentMeta, agentID: String, transcriptPath: String?) {
        guard known(agentID: agentID, toolUseID: meta.toolUseID) != nil else { return }
        let index = entry(agentID: agentID, toolUseID: meta.toolUseID, at: nil)
        var agent = agents[index]
        agent.hasMeta = true
        agent.type = agent.type ?? meta.agentType
        agent.description = agent.description ?? meta.description
        agent.model = agent.model ?? meta.model.flatMap { $0 == "inherit" ? nil : $0 }
        agent.depth = meta.spawnDepth ?? agent.depth
        agent.isFork = agent.isFork || meta.isFork == true || meta.agentType == "fork"
        agent.worktreePath = agent.worktreePath ?? meta.worktreePath
        agent.worktreeBranch = agent.worktreeBranch ?? meta.worktreeBranch
        agent.transcriptPath = agent.transcriptPath ?? transcriptPath
        if agent.background == nil, let shape = meta.requestShape { agent.background = shape == "background" }
        agents[index] = agent
        settle()
    }

    /// Where Claude Code keeps a sub-agent's transcript and `meta.json`: `<session>/subagents/agent-<id>.jsonl`, beside
    /// the session's own `<session>.jsonl`.
    public static func transcriptURL(agentID: String, sessionTranscript: String) -> URL {
        let session = URL(fileURLWithPath: sessionTranscript).deletingPathExtension()
        return session.appending(path: "subagents/agent-\(agentID).jsonl", directoryHint: .notDirectory)
    }

    public static func metaURL(agentID: String, sessionTranscript: String) -> URL {
        transcriptURL(agentID: agentID, sessionTranscript: sessionTranscript).deletingPathExtension().appendingPathExtension("meta.json")
    }

    // MARK: Waiting

    /// How many sub-agents are still at work, for `thread.wait`: the ones the hooks saw start and not stop
    /// (`hookAgents`, `ThreadActivity.agents`, which also counts Claude Code's own agents), less those this value saw
    /// end — a notification in the transcript says it as surely as a `SubagentStop` — plus those it saw launched by
    /// the running process and not end, whose `SubagentStart` was lost. Nothing older than `limit` counts.
    public func runningCount(hookAgents: [String: Date], now: Date, limit: TimeInterval) -> Int {
        var ids: Set<String> = []
        for (id, started) in hookAgents where now.timeIntervalSince(started) < limit {
            if let agent = agent(id), !agent.state.isRunning { continue }
            ids.insert(id)
        }
        guard let epoch else { return ids.count }
        for agent in agents where agent.state.isRunning {
            guard let started = agent.startedAt, started >= epoch, now.timeIntervalSince(started) < limit else { continue }
            ids.insert(agent.agentID ?? agent.id)
        }
        return ids.count
    }

    // MARK: Folding

    /// An `Agent` call, launched or answered.
    private mutating func launched(call: String, input: JSONValue, result: JSONValue?, isError: Bool, startedAt: Date?,
                                   endedAt: Date?, parent: String?) {
        let agentID = result?["agentId"]?.nonEmptyString
        let index = entry(agentID: agentID, toolUseID: call, at: startedAt)
        var agent = agents[index]
        agent.type = agent.type ?? input["subagent_type"]?.nonEmptyString ?? result?["agentType"]?.nonEmptyString
        agent.description = agent.description ?? input["description"]?.nonEmptyString ?? result?["description"]?.nonEmptyString
        agent.model = result?["resolvedModel"]?.nonEmptyString
            ?? agent.model ?? input["model"]?.nonEmptyString.flatMap { $0 == "inherit" ? nil : $0 }
        agent.isolation = agent.isolation ?? input["isolation"]?.nonEmptyString
        agent.parentID = agent.parentID ?? parent
        if let start = startedAt { agent.startedAt = min(agent.startedAt ?? start, start) }
        let status = result?["status"]?.string
        if status == "async_launched" || result?["isAsync"]?.bool == true {
            agent.background = true
        } else if let background = input["run_in_background"]?.bool, agent.background == nil {
            agent.background = background
        }
        if isError {
            agent.state = .failed
            agent.endedAt = agent.endedAt ?? endedAt
        } else if status == "completed" {
            agent.background = agent.background ?? false
            agent.state = .completed
            agent.endedAt = agent.endedAt ?? endedAt
            agent.durationMs = result?["totalDurationMs"]?.int ?? agent.durationMs
            agent.tokens = result?["totalTokens"]?.int ?? agent.tokens
            agent.toolUses = result?["totalToolUseCount"]?.int ?? agent.toolUses
            if let text = result?["content"]?.array?.compactMap({ $0["text"]?.nonEmptyString }).joined(separator: "\n"), !text.isEmpty {
                agent.result = Self.excerpt(text)
            }
        }
        if let path = result?["worktreePath"]?.nonEmptyString { agent.worktreePath = path }
        if let branch = result?["worktreeBranch"]?.nonEmptyString { agent.worktreeBranch = branch }
        agents[index] = agent
    }

    /// A `<task-notification>`, when it is about a sub-agent: one this value knows, or an id of the shape Claude Code
    /// gives sub-agents (`a…`) with a sub-agent's totals. A shell (`b…`), a Monitor or an MCP task is someone else's.
    private mutating func reported(_ notification: ClaudeTaskNotification) -> Bool {
        let looksLikeAgent = notification.taskID.hasPrefix("a")
            && (notification.tokens != nil || notification.summary?.hasPrefix("Agent") == true)
        guard known(agentID: notification.taskID, toolUseID: notification.toolUseID) != nil || looksLikeAgent else { return false }
        let index = entry(agentID: notification.taskID, toolUseID: notification.toolUseID, at: nil)
        var agent = agents[index]
        agent.background = agent.background ?? true
        switch notification.status {
        case "failed": agent.state = .failed
        case "killed", "stopped": agent.state = .stopped
        default: agent.state = .completed
        }
        agent.endedAt = notification.at ?? agent.endedAt
        agent.durationMs = notification.durationMs ?? agent.durationMs
        agent.tokens = notification.tokens ?? agent.tokens
        agent.toolUses = notification.toolUses ?? agent.toolUses
        if let result = notification.result { agent.result = Self.excerpt(result) }
        agent.worktreePath = notification.worktreePath ?? agent.worktreePath
        agent.worktreeBranch = notification.worktreeBranch ?? agent.worktreeBranch
        agents[index] = agent
        return true
    }

    /// The entry `agentID` or `toolUseID` names, if any.
    private func known(agentID: String?, toolUseID: String?) -> Int? {
        if let agentID, let index = agents.firstIndex(where: { $0.agentID == agentID }) { return index }
        if let toolUseID, let index = agents.firstIndex(where: { $0.toolUseID == toolUseID }) { return index }
        return nil
    }

    /// The entry for `agentID` / `toolUseID`, made when neither is known; two entries that turn out to be one agent —
    /// one named by its id, the other by its call — are merged into the earlier.
    private mutating func entry(agentID: String?, toolUseID: String?, at: Date?) -> Int {
        let byAgent = agentID.flatMap { id in agents.firstIndex { $0.agentID == id } }
        let byCall = toolUseID.flatMap { id in agents.firstIndex { $0.toolUseID == id } }
        var index: Int
        switch (byAgent, byCall) {
        case let (first?, second?) where first != second:
            let (keep, drop) = (min(first, second), max(first, second))
            agents[keep].absorb(agents[drop])
            agents.remove(at: drop)
            index = keep
        case let (found?, _), let (nil, found?):
            index = found
        case (nil, nil):
            let id = agentID ?? toolUseID.map { "tool:\($0)" } ?? "agent-\(agents.count)"
            agents.append(Agent(id: id, startedAt: at))
            index = agents.count - 1
        }
        if let agentID, agents[index].agentID == nil {
            agents[index].agentID = agentID
            agents[index].id = agentID
        }
        if let toolUseID, agents[index].toolUseID == nil { agents[index].toolUseID = toolUseID }
        if let at, agents[index].startedAt.map({ at < $0 }) ?? true { agents[index].startedAt = at }
        return index
    }

    /// Ends what the running process cannot be running, and keeps the list within `limit`.
    private mutating func settle() {
        if let epoch {
            for index in agents.indices where agents[index].state.isRunning {
                guard let started = agents[index].startedAt, started < epoch else { continue }
                agents[index].state = .interrupted
            }
        }
        while agents.count > Self.limit {
            let index = agents.firstIndex { !$0.state.isRunning } ?? 0
            agents.remove(at: index)
        }
    }

    static func excerpt(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > resultLimit ? String(trimmed.prefix(resultLimit - 1)) + "…" : trimmed
    }
}

/// `agent-<id>.meta.json`, beside a sub-agent's transcript: what Claude Code wrote when it spawned it. Not a
/// documented format (docs/research/claude-native.md §1.3): every field is optional, and a file that is not a JSON
/// object reads as `nil`.
public struct ClaudeSubagentMeta: Sendable, Equatable {
    public var agentType: String?
    public var description: String?
    public var toolUseID: String?
    public var spawnDepth: Int?
    /// What was asked for (`haiku`, `inherit`), not the resolved model.
    public var model: String?
    public var isFork: Bool?
    public var worktreePath: String?
    public var worktreeBranch: String?
    public var finished: Bool?
    /// `background` or `foreground`.
    public var requestShape: String?

    public init?(json: some DataProtocol) {
        guard let value = JSONValue(json: json), value.object != nil else { return nil }
        agentType = value["agentType"]?.nonEmptyString
        description = value["description"]?.nonEmptyString
        toolUseID = value["toolUseId"]?.nonEmptyString
        spawnDepth = value["spawnDepth"]?.int
        model = value["model"]?.nonEmptyString
        isFork = value["isFork"]?.bool
        worktreePath = value["worktreePath"]?.nonEmptyString
        worktreeBranch = value["worktreeBranch"]?.nonEmptyString
        finished = value["finished"]?.bool
        requestShape = value["requestShape"]?.nonEmptyString
    }

    /// Reads `url`; `nil` when it is missing or unreadable.
    public static func read(_ url: URL) -> ClaudeSubagentMeta? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return ClaudeSubagentMeta(json: data)
    }
}
