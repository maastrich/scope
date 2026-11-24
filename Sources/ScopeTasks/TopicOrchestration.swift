import Foundation
import ScopeCore

/// A topic's own orchestrator: one thread per topic, at the scope root, that knows the topic's tasks, talks to their
/// threads, opens new tasks in the topic and says where the topic stands.
///
/// Built on the resident threads' model (`ResidentRole`) without being one: residents exist in every scope from the
/// start, an orchestrator only once someone opens it from the topic's row. Nothing runs, costs or wakes until then.
/// It is told about the topic's milestones only — a pull request merged, every task delivered — through the acting
/// triggers' gate and caps (`ActingTrigger.topic`), never about each turn of each task. It closes once the topic has
/// no open task left. Pure decisions here; the app gathers the facts and acts.
public enum TopicOrchestration {
    /// What the orchestrator is told about one task of its topic.
    public struct TaskFacts: Sendable, Equatable {
        public var slug: String
        public var name: String
        /// `working`, `waiting for you`, `done`, … as the sidebar would say it.
        public var state: String
        public var branch: String
        /// `#12 open, checks passing`, one per pull request.
        public var pullRequests: [String]
        public var brief: String?
        /// The ids of its threads, for `scope thread send`.
        public var threads: [String]
        public var archived: Bool

        public init(slug: String, name: String, state: String, branch: String, pullRequests: [String] = [],
                    brief: String? = nil, threads: [String] = [], archived: Bool = false) {
            self.slug = slug
            self.name = name
            self.state = state
            self.branch = branch
            self.pullRequests = pullRequests
            self.brief = brief
            self.threads = threads
            self.archived = archived
        }
    }

    /// The thread's title.
    public static func title(for topic: String) -> String { "Topic · \(topic)" }

    /// The opening prompt: who it is, what it may do, and where the current state is — `scope topic show`, asked
    /// again whenever it needs it, since anything written here goes stale with the first turn of a task.
    public static func brief(topic: String, scope: String, tasks: [TaskFacts]) -> String {
        """
        You orchestrate the topic “\(topic)” of the scope \(scope) in Scope: a group of related tasks, each with its \
        own branch, worktrees and agent threads. You do not write their code; you coordinate them.

        - The topic as it stands now — every task, its state, branch, pull requests, checks, brief and threads: \
        `scope topic show "\(topic)"` (MCP `scope_topic_show`). Run it before answering “where is the topic at”; \
        what follows is only how it stood when you started.
        - Talk to a task's agent: `scope thread send <thread> "<message>"`, then `scope thread wait <thread>`.
        - New work in the topic: `scope task new "<brief>" --topic "\(topic)"`.
        - Scope tells you when a pull request of the topic merges and when every task is delivered — nothing else; \
        do not poll. Answer the user when they ask, and act on those notices when there is something to do.
        - Once the topic has no open task left and the user is done with this thread, Scope puts it away; \
        opening the topic's orchestrator again resumes this conversation.

        \(report(topic: topic, tasks: tasks))
        """
    }

    /// `scope topic show`: the topic's open tasks, then what was archived, as plain text an agent can read.
    public static func report(topic: String, tasks: [TaskFacts]) -> String {
        let open = tasks.filter { !$0.archived }
        let archived = tasks.filter(\.archived)
        var lines = ["Topic “\(topic)”: \(open.count) open task\(open.count == 1 ? "" : "s")"
                     + (archived.isEmpty ? "" : ", \(archived.count) archived")]
        for task in open {
            lines.append("")
            lines.append("- \(task.name) (\(task.slug)) — \(task.state), branch \(task.branch)")
            if !task.pullRequests.isEmpty { lines.append("  pull requests: " + task.pullRequests.joined(separator: "; ")) }
            if !task.threads.isEmpty { lines.append("  threads: " + task.threads.joined(separator: ", ")) }
            if let brief = excerpt(task.brief) { lines.append("  brief: " + brief) }
        }
        if !archived.isEmpty {
            lines.append("")
            lines.append("Archived: " + archived.map { task in
                "\(task.name) (\(task.slug)\(task.pullRequests.isEmpty ? "" : ", " + task.pullRequests.joined(separator: "; ")))"
            }.joined(separator: ", "))
        }
        return lines.joined(separator: "\n")
    }

    static func excerpt(_ brief: String?, limit: Int = 280) -> String? {
        guard let brief else { return nil }
        let flat = brief.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
        guard !flat.isEmpty else { return nil }
        return flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
    }

    // MARK: Milestones

    /// What the orchestrator is told, at most once each.
    public enum Milestone: Sendable, Equatable {
        /// A pull request of a task of the topic merged.
        case merged(task: String, number: Int, url: String)
        /// Every open task of the topic has all its pull requests merged.
        case delivered(tasks: [String])

        /// What makes it one occasion: the acting ledger acts once per key.
        public var key: String {
            switch self {
            case .merged(_, _, let url): "merged:\(url)"
            case .delivered(let tasks): "delivered:" + tasks.sorted().joined(separator: ",")
            }
        }
    }

    /// One task of the topic as the milestones read it.
    public struct Member: Sendable, Equatable {
        public var task: String
        public var pullRequests: [LinkedPullRequest]
        public var archived: Bool

        public init(task: String, pullRequests: [LinkedPullRequest], archived: Bool = false) {
            self.task = task
            self.pullRequests = pullRequests
            self.archived = archived
        }
    }

    /// The milestones of the topic since the orchestrator opened: each pull request merged after `since`, then —
    /// once every task has its pull requests merged (closed ones aside, at least one merged each) — the topic
    /// delivered. Archived tasks count: a merged task is archived right after its merge, and a notice held meanwhile
    /// must still come; one archived without a pull request was dropped and holds nothing up. Read from the state, not
    /// from a change, so a notice the gate holds comes back at the next look, and the acting ledger keeps each key to
    /// one act. An open task with no pull request holds the topic undelivered: its work has not landed.
    public static func milestones(_ tasks: [Member], since: Date) -> [Milestone] {
        var result: [Milestone] = []
        for task in tasks {
            for link in task.pullRequests where link.isMerged {
                guard let merged = link.mergedAt, merged >= since else { continue }
                result.append(.merged(task: task.task, number: link.number, url: link.url.absoluteString))
            }
        }
        let counted = tasks.filter { !$0.archived || !$0.pullRequests.isEmpty }
        let delivered = !counted.isEmpty && counted.allSatisfy { task in
            task.pullRequests.contains(where: \.isMerged) && task.pullRequests.allSatisfy { $0.isMerged || $0.state == "closed" }
        }
        let recent = counted.contains { $0.pullRequests.contains { ($0.mergedAt ?? .distantPast) >= since } }
        if delivered, recent { result.append(.delivered(tasks: counted.map(\.task))) }
        return result
    }

    // MARK: Putting away

    /// What Scope looks at before putting an orchestrator away.
    public struct Standing: Sendable, Equatable {
        /// The open tasks of its topic.
        public var openTasks: Int
        /// A turn is in progress.
        public var working: Bool
        /// It asked the user something and has no answer yet.
        public var waitingOnUser: Bool
        /// Messages are queued for it.
        public var pendingMessages: Bool
        /// Its last turn ended and the user has not looked at the result.
        public var unread: Bool
        /// The user has it on screen.
        public var watched: Bool
        /// The latest sign of life: a person typing in it, the end of a turn, a launch.
        public var lastActivity: Date

        public init(openTasks: Int, working: Bool = false, waitingOnUser: Bool = false, pendingMessages: Bool = false,
                    unread: Bool = false, watched: Bool = false, lastActivity: Date) {
            self.openTasks = openTasks
            self.working = working
            self.waitingOnUser = waitingOnUser
            self.pendingMessages = pendingMessages
            self.unread = unread
            self.watched = watched
            self.lastActivity = lastActivity
        }
    }

    /// Why an orchestrator stays.
    public enum Hold: String, Sendable, Equatable {
        case openTasks, working, waitingOnUser, pendingMessages, unread, watched, recentActivity
    }

    /// How long an orchestrator without tasks must have been left alone before Scope puts it away. The end of a turn
    /// counts as activity, so its last report — the recap of a delivered topic — is never closed under the reader.
    public static let quietBeforeClosing: TimeInterval = 30 * 60

    /// Why the orchestrator stays, or `nil` when Scope may put it away: its topic has no open task left (archived,
    /// closed, or filed elsewhere), it is doing nothing and owes nothing, the user has read its last answer, is not
    /// looking at it, and nobody — person or turn — touched it for `quiet`. Closing at the end of the turn that
    /// answered the last merge threw away a report nobody had read, and a conversation the user was still having.
    public static func hold(_ standing: Standing, now: Date, quiet: TimeInterval = quietBeforeClosing) -> Hold? {
        if standing.openTasks > 0 { return .openTasks }
        if standing.working { return .working }
        if standing.waitingOnUser { return .waitingOnUser }
        if standing.pendingMessages { return .pendingMessages }
        if standing.unread { return .unread }
        if standing.watched { return .watched }
        if now.timeIntervalSince(standing.lastActivity) < quiet { return .recentActivity }
        return nil
    }
}

/// The orchestrators that were closed, kept so that opening a topic's orchestrator again resumes its conversation
/// instead of starting a blank one: the record carries the driver session to resume. One per topic of a scope, the
/// newest `limit` only — a driver does not keep its sessions forever either.
public struct RetiredOrchestrators: Codable, Sendable, Equatable {
    public private(set) var records: [ThreadRecord]

    public static let limit = 50

    public init(records: [ThreadRecord] = []) {
        self.records = records
    }

    /// Keeps `record` as the closed orchestrator of its topic, replacing an older one. Ignored when it orchestrates
    /// nothing or has no session to resume: reopening that one could only start over.
    public mutating func keep(_ record: ThreadRecord) {
        guard let topic = record.topic, record.resumeID != nil else { return }
        remove(topic: topic, scope: record.scopeID)
        records.append(record)
        if records.count > Self.limit { records.removeFirst(records.count - Self.limit) }
    }

    /// The closed orchestrator of `topic`, whatever the topic's spelling.
    public func record(topic: String, scope: ScopeID) -> ThreadRecord? {
        let key = TaskTopic.key(topic)
        return records.last { $0.scopeID == scope && $0.topic.map(TaskTopic.key) == key }
    }

    /// Takes the closed orchestrator of `topic` out: it is open again, or gone for good.
    @discardableResult
    public mutating func remove(topic: String, scope: ScopeID) -> ThreadRecord? {
        let found = record(topic: topic, scope: scope)
        let key = TaskTopic.key(topic)
        records.removeAll { $0.scopeID == scope && $0.topic.map(TaskTopic.key) == key }
        return found
    }

    /// The topic changed name: its closed orchestrator follows, so the new name still finds it.
    public mutating func rename(topic: String, to newName: String, title: String, scope: ScopeID) {
        let key = TaskTopic.key(topic)
        for index in records.indices where records[index].scopeID == scope && records[index].topic.map(TaskTopic.key) == key {
            records[index].topic = newName
            records[index].title = title
        }
    }

    // MARK: Disk

    /// `<home>/retired-orchestrators.json`
    public static func url(home: URL) -> URL {
        home.appending(path: "retired-orchestrators.json", directoryHint: .notDirectory)
    }

    /// What is on disk; empty when the file is missing or unreadable — a lost list costs a resumed conversation, not
    /// a launch.
    public static func load(home: URL) -> RetiredOrchestrators {
        (try? JSONStore.load(RetiredOrchestrators.self, from: url(home: home), fractionalSeconds: true)) ?? RetiredOrchestrators()
    }

    public func save(home: URL) throws {
        try JSONStore.save(self, to: Self.url(home: home), fractionalSeconds: true)
    }
}
