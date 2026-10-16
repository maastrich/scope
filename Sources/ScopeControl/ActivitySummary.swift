import Foundation
import ScopeCore

/// `scope summary [period]` — what was done over a period, scope by scope.
public struct SummaryParams: Codable, Sendable, Equatable {
    /// `last week`, `2026-10-01..2026-10-14`, … (`ActivityPeriod.grammar`); `nil` = `ActivityPeriod.defaultExpression`.
    public var period: String?
    /// Slug, name or id of one scope, declared or not any more; `nil` for every scope.
    public var scope: String?
    /// Id or slug of one task: its whole brief and every thread, whatever the period.
    public var task: String?

    public init(period: String? = nil, scope: String? = nil, task: String? = nil) {
        self.period = period
        self.scope = scope
        self.task = task
    }
}

/// How a task ended, or where it stands — judged from the record alone. What its threads last said is kept when it is
/// archived or closed (`TaskDeliverable`), but an answer does not say whether the work landed.
public enum TaskOutcome: String, Codable, Sendable, CaseIterable {
    /// Its pull request was seen merged.
    case merged
    /// Archived or closed with a pull request Scope never saw merged nor closed: handed over, fate unknown here.
    case delivered
    /// Its pull request was closed unmerged, or the task was closed without one: dropped on the way.
    case abandoned
    /// Archived without a pull request: finished without code to merge, or set aside — Scope cannot tell which.
    case archived
    /// Still open.
    case active

    /// The verdict from what the record holds. A merged pull request wins over everything: the work landed even if
    /// the task is still open.
    public static func classify(archived: Bool, closed: Bool, pullRequestState: String?, hasPullRequest: Bool) -> TaskOutcome {
        if pullRequestState == "merged" { return .merged }
        if !archived && !closed { return .active }
        if pullRequestState == "closed" { return .abandoned }
        if hasPullRequest { return .delivered }
        return closed ? .abandoned : .archived
    }
}

public struct SummaryResult: Codable, Sendable, Equatable {
    public struct Period: Codable, Sendable, Equatable {
        public var label: String
        public var since: Date
        /// Excluded.
        public var until: Date
        public var timeZone: String
    }

    public struct PullRequest: Codable, Sendable, Equatable {
        public var number: Int
        public var url: URL
        public var title: String
        /// `open`, `merged`, `closed`; absent when Scope never saw it after binding it — ask GitHub.
        public var state: String?
    }

    public struct Thread: Codable, Sendable, Equatable {
        public var id: String
        public var title: String
        public var driver: String
        public var createdAt: Date
        public var lastLaunchedAt: Date?
        /// When it was closed; absent while it still exists.
        public var closedAt: Date?
        public var launches: Int
        /// The driver's own session id, for a driver that keeps transcripts of its own (Claude Code's `--resume`).
        public var session: String?
        public var openedByAgent: Bool
        /// Tokens its agent consumed, all told (`TokenLedger`); absent when Scope read no transcript for it.
        public var tokens: Int?
    }

    public struct Task: Codable, Sendable, Equatable {
        public var id: String
        public var slug: String
        public var name: String
        public var topic: String?
        public var branch: String
        public var repos: [String]
        public var outcome: TaskOutcome
        public var createdAt: Date
        public var archivedAt: Date?
        /// When it was closed (its record deleted); absent otherwise.
        public var closedAt: Date?
        /// The latest date Scope knows of: a thread launched or closed, the task archived or closed.
        public var lastActivity: Date
        public var pullRequest: PullRequest?
        public var createdByAgent: Bool
        public var parentTask: String?
        /// The opening lines of the brief, at most `ActivitySummary.briefLimit` characters; the detail has it whole.
        public var brief: String?
        public var threads: [Thread]
        /// Tokens its threads consumed, all told; absent when Scope read a transcript for none of them.
        public var tokens: Int?
        /// Seconds its agents worked, every thread added up; absent when Scope saw no turn of it.
        public var agentSeconds: Double?
        /// Seconds it waited on its owner (questions, permissions, results left unread), wall-clock.
        public var waitingSeconds: Double?
        /// The opening lines of the last answer kept when the task was archived or closed, at most
        /// `ActivitySummary.answerLimit` characters: what a study came to. Agent output.
        public var answer: String?
        /// The report files kept with it (`REPORT.md`, `api/docs/study.md`).
        public var reports: [String]?
    }

    public struct Counts: Codable, Sendable, Equatable {
        public var merged = 0
        public var delivered = 0
        public var abandoned = 0
        public var archived = 0
        public var active = 0

        public init() {}

        public var total: Int { merged + delivered + abandoned + archived + active }

        mutating func add(_ outcome: TaskOutcome) {
            switch outcome {
            case .merged: merged += 1
            case .delivered: delivered += 1
            case .abandoned: abandoned += 1
            case .archived: archived += 1
            case .active: active += 1
            }
        }
    }

    public struct Scope: Codable, Sendable, Equatable {
        public var slug: String
        public var name: String
        /// `false` for a scope removed since: its tasks are still reported, under the name they were recorded with.
        public var declared: Bool
        public var counts: Counts
        /// Ordered by topic (tasks without one last), then by creation.
        public var tasks: [Task]
        /// Threads opened outside any task: at the scope root or in a base checkout. Scope's own resident threads are
        /// left out — they run all the time and say nothing about the work.
        public var threads: [Thread]
    }

    public var period: Period
    public var scopes: [Scope]
    /// One task asked for by `task`, with its whole brief.
    public var detail: Detail?
    /// When the history of closed tasks and threads begins: before it, a closed one left no trace at all.
    public var historySince: Date?
    /// What the summary cannot say, in plain words, for whoever writes it up.
    public var limits: [String]

    public struct Detail: Codable, Sendable, Equatable {
        public var scope: String
        public var task: Task
        public var prompt: String?
        /// Each thread's last answer, kept when the task was archived or closed, its end cut to
        /// `ActivitySummary.detailReplyLimit` characters; `scope task show` has them whole. Agent output.
        public var replies: [TaskDeliverable.Reply]?
    }
}

/// Builds a `SummaryResult` from snapshots: live records, and the history of the ones Scope deleted. Pure.
public enum ActivitySummary {
    /// A declared scope, as the app knows it now.
    public struct ScopeRef: Sendable, Equatable {
        public var id: String
        public var slug: String
        public var name: String
        public var root: String

        public init(id: String, slug: String, name: String, root: String) {
            self.id = id
            self.slug = slug
            self.name = name
            self.root = root
        }
    }

    /// A brief is a page; the summary shows its first sentences.
    public static let briefLimit = 240
    /// The detail of one task shows its brief up to this.
    public static let detailPromptLimit = 20_000
    /// A task's line shows the start of its last answer up to this.
    public static let answerLimit = 300
    /// The detail of one task shows the end of each kept answer up to this.
    public static let detailReplyLimit = 6_000

    public static let fixedLimits = [
        "Of what was said in a task's threads, Scope keeps only each thread's last answer (and the task's REPORT.md), and only from the moment the task is archived or closed; a thread closed before that left nothing. `scope task show <task>` prints them whole.",
        "Pull request states are the last ones Scope saw while the task was open; an absent state means Scope never looked — check it with `gh pr view <url>`.",
        "`archived` means put away without a pull request: finished with nothing to merge, or set aside. Scope cannot tell which.",
        "Agent time adds up the turns of every thread of a task; waiting time is how long it waited on you — a question, a permission, or a result not yet followed by a new prompt — counted once however many threads waited. Both come from the hooks of the drivers that have them, and are absent for a task Scope saw no turn of.",
    ]

    public static func build(
        period: ActivityPeriod, timeZone: TimeZone = .current,
        scopes declared: [ScopeRef], tasks: [TaskSnapshot], threads: [ThreadSnapshot], history: [HistoryEntry],
        deliverables: [String: TaskDeliverable] = [:], scopeFilter: String? = nil, tokens: [String: Int] = [:]
    ) -> SummaryResult {
        let world = World(declared: declared, tasks: tasks, threads: threads, history: history, deliverables: deliverables, tokens: tokens)
        let wanted = scopeFilter.map { world.matchingScopeKeys($0) }

        var byScope: [String: (tasks: [SummaryResult.Task], threads: [SummaryResult.Thread])] = [:]
        for entry in world.allTasks {
            let key = world.scopeKey(id: entry.snapshot.scopeID, slug: entry.snapshot.scopeSlug)
            guard wanted?.contains(key) ?? true else { continue }
            let task = world.render(entry)
            let dates = [task.createdAt, task.archivedAt, task.closedAt].compactMap { $0 }
                + task.threads.flatMap { [$0.createdAt, $0.lastLaunchedAt, $0.closedAt].compactMap { $0 } }
            guard dates.contains(where: period.contains) else { continue }
            byScope[key, default: ([], [])].tasks.append(task)
        }
        for (snapshot, closedAt) in world.looseThreads {
            let key = world.scopeKey(id: snapshot.scopeID, root: snapshot.scopeRoot)
            guard wanted?.contains(key) ?? true else { continue }
            let thread = world.render(snapshot, closedAt: closedAt)
            guard [thread.createdAt, thread.lastLaunchedAt, thread.closedAt].compactMap({ $0 }).contains(where: period.contains)
            else { continue }
            byScope[key, default: ([], [])].threads.append(thread)
        }

        let scopes = byScope.map { key, content in
            let identity = world.identity(of: key)
            var counts = SummaryResult.Counts()
            content.tasks.forEach { counts.add($0.outcome) }
            return SummaryResult.Scope(slug: identity.slug, name: identity.name, declared: identity.declared, counts: counts,
                                       tasks: content.tasks.sorted(by: taskOrder),
                                       threads: content.threads.sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) })
        }
        .sorted { ($0.declared ? 0 : 1, $0.slug) < ($1.declared ? 0 : 1, $1.slug) }

        return SummaryResult(
            period: .init(label: period.label, since: period.since, until: period.until, timeZone: timeZone.identifier),
            scopes: scopes, detail: nil, historySince: history.map(\.at).min(), limits: limits(history: history, tokens: tokens)
        )
    }

    /// One task, found by id or slug among live records first, then among closed ones (the latest close wins).
    public static func detail(
        of name: String, timeZone: TimeZone = .current, period: ActivityPeriod,
        scopes declared: [ScopeRef], tasks: [TaskSnapshot], threads: [ThreadSnapshot], history: [HistoryEntry],
        deliverables: [String: TaskDeliverable] = [:], tokens: [String: Int] = [:]
    ) -> SummaryResult? {
        let world = World(declared: declared, tasks: tasks, threads: threads, history: history, deliverables: deliverables, tokens: tokens)
        guard let entry = world.task(named: name) else { return nil }
        let key = world.scopeKey(id: entry.snapshot.scopeID, slug: entry.snapshot.scopeSlug)
        let prompt = entry.snapshot.prompt.map { $0.count > detailPromptLimit ? String($0.prefix(detailPromptLimit)) + "…" : $0 }
        let replies = deliverables[entry.snapshot.id]?.replies.map { reply in
            var trimmed = reply
            if reply.text.count > detailReplyLimit { trimmed.text = "…" + reply.text.suffix(detailReplyLimit) }
            return trimmed
        }
        return SummaryResult(
            period: .init(label: period.label, since: period.since, until: period.until, timeZone: timeZone.identifier),
            scopes: [], detail: .init(scope: world.identity(of: key).slug, task: world.render(entry), prompt: prompt,
                                      replies: replies.flatMap { $0.isEmpty ? nil : $0 }),
            historySince: history.map(\.at).min(), limits: limits(history: history, tokens: tokens)
        )
    }

    /// `scope task show`: one task's whole brief and everything kept of it, found like `detail` finds it.
    public static func show(
        _ name: String, scopes declared: [ScopeRef], tasks: [TaskSnapshot], threads: [ThreadSnapshot],
        history: [HistoryEntry], deliverables: [String: TaskDeliverable]
    ) -> TaskShowResult? {
        let world = World(declared: declared, tasks: tasks, threads: threads, history: history, deliverables: deliverables, tokens: [:])
        guard let entry = world.task(named: name) else { return nil }
        let key = world.scopeKey(id: entry.snapshot.scopeID, slug: entry.snapshot.scopeSlug)
        let task = world.render(entry)
        let deliverable = deliverables[entry.snapshot.id]
        var notes: [String] = []
        if task.outcome == .active || (task.archivedAt == nil && task.closedAt == nil) {
            notes.append("The task is open: its threads' last answers are kept when it is archived or closed. `scope thread read <thread> --reply` shows one now.")
        } else if deliverable == nil {
            notes.append("Nothing was kept: the task was put away before Scope kept answers, its threads had answered nothing, or they were closed before it.")
        }
        if entry.closedAt != nil, let prompt = entry.snapshot.prompt, prompt.hasSuffix("…"), prompt.count > TaskSnapshot.promptLimit {
            notes.append("The brief is cut at \(TaskSnapshot.promptLimit) characters: closed tasks keep no more of it.")
        }
        return TaskShowResult(scope: world.identity(of: key).slug, task: task, prompt: entry.snapshot.prompt,
                              deliverable: deliverable, notes: notes)
    }

    static func limits(history: [HistoryEntry], tokens: [String: Int] = [:]) -> [String] {
        let since = history.map(\.at).min()
        let start = since.map { "Closed tasks and threads are known from \($0.formatted(.iso8601.year().month().day())) on" }
            ?? "No task or thread has been closed since Scope started keeping a history"
        return fixedLimits + [start + "; one closed earlier left no trace."] + (tokens.isEmpty ? [] : [TokenUsageText.summaryLimit])
    }

    /// Topic first (tasks without one after), then creation.
    static func taskOrder(_ lhs: SummaryResult.Task, _ rhs: SummaryResult.Task) -> Bool {
        let left = lhs.topic?.lowercased(), right = rhs.topic?.lowercased()
        if left != right {
            switch (left, right) {
            case (nil, _): return false
            case (_, nil): return true
            case let (l?, r?): return l < r
            }
        }
        return (lhs.createdAt, lhs.id) < (rhs.createdAt, rhs.id)
    }

    /// The first paragraph of a brief — headings and rules before it skipped, whitespace collapsed — cut at a word
    /// before `limit`. What follows it is context the agent needed, not what the task was.
    public static func excerpt(_ prompt: String?, limit: Int = briefLimit) -> String? {
        guard let prompt else { return nil }
        var paragraph: [String] = []
        for raw in prompt.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let filler = line.isEmpty || line.hasPrefix("#") || line.allSatisfy { "-=*_`".contains($0) }
            if filler {
                if paragraph.isEmpty { continue } else { break }
            }
            paragraph.append(line)
        }
        let text = paragraph.joined(separator: " ").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !text.isEmpty else { return nil }
        guard text.count > limit else { return text }
        let cut = text.prefix(limit)
        let atWord = cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut
        return atWord.trimmingCharacters(in: .punctuationCharacters.union(.whitespaces)) + "…"
    }

    /// Everything known, indexed once.
    private struct World {
        struct TaskEntry {
            var snapshot: TaskSnapshot
            var closedAt: Date?
        }

        struct Identity {
            var slug: String
            var name: String
            var declared: Bool
        }

        let declared: [ScopeRef]
        let allTasks: [TaskEntry]
        /// Threads of each task, live and closed.
        let threadsByTask: [String: [(ThreadSnapshot, Date?)]]
        /// Threads that belong to no known task, residents left out.
        let looseThreads: [(ThreadSnapshot, Date?)]
        /// Undeclared scopes met in the records: key → identity as recorded.
        let recorded: [String: Identity]
        /// Thread id → tokens consumed, all told.
        let tokens: [String: Int]

        let deliverables: [String: TaskDeliverable]

        init(declared: [ScopeRef], tasks: [TaskSnapshot], threads: [ThreadSnapshot], history: [HistoryEntry],
             deliverables: [String: TaskDeliverable] = [:], tokens: [String: Int]) {
            self.declared = declared
            self.tokens = tokens
            self.deliverables = deliverables
            let live = Set(tasks.map(\.id))
            var closedTasks: [TaskEntry] = []
            var closedThreads: [(ThreadSnapshot, Date?)] = []
            for entry in history {
                switch entry.kind {
                case .taskClosed:
                    // A task closed, reopened from nothing and closed again is two entries; a live record beats both.
                    if let task = entry.task, !live.contains(task.id) { closedTasks.append(TaskEntry(snapshot: task, closedAt: entry.at)) }
                case .threadClosed:
                    if let thread = entry.thread { closedThreads.append((thread, entry.at)) }
                }
            }
            allTasks = tasks.map { TaskEntry(snapshot: $0, closedAt: nil) } + closedTasks
            let liveThreads = Set(threads.map(\.id))
            let everyThread = threads.map { ($0, Date?.none) } + closedThreads.filter { !liveThreads.contains($0.0.id) }
            let taskIDs = Set(allTasks.map(\.snapshot.id))
            var byTask: [String: [(ThreadSnapshot, Date?)]] = [:]
            var loose: [(ThreadSnapshot, Date?)] = []
            for thread in everyThread where thread.0.resident == nil {
                if let task = thread.0.taskID, taskIDs.contains(task) { byTask[task, default: []].append(thread) } else { loose.append(thread) }
            }
            threadsByTask = byTask
            looseThreads = loose

            var recorded: [String: Identity] = [:]
            let declaredIDs = Set(declared.map(\.id))
            for task in allTasks.map(\.snapshot) where !declaredIDs.contains(task.scopeID) {
                recorded["slug:" + task.scopeSlug] = recorded["slug:" + task.scopeSlug]
                    ?? Identity(slug: task.scopeSlug, name: task.scopeName, declared: false)
            }
            self.recorded = recorded
        }

        /// A task by id or slug: a live record first, then the latest close.
        func task(named name: String) -> TaskEntry? {
            let candidates = allTasks.filter { $0.snapshot.id == name || $0.snapshot.slug == name }
            return candidates.first(where: { $0.closedAt == nil })
                ?? candidates.max(by: { ($0.closedAt ?? .distantPast) < ($1.closedAt ?? .distantPast) })
        }

        /// A declared scope by id; otherwise the slug the task recorded.
        func scopeKey(id: String, slug: String) -> String {
            declared.contains { $0.id == id } ? "id:" + id : "slug:" + slug
        }

        /// A declared scope by id or root; otherwise the root folder's name, which is what a scope's slug defaults to.
        func scopeKey(id: String, root: String) -> String {
            if declared.contains(where: { $0.id == id }) { return "id:" + id }
            if let scope = declared.first(where: { $0.root == root }) { return "id:" + scope.id }
            return "slug:" + slugify(URL(fileURLWithPath: root).lastPathComponent)
        }

        func identity(of key: String) -> Identity {
            if key.hasPrefix("id:"), let scope = declared.first(where: { "id:" + $0.id == key }) {
                return Identity(slug: scope.slug, name: scope.name, declared: true)
            }
            if let known = recorded[key] { return known }
            let slug = String(key.dropFirst("slug:".count))
            return Identity(slug: slug, name: slug, declared: false)
        }

        /// Every key `filter` may name: a declared scope by slug, name or id, or a scope known only from its records.
        func matchingScopeKeys(_ filter: String) -> Set<String> {
            let wanted = filter.lowercased()
            var keys = Set(declared.filter { [$0.slug, $0.name, $0.id].map { $0.lowercased() }.contains(wanted) }.map { "id:" + $0.id })
            for (key, identity) in recorded where [identity.slug, identity.name].map({ $0.lowercased() }).contains(wanted) {
                keys.insert(key)
            }
            if keys.isEmpty { keys.insert("slug:" + wanted) }
            return keys
        }

        func render(_ entry: TaskEntry) -> SummaryResult.Task {
            let task = entry.snapshot
            let kept = deliverables[task.id]
            let threads = (threadsByTask[task.id] ?? []).map { render($0.0, closedAt: $0.1) }
                .sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
            let pr = task.pullRequest
            let outcome = TaskOutcome.classify(archived: task.archivedAt != nil, closed: entry.closedAt != nil,
                                               pullRequestState: pr?.state, hasPullRequest: pr != nil)
            let dates = [task.createdAt, task.archivedAt, entry.closedAt].compactMap { $0 }
                + threads.flatMap { [$0.createdAt, $0.lastLaunchedAt, $0.closedAt].compactMap { $0 } }
            return SummaryResult.Task(
                id: task.id, slug: task.slug, name: task.name, topic: task.topic, branch: task.branch, repos: task.repos,
                outcome: outcome, createdAt: task.createdAt, archivedAt: task.archivedAt, closedAt: entry.closedAt,
                lastActivity: dates.max() ?? task.createdAt,
                pullRequest: pr.map { .init(number: $0.number, url: $0.url, title: $0.title, state: $0.state) },
                createdByAgent: task.createdByAgent, parentTask: task.parentTask,
                brief: ActivitySummary.excerpt(task.prompt), threads: threads,
                tokens: threads.compactMap(\.tokens).reduce(nil) { ($0 ?? 0) + $1 },
                agentSeconds: task.agentSeconds, waitingSeconds: task.waitingSeconds,
                answer: kept.flatMap { ActivitySummary.excerpt($0.lastReply?.text, limit: ActivitySummary.answerLimit) },
                reports: kept.flatMap { $0.files.isEmpty ? nil : $0.files.map(\.name) }
            )
        }

        func render(_ thread: ThreadSnapshot, closedAt: Date?) -> SummaryResult.Thread {
            SummaryResult.Thread(id: thread.id, title: thread.title, driver: thread.driverID, createdAt: thread.createdAt,
                                 lastLaunchedAt: thread.lastLaunchedAt, closedAt: closedAt, launches: thread.launchCount,
                                 session: thread.session, openedByAgent: thread.openedByAgent, tokens: tokens[thread.id])
        }
    }
}

/// `scope task show <id|slug>` — a task's whole brief and what was kept of it when it was archived or closed: each
/// thread's last answer and its report file. Read-only; open, archived and closed tasks alike.
public struct TaskShowParams: Codable, Sendable, Equatable {
    /// Task id or slug.
    public var task: String

    public init(task: String) {
        self.task = task
    }
}

public struct TaskShowResult: Codable, Sendable, Equatable {
    /// The slug of the task's scope.
    public var scope: String
    public var task: SummaryResult.Task
    /// The whole brief (cut at `TaskSnapshot.promptLimit` for a closed task).
    public var prompt: String?
    /// What was kept at archive or close; `nil` for an open task and for one put away with nothing to keep.
    public var deliverable: TaskDeliverable?
    /// What the answer cannot say, in plain words.
    public var notes: [String]
    /// Always `true`: the replies and reports are agents' output.
    public var untrusted: Bool

    public init(scope: String, task: SummaryResult.Task, prompt: String?, deliverable: TaskDeliverable?, notes: [String]) {
        self.scope = scope
        self.task = task
        self.prompt = prompt
        self.deliverable = deliverable
        self.notes = notes
        self.untrusted = true
    }
}
