import Foundation
import ScopeCore

/// What a thread's driver has been doing, folded from its adapter events: the last tool it ran and on what, the
/// turn in progress, the recent turns and how each ended, its last answer, and where its transcript is.
///
/// A *turn* here is a stretch of work: it opens on a prompt (or on the first tool run after a wait) and closes the
/// moment the agent stops — done, failed, or waiting on someone. A turn that asks for a permission and then goes on
/// is therefore two turns, which is what a timeline of who was waiting on whom wants.
///
/// Folded from `AdapterEvent` rather than `HookEvent`: it is what the app holds, and its `receivedAt` is the app's
/// own clock, the one `AgentReply` and `ThreadWait` already compare against.
public struct ThreadActivity: Codable, Sendable, Equatable {
    /// Schema version written by this build. Anything else decodes as no activity (see `ThreadActivityStore`).
    public static let currentVersion = 1
    /// Turns kept, oldest dropped first.
    public static let turnLimit = 200
    /// UTF-8 bytes of the last reply kept, from its end: an answer's conclusion is at its bottom.
    public static let replyLimit = 16 * 1024
    /// Characters of a turn's reply kept on the turn itself (`Turn.said`): enough to recognise it when hovering it.
    public static let saidLimit = 140
    /// UTF-8 bytes of the answer being written kept, from its end (`saying`): more than `replyLimit`, since this one
    /// is read as it grows and a cut at the top is less of a surprise than one in the middle.
    public static let sayingLimit = 64 * 1024

    /// The answer the agent is writing, from `turn.said` events: one message of the driver, gathered flush by flush,
    /// replaced when the next message starts and dropped when the turn ends (`lastReply` then holds the answer).
    /// Not written to the activity file: a half-written answer is worth nothing after a restart.
    public struct Saying: Sendable, Equatable {
        /// The driver's own id for the message, so a flush is appended to the right one.
        public var messageID: String?
        public var text: String
        /// `true` once the driver said the message is complete.
        public var isFinal: Bool
        /// When the last piece arrived.
        public var at: Date

        public init(messageID: String? = nil, text: String, isFinal: Bool = false, at: Date) {
            self.messageID = messageID
            self.text = text
            self.isFinal = isFinal
            self.at = at
        }
    }

    public struct Tool: Codable, Sendable, Equatable {
        public var name: String
        /// `HookStdin.toolTarget`: the file, the command's first line, the pattern, …
        public var target: String?
        public var at: Date
        /// How long the call took, when the driver says (`PostToolUse`'s `duration_ms`).
        public var durationMs: Int?

        public init(name: String, target: String? = nil, at: Date, durationMs: Int? = nil) {
            self.name = name
            self.target = target
            self.at = at
            self.durationMs = durationMs
        }
    }

    /// Tool calls kept per turn, the first ones: a turn that runs more is a turn whose count says enough.
    public static let callLimit = 60

    public struct Turn: Codable, Sendable, Equatable {
        public enum Outcome: String, Codable, Sendable, CaseIterable {
            case ended
            case failed
            case inputRequested = "input"
            case permissionRequested = "permission"
            /// A new prompt arrived while the turn was still open: Esc has no hook, this is how it shows.
            case interrupted
            /// The process went away (or the app did) mid-turn.
            case exited

            /// The agent stopped to wait for someone, and goes on from here once answered.
            public var isWait: Bool { self == .inputRequested || self == .permissionRequested }
        }

        /// `nil` when the driver never reports a turn start (Codex `notify`).
        public var startedAt: Date?
        public var endedAt: Date
        public var outcome: Outcome
        /// Tool calls reported during the turn.
        public var tools: Int
        /// `turn.failed`: the driver's error code (`rate_limit`, …).
        public var error: String?
        /// The first words of what the agent answered at the end of the turn, at most `saidLimit` characters, when
        /// its driver says. Optional so files written before it existed still decode under the same version.
        public var said: String?
        /// The calls reported during the turn, the first `callLimit` of them, in order. Optional for the same reason.
        public var calls: [Tool]?

        public init(startedAt: Date?, endedAt: Date, outcome: Outcome, tools: Int = 0, error: String? = nil, said: String? = nil,
                    calls: [Tool]? = nil) {
            self.startedAt = startedAt
            self.endedAt = endedAt
            self.outcome = outcome
            self.tools = tools
            self.error = error
            self.said = said
            self.calls = calls
        }

        /// Seconds of work, `0` when the start is unknown.
        public var duration: TimeInterval { startedAt.map { max(0, endedAt.timeIntervalSince($0)) } ?? 0 }
    }

    public var version: Int
    public var lastTool: Tool?
    /// What the agent is waiting on, when its driver says: the tool a permission is asked for and its target, or
    /// the question tool and the question. `nil` again as soon as the agent goes on.
    public var pendingRequest: Tool?
    /// When the turn in progress started; `nil` between turns.
    public var turnStartedAt: Date?
    /// Tool calls so far in the turn in progress.
    public var turnTools: Int
    /// The calls of the turn in progress, the first `callLimit`: what the reading column lists under the answer.
    public var turnCalls: [Tool] = []
    /// Finished turns, oldest first, at most `turnLimit`.
    public var turns: [Turn]
    /// The agent's last answer, its end kept within `replyLimit`. `thread.read` keeps answering from the full one.
    public var lastReply: AgentReply?
    public var transcriptPath: String?
    /// What the agent plans and how far it is (`AgentPlan`), folded from the todo and plan tools it reports; `nil`
    /// until it reports one. Kept in the file: a plan is as much the state of the work as the turns are.
    public var plan: AgentPlan?
    /// When the driver sent the event that closed the last turn as ended or failed (`AdapterEvent.sentAt`): anything
    /// it sent before that belongs to that turn, however late it reaches the app (see `isLate(_:)`).
    public var turnEndSentAt: Date?
    /// The answer being written, while a turn is open and the driver reports it; `nil` otherwise.
    public var saying: Saying?
    /// The driver's sub-agents still running, by id, with when each started (`agent.started` without its
    /// `agent.ended`). A turn can end while one runs in the background — Claude Code answers "waiting for N
    /// background agents" and starts a new turn when they report — so the thread is not done with its work
    /// until they are (`runningAgents(now:)`, read by `ThreadWait`). Not written to the activity file: no
    /// sub-agent outlives the process, and a restart would carry a ghost.
    public var agents: [String: Date] = [:]

    /// The longest a sub-agent is believed to still run without its end being reported: an `agent.ended` lost on
    /// the way (a hook that timed out, a kill) must not hold every later wait on the thread to its deadline.
    public static let agentLimit: TimeInterval = 2 * 3600

    /// Everything but `saying`, `turnCalls` and `agents`, which belong to the live process: a restart closes the
    /// open turn as `.exited` (`restoring`), so what it was writing and running is not worth a write per tool call.
    enum CodingKeys: String, CodingKey {
        case version, lastTool, pendingRequest, turnStartedAt, turnTools, turns, lastReply, transcriptPath, turnEndSentAt, plan
    }

    /// The calls of the last turn that ended or failed, or of the one in progress: what "this turn" means to a reader.
    public var currentCalls: [Tool] {
        inTurn || turns.isEmpty ? turnCalls : (turns.last?.calls ?? [])
    }

    public init(lastTool: Tool? = nil, pendingRequest: Tool? = nil, turnStartedAt: Date? = nil, turnTools: Int = 0, turns: [Turn] = [],
                lastReply: AgentReply? = nil, transcriptPath: String? = nil) {
        version = Self.currentVersion
        self.lastTool = lastTool
        self.pendingRequest = pendingRequest
        self.turnStartedAt = turnStartedAt
        self.turnTools = turnTools
        self.turns = turns
        self.lastReply = lastReply
        self.transcriptPath = transcriptPath
    }

    /// `true` while a turn is open.
    public var inTurn: Bool { turnStartedAt != nil }

    /// How many sub-agents are still at work, as far as the driver said: the ones started within `agentLimit`.
    public func runningAgents(now: Date = .now) -> Int {
        agents.values.filter { now.timeIntervalSince($0) < Self.agentLimit }.count
    }

    /// `true` for an event that arrives after its turn is over and must not reopen it:
    ///
    /// - one the driver sent before the end of the last turn, delivered late (each hook is its own process and its
    ///   own connection, and a background app's queues are throttled);
    /// - a tool report or a request once the last turn *ended* or *failed* and no prompt opened another: a
    ///   background command or sub-agent still reporting, a permission notification for a call already decided.
    ///   Only a prompt (`UserPromptSubmit`, a background task's completion included) starts the next turn.
    ///
    /// A turn closed any other way still goes on with its next tool: after a question or a permission (`isWait`),
    /// after Esc (`interrupted`, which may have been an Esc the driver ignored), or with no history at all. So does
    /// one Scope just handed a prompt (`promptPending`): should its `UserPromptSubmit` hook be lost, the tools are
    /// the only sign the work began.
    public func isLate(_ event: AdapterEvent, promptPending: Bool = false) -> Bool {
        switch event.kind {
        case .turnStarted, .inputRequested, .permissionRequested: break
        case .turnEnded, .turnFailed, .threadEnded, .sessionStarted, .turnSaid, .agentStarted, .agentEnded, .limitsReported: return false
        }
        if let sent = event.sentAt, let end = turnEndSentAt, sent < end { return true }
        guard !promptPending, !inTurn, let last = turns.last, last.outcome == .ended || last.outcome == .failed else { return false }
        let isPrompt = event.kind == .turnStarted && (event.payload[HookEvent.toolKey] ?? "").isEmpty
        return !isPrompt
    }

    /// The activity after `event`; `promptPending` as in `isLate(_:promptPending:)`.
    public func apply(_ event: AdapterEvent, promptPending: Bool = false) -> ThreadActivity {
        var next = self
        let at = event.receivedAt
        if let path = event.payload[HookEvent.transcriptKey], !path.isEmpty { next.transcriptPath = path }
        if let reply = AgentReply.from(event) { next.lastReply = Self.bounded(reply) }
        // A todo list or a plan is the latest word on the work whatever turn it reaches the app in.
        if event.kind == .turnStarted, let tool = event.payload[HookEvent.toolKey], !tool.isEmpty,
           let plan = AgentPlan.applying(tool: tool, raw: event.raw, to: plan, at: at) {
            next.plan = plan
        }
        if isLate(event, promptPending: promptPending) {
            // Still the last thing the agent ran, but no turn of its own.
            if event.kind == .turnStarted, let tool = event.payload[HookEvent.toolKey], !tool.isEmpty {
                next.lastTool = Tool(name: tool, target: event.payload[HookEvent.targetKey], at: at)
            }
            return next
        }
        if event.kind == .turnEnded || event.kind == .turnFailed, let sent = event.sentAt {
            next.turnEndSentAt = max(sent, turnEndSentAt ?? sent)
        }
        switch event.kind {
        case .inputRequested, .permissionRequested:
            // Claude Code follows a question's `PreToolUse` with a `Notification` that names no tool: that one adds
            // nothing to the request already kept.
            if let tool = event.payload[HookEvent.toolKey], !tool.isEmpty {
                next.pendingRequest = Tool(name: tool, target: event.payload[HookEvent.targetKey], at: at)
            }
        case .sessionStarted, .turnSaid, .agentStarted, .agentEnded, .limitsReported:
            break
        default:
            next.pendingRequest = nil
        }
        switch event.kind {
        case .agentStarted:
            if let id = event.payload[HookEvent.agentKey], !id.isEmpty { next.agents[id] = at }
        case .agentEnded:
            if let id = event.payload[HookEvent.agentKey] { next.agents[id] = nil }
        case .turnSaid:
            next.say(event.payload[HookEvent.saidKey] ?? "", message: event.payload[HookEvent.messageKey],
                     final: event.payload[HookEvent.finalKey] == "true", at: at)
        case .turnStarted:
            if let tool = event.payload[HookEvent.toolKey], !tool.isEmpty {
                // `PostToolUse`: the tool has run. After a wait, this is the turn going on.
                let call = Tool(name: tool, target: event.payload[HookEvent.targetKey], at: at,
                                durationMs: event.payload[HookEvent.durationKey].flatMap(Int.init))
                next.lastTool = call
                if next.turnStartedAt == nil { next.turnStartedAt = at }
                next.turnTools += 1
                if next.turnCalls.count < Self.callLimit { next.turnCalls.append(call) }
            } else {
                // `UserPromptSubmit`: a new prompt. One still open was interrupted without the keystroke being
                // seen (`closingOpenTurn`), at some point after the last thing it reported.
                next = next.closingOpenTurn(as: .interrupted, at: next.turnStartedAt ?? at)
                next.turnStartedAt = at
                next.saying = nil
            }
        case .turnEnded:
            next.close(.ended, at: at)
        case .turnFailed:
            next.close(.failed, at: at, error: event.payload[HookEvent.errorKey])
        case .inputRequested:
            next.close(.inputRequested, at: at, onlyIfOpen: true)
        case .permissionRequested:
            next.close(.permissionRequested, at: at, onlyIfOpen: true)
        case .threadEnded:
            next.close(.exited, at: at, onlyIfOpen: true)
            next.agents = [:]
        case .sessionStarted:
            // A new session of the driver (a relaunch, a resume): whatever the previous one ran is gone with it.
            next.agents = [:]
        case .limitsReported:
            break
        }
        return next
    }

    /// Closes the open turn, if any, at `date` or at its last tool if that came later: `.exited` when the process
    /// is gone or the app was not running to see the end, `.interrupted` when the user stopped it (Esc and Ctrl-C
    /// have no hook; the app sees the keystroke).
    public func closingOpenTurn(as outcome: Turn.Outcome = .exited, at date: Date) -> ThreadActivity {
        var next = self
        next.close(outcome, at: max(date, lastTool?.at ?? date), onlyIfOpen: true)
        return next
    }

    /// `saved`, read back after a restart, under what arrived since: its open turn is closed as `.exited` at the
    /// last moment it knew of (no process outlives the app), its turns go before the new ones, and anything the
    /// new events did not say yet is taken from it.
    public func restoring(_ saved: ThreadActivity) -> ThreadActivity {
        let saved = saved.closingOpenTurn(at: saved.turnStartedAt ?? saved.lastTool?.at ?? .distantPast)
        var next = self
        next.turns = Array((saved.turns + turns).suffix(Self.turnLimit))
        next.lastTool = lastTool ?? saved.lastTool
        next.lastReply = lastReply ?? saved.lastReply
        next.transcriptPath = transcriptPath ?? saved.transcriptPath
        next.plan = plan ?? saved.plan
        next.turnEndSentAt = turnEndSentAt ?? saved.turnEndSentAt
        return next
    }

    /// A piece of the answer being written. A different message id starts the text over: the driver writes several
    /// messages in a turn (one between each tool call), and the reading column shows the one in progress, which is
    /// what `lastReply` will hold once the turn ends. Nothing opens a turn here: the text is read, not counted.
    private mutating func say(_ delta: String, message: String?, final: Bool, at: Date) {
        if var current = saying, current.messageID == message {
            current.text += delta
            current.isFinal = final
            current.at = at
            saying = current
        } else {
            saying = Saying(messageID: message, text: delta, isFinal: final, at: at)
        }
        if let text = saying?.text, text.utf8.count > Self.sayingLimit {
            saying?.text = Self.tail(text, bytes: Self.sayingLimit)
        }
    }

    /// Records the end of a turn. A request arriving between turns says nothing new (Claude Code sends a
    /// question's `PreToolUse` and then a `Notification` for the same prompt), so it is skipped. An end with no turn
    /// open is still a turn: the driver never reported its start (Codex), or it went on after a wait, from that wait.
    private mutating func close(_ outcome: Turn.Outcome, at date: Date, error: String? = nil, onlyIfOpen: Bool = false) {
        guard inTurn || !onlyIfOpen else { return }
        // The answer is written: `lastReply` has it, and a turn that stopped another way has no answer to show.
        saying = nil
        let start = turnStartedAt ?? turns.last.flatMap { $0.outcome.isWait ? $0.endedAt : nil }
        // `apply` takes the reply before it closes the turn: a reply dated inside the turn is this turn's answer.
        let said = lastReply.flatMap { reply in
            reply.at >= (start ?? turns.last?.endedAt ?? .distantPast) && reply.at <= date ? Self.excerpt(reply.text) : nil
        }
        turns.append(Turn(startedAt: start, endedAt: date, outcome: outcome, tools: turnTools,
                          error: error.flatMap { $0.isEmpty ? nil : $0 }, said: said, calls: turnCalls.isEmpty ? nil : turnCalls))
        if turns.count > Self.turnLimit { turns.removeFirst(turns.count - Self.turnLimit) }
        turnStartedAt = nil
        turnTools = 0
        turnCalls = []
    }

    /// The opening of `text` on one line, whitespace collapsed, cut at a word before `saidLimit`; `nil` when empty.
    public static func excerpt(_ text: String, limit: Int = saidLimit) -> String? {
        let line = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !line.isEmpty else { return nil }
        guard line.count > limit else { return line }
        let cut = line.prefix(limit)
        let atWord = cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut
        return atWord + "…"
    }

    /// `reply` cut to its last `replyLimit` UTF-8 bytes, behind a `…`.
    public static func bounded(_ reply: AgentReply) -> AgentReply {
        guard reply.text.utf8.count > replyLimit else { return reply }
        return AgentReply(text: tail(reply.text, bytes: replyLimit), at: reply.at)
    }

    /// The last `bytes` UTF-8 bytes of `text`, behind a `…`.
    static func tail(_ text: String, bytes: Int) -> String {
        // A cut in the middle of a character decodes as U+FFFD; drop that rather than show it.
        let tail = String(decoding: text.utf8.suffix(bytes - 3), as: UTF8.self).drop { $0 == "\u{FFFD}" }
        return "…" + tail
    }
}

/// Owner of `<home>/threads/<id>.activity.json`, beside the thread record rather than inside it: the record is
/// written on every event and stays small, the activity is written when a turn ends and holds up to 200 turns and a
/// reply. `ThreadRecordStore.loadAll` ignores the file (its stem is not a thread id).
public actor ThreadActivityStore {
    public nonisolated let directory: URL

    public init(home: URL) {
        directory = ScopeHome.threadsURL(home: home)
    }

    public nonisolated func url(for id: ThreadID) -> URL {
        directory.appending(path: "\(id.rawValue).activity.json", directoryHint: .notDirectory)
    }

    /// The saved activity, `nil` when there is none, or it is unreadable or from another schema version: this is
    /// history, not state, and losing it never stops a thread.
    public func load(_ id: ThreadID) -> ThreadActivity? {
        guard let activity = try? JSONStore.load(ThreadActivity.self, from: url(for: id), fractionalSeconds: true),
              activity.version == ThreadActivity.currentVersion else { return nil }
        return activity
    }

    public func save(_ activity: ThreadActivity, for id: ThreadID) {
        do {
            try JSONStore.save(activity, to: url(for: id), fractionalSeconds: true)
        } catch {
            Log.threads.error("thread activity \(id) write failed: \(String(describing: error))")
        }
    }

    /// Missing file is not an error.
    public func delete(_ id: ThreadID) {
        try? FileManager.default.removeItem(at: url(for: id))
    }
}
