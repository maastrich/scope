import Foundation

/// The compactions of a Claude Code session, and whether one is under way.
///
/// The list comes from the transcript (`compact_boundary`): it has the figures — tokens before and after, how long
/// it took — and is there again after a relaunch. The hooks only say one is running: from `PreCompact` until
/// `PostCompact`, the boundary itself, or anything that proves it over (a compacted session starting, a turn
/// ending), so a `PreCompact` whose `PostCompact` never came cannot leave it running.
public struct ClaudeCompactions: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        /// `auto` or `manual`.
        public var trigger: String?
        public var preTokens: Int?
        public var postTokens: Int?
        public var durationMs: Int?
        public var at: Date?

        public init(trigger: String? = nil, preTokens: Int? = nil, postTokens: Int? = nil, durationMs: Int? = nil, at: Date? = nil) {
            self.trigger = trigger
            self.preTokens = preTokens
            self.postTokens = postTokens
            self.durationMs = durationMs
            self.at = at
        }

        public var isAutomatic: Bool { trigger == "auto" }
    }

    /// A compaction under way: its trigger and when `PreCompact` said so — set once, not on every hook.
    public struct Running: Sendable, Equatable {
        public var trigger: String?
        public var since: Date
    }

    /// Oldest first.
    public private(set) var entries: [Entry] = []
    public private(set) var running: Running?

    static let limit = 100

    public init() {}

    public var count: Int { entries.count }
    public var last: Entry? { entries.last }
    public var isRunning: Bool { running != nil }

    /// Hooks that prove a compaction is over without being its `PostCompact`.
    static let endingEvents: Set<String> = ["PostCompact", "Stop", "StopFailure", "SessionEnd", "UserPromptSubmit"]

    public mutating func apply(_ facts: ClaudeHookFacts) {
        // A sub-agent's context is its own business.
        guard facts.agentID == nil else { return }
        if facts.event == "PreCompact" {
            running = Running(trigger: facts.body["trigger"]?.nonEmptyString, since: facts.at)
        } else if Self.endingEvents.contains(facts.event)
                    || (facts.event == "SessionStart" && facts.body["source"]?.string == "compact") {
            running = nil
        }
    }

    public mutating func apply(_ records: [ClaudeTranscriptRecord]) {
        for case .compaction(let compaction) in records {
            running = nil
            let entry = Entry(trigger: compaction.trigger, preTokens: compaction.preTokens, postTokens: compaction.postTokens,
                              durationMs: compaction.durationMs, at: compaction.at)
            // A transcript read again from its start (rewritten, or followed anew) gives the same boundaries again.
            guard !entries.contains(where: { $0.at == entry.at && $0.preTokens == entry.preTokens }) else { continue }
            entries.append(entry)
            if entries.count > Self.limit { entries.removeFirst(entries.count - Self.limit) }
        }
    }
}
