import Foundation
import ScopeAdapters
import ScopeCore

/// One thread's turns as a timeline reads them: a live thread's from its `ThreadActivity`, a closed one's from the
/// task's `TaskTimelineLog`, which keeps them once the thread and its activity file are gone.
public struct TimelineLaneSource: Codable, Sendable, Equatable {
    public var threadID: String
    public var title: String
    public var driverID: String
    public var createdAt: Date
    /// When the thread was closed; `nil` while it is open.
    public var closedAt: Date?
    public var turns: [ThreadActivity.Turn]
    /// Live threads only: when the turn in progress started.
    public var openTurnSince: Date?
    /// Live threads only: what the thread shows now, which says whether its last wait is still going on.
    public var state: ThreadState?

    public init(threadID: String, title: String, driverID: String, createdAt: Date, closedAt: Date? = nil,
                turns: [ThreadActivity.Turn], openTurnSince: Date? = nil, state: ThreadState? = nil) {
        self.threadID = threadID
        self.title = title
        self.driverID = driverID
        self.createdAt = createdAt
        self.closedAt = closedAt
        self.turns = turns
        self.openTurnSince = openTurnSince
        self.state = state
    }
}

/// A pull request's checks as one refresh saw them, kept so the timeline can mark when they went red or green.
public struct TaskCheckMark: Codable, Sendable, Equatable {
    /// `passing`, `failing` or `pending` (`PullRequest.Checks`).
    public var state: String
    public var at: Date
    public var number: Int

    public init(state: String, at: Date, number: Int) {
        self.state = state
        self.at = at
        self.number = number
    }
}

/// A task since its creation: one lane per thread, its turns as bars of work, the stretches where it waited on the
/// owner, the task's own events as ticks, and three totals. Pure: built from records, drawn by the app, summed by
/// `scope summary`.
///
/// What counts as waiting on you:
/// - a question or a permission, from the moment the agent asked to the moment it went on;
/// - a finished (or failed) turn, from its end to the next prompt: the result sat there until someone came back.
///   A thread that is still showing an unread result keeps counting until now; once it was read and nothing followed,
///   it stops at its end — the app does not record when it was read.
/// A turn that was interrupted, or a thread that exited, waits on nobody.
///
/// Agent time adds the turns of every thread (two agents working an hour side by side is two hours of work); waiting
/// time is wall-clock, counted once however many threads wait at the same moment.
public struct TaskTimeline: Sendable, Equatable {
    public struct Span: Sendable, Equatable {
        public enum Kind: String, Sendable, CaseIterable {
            case working
            case waitingAnswer
            case waitingPermission
            case unreadResult

            public var isWait: Bool { self != .working }
        }

        public var kind: Kind
        public var start: Date
        public var end: Date
        /// The turn a working span draws; `nil` for the turn in progress and for waits.
        public var turn: ThreadActivity.Turn?
        /// The turn in progress, still growing.
        public var running: Bool

        public init(kind: Kind, start: Date, end: Date, turn: ThreadActivity.Turn? = nil, running: Bool = false) {
            self.kind = kind
            self.start = start
            self.end = end
            self.turn = turn
            self.running = running
        }

        public var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }
        public var failed: Bool { turn?.outcome == .failed }
    }

    public struct Lane: Sendable, Equatable, Identifiable {
        public var id: String
        public var title: String
        public var driverID: String
        public var closedAt: Date?
        /// Waits first, then work, each in time order.
        public var spans: [Span]
    }

    public struct Tick: Sendable, Equatable {
        public enum Kind: String, Sendable, CaseIterable {
            case created, pullRequestOpened, checksPassing, checksFailing, merged, pullRequestClosed, archived
        }

        public var kind: Kind
        public var at: Date
        public var label: String
    }

    public struct Totals: Sendable, Equatable {
        public var agent: TimeInterval
        public var waiting: TimeInterval
        public var elapsed: TimeInterval
    }

    public var start: Date
    public var end: Date
    public var lanes: [Lane]
    public var ticks: [Tick]
    public var totals: Totals

    /// - Parameters:
    ///   - end: where the timeline stops: the archive date, or now for a task still open.
    ///   - pullRequest: `(number, openedAt, mergedAt, closedAt)` of the task's pull request, dates as GitHub gave them.
    public static func build(
        createdAt: Date, archivedAt: Date?, now: Date,
        pullRequests: [(number: Int, openedAt: Date?, mergedAt: Date?, closedAt: Date?)] = [],
        checks: [TaskCheckMark] = [], lanes sources: [TimelineLaneSource]
    ) -> TaskTimeline {
        let start = createdAt
        let end = max(start, archivedAt ?? now)
        let clip = { (date: Date) in min(max(date, start), end) }

        let lanes = sources.sorted { ($0.createdAt, $0.threadID) < ($1.createdAt, $1.threadID) }.map { source in
            Lane(id: source.threadID, title: source.title, driverID: source.driverID, closedAt: source.closedAt,
                 spans: spans(of: source, end: end).compactMap { span in
                     var span = span
                     span.start = clip(span.start)
                     span.end = clip(span.end)
                     // A wait clipped to nothing is gone; a turn of no known length still marks its end.
                     return span.kind.isWait && span.duration == 0 ? nil : span
                 })
        }

        var ticks = [Tick(kind: .created, at: start, label: "Task created")]
        for pr in pullRequests {
            if let opened = pr.openedAt { ticks.append(Tick(kind: .pullRequestOpened, at: clip(opened), label: "#\(pr.number) opened")) }
            if let merged = pr.mergedAt {
                ticks.append(Tick(kind: .merged, at: clip(merged), label: "#\(pr.number) merged"))
            } else if let closed = pr.closedAt {
                ticks.append(Tick(kind: .pullRequestClosed, at: clip(closed), label: "#\(pr.number) closed"))
            }
        }
        ticks += checkTicks(checks).map { Tick(kind: $0.kind, at: clip($0.at), label: $0.label) }
        if let archivedAt { ticks.append(Tick(kind: .archived, at: clip(archivedAt), label: "Archived")) }
        ticks.sort { $0.at < $1.at }

        let all = lanes.flatMap(\.spans)
        let agent = all.filter { $0.kind == .working }.map(\.duration).reduce(0, +)
        let waiting = unionLength(all.filter(\.kind.isWait).map { ($0.start, $0.end) })
        return TaskTimeline(start: start, end: end, lanes: lanes, ticks: ticks,
                            totals: Totals(agent: agent, waiting: waiting, elapsed: end.timeIntervalSince(start)))
    }

    /// Agent and waiting time of a task, for `scope summary`.
    public static func totals(createdAt: Date, archivedAt: Date?, now: Date, lanes: [TimelineLaneSource]) -> Totals {
        build(createdAt: createdAt, archivedAt: archivedAt, now: now, lanes: lanes).totals
    }

    /// Work and waits of one thread, unclipped.
    static func spans(of source: TimelineLaneSource, end: Date) -> [Span] {
        let turns = source.turns.sorted { $0.endedAt < $1.endedAt }
        var work: [Span] = []
        var waits: [Span] = []
        for (index, turn) in turns.enumerated() {
            work.append(Span(kind: .working, start: turn.startedAt ?? turn.endedAt, end: turn.endedAt, turn: turn))
            guard let kind = waitKind(after: turn.outcome) else { continue }
            let next = index + 1 < turns.count ? (turns[index + 1].startedAt ?? turns[index + 1].endedAt) : source.openTurnSince
            if let next {
                if next > turn.endedAt { waits.append(Span(kind: kind, start: turn.endedAt, end: next)) }
            } else if let until = trailingWaitEnd(of: source, kind: kind, end: end) {
                waits.append(Span(kind: kind, start: turn.endedAt, end: until))
            }
        }
        if let open = source.openTurnSince {
            work.append(Span(kind: .working, start: open, end: source.closedAt.map { min($0, end) } ?? end, running: source.closedAt == nil))
        }
        return waits + work
    }

    static func waitKind(after outcome: ThreadActivity.Turn.Outcome) -> Span.Kind? {
        switch outcome {
        case .inputRequested: .waitingAnswer
        case .permissionRequested: .waitingPermission
        case .ended, .failed: .unreadResult
        case .interrupted, .exited: nil
        }
    }

    /// How long the last wait of a thread lasts: a closed thread's question until it was closed (an unread result
    /// there was most likely read before), a live thread's as long as it still shows it.
    static func trailingWaitEnd(of source: TimelineLaneSource, kind: Span.Kind, end: Date) -> Date? {
        if let closedAt = source.closedAt { return kind == .unreadResult ? nil : min(closedAt, end) }
        switch (kind, source.state) {
        case (.waitingAnswer, .waiting(.input)?), (.waitingPermission, .waiting(.permission)?): return end
        case (.unreadResult, let state?) where state.isUnreadResult: return end
        default: return nil
        }
    }

    /// One tick each time the checks settle on a colour other than the last one: a refresh that sees the same state
    /// again adds nothing, a new push that goes red again after a pending run does.
    static func checkTicks(_ marks: [TaskCheckMark]) -> [(kind: Tick.Kind, at: Date, label: String)] {
        var ticks: [(kind: Tick.Kind, at: Date, label: String)] = []
        var last: String?
        for mark in marks.sorted(by: { $0.at < $1.at }) {
            defer { last = mark.state }
            guard mark.state != last else { continue }
            switch mark.state {
            case "passing": ticks.append((.checksPassing, mark.at, "Checks passing on #\(mark.number)"))
            case "failing": ticks.append((.checksFailing, mark.at, "Checks failing on #\(mark.number)"))
            default: break
            }
        }
        return ticks
    }

    /// Total length covered by `intervals`, overlaps counted once.
    static func unionLength(_ intervals: [(Date, Date)]) -> TimeInterval {
        var total: TimeInterval = 0
        var current: (Date, Date)?
        for interval in intervals.sorted(by: { $0.0 < $1.0 }) where interval.1 > interval.0 {
            if let open = current, interval.0 <= open.1 {
                current = (open.0, max(open.1, interval.1))
            } else {
                if let open = current { total += open.1.timeIntervalSince(open.0) }
                current = interval
            }
        }
        if let open = current { total += open.1.timeIntervalSince(open.0) }
        return total
    }

    /// The stretches where something happened: work, and the ticks. What the scale keeps at full size.
    public var activity: [DateInterval] {
        lanes.flatMap(\.spans).filter { $0.kind == .working }.map { DateInterval(start: $0.start, end: $0.end) }
            + ticks.map { DateInterval(start: $0.at, duration: 0) }
    }
}
