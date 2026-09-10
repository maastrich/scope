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

    /// `false` refuses every mutating request coming from a thread. The user's own terminal keeps working.
    public var agentsMayDrive: Bool
    /// How deep the chain of agents opening agents may go. A thread the user opened is at depth 0, so the
    /// default of 1 lets an agent open a thread and stops that thread from opening another: recursion is a
    /// choice you make on purpose, not something a prompt discovers.
    public var maxDepth: Int
    /// Opening a thread from an agent.
    public var threads: Approval
    /// Creating (and closing) a task from an agent — a branch and one worktree per repository. `allow` by
    /// default: Scope exists to let agents work unattended, and a task is sandboxed and undone in one step;
    /// `ask` is there for whoever would rather confirm each one.
    public var tasks: Approval
    /// How long the app waits for the user to answer an `ask` before refusing, in seconds.
    public var approvalTimeout: Int

    public static let defaultApprovalTimeout = 120

    public init(agentsMayDrive: Bool = true, maxDepth: Int = 1, threads: Approval = .allow,
                tasks: Approval = .allow, approvalTimeout: Int = AutomationSettings.defaultApprovalTimeout) {
        self.agentsMayDrive = agentsMayDrive
        self.maxDepth = max(0, maxDepth)
        self.threads = threads
        self.tasks = tasks
        self.approvalTimeout = max(5, approvalTimeout)
    }

    private enum CodingKeys: String, CodingKey {
        case agentsMayDrive, maxDepth, threads, tasks, approvalTimeout
    }

    /// Lenient: every key is optional and an unknown approval word falls back to the default, so hand-editing
    /// `config.json` cannot lock the user out of the app.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AutomationSettings()
        agentsMayDrive = try container.decodeIfPresent(Bool.self, forKey: .agentsMayDrive) ?? defaults.agentsMayDrive
        maxDepth = max(0, try container.decodeIfPresent(Int.self, forKey: .maxDepth) ?? defaults.maxDepth)
        threads = (try? container.decodeIfPresent(Approval.self, forKey: .threads)).flatMap { $0 } ?? defaults.threads
        tasks = (try? container.decodeIfPresent(Approval.self, forKey: .tasks)).flatMap { $0 } ?? defaults.tasks
        approvalTimeout = max(5, try container.decodeIfPresent(Int.self, forKey: .approvalTimeout) ?? defaults.approvalTimeout)
    }
}
