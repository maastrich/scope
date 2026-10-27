import Foundation
import ScopeDrivers

/// Where a task's Claude Code threads keep their auto memory (code.claude.com/docs/en/memory, "Storage location").
///
/// Claude Code files auto memory under `<config dir>/projects/<project>/memory/`, `<project>` being the git
/// repository's main checkout — so every worktree of a repository shares it — or the working directory outside a git
/// repository. A thread in a task sandbox therefore already lands on its repository's memory, but a thread at the
/// root of a task of several repositories does not: the task root is no repository, it gets a folder of its own, and
/// what the agent learns there is lost once the task is archived.
///
/// Scope sets the folder itself, through `autoMemoryDirectory` in the thread's `--settings` file (which outranks the
/// user's and the project's settings): a thread inside a sandbox uses the memory of its repository's base checkout —
/// the same folder Claude Code picks on its own there, and the one a session started in the checkout uses — and a
/// thread anywhere else in the task uses the scope's, the folder a thread at the scope root has always used. The
/// other memories of the task are granted for reading (`permissions.additionalDirectories`) and named in the task's
/// context file, so a repository's thread still sees what was learnt for the whole scope.
public enum ClaudeMemory {
    /// Claude Code's own cut: longer folder names keep 200 characters and gain a hash of the full path.
    static let maxFolderNameLength = 200

    /// `<project>` for `path`, as Claude Code derives it: every UTF-16 unit that is not an ASCII letter or digit
    /// becomes `-`; past 200 characters, the name is cut and suffixed with `-<hash>`, the base-36 absolute value of
    /// the path's 32-bit string hash (`h = h * 31 + unit`, wrapping).
    public static func projectFolderName(_ path: String) -> String {
        let units = path.utf16.map { unit -> Character in
            switch unit {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A: Character(UnicodeScalar(UInt8(unit)))
            default: "-"
            }
        }
        let name = String(units)
        guard name.count > maxFolderNameLength else { return name }
        return String(name.prefix(maxFolderNameLength)) + "-" + String(abs(Int64(stringHash(path))), radix: 36)
    }

    /// JavaScript's `(h << 5) - h + charCode | 0` over the UTF-16 units.
    static func stringHash(_ string: String) -> Int32 {
        var hash: Int32 = 0
        for unit in string.utf16 { hash = (hash &<< 5) &- hash &+ Int32(unit) }
        return hash
    }

    /// The folder Claude Code would name for `path`: `realpath`, symbolic links resolved (`/tmp` is `/private/tmp`
    /// to it; Foundation's `resolvingSymlinksInPath` strips `/private` back off). A path that no longer exists — an
    /// archived task's root — keeps its missing tail under its deepest existing ancestor, resolved.
    public static func canonicalPath(_ path: String) -> String {
        var head = URL(fileURLWithPath: path).standardizedFileURL.path(percentEncoded: false)
        while head.count > 1, head.hasSuffix("/") { head.removeLast() }
        var tail: [String] = []
        while true {
            if let resolved = realpath(head, nil) {
                defer { free(resolved) }
                let base = String(cString: resolved)
                return tail.isEmpty ? base : (base == "/" ? "" : base) + "/" + tail.reversed().joined(separator: "/")
            }
            guard head != "/", !head.isEmpty else { return path }
            tail.append((head as NSString).lastPathComponent)
            head = (head as NSString).deletingLastPathComponent
        }
    }

    /// The Claude Code configuration folder a thread uses, and whether Scope may choose its memory folder.
    public struct Locator: Sendable, Equatable {
        /// `$CLAUDE_CONFIG_DIR`, else `~/.claude`.
        public var configDirectory: URL

        public init(configDirectory: URL) {
            self.configDirectory = configDirectory
        }

        /// `<config>/projects/`
        public var projectsDirectory: URL { configDirectory.appending(path: "projects", directoryHint: .isDirectory) }

        /// `<config>/projects/<project>/memory/` for a project folder.
        public func memoryDirectory(forProject path: String) -> URL {
            projectsDirectory
                .appending(path: ClaudeMemory.projectFolderName(ClaudeMemory.canonicalPath(path)), directoryHint: .isDirectory)
                .appending(path: "memory", directoryHint: .isDirectory)
        }

        /// The locator for a thread whose environment is `environment` (the login shell's, which the thread inherits),
        /// or `nil` when the user already decided where memory goes, or that there is none: auto memory turned off
        /// (`CLAUDE_CODE_DISABLE_AUTO_MEMORY`, `autoMemoryEnabled: false`), a folder of their own
        /// (`autoMemoryDirectory` in their settings), or one project name for everything (`CLAUDE_CODE_PROJECT_DIR_NAME`).
        /// `userSettings` reads `<config>/settings.json`.
        public static func resolve(environment: [String: String], userHome: String,
                                   userSettings: (URL) -> Data? = { try? Data(contentsOf: $0) }) -> Locator? {
            if let disabled = environment["CLAUDE_CODE_DISABLE_AUTO_MEMORY"], !disabled.isEmpty, disabled != "0" { return nil }
            if let name = environment["CLAUDE_CODE_PROJECT_DIR_NAME"], !name.isEmpty { return nil }
            let config: URL
            if let custom = environment["CLAUDE_CONFIG_DIR"], !custom.isEmpty {
                config = URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
            } else {
                config = URL(fileURLWithPath: userHome, isDirectory: true).appending(path: ".claude", directoryHint: .isDirectory)
            }
            let settingsURL = config.appending(path: "settings.json", directoryHint: .notDirectory)
            if let data = userSettings(settingsURL),
               let settings = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                if settings["autoMemoryDirectory"] != nil { return nil }
                if settings["autoMemoryEnabled"] as? Bool == false { return nil }
            }
            return Locator(configDirectory: config)
        }
    }

    /// Whose memory a folder is.
    public enum Owner: Sendable, Equatable, Hashable {
        /// A repository of the scope, by its path relative to the scope root (`"."` for a repo scope).
        case repository(String)
        /// The scope as a whole: what holds across its repositories.
        case scope
    }

    /// One memory folder of a task.
    public struct Placement: Sendable, Equatable {
        public var owner: Owner
        /// The folder Claude Code names it after: the repository's base checkout, or the scope root.
        public var projectPath: String
        /// `<config>/projects/<project>/memory/`
        public var directory: URL
        /// What a row calls it: the repository name, or the scope's.
        public var label: String

        public init(owner: Owner, projectPath: String, directory: URL, label: String) {
            self.owner = owner
            self.projectPath = projectPath
            self.directory = directory
            self.label = label
        }
    }

    /// The scope's memory: the folder of the scope root.
    public static func scopePlacement(task: TaskRecord, locator: Locator) -> Placement {
        Placement(owner: .scope, projectPath: task.scopeRoot, directory: locator.memoryDirectory(forProject: task.scopeRoot),
                  label: task.scopeName)
    }

    /// The memory of each active repository of the task, in the task's order: the folder of its base checkout.
    public static func repositoryPlacements(task: TaskRecord, locator: Locator) -> [Placement] {
        task.activeRepos.map { repository(repo: $0, task: task, locator: locator) }
    }

    static func repository(repo: TaskRepo, task: TaskRecord, locator: Locator) -> Placement {
        let checkout = repo.isScopeRoot
            ? task.scopeRoot
            : URL(fileURLWithPath: task.scopeRoot, isDirectory: true).appending(path: repo.repoRelativePath).path(percentEncoded: false)
        return Placement(owner: .repository(repo.repoRelativePath), projectPath: checkout,
                         directory: locator.memoryDirectory(forProject: checkout),
                         label: repo.isScopeRoot ? task.scopeName : repo.name)
    }

    /// The memory a thread of `task` started at `cwd` uses: its repository's when the cwd is inside a sandbox
    /// (a secondary worktree included), the scope's anywhere else — the root of a task of several repositories, whose
    /// work spans them.
    public static func placement(cwd: String, task: TaskRecord, locator: Locator) -> Placement {
        guard let sandbox = task.sandbox(containing: cwd) else { return scopePlacement(task: task, locator: locator) }
        return repository(repo: sandbox, task: task, locator: locator)
    }

    /// The task's other memory folders, for a thread whose own is `own`: readable without a prompt, named in the
    /// context file. The scope's for a repository's thread, every repository's for a thread on the scope's.
    public static func companions(of own: Placement, task: TaskRecord, locator: Locator) -> [Placement] {
        var all = [scopePlacement(task: task, locator: locator)] + repositoryPlacements(task: task, locator: locator)
        all.removeAll { $0.directory.filesystemPath == own.directory.filesystemPath }
        var seen = Set<String>()
        return all.filter { seen.insert($0.directory.filesystemPath).inserted }
    }

    /// The settings a thread's `--settings` file gains for `own`: `autoMemoryDirectory`, and the companions as
    /// `permissions.additionalDirectories` (read access only; writing there asks like any other edit).
    public static func settings(own: Placement, companions: [Placement]) -> ThreadMemorySettings {
        ThreadMemorySettings(directory: own.directory.filesystemPath, readable: companions.map(\.directory.filesystemPath))
    }

    // MARK: Context file

    /// Lines of the index loaded from a companion's `MEMORY.md` into the context file at most: its own index is
    /// loaded by Claude Code; this one only has to make the scope's rules visible.
    static let inlinedIndexLines = 60

    /// The `## Memory` section of a task's context file: which memory its threads use, and the other ones with the
    /// scope's index quoted, so a rule the user taught at the scope level reaches a repository's thread. `index`
    /// reads a `MEMORY.md`, `nil` when there is none.
    public static func contextSection(task: TaskRecord, locator: Locator, index: (URL) -> String?) -> [String] {
        let scope = scopePlacement(task: task, locator: locator)
        let own = placement(cwd: task.threadCwd.filesystemPath, task: task, locator: locator)
        var lines = ["## Memory", ""]
        switch own.owner {
        case .repository:
            lines.append("Your auto memory is the memory of **\(own.label)** (`\(own.directory.filesystemPath)`): every task of this "
                         + "repository and its checkout share it, and it outlives this task. Save there what is true of the repository.")
        case .scope:
            lines.append("Your auto memory is the memory of the scope **\(scope.label)** (`\(scope.directory.filesystemPath)`): every task "
                         + "of the scope shares it. Save there what holds across its repositories; what is true of one repository "
                         + "belongs in that repository's memory below.")
        }
        lines.append("")
        let companions = companions(of: own, task: task, locator: locator)
        for companion in companions {
            let path = companion.directory.appending(path: "MEMORY.md", directoryHint: .notDirectory)
            switch companion.owner {
            case .scope:
                lines.append("Memory of the scope **\(companion.label)**, for what holds across its repositories: `\(path.filesystemPath)`.")
                if let text = index(path) {
                    let entries = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
                    if !entries.isEmpty {
                        lines.append("Its index, as it stood when this file was written:")
                        lines.append("")
                        lines += entries.prefix(inlinedIndexLines)
                        if entries.count > inlinedIndexLines { lines.append("- … \(entries.count - inlinedIndexLines) more in the file") }
                    }
                }
            case .repository:
                lines.append("Memory of **\(companion.label)**: `\(path.filesystemPath)` — read it before working in that repository.")
            }
            lines.append("")
        }
        return lines
    }
}
