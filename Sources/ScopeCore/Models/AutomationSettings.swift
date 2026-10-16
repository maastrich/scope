import Foundation

/// What an agent is allowed to do to a scope from inside a thread.
///
/// A control request made from a plain terminal is the user and is never filtered by these; they only
/// govern requests whose caller is a thread Scope itself launched. Stored under
/// `preferences.automation` as an optional block, so a `config.json` written before it existed decodes
/// to `nil` and means "the defaults below".
public struct AutomationSettings: Codable, Sendable, Equatable {
    /// How a mutating request from a thread is treated.
    public enum Approval: String, Codable, Sendable, CaseIterable {
        /// Done straight away.
        case allow
        /// The app asks the user first; the request waits for the answer.
        case ask
        /// Refused (`denied`).
        case deny

        /// What Settings shows.
        public var title: String {
            switch self {
            case .allow: "Without asking"
            case .ask: "After asking me"
            case .deny: "Never"
            }
        }
    }

    /// Which threads an agent may read, type into, stop or close.
    public enum ThreadReach: String, Codable, Sendable, CaseIterable {
        /// Every thread Scope runs — another task's, another scope's, the user's own.
        case any
        /// Only what the agent set in motion: the threads it opened, the ones those opened, and so on down.
        case own

        /// What Settings shows.
        public var title: String {
            switch self {
            case .any: "Any thread"
            case .own: "Only the ones it opened"
            }
        }
    }

    /// `false` refuses every mutating request coming from a thread. The user's own terminal keeps working.
    public var agentsMayDrive: Bool
    /// Which threads an agent may act on. `any` by default: threads are how agents hand work to each other
    /// across tasks, and every message says who sent it. `own` is the old rule, for whoever wants each agent
    /// fenced into the threads it opened and their descendants.
    public var threadReach: ThreadReach
    /// Which threads an agent may hand a driver command to (`thread.send --command`: `/model`, `/clear`, typed
    /// verbatim, with no line saying who sent it). `own` by default — a command rewrites how another agent works,
    /// and one not signed cannot be told from the user's own — and never wider than `threadReach`
    /// (`effectiveCommandReach`).
    public var commandReach: ThreadReach
    /// How deep the chain of agents opening agents may go, or `nil` for no limit (the default). A thread the user
    /// opened is at depth 0, its task's thread too; a task an agent creates from inside a task is one deeper. It is
    /// no longer what stops a runaway — `maxAgentTasks` and `maxAgentThreads` are — so it stays only as a fence for
    /// whoever wants one: 0 keeps agents from opening anything, 1 lets them open work that may not open more.
    public var depthLimit: Int?
    /// How many tasks agents may keep open at once, every scope together: what a loop of tasks creating tasks runs
    /// into. Archived tasks and the ones you created yourself do not count.
    public var maxAgentTasks: Int
    /// How many threads agents may keep running at once, every scope together. A stopped thread and the ones you
    /// opened yourself do not count; the threads of agents' tasks do.
    public var maxAgentThreads: Int
    /// Opening a thread from an agent.
    public var threads: Approval
    /// Creating (and closing) a task from an agent — a branch and one worktree per repository. `allow` by
    /// default: Scope exists to let agents work unattended, and a task is sandboxed and undone in one step;
    /// `ask` is there for whoever would rather confirm each one.
    public var tasks: Approval
    /// Cutting a release from an agent (`scope release`): a clone of the default branch under Scope's home, the
    /// repository's release script, the user's git identity. `ask` by default — the one place the autonomy default
    /// flips: a tag pushed is a version shipped, and nothing undoes it.
    public var releases: Approval
    /// How long the app waits for the user to answer an `ask` before refusing, in seconds.
    public var approvalTimeout: Int

    public static let defaultApprovalTimeout = 120
    /// Generous for an orchestrator fanning work out and its tasks splitting theirs; low enough that a loop stops
    /// before the disk or the machine notices.
    public static let defaultMaxAgentTasks = 12
    public static let defaultMaxAgentThreads = 24
    /// What the Settings steppers allow for the two budgets.
    public static let budgetRange = 1...100

    public init(agentsMayDrive: Bool = true, threadReach: ThreadReach = .any, commandReach: ThreadReach = .own,
                depthLimit: Int? = nil,
                maxAgentTasks: Int = AutomationSettings.defaultMaxAgentTasks,
                maxAgentThreads: Int = AutomationSettings.defaultMaxAgentThreads,
                threads: Approval = .allow, tasks: Approval = .allow, releases: Approval = .ask,
                approvalTimeout: Int = AutomationSettings.defaultApprovalTimeout) {
        self.agentsMayDrive = agentsMayDrive
        self.threadReach = threadReach
        self.commandReach = commandReach
        self.depthLimit = depthLimit.map { max(0, $0) }
        self.maxAgentTasks = AutomationSettings.clampBudget(maxAgentTasks)
        self.maxAgentThreads = AutomationSettings.clampBudget(maxAgentThreads)
        self.threads = threads
        self.tasks = tasks
        self.releases = releases
        self.approvalTimeout = max(5, approvalTimeout)
    }

    public static func clampBudget(_ value: Int) -> Int {
        min(max(value, budgetRange.lowerBound), budgetRange.upperBound)
    }

    /// The reach of a driver command: `commandReach`, unless `threadReach` is already the fence.
    public var effectiveCommandReach: ThreadReach {
        threadReach == .own ? .own : commandReach
    }

    private enum CodingKeys: String, CodingKey {
        case agentsMayDrive, threadReach, commandReach, depthLimit, maxAgentTasks, maxAgentThreads, threads, tasks, releases,
             approvalTimeout
    }

    /// `maxDepth` was the ceiling when it was the only guard, 1 by default. Settings wrote the whole block on any
    /// change, so a stored 1 cannot be told from the default and is dropped with the old meaning; a stored 0 was a
    /// choice — no agent opens anything — and is kept.
    private enum LegacyKeys: String, CodingKey {
        case maxDepth
    }

    /// Lenient: every key is optional and an unknown approval word falls back to the default, so hand-editing
    /// `config.json` cannot lock the user out of the app.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AutomationSettings()
        agentsMayDrive = try container.decodeIfPresent(Bool.self, forKey: .agentsMayDrive) ?? defaults.agentsMayDrive
        threadReach = (try? container.decodeIfPresent(ThreadReach.self, forKey: .threadReach)).flatMap { $0 } ?? defaults.threadReach
        commandReach = (try? container.decodeIfPresent(ThreadReach.self, forKey: .commandReach)).flatMap { $0 } ?? defaults.commandReach
        if container.contains(.depthLimit) {
            depthLimit = (try? container.decodeIfPresent(Int.self, forKey: .depthLimit)).flatMap { $0 }.map { max(0, $0) }
        } else {
            let legacy = try? decoder.container(keyedBy: LegacyKeys.self).decodeIfPresent(Int.self, forKey: .maxDepth)
            depthLimit = (legacy ?? nil).flatMap { $0 <= 0 ? 0 : nil }
        }
        maxAgentTasks = AutomationSettings.clampBudget(
            (try? container.decodeIfPresent(Int.self, forKey: .maxAgentTasks)).flatMap { $0 } ?? defaults.maxAgentTasks)
        maxAgentThreads = AutomationSettings.clampBudget(
            (try? container.decodeIfPresent(Int.self, forKey: .maxAgentThreads)).flatMap { $0 } ?? defaults.maxAgentThreads)
        threads = (try? container.decodeIfPresent(Approval.self, forKey: .threads)).flatMap { $0 } ?? defaults.threads
        tasks = (try? container.decodeIfPresent(Approval.self, forKey: .tasks)).flatMap { $0 } ?? defaults.tasks
        releases = (try? container.decodeIfPresent(Approval.self, forKey: .releases)).flatMap { $0 } ?? defaults.releases
        approvalTimeout = max(5, try container.decodeIfPresent(Int.self, forKey: .approvalTimeout) ?? defaults.approvalTimeout)
    }
}
