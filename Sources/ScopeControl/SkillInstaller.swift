import Foundation
import ScopeCore

/// Installs the **Scope tasks** skill for the agents a user runs — Claude Code, Codex, Cursor — at user level,
/// so every session they start knows how to work with Scope's tasks and threads: when to sandbox work into a
/// task, how to name one, how to open a thread in it, read it, hand it a prompt, and close it.
///
/// A skill is a folder with a `SKILL.md` (the agentskills.io shape the three clients read). Each client keeps
/// its user-level skills in its own home (`~/.claude/skills`, `~/.codex/skills`, `~/.cursor/skills`); Scope
/// writes the one folder it owns and never touches a neighbour. The file carries a version marker, so an
/// app update can say *update* rather than *installed* while the text it shipped is behind.
public struct SkillInstaller: Sendable {
    public typealias Client = MCPRegistration.Client

    public enum State: Sendable, Equatable {
        /// The client is not on this machine (no home folder of its own).
        case unavailable
        case absent
        case installed
        /// Our skill, from an older app: the text moved on.
        case outdated
        /// A folder of that name that is not ours (no marker): left alone.
        case foreign
    }

    /// Folder name of the skill, the name agents see. Per build: a Debug app talks to its own `scope-debug`
    /// server, and its skill must not shadow the installed app's.
    public let name: String
    /// The user's home, where every client keeps its skills (a temporary folder in tests).
    public let userHome: URL
    /// The MCP server entry the skill's tool names hang off (`scope`, or `scope-debug`).
    public let serverName: String

    /// Bumped whenever `SKILL.md`'s text changes, so installed copies read as outdated and get rewritten.
    public static let version = 1
    static let marker = "scope-skill-version:"

    public init(userHome: URL, debug: Bool) {
        self.userHome = userHome
        self.name = debug ? "scope-debug-tasks" : "scope-tasks"
        self.serverName = debug ? "scope-debug" : "scope"
    }

    /// `~/.claude`, `~/.codex`, `~/.cursor`: the client's own home, which exists once it ran at least once.
    public func clientHome(_ client: Client) -> URL {
        switch client {
        case .claudeCode: userHome.appending(path: ".claude", directoryHint: .isDirectory)
        case .codex: userHome.appending(path: ".codex", directoryHint: .isDirectory)
        case .cursor: userHome.appending(path: ".cursor", directoryHint: .isDirectory)
        }
    }

    /// `<client home>/skills/<name>`
    public func skillDirectory(_ client: Client) -> URL {
        clientHome(client).appending(path: "skills", directoryHint: .isDirectory).appending(path: name, directoryHint: .isDirectory)
    }

    /// `<client home>/skills/<name>/SKILL.md`
    public func skillFile(_ client: Client) -> URL {
        skillDirectory(client).appending(path: "SKILL.md", directoryHint: .notDirectory)
    }

    public func state(of client: Client, fileManager: FileManager = .default) -> State {
        guard MCPRegistration.isDirectory(clientHome(client)) else { return .unavailable }
        let file = skillFile(client)
        guard fileManager.fileExists(atPath: skillDirectory(client).path) else { return .absent }
        guard let text = try? String(contentsOf: file, encoding: .utf8), let version = Self.installedVersion(text) else {
            return .foreign
        }
        return version == Self.version ? .installed : .outdated
    }

    /// Writes (or rewrites) the skill for `client`. A foreign folder of the same name is left untouched.
    public func install(_ client: Client, fileManager: FileManager = .default) throws {
        let directory = skillDirectory(client)
        if state(of: client, fileManager: fileManager) == .foreign {
            throw ControlError(.failed, "\(directory.path) already holds a skill that is not Scope's; move it aside to install this one.")
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try MCPRegistration.write(Data(skillText.utf8), to: skillFile(client))
    }

    /// Removes our skill folder; a foreign one or a missing one is left as it is.
    public func remove(_ client: Client, fileManager: FileManager = .default) throws {
        switch state(of: client, fileManager: fileManager) {
        case .installed, .outdated: try fileManager.removeItem(at: skillDirectory(client))
        case .absent, .foreign, .unavailable: return
        }
    }

    /// The version written in a `SKILL.md`, `nil` when the file is not ours.
    static func installedVersion(_ text: String) -> Int? {
        guard let range = text.range(of: marker) else { return nil }
        let tail = text[range.upperBound...].drop(while: { $0 == " " })
        let digits = tail.prefix(while: \.isNumber)
        return Int(digits)
    }

    /// The skill: what an agent should know to work with Scope's tasks, written for the `scope` command line
    /// (already on the PATH inside a thread) with the MCP tools named alongside for a session that has the server.
    public var skillText: String {
        """
        ---
        name: \(name)
        description: Work with Scope tasks and threads — sandbox work into a task (branch + git worktrees), open agent threads in it, read and drive them, close the task — through the `scope` command line or the `\(serverName)` MCP tools. Use when the user names a Scope task, asks to start work "in a task", "in a sandbox" or "on a branch", wants another agent on a piece of work, or asks what Scope is running.
        ---
        <!-- \(Self.marker) \(Self.version) — written by Scope; reinstall from Settings ▸ Automation after an update. -->

        # Scope tasks

        Scope is the macOS app running this session. A **scope** is a folder of repositories. A **task** is a
        named unit of work: one branch and one git worktree per repository it touches, so agents work in a sandbox
        and never in the user's checkouts. A **thread** is an agent (Claude Code, Codex, Cursor, a shell) in a
        terminal, at the scope root or inside a task's sandbox.

        Inside a thread, `scope` is on the PATH and knows which scope and task you are in (`SCOPE_SCOPE`,
        `SCOPE_TASK`, `SCOPE_TASK_ROOT`, `SCOPE_THREAD`). From a session Scope did not launch, the same commands
        are the MCP tools `\(serverName)`: `scope_list`, `scope_task_new`, `scope_thread_new`, `scope_thread_read`,
        `scope_thread_send`, `scope_thread_stop`, `scope_thread_close`, `scope_task_close`, `scope_ping`.

        ## Referring to a task

        A task has a **name** (what the user calls it, shown in Scope's sidebar) and a **slug** (its sandbox folder
        name, derived from the name). Commands take the slug or the id; `scope list tasks` prints both, with the
        branch, the repositories and the sandbox paths:

        ```sh
        scope list tasks                  # every task of the current scope: name, slug, branch, repos
        scope list tasks --scope acme     # of another scope (slug, name, id or path)
        scope list threads                # who is running where, with the task each thread belongs to
        scope list --json                 # the same, machine-readable
        ```

        When the user names a task, match it against the names and slugs of `scope list tasks` before acting;
        ask when two could fit.

        ## Starting work in a task

        ```sh
        scope task new "Add rate limiting to the public API" --dry-run     # see the proposal, write nothing
        scope task new "Add rate limiting to the public API"               # branch, worktrees, first thread
        scope task new "…" --repo api --repo web --branch feat/rate-limit --title "Rate limiting"
        scope task new "…" --no-thread                                     # the sandbox alone
        ```

        The prompt is what the task is about; the driver proposes the title, the slug, the branch and the
        repositories from it, and every one can be pinned with a flag. Run with `--dry-run` first when the user
        has not spelled out the repositories or the branch: the answer is what would be created, and nothing is
        written. Creating a task may need the user's approval (Settings ▸ Automation); a refusal is an answer,
        not an error to work around.

        ## Threads in a task

        ```sh
        scope thread new --task rate-limiting -p "Write the middleware and its tests"   # prints the thread id
        scope thread new --task rate-limiting --driver codex --title "review"
        scope thread read <id> -n 80          # the last lines of its terminal
        scope thread send <id> "run the tests again"
        scope thread stop <id>                # stop the process, keep the row
        scope thread close <id>               # hang up and remove
        ```

        You may type into, stop or close only the threads you opened. A thread's working directory is the
        task's sandbox, so an agent opened there commits on the task branch and never touches the base checkout.

        ## Finishing

        ```sh
        scope task close rate-limiting                  # threads hung up, worktrees removed, branch kept
        scope task close rate-limiting --delete-branch  # after the merge
        ```

        Closing refuses to drop uncommitted work unless `--force` is given; say so to the user rather than forcing.

        ## Rules

        - Never work in the base checkouts (the scope's own repository folders): a task's sandbox is where work
          goes. Ask for a task when there is none.
        - Reference tasks by slug in commands and by name to the user.
        - `scope ping` tells whether Scope is listening and what agents are currently allowed to do.
        """
    }
}
