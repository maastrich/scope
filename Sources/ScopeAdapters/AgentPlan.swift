import Foundation

/// What a thread's agent plans to do and how far it is, folded from the tool calls its hooks already report: the
/// todo list Claude Code keeps with `TodoWrite` (each item with its `content`, its `status` and, while it runs, its
/// `activeForm`), and the plan it writes out of plan mode (`ExitPlanMode`'s `plan`, markdown whose first heading is
/// the title and whose numbered or checkbox items are the steps). The latest plan wins: a `TodoWrite` replaces the
/// list, a plan sets the title and, while there is no list, the steps.
///
/// Read from the `PostToolUse` payload (`tool_input`) rather than from a tool's name alone: the driver may rename
/// the tool, so any call whose input holds an array of objects with a text and a status is a list of steps, and any
/// whose input holds a `plan` string is a plan. A shape this does not know changes nothing and fails nothing.
public struct AgentPlan: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable, CaseIterable {
        case pending
        case inProgress = "in_progress"
        case completed
    }

    public struct Step: Codable, Sendable, Equatable, Hashable {
        public var text: String
        public var status: Status
        /// The present-tense form the agent gave the step for while it runs (`Running the tests` for `Run the
        /// tests`), when it gave one.
        public var activeForm: String?

        public init(text: String, status: Status, activeForm: String? = nil) {
            self.text = text
            self.status = status
            self.activeForm = activeForm
        }

        /// What a row says: the active form while the step runs, the step itself otherwise.
        public var label: String {
            status == .inProgress ? (activeForm.flatMap { $0.isEmpty ? nil : $0 } ?? text) : text
        }
    }

    /// Where the steps came from: a todo list replaces anything, a plan only replaces steps that came from a plan.
    public enum Source: String, Codable, Sendable {
        case todos
        case plan
    }

    public var title: String?
    public var steps: [Step]
    public var source: Source?
    public var updatedAt: Date

    public init(title: String? = nil, steps: [Step] = [], source: Source? = nil, updatedAt: Date) {
        self.title = title
        self.steps = steps
        self.source = source
        self.updatedAt = updatedAt
    }

    /// The step the agent is on: the first in progress, else the first still pending.
    public var currentStep: Step? {
        steps.first { $0.status == .inProgress } ?? steps.first { $0.status == .pending }
    }

    public var done: Int { steps.filter { $0.status == .completed }.count }
    public var total: Int { steps.count }

    /// `3/7 steps`; `no steps` for a plan with a title alone.
    public var summary: String {
        total == 0 ? "no steps" : "\(done)/\(total) steps"
    }

    /// Steps remain: what the sidebar hints at. A finished list, or a title alone, is not in progress.
    public var isInProgress: Bool { total > 0 && done < total }

    /// What a closed card says: `3/7 steps · Run the tests`, or the counts alone once every step is done.
    public var headline: String {
        guard total > 0 else { return title ?? "no steps" }
        guard let current = currentStep else { return summary }
        return "\(summary) · \(current.label)"
    }

    // MARK: Folding

    /// Tools whose `PostToolUse` is read for a plan, by name — and, past these, any tool whose name says it is about
    /// a todo list, a plan or tasks, so a renamed tool keeps feeding the card.
    public static let knownTools: Set<String> = ["TodoWrite", "ExitPlanMode", "EnterPlanMode"]

    public static func isCandidate(tool: String) -> Bool {
        if knownTools.contains(tool) { return true }
        let lowered = tool.lowercased()
        return lowered.contains("todo") || lowered.contains("plan") || lowered.contains("task")
    }

    /// The plan after a call to `tool` whose hook stdin was `raw`; `nil` when the call says nothing about a plan
    /// (an unknown shape, a truncated or missing stdin). `current` is the plan so far, if any.
    public static func applying(tool: String, raw: String?, to current: AgentPlan?, at: Date) -> AgentPlan? {
        guard isCandidate(tool: tool), let raw,
              let object = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any],
              let input = object["tool_input"] as? [String: Any] else { return nil }
        return applying(input: input, to: current, at: at)
    }

    /// The same, from the parsed `tool_input`.
    public static func applying(input: [String: Any], to current: AgentPlan?, at: Date) -> AgentPlan? {
        if let plan = input["plan"] as? String, !plan.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let parsed = parsePlan(markdown: plan)
            var next = current ?? AgentPlan(updatedAt: at)
            next.title = parsed.title ?? next.title
            // A list the agent keeps by hand outlives a plan; steps read out of a plan give way to the next plan.
            if !parsed.steps.isEmpty, next.steps.isEmpty || next.source == .plan {
                next.steps = parsed.steps
                next.source = .plan
            }
            next.updatedAt = at
            return next
        }
        if let steps = parseSteps(input: input) {
            var next = current ?? AgentPlan(updatedAt: at)
            next.steps = steps
            next.source = .todos
            next.updatedAt = at
            return next
        }
        return nil
    }

    // MARK: Parsing

    /// Keys an item's text is read from, in the order tried.
    public static let textKeys = ["content", "text", "title", "task", "subject", "name", "description"]
    public static let activeFormKeys = ["activeForm", "active_form"]

    /// The first array in `input` whose every element is an object with a text and a status; an empty `todos` is a
    /// cleared list. `nil` when nothing in the input has that shape.
    public static func parseSteps(input: [String: Any]) -> [Step]? {
        // `todos` first: the key Claude Code uses, so a second array in the same input cannot shadow it — and the
        // one key whose empty array means a cleared list rather than nothing to say.
        if let todos = input["todos"] as? [Any], todos.isEmpty { return [] }
        let candidates = (input["todos"].map { [$0] } ?? []) + input.sorted { $0.key < $1.key }.map(\.value)
        for value in candidates {
            guard let array = value as? [Any], !array.isEmpty else { continue }
            let steps = array.compactMap(parseStep)
            if steps.count == array.count { return steps }
        }
        return nil
    }

    static func parseStep(_ value: Any) -> Step? {
        guard let object = value as? [String: Any], let rawStatus = object["status"] as? String,
              let status = Status(loose: rawStatus) else { return nil }
        let text = textKeys.lazy.compactMap { object[$0] as? String }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
        guard let text else { return nil }
        let activeForm = activeFormKeys.lazy.compactMap { object[$0] as? String }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
        return Step(text: text, status: status, activeForm: activeForm)
    }

    /// A plan written in markdown: its title is the first heading, else its first line; its steps are its numbered
    /// items (`1.`, `2)`) and checkboxes (`- [ ]`, `- [x]`) at the top level, a checked box being done.
    public static func parsePlan(markdown: String) -> (title: String?, steps: [Step]) {
        var title: String?
        var firstLine: String?
        var steps: [Step] = []
        for rawLine in markdown.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if title == nil, trimmed.hasPrefix("#") {
                let heading = trimmed.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                if !heading.isEmpty { title = clean(heading) }
                continue
            }
            if firstLine == nil { firstLine = clean(trimmed) }
            // Items nested deeper than three spaces are the sub-points of a step, not steps.
            let indent = line.prefix { $0 == " " || $0 == "\t" }.count
            guard indent <= 3, let step = parseItem(trimmed) else { continue }
            steps.append(step)
        }
        return (title ?? firstLine.map { String($0.prefix(120)) }, steps)
    }

    /// One markdown list item that is a step; `nil` for a plain bullet or prose.
    static func parseItem(_ line: String) -> Step? {
        if let range = line.range(of: #"^[-*+]\s+\[([ xX])\]\s+"#, options: .regularExpression) {
            let mark = line[range].first { $0 == "x" || $0 == "X" }
            let text = clean(String(line[range.upperBound...]))
            guard !text.isEmpty else { return nil }
            return Step(text: text, status: mark == nil ? .pending : .completed)
        }
        if let range = line.range(of: #"^\d{1,3}[.)]\s+"#, options: .regularExpression) {
            let text = clean(String(line[range.upperBound...]))
            guard !text.isEmpty else { return nil }
            return Step(text: text, status: .pending)
        }
        return nil
    }

    /// Markdown emphasis and code marks dropped, whitespace collapsed.
    static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

extension AgentPlan.Status {
    /// The status words drivers use, folded onto the three states; `nil` for a word that is none of them.
    init?(loose word: String) {
        switch word.lowercased().replacingOccurrences(of: "-", with: "_").replacingOccurrences(of: " ", with: "_") {
        case "pending", "todo", "open", "not_started", "queued": self = .pending
        case "in_progress", "inprogress", "active", "doing", "running", "started": self = .inProgress
        case "completed", "complete", "done", "finished", "closed": self = .completed
        default: return nil
        }
    }
}
