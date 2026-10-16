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

    public struct Tool: Codable, Sendable, Equatable {
        public var name: String
        /// `HookStdin.toolTarget`: the file, the command's first line, the pattern, …
        public var target: String?
        public var at: Date

        public init(name: String, target: String? = nil, at: Date) {
            self.name = name
            self.target = target
            self.at = at
        }
    }

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

        public init(startedAt: Date?, endedAt: Date, outcome: Outcome, tools: Int = 0, error: String? = nil) {
            self.startedAt = startedAt
            self.endedAt = endedAt
            self.outcome = outcome
            self.tools = tools
            self.error = error
        }
    }

    public var version: Int
    public var lastTool: Tool?
    /// When the turn in progress started; `nil` between turns.
    public var turnStartedAt: Date?
    /// Tool calls so far in the turn in progress.
    public var turnTools: Int
    /// Finished turns, oldest first, at most `turnLimit`.
    public var turns: [Turn]
    /// The agent's last answer, its end kept within `replyLimit`. `thread.read` keeps answering from the full one.
    public var lastReply: AgentReply?
    public var transcriptPath: String?

    public init(lastTool: Tool? = nil, turnStartedAt: Date? = nil, turnTools: Int = 0, turns: [Turn] = [],
                lastReply: AgentReply? = nil, transcriptPath: String? = nil) {
        version = Self.currentVersion
        self.lastTool = lastTool
        self.turnStartedAt = turnStartedAt
        self.turnTools = turnTools
        self.turns = turns
        self.lastReply = lastReply
        self.transcriptPath = transcriptPath
    }

    /// `true` while a turn is open.
    public var inTurn: Bool { turnStartedAt != nil }

    /// The activity after `event`.
    public func apply(_ event: AdapterEvent) -> ThreadActivity {
        var next = self
        let at = event.receivedAt
        if let path = event.payload[HookEvent.transcriptKey], !path.isEmpty { next.transcriptPath = path }
        if let reply = AgentReply.from(event) { next.lastReply = Self.bounded(reply) }
        switch event.kind {
        case .turnStarted:
            if let tool = event.payload[HookEvent.toolKey], !tool.isEmpty {
                // `PostToolUse`: the tool has run. After a wait, this is the turn going on.
                next.lastTool = Tool(name: tool, target: event.payload[HookEvent.targetKey], at: at)
                if next.turnStartedAt == nil { next.turnStartedAt = at }
                next.turnTools += 1
            } else {
                // `UserPromptSubmit`: a new prompt. One still open was interrupted.
                next.close(.interrupted, at: at)
                next.turnStartedAt = at
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
        case .sessionStarted:
            break
        }
        return next
    }

    /// Closes the open turn, if any, as `.exited`: the process is gone, or the app was not running to see the end.
    public func closingOpenTurn(at date: Date) -> ThreadActivity {
        var next = self
        next.close(.exited, at: max(date, lastTool?.at ?? date), onlyIfOpen: true)
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
        return next
    }

    /// Records the end of a turn. A request arriving between turns says nothing new (Claude Code sends a
    /// `PermissionRequest` and then a `Notification` for the same prompt), so it is skipped. An end with no turn
    /// open is still a turn: the driver never reported its start (Codex), or it went on after a wait, from that wait.
    private mutating func close(_ outcome: Turn.Outcome, at date: Date, error: String? = nil, onlyIfOpen: Bool = false) {
        guard inTurn || (!onlyIfOpen && outcome != .interrupted) else { return }
        let start = turnStartedAt ?? turns.last.flatMap { $0.outcome.isWait ? $0.endedAt : nil }
        turns.append(Turn(startedAt: start, endedAt: date, outcome: outcome, tools: turnTools,
                          error: error.flatMap { $0.isEmpty ? nil : $0 }))
        if turns.count > Self.turnLimit { turns.removeFirst(turns.count - Self.turnLimit) }
        turnStartedAt = nil
        turnTools = 0
    }

    /// `reply` cut to its last `replyLimit` UTF-8 bytes, behind a `…`.
    public static func bounded(_ reply: AgentReply) -> AgentReply {
        let bytes = reply.text.utf8
        guard bytes.count > replyLimit else { return reply }
        // A cut in the middle of a character decodes as U+FFFD; drop that rather than show it.
        let tail = String(decoding: bytes.suffix(replyLimit - 3), as: UTF8.self).drop { $0 == "\u{FFFD}" }
        return AgentReply(text: "…" + tail, at: reply.at)
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
