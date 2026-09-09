import Foundation

/// A driver profile: how Scope starts a tool inside a thread (spec §5).
///
/// Profiles live in `<home>/drivers/<id>.json`. The bundled ones (`shell`, `claude-code`, `codex`,
/// `cursor`) are copied there on first run and can be edited or replaced by the user.
public struct DriverProfile: Codable, Sendable, Equatable, Identifiable {
    /// Which project-context file the tool reads and how Scope projects its own context into it.
    ///
    /// The name is what matters today: a task writes its projection under the name of every installed
    /// profile whose mode is not `none` (`TaskManager.writeProjection`), since its threads can run several
    /// drivers. `generate`, `file` and `flag` all produce the generated file for now — no driver exposes a
    /// context flag, so there is nothing to pass one to.
    public struct Context: Codable, Sendable, Equatable {
        /// How the context file is produced for a task sandbox.
        public enum Mode: String, Codable, Sendable {
            /// Scope generates the file from the graph.
            case generate
            /// Scope writes the file as-is.
            case file
            /// The context is passed as a command-line flag.
            case flag
            /// No projection.
            case none
        }

        /// File name the tool reads (`CLAUDE.md`, `AGENTS.md`).
        public var file: String
        /// Projection mode.
        public var mode: Mode

        public init(file: String, mode: Mode) {
            self.file = file
            self.mode = mode
        }
    }

    /// The event adapter that turns the tool's hooks / notifications into thread states (spec §4.7).
    public struct Adapter: Codable, Sendable, Equatable {
        /// Adapter identifier (`claude-hooks`, `codex-notify`, `cursor-hooks`).
        public var kind: String
        /// Free-form adapter options.
        public var options: [String: String]?

        public init(kind: String, options: [String: String]? = nil) {
            self.kind = kind
            self.options = options
        }
    }

    /// Identifier, `^[a-z0-9][a-z0-9-]*$`; the file is named `<id>.json`.
    public var id: String
    /// Display name.
    public var name: String
    /// `"$SHELL"`, a bare name resolved against the login-shell PATH, an absolute path or `~/…`.
    public var command: String
    /// Arguments appended to `command`; may use placeholders.
    public var args: [String]
    /// Extra environment for the child; values may use placeholders.
    public var env: [String: String]
    /// `true` → argv[0] = `-<shell basename>` so the shell starts as a login shell (Terminal.app style).
    public var loginShell: Bool?
    /// Context projection, if the tool reads a project file.
    public var context: Context?
    /// Full argv used to resume a previous session; may use placeholders.
    public var resume: [String]?
    /// Full argv used for headless runs (graph, M3); may use placeholders.
    public var headless: [String]?
    /// Full argv for a *microsession*: one short, structured question (the New Task proposal) answered by the
    /// driver's light model, with a read-only tool allowlist so it can look a mentioned pull request up.
    /// Falls back to `headless` when absent; may use placeholders.
    public var headlessLight: [String]?
    /// Arguments appended to `args` when a thread starts with an initial prompt (a task created from a
    /// prompt): `["{prompt}"]` for tools that take the prompt as a positional argument. Nil → the prompt
    /// is not passed on the command line.
    public var prompt: [String]?
    /// Event adapter.
    public var adapter: Adapter?
    /// `true` on bundled copies. Keep it (with `version`) to receive updates of the bundled profile; drop
    /// it once you edit the file so `DriverRegistry.installBuiltins` never overwrites your copy.
    public var builtin: Bool?
    /// Revision of the bundled profile; an installed copy with a lower revision is replaced at startup.
    public var version: Int?
    /// SF Symbol name for the sidebar and tabs (`terminal`, `sparkles`).
    public var icon: String?

    public init(
        id: String,
        name: String,
        command: String,
        args: [String] = [],
        env: [String: String] = [:],
        loginShell: Bool? = nil,
        context: Context? = nil,
        resume: [String]? = nil,
        headless: [String]? = nil,
        headlessLight: [String]? = nil,
        prompt: [String]? = nil,
        adapter: Adapter? = nil,
        builtin: Bool? = nil,
        version: Int? = nil,
        icon: String? = nil
    ) {
        self.id = id
        self.name = name
        self.command = command
        self.args = args
        self.env = env
        self.loginShell = loginShell
        self.context = context
        self.resume = resume
        self.headless = headless
        self.headlessLight = headlessLight
        self.prompt = prompt
        self.adapter = adapter
        self.builtin = builtin
        self.version = version
        self.icon = icon
    }

    // `args` and `env` are optional on disk so a hand-written profile can be as short as
    // `{ "id": "x", "name": "X", "command": "x" }`.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        command = try container.decode(String.self, forKey: .command)
        args = try container.decodeIfPresent([String].self, forKey: .args) ?? []
        env = try container.decodeIfPresent([String: String].self, forKey: .env) ?? [:]
        loginShell = try container.decodeIfPresent(Bool.self, forKey: .loginShell)
        context = try container.decodeIfPresent(Context.self, forKey: .context)
        resume = try container.decodeIfPresent([String].self, forKey: .resume)
        headless = try container.decodeIfPresent([String].self, forKey: .headless)
        headlessLight = try container.decodeIfPresent([String].self, forKey: .headlessLight)
        prompt = try container.decodeIfPresent([String].self, forKey: .prompt)
        adapter = try container.decodeIfPresent(Adapter.self, forKey: .adapter)
        builtin = try container.decodeIfPresent(Bool.self, forKey: .builtin)
        version = try container.decodeIfPresent(Int.self, forKey: .version)
        icon = try container.decodeIfPresent(String.self, forKey: .icon)
    }

    /// `true` when the child must be started as a login shell.
    public var isLoginShell: Bool { loginShell ?? false }

    /// `true` when the profile declares a non-empty `resume` argv.
    public var canResume: Bool { !(resume ?? []).isEmpty }

    /// `true` when the profile can take an initial prompt on the command line (`prompt` argv).
    public var acceptsInitialPrompt: Bool { !(prompt ?? []).isEmpty }

    /// The argv a microsession runs: the light one when the profile declares it, else the headless argv.
    public var microsession: [String]? {
        let light = headlessLight ?? []
        return light.isEmpty ? headless : light
    }

    /// Checks the id, the command and every `{placeholder}` used in `args`, `resume`, `headless`,
    /// `headlessLight`, `prompt` and `env`.
    public func validate() throws(DriverProfileError) {
        guard Self.isValidID(id) else { throw .invalidID(id) }
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw .emptyCommand(id)
        }
        try Self.checkPlaceholders(in: [command], field: "command")
        try Self.checkPlaceholders(in: args, field: "args")
        try Self.checkPlaceholders(in: resume ?? [], field: "resume")
        try Self.checkPlaceholders(in: headless ?? [], field: "headless")
        try Self.checkPlaceholders(in: headlessLight ?? [], field: "headlessLight")
        try Self.checkPlaceholders(in: prompt ?? [], field: "prompt")
        try Self.checkPlaceholders(in: env.keys.sorted().map { env[$0] ?? "" }, field: "env")
    }

    /// `^[a-z0-9][a-z0-9-]*$`
    public static func isValidID(_ id: String) -> Bool {
        guard let first = id.unicodeScalars.first else { return false }
        guard ("a"..."z").contains(first) || ("0"..."9").contains(first) else { return false }
        return id.unicodeScalars.allSatisfy { scalar in
            ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) || scalar == "-"
        }
    }

    private static func checkPlaceholders(in strings: [String], field: String) throws(DriverProfileError) {
        for string in strings {
            for name in DriverPlaceholder.referencedNames(in: string) where DriverPlaceholder(rawValue: name) == nil {
                throw .badPlaceholder(name, in: field)
            }
        }
    }
}

/// Why a profile was rejected by `DriverProfile.validate()`.
public enum DriverProfileError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The id is not `^[a-z0-9][a-z0-9-]*$`.
    case invalidID(String)
    /// `command` is empty (associated value: the profile id).
    case emptyCommand(String)
    /// An unknown `{placeholder}` appears in the named field.
    case badPlaceholder(String, in: String)

    public var description: String {
        switch self {
        case .invalidID(let id):
            return "Invalid driver id \"\(id)\": use lowercase letters, digits and dashes, starting with a letter or digit."
        case .emptyCommand(let id):
            return "Driver \"\(id)\" has an empty \"command\"."
        case .badPlaceholder(let name, let field):
            let known = DriverPlaceholder.allCases.map { "{\($0.rawValue)}" }.joined(separator: ", ")
            return "Unknown placeholder {\(name)} in \"\(field)\". Known placeholders: \(known)."
        }
    }
}

/// Placeholders allowed in `args`, `resume`, `headless`, `prompt` and `env` values.
///
/// A placeholder is written `{name}`. Braces around anything else (`{}`, `{ "json": 1 }`, `{Foo}`)
/// are left untouched, so JSON or brace-expansion syntax can still appear in arguments.
public enum DriverPlaceholder: String, CaseIterable, Sendable {
    /// Scope's thread id.
    case threadID = "thread_id"
    /// The driver's own session id captured by an adapter (`ThreadRecord.resumeID`).
    case resumeID = "resume_id"
    /// The thread's working directory.
    case cwd = "cwd"
    /// The scope root path.
    case scope = "scope"
    /// The task root path (M2).
    case task = "task"
    /// `SCOPE_HOME`.
    case home = "home"
    /// The prompt for headless runs, or the initial prompt of a thread (`prompt` argv).
    case prompt = "prompt"
    /// Absolute path of the `scope-hook` binary (embedded in the app, or found on PATH).
    case scopeHook = "scope_hook"

    /// Every `{name}`-shaped token in `string`, in order, including unknown names (for validation).
    public static func referencedNames(in string: String) -> [String] {
        var names: [String] = []
        for token in tokenize(string) {
            if case .placeholder(let name) = token { names.append(name) }
        }
        return names
    }

    enum Token: Equatable {
        case literal(Substring)
        case placeholder(String)
    }

    /// Splits `string` into literal runs and `{name}` placeholders (`name` = `[a-z_]+`).
    static func tokenize(_ string: String) -> [Token] {
        var tokens: [Token] = []
        var literalStart = string.startIndex
        var index = string.startIndex
        while index < string.endIndex {
            guard string[index] == "{" else {
                index = string.index(after: index)
                continue
            }
            var cursor = string.index(after: index)
            while cursor < string.endIndex, isNameCharacter(string[cursor]) {
                cursor = string.index(after: cursor)
            }
            let nameRange = string.index(after: index)..<cursor
            guard !nameRange.isEmpty, cursor < string.endIndex, string[cursor] == "}" else {
                index = string.index(after: index)
                continue
            }
            if literalStart < index { tokens.append(.literal(string[literalStart..<index])) }
            tokens.append(.placeholder(String(string[nameRange])))
            index = string.index(after: cursor)
            literalStart = index
        }
        if literalStart < string.endIndex { tokens.append(.literal(string[literalStart...])) }
        return tokens
    }

    private static func isNameCharacter(_ character: Character) -> Bool {
        character == "_" || ("a"..."z").contains(character)
    }
}

/// Values substituted for placeholders when a launch is planned.
public struct PlaceholderValues: Sendable {
    /// `{thread_id}`
    public var threadID: String
    /// `{resume_id}`; nil until an adapter captures the driver's session id.
    public var resumeID: String?
    /// `{cwd}`
    public var cwd: String
    /// `{scope}` — the scope root path.
    public var scope: String
    /// `{task}` — the task root path (M2); nil in M0.
    public var task: String?
    /// `{home}` — `SCOPE_HOME`.
    public var home: String
    /// `{prompt}` — headless runs and threads started with an initial prompt.
    public var prompt: String?
    /// `{scope_hook}` — absolute path of the `scope-hook` binary (see `ScopeHookLocator`).
    public var scopeHook: String?

    public init(
        threadID: String,
        resumeID: String? = nil,
        cwd: String,
        scope: String,
        task: String? = nil,
        home: String,
        prompt: String? = nil,
        scopeHook: String? = nil
    ) {
        self.threadID = threadID
        self.resumeID = resumeID
        self.cwd = cwd
        self.scope = scope
        self.task = task
        self.home = home
        self.prompt = prompt
        self.scopeHook = scopeHook
    }

    /// The value for one placeholder, nil when it has no value in this context.
    public func value(for placeholder: DriverPlaceholder) -> String? {
        switch placeholder {
        case .threadID: return threadID
        case .resumeID: return resumeID
        case .cwd: return cwd
        case .scope: return scope
        case .task: return task
        case .home: return home
        case .prompt: return prompt
        case .scopeHook: return scopeHook
        }
    }

    /// Replaces every known `{placeholder}` in `string`. A referenced placeholder without a value throws
    /// `LaunchError.placeholderUnavailable`; unknown names are left as written (`validate()` rejects them earlier).
    public func expand(_ string: String) throws(LaunchError) -> String {
        var result = ""
        for token in DriverPlaceholder.tokenize(string) {
            switch token {
            case .literal(let text):
                result.append(contentsOf: text)
            case .placeholder(let name):
                guard let placeholder = DriverPlaceholder(rawValue: name) else {
                    result.append("{\(name)}")
                    continue
                }
                guard let value = value(for: placeholder) else {
                    throw .placeholderUnavailable(placeholder)
                }
                result.append(value)
            }
        }
        return result
    }

    /// `expand(_:)` over an argv.
    public func expand(_ strings: [String]) throws(LaunchError) -> [String] {
        var result: [String] = []
        result.reserveCapacity(strings.count)
        for string in strings {
            result.append(try expand(string))
        }
        return result
    }

    /// `expand(_:)` over environment values (keys are never expanded).
    public func expand(_ environment: [String: String]) throws(LaunchError) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in environment {
            result[key] = try expand(value)
        }
        return result
    }
}
