import Foundation

/// One thing a Claude Code session is asking the user, with what it asks: a tool permission (the command, the file
/// and the kind of edit, the URL, the MCP tool and its server, the rules Claude Code offers to add), a question
/// (`AskUserQuestion`: each question, its header, its options, single or multiple choice), a plan (`ExitPlanMode`) or
/// an MCP server's form (elicitation).
///
/// Built from the hook that carries the content — `PermissionRequest`, the question tools' `PreToolUse`,
/// `Elicitation` — and kept by `ClaudePendingRequests` until something says it was answered. Free text is bounded
/// (`textLimit`): a command or a plan can be long, and this value travels to the CLI and is observed by the UI.
public struct ClaudePendingRequest: Sendable, Equatable, Codable, Identifiable {
    public enum Kind: String, Sendable, Codable, CaseIterable {
        /// A tool waits for the user's go-ahead.
        case permission
        /// `AskUserQuestion`.
        case question
        /// `ExitPlanMode`: the plan waits for approval.
        case plan
        /// An MCP server asks for input (a form, or a URL to open).
        case elicitation
    }

    public struct Question: Sendable, Equatable, Codable {
        public struct Option: Sendable, Equatable, Codable {
            public var label: String
            public var description: String?

            public init(label: String, description: String? = nil) {
                self.label = label
                self.description = description
            }
        }

        public var question: String
        /// The short tab title Claude Code draws above the question (`Color`, `Checks`).
        public var header: String?
        public var multiSelect: Bool
        public var options: [Option]

        public init(question: String, header: String? = nil, multiSelect: Bool = false, options: [Option] = []) {
            self.question = question
            self.header = header
            self.multiSelect = multiSelect
            self.options = options
        }
    }

    /// `toolu_…` when the hook said, else a digest of what is asked: the same request read twice gets the same id.
    public var id: String
    public var kind: Kind
    /// `tool_name`: `Bash`, `Edit`, `mcp__server__tool`, `AskUserQuestion`; `nil` for an elicitation.
    public var tool: String?
    public var toolUseID: String?
    /// The sub-agent asking, when it is one (`agent_id`): its dialog shows in the same terminal.
    public var agentID: String?
    public var agentType: String?
    /// When the hook that described it arrived.
    public var askedAt: Date
    /// The dialog is up and waits for someone: confirmed by `permission_prompt` / `elicitation_*` (a permission and a
    /// form are described a moment before, and another hook or auto mode may still decide them), from the start for a
    /// question or a plan.
    public var shown: Bool

    // MARK: Permission

    /// A shell command, whole (bounded).
    public var command: String?
    /// What the agent says the call does (`description` of a `Bash` or an MCP tool call).
    public var summary: String?
    /// The file an edit, a write or a notebook edit touches.
    public var filePath: String?
    /// What kind of change: `create or overwrite`, `edit`, `edit (every occurrence)`, `3 edits`, `notebook: insert`…
    public var edit: String?
    /// A `WebFetch` URL, a `WebSearch` query.
    public var url: String?
    public var query: String?
    /// An MCP tool's server (`mcp_server.name`, or the middle of `mcp__server__tool`) and its own name; an
    /// elicitation's server.
    public var mcpServer: String?
    public var mcpTool: String?
    /// The rules Claude Code offers to remember with the answer (`permission_suggestions`), in words:
    /// `allow mcp__probe__probe_echo (local settings)`, `switch to acceptEdits (session)`.
    public var suggestions: [String]

    // MARK: Question, plan, elicitation

    public var questions: [Question]
    public var plan: String?
    public var planFilePath: String?
    /// An elicitation's message and mode (`form`, `url`), and the URL a `url` one wants opened.
    public var message: String?
    public var mode: String?
    /// The fields a form asks for, by name.
    public var fields: [String]

    /// Most characters any free text keeps.
    public static let textLimit = 4000

    public init(id: String, kind: Kind, tool: String? = nil, toolUseID: String? = nil, agentID: String? = nil,
                agentType: String? = nil, askedAt: Date, shown: Bool = false) {
        self.id = id
        self.kind = kind
        self.tool = tool
        self.toolUseID = toolUseID
        self.agentID = agentID
        self.agentType = agentType
        self.askedAt = askedAt
        self.shown = shown
        suggestions = []
        questions = []
        fields = []
    }

    /// The fingerprint a request without a `tool_use_id` is matched on: its tool and its input, as Claude Code sent
    /// them. A `PermissionRequest` carries no id, so its `PostToolUse` finds it through this.
    static func fingerprint(tool: String?, input: JSONValue?) -> String {
        "\(tool ?? "")|\(input?.jsonString ?? "")"
    }

    /// FNV-1a of `text`, hex: stable across launches, unlike `hashValue`.
    static func digest(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }

    static func bounded(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        return text.count > textLimit ? String(text.prefix(textLimit - 1)) + "…" : text
    }

    // MARK: Reading a hook

    /// A tool permission, from `PermissionRequest`.
    static func permission(_ facts: ClaudeHookFacts) -> ClaudePendingRequest {
        let tool = facts.toolName
        let input = facts.toolInput
        let id = facts.toolUseID ?? "perm-" + digest(fingerprint(tool: tool, input: input))
        var request = ClaudePendingRequest(id: id, kind: .permission, tool: tool, toolUseID: facts.toolUseID,
                                           agentID: facts.agentID, agentType: facts.agentType, askedAt: facts.at)
        request.readToolInput(input)
        if let tool, let mcp = Self.mcpName(tool) {
            request.mcpServer = facts.body["mcp_server"]?["name"]?.nonEmptyString ?? mcp.server
            request.mcpTool = mcp.tool
            request.summary = request.summary ?? input?["description"]?.nonEmptyString
        }
        request.suggestions = (facts.body["permission_suggestions"]?.array ?? []).compactMap(Self.suggestion)
        return request
    }

    /// A question or a plan, from the question tools' `PreToolUse` (or their transcript call).
    static func question(tool: String, toolUseID: String?, input: JSONValue?, agentID: String?, agentType: String?,
                         at: Date) -> ClaudePendingRequest {
        let id = toolUseID ?? "ask-" + digest(fingerprint(tool: tool, input: input))
        var request = ClaudePendingRequest(id: id, kind: tool == "ExitPlanMode" ? .plan : .question, tool: tool,
                                           toolUseID: toolUseID, agentID: agentID, agentType: agentType, askedAt: at,
                                           shown: true)
        if request.kind == .plan {
            request.plan = bounded(input?["plan"]?.nonEmptyString)
            request.planFilePath = input?["planFilePath"]?.nonEmptyString
        } else {
            request.questions = (input?["questions"]?.array ?? []).compactMap(Self.question)
        }
        return request
    }

    /// An MCP server's form, from `Elicitation`.
    static func elicitation(_ facts: ClaudeHookFacts) -> ClaudePendingRequest {
        let server = facts.body["mcp_server_name"]?.nonEmptyString
        let message = facts.body["message"]?.nonEmptyString
        var request = ClaudePendingRequest(id: "elicit-" + digest("\(server ?? "")|\(message ?? "")|\(facts.at.timeIntervalSince1970)"),
                                           kind: .elicitation, agentID: facts.agentID, agentType: facts.agentType,
                                           askedAt: facts.at)
        request.mcpServer = server
        request.message = bounded(message)
        request.mode = facts.body["mode"]?.nonEmptyString
        request.url = facts.body["url"]?.nonEmptyString
        request.fields = (facts.body["requested_schema"]?["properties"]?.object ?? [:]).keys.sorted()
        return request
    }

    /// The content of a tool call worth showing before it runs.
    private mutating func readToolInput(_ input: JSONValue?) {
        guard let input else { return }
        switch tool {
        case "Bash":
            command = Self.bounded(input["command"]?.nonEmptyString)
            summary = input["description"]?.nonEmptyString
        case "Write":
            filePath = input["file_path"]?.nonEmptyString
            edit = "create or overwrite"
        case "Edit":
            filePath = input["file_path"]?.nonEmptyString
            edit = input["replace_all"]?.bool == true ? "edit (every occurrence)" : "edit"
        case "MultiEdit":
            filePath = input["file_path"]?.nonEmptyString
            let count = input["edits"]?.array?.count ?? 0
            edit = count == 1 ? "1 edit" : "\(count) edits"
        case "NotebookEdit":
            filePath = input["notebook_path"]?.nonEmptyString
            edit = "notebook: " + (input["edit_mode"]?.nonEmptyString ?? "replace")
        case "WebFetch":
            url = input["url"]?.nonEmptyString
        case "WebSearch":
            query = input["query"]?.nonEmptyString
        default:
            // Other tools (Read, Grep, a sub-agent's Task, an MCP call): the path or pattern they name, when any.
            filePath = input["file_path"]?.nonEmptyString ?? input["path"]?.nonEmptyString
            command = Self.bounded(input["pattern"]?.nonEmptyString ?? input["prompt"]?.nonEmptyString)
        }
    }

    private static func question(_ value: JSONValue) -> Question? {
        guard let text = value["question"]?.nonEmptyString else { return nil }
        let options = (value["options"]?.array ?? []).compactMap { option -> Question.Option? in
            guard let label = option["label"]?.nonEmptyString else { return nil }
            return Question.Option(label: label, description: option["description"]?.nonEmptyString)
        }
        return Question(question: bounded(text) ?? text, header: value["header"]?.nonEmptyString,
                        multiSelect: value["multiSelect"]?.bool ?? false, options: options)
    }

    /// `{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"npm test:*"}],"behavior":"allow",
    /// "destination":"localSettings"}` → `allow Bash(npm test:*) (local settings)`.
    private static func suggestion(_ value: JSONValue) -> String? {
        let destination = value["destination"]?.nonEmptyString.map { " (\(words($0)))" } ?? ""
        switch value["type"]?.string {
        case "addRules", "replaceRules":
            let rules = (value["rules"]?.array ?? []).compactMap { rule -> String? in
                guard let name = rule["toolName"]?.nonEmptyString else { return nil }
                return rule["ruleContent"]?.nonEmptyString.map { "\(name)(\($0))" } ?? name
            }
            guard !rules.isEmpty else { return nil }
            return "\(value["behavior"]?.nonEmptyString ?? "allow") \(rules.joined(separator: ", "))\(destination)"
        case "setMode":
            return value["mode"]?.nonEmptyString.map { "switch to \($0)\(destination)" }
        case "addDirectories":
            let directories = (value["directories"]?.array ?? []).compactMap(\.nonEmptyString)
            return directories.isEmpty ? nil : "add \(directories.joined(separator: ", "))\(destination)"
        default:
            return nil
        }
    }

    /// `localSettings` → `local settings`.
    private static func words(_ camel: String) -> String {
        camel.reduce(into: "") { text, character in
            if character.isUppercase { text += " " + character.lowercased() } else { text.append(character) }
        }
    }

    /// `mcp__server__tool` → (`server`, `tool`); `nil` for any other name.
    public static func mcpName(_ tool: String) -> (server: String, tool: String)? {
        let parts = tool.split(separator: "__", omittingEmptySubsequences: false)
        guard parts.count >= 3, parts[0] == "mcp", !parts[1].isEmpty else { return nil }
        let name = parts[2...].joined(separator: "__")
        return name.isEmpty ? nil : (String(parts[1]), name)
    }

    // MARK: In words

    /// The question's text, for a request that is one.
    public var firstQuestion: String? { questions.first?.question }

    /// One line saying what is asked, for a sidebar row, an Inbox item, a notification's body:
    /// `git push origin main`, `Which color should the probe use?`, `probe_echo on probe`, `Edit App.swift`.
    public var headline: String {
        switch kind {
        case .question:
            let first = firstQuestion ?? "A question"
            return questions.count > 1 ? "\(first) (+\(questions.count - 1) more)" : first
        case .plan:
            return Self.firstLine(plan).map { "Plan: \($0)" } ?? "A plan to approve"
        case .elicitation:
            let what = message ?? "asks for input"
            return mcpServer.map { "\($0): \(what)" } ?? what
        case .permission:
            if let command, let line = Self.firstLine(command) { return line }
            if let mcpTool { return mcpServer.map { "\(mcpTool) on \($0)" } ?? mcpTool }
            if let filePath {
                let name = (filePath as NSString).lastPathComponent
                let verb = tool == "Write" ? "Write" : tool == "Read" ? "Read" : "Edit"
                return "\(verb) \(name.isEmpty ? filePath : name)"
            }
            if let url { return "Fetch \(url)" }
            if let query { return "Search the web for \"\(query)\"" }
            return tool.map { "Use \($0)" } ?? "A permission"
        }
    }

    /// The first line worth reading: a plan opening on `## Plan` says nothing until its first bullet.
    static func firstLine(_ text: String?) -> String? {
        let lines = (text ?? "").split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let prose = lines.filter { !$0.hasPrefix("#") }
        return (prose.isEmpty ? lines : prose).lazy
            .map { line in
                var line = Substring(line)
                while let first = line.first, "#>*-".contains(first) { line = line.dropFirst() }
                return line.trimmingCharacters(in: .whitespaces)
            }
            .first { !$0.isEmpty }
    }
}
