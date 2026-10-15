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

/// How a task ended, or where it stands — judged from the record alone, since nothing of what was said in its threads
/// survives them.
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

    public static let fixedLimits = [
        "Nothing said in a thread is kept by Scope: a task is known by its name, its brief, its branch and its pull request, not by what its agents did.",
        "Pull request states are the last ones Scope saw while the task was open; an absent state means Scope never looked — check it with `gh pr view <url>`.",
        "`archived` means put away without a pull request: finished with nothing to merge, or set aside. Scope cannot tell which.",
    ]

    public static func build(
        period: ActivityPeriod, timeZone: TimeZone = .current,
        scopes declared: [ScopeRef], tasks: [TaskSnapshot], threads: [ThreadSnapshot], history: [HistoryEntry],
        scopeFilter: String? = nil
    ) -> SummaryResult {
        let world = World(declared: declared, tasks: tasks, threads: threads, history: history)
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
            let thread = World.render(snapshot, closedAt: closedAt)
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
            scopes: scopes, detail: nil, historySince: history.map(\.at).min(), limits: limits(history: history)
        )
    }

    /// One task, found by id or slug among live records first, then among closed ones (the latest close wins).
    public static func detail(
        of name: String, timeZone: TimeZone = .current, period: ActivityPeriod,
        scopes declared: [ScopeRef], tasks: [TaskSnapshot], threads: [ThreadSnapshot], history: [HistoryEntry]
    ) -> SummaryResult? {
        let world = World(declared: declared, tasks: tasks, threads: threads, history: history)
        let candidates = world.allTasks.filter { $0.snapshot.id == name || $0.snapshot.slug == name }
        guard let entry = candidates.first(where: { $0.closedAt == nil }) ?? candidates.max(by: { ($0.closedAt ?? .distantPast) < ($1.closedAt ?? .distantPast) })
        else { return nil }
        let key = world.scopeKey(id: entry.snapshot.scopeID, slug: entry.snapshot.scopeSlug)
        let prompt = entry.snapshot.prompt.map { $0.count > detailPromptLimit ? String($0.prefix(detailPromptLimit)) + "…" : $0 }
        return SummaryResult(
            period: .init(label: period.label, since: period.since, until: period.until, timeZone: timeZone.identifier),
            scopes: [], detail: .init(scope: world.identity(of: key).slug, task: world.render(entry), prompt: prompt),
            historySince: history.map(\.at).min(), limits: limits(history: history)
        )
    }

    static func limits(history: [HistoryEntry]) -> [String] {
        let since = history.map(\.at).min()
        let start = since.map { "Closed tasks and threads are known from \($0.formatted(.iso8601.year().month().day())) on" }
            ?? "No task or thread has been closed since Scope started keeping a history"
        return fixedLimits + [start + "; one closed earlier left no trace."]
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

    /// The opening of a brief: headings and blank lines skipped, whitespace collapsed, cut at a word before `limit`.
    public static func excerpt(_ prompt: String?, limit: Int = briefLimit) -> String? {
        guard let prompt else { return nil }
        let lines = prompt.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") && !$0.allSatisfy { "-=*_`".contains($0) } }
        let text = lines.joined(separator: " ").split(whereSeparator: \.isWhitespace).joined(separator: " ")
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

        init(declared: [ScopeRef], tasks: [TaskSnapshot], threads: [ThreadSnapshot], history: [HistoryEntry]) {
            self.declared = declared
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
            let threads = (threadsByTask[task.id] ?? []).map { World.render($0.0, closedAt: $0.1) }
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
                brief: ActivitySummary.excerpt(task.prompt), threads: threads
            )
        }

        static func render(_ thread: ThreadSnapshot, closedAt: Date?) -> SummaryResult.Thread {
            SummaryResult.Thread(id: thread.id, title: thread.title, driver: thread.driverID, createdAt: thread.createdAt,
                                 lastLaunchedAt: thread.lastLaunchedAt, closedAt: closedAt, launches: thread.launchCount,
                                 session: thread.session, openedByAgent: thread.openedByAgent)
        }
    }
}
