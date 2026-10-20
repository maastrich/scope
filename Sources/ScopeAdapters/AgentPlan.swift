import Foundation

/// What a thread's agent plans to do and how far it is, folded from the tool calls its hooks already report: the
/// todo list Claude Code keeps with `TodoWrite` (each item with its `content`, its `status` and, while it runs, its
/// `activeForm`); the task list newer versions keep instead, one task at a time (`TaskCreate` answers the new task's
/// `id`, `TaskUpdate` moves one by `taskId`, `TaskList` answers them all, and the `TaskCreated` / `TaskCompleted`
/// hooks say the same outside a tool call); and the plan it writes out of plan mode (`ExitPlanMode`'s `plan`,
/// markdown whose first heading is the title and whose numbered or checkbox items are the steps). The latest plan
/// wins: a `TodoWrite` or a `TaskList` replaces the list, a task call moves its one step, a plan sets the title and,
/// while there is no list, the steps.
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
        /// The driver's own id for a step that has one (a task of `TaskCreate`): what a later update names it by.
        public var id: String?
        public var text: String
        public var status: Status
        /// The present-tense form the agent gave the step for while it runs (`Running the tests` for `Run the
        /// tests`), when it gave one.
        public var activeForm: String?

        public init(id: String? = nil, text: String, status: Status, activeForm: String? = nil) {
            self.id = id
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
        /// One task at a time, by id (`TaskCreate`, `TaskUpdate`, `TaskList`, the task hooks).
        case tasks
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
    public static let knownTools: Set<String> = ["TodoWrite", "TaskCreate", "TaskUpdate", "TaskList", "ExitPlanMode",
                                                 "EnterPlanMode"]
    /// Claude Code hooks about a task of the list, fired outside any tool call (`plan.updated`).
    public static let taskHooks: Set<String> = ["TaskCreated", "TaskCompleted"]

    public static func isCandidate(tool: String) -> Bool {
        if knownTools.contains(tool) { return true }
        let lowered = tool.lowercased()
        return lowered.contains("todo") || lowered.contains("plan") || lowered.contains("task")
    }

    /// The plan after a hook whose stdin was `raw`: a call to `tool` (`PostToolUse`), or with no tool a task hook
    /// (`TaskCreated`, `TaskCompleted`). `nil` when it says nothing about a plan (an unknown shape, a truncated or
    /// missing stdin). `current` is the plan so far, if any.
    public static func applying(tool: String?, raw: String?, to current: AgentPlan?, at: Date) -> AgentPlan? {
        guard let raw, let object = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] else { return nil }
        if let hook = object["hook_event_name"] as? String, taskHooks.contains(hook) {
            return applyingTaskHook(object, completed: hook == "TaskCompleted", to: current, at: at)
        }
        guard let tool, isCandidate(tool: tool), let input = object["tool_input"] as? [String: Any] else { return nil }
        let response = jsonObject(object["tool_response"])
        return applying(input: input, response: response, to: current, at: at)
    }

    /// A `tool_response` as an object: Claude Code gives the structured output, older versions a JSON string.
    static func jsonObject(_ value: Any?) -> [String: Any]? {
        if let object = value as? [String: Any] { return object }
        guard let text = value as? String else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }

    /// The same, from the parsed `tool_input` and `tool_response`.
    public static func applying(input: [String: Any], response: [String: Any]? = nil, to current: AgentPlan?,
                                at: Date) -> AgentPlan? {
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
        if let response, let next = applyingTasks(input: input, response: response, to: current, at: at) {
            return next
        }
        if let steps = parseSteps(input: input) {
            var next = current ?? AgentPlan(updatedAt: at)
            next.steps = steps
            next.source = .todos
            next.updatedAt = at
            return next
        }
        if input["taskId"] != nil, let next = applyingTasks(input: input, response: [:], to: current, at: at) {
            return next
        }
        return nil
    }

    // MARK: Task tools

    /// `TaskList` (`tasks[]` in the response: the whole list), `TaskCreate` (`task` in the response: one new step),
    /// `TaskUpdate` (`taskId` in the input: one step moved, or removed when its status is `deleted`). `nil` when the
    /// call has none of these shapes, or names a step the plan does not hold and gives it no text.
    static func applyingTasks(input: [String: Any], response: [String: Any], to current: AgentPlan?, at: Date) -> AgentPlan? {
        if let tasks = response["tasks"] as? [[String: Any]] {
            let known = Dictionary((current?.steps ?? []).compactMap { step in step.id.map { ($0, step) } }) { first, _ in first }
            let steps = tasks.compactMap { task -> Step? in
                guard let id = string(task["id"]), let text = text(of: task),
                      let status = (task["status"] as? String).flatMap(Status.init(loose:)) else { return nil }
                return Step(id: id, text: text, status: status, activeForm: known[id]?.activeForm)
            }
            guard steps.count == tasks.count else { return nil }
            return withTaskSteps(current, at: at) { $0 = steps }
        }
        if let task = response["task"] as? [String: Any], let id = string(task["id"]),
           let text = text(of: task) ?? text(of: input) {
            return upsert(id: id, text: text, status: nil, activeForm: string(input["activeForm"]), in: current, at: at)
        }
        if let id = string(input["taskId"]) ?? string(response["taskId"]) {
            let word = input["status"] as? String
            if word?.lowercased() == "deleted" {
                guard current?.steps.contains(where: { $0.id == id }) == true else { return nil }
                return withTaskSteps(current, at: at) { $0.removeAll { $0.id == id } }
            }
            return upsert(id: id, text: text(of: input), status: word.flatMap(Status.init(loose:)),
                          activeForm: string(input["activeForm"]), in: current, at: at)
        }
        return nil
    }

    /// `TaskCreated` / `TaskCompleted`: `task_id`, `task_subject`, `task_description`.
    static func applyingTaskHook(_ object: [String: Any], completed: Bool, to current: AgentPlan?, at: Date) -> AgentPlan? {
        guard let id = string(object["task_id"]) else { return nil }
        let text = [object["task_subject"], object["task_description"]].lazy.compactMap { $0 as? String }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
        return upsert(id: id, text: text, status: completed ? .completed : nil, activeForm: nil, in: current, at: at)
    }

    /// The step `id` moved, or added at the end (pending) when the plan does not hold it yet and `text` names it.
    static func upsert(id: String, text: String?, status: Status?, activeForm: String?, in current: AgentPlan?, at: Date) -> AgentPlan? {
        let holds = current?.source == .tasks && current?.steps.contains { $0.id == id } == true
        guard holds || text != nil else { return nil }
        return withTaskSteps(current, at: at) { steps in
            if let index = steps.firstIndex(where: { $0.id == id }) {
                if let text { steps[index].text = text }
                if let status { steps[index].status = status }
                if let activeForm { steps[index].activeForm = activeForm }
            } else if let text {
                steps.append(Step(id: id, text: text, status: status ?? .pending, activeForm: activeForm))
            }
        }
    }

    /// `current` with its steps changed by `change`. Steps that did not come from tasks (a todo list, a plan's
    /// items) are dropped first: the agent has moved to its task list, and a task id means nothing among them.
    static func withTaskSteps(_ current: AgentPlan?, at: Date, _ change: (inout [Step]) -> Void) -> AgentPlan {
        var next = current ?? AgentPlan(updatedAt: at)
        if next.source != .tasks { next.steps = [] }
        change(&next.steps)
        next.source = .tasks
        next.updatedAt = at
        return next
    }

    static func string(_ value: Any?) -> String? {
        if let text = value as? String { return text.isEmpty ? nil : text }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    static func text(of object: [String: Any]) -> String? {
        textKeys.lazy.compactMap { object[$0] as? String }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
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
        guard let text = text(of: object) else { return nil }
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
