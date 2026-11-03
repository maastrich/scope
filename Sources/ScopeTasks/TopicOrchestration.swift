import Foundation

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
        - When the topic has no open task left, Scope closes this thread.

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

    /// The milestones of the topic's open tasks since the orchestrator opened: each pull request merged after
    /// `since`, then — once every task has its pull requests merged (closed ones aside, at least one merged each) —
    /// the topic delivered. Read from the state, not from a change: a notice the gate holds while the orchestrator
    /// works comes back at the next refresh, and the acting ledger keeps each key to one act. A task with no pull
    /// request holds the topic undelivered: its work has not landed.
    public static func milestones(_ tasks: [(task: String, pullRequests: [LinkedPullRequest])], since: Date) -> [Milestone] {
        var result: [Milestone] = []
        for task in tasks {
            for link in task.pullRequests where link.isMerged {
                guard let merged = link.mergedAt, merged >= since else { continue }
                result.append(.merged(task: task.task, number: link.number, url: link.url.absoluteString))
            }
        }
        let delivered = !tasks.isEmpty && tasks.allSatisfy { task in
            task.pullRequests.contains(where: \.isMerged) && task.pullRequests.allSatisfy { $0.isMerged || $0.state == "closed" }
        }
        let recent = tasks.contains { $0.pullRequests.contains { ($0.mergedAt ?? .distantPast) >= since } }
        if delivered, recent { result.append(.delivered(tasks: tasks.map(\.task))) }
        return result
    }

    /// The orchestrator goes when its topic has no open task left: archived, closed, or filed elsewhere.
    public static func shouldClose(openTasks: Int) -> Bool { openTasks == 0 }
}
