import Foundation
import ScopeCore

/// One step of a mission: a child task with a validation step. The orchestrator names it and marks it done; Scope
/// runs the validation and records what it said.
public struct Milestone: Codable, Sendable, Equatable, Hashable, Identifiable {
    public enum State: String, Codable, Sendable, CaseIterable {
        /// Named, not finished.
        case open
        /// Marked done; the validation is running, or there is none and it is finished.
        case done
        /// The validation command exited 0.
        case validated
        /// The validation command failed; `log` says how.
        case failed

        /// Whether the milestone counts as reached: validated, or done with nothing to validate.
        public var isComplete: Bool { self == .validated || self == .done }
    }

    public var id: String
    public var title: String
    /// A shell command run in the milestone's sandbox when it is marked done (the test suite, a build, `gh pr checks`).
    /// `nil` means done is enough.
    public var validation: String?
    /// The child task doing the milestone, when one was named.
    public var task: TaskID?
    public var state: State
    public var doneAt: Date?
    public var validatedAt: Date?
    /// `exit 1`, `timed out`: the last validation's end.
    public var exit: String?
    /// The end of the last validation's output, bounded (`Mission.logLimit`).
    public var log: String?

    public init(id: String = Milestone.newID(), title: String, validation: String? = nil, task: TaskID? = nil,
                state: State = .open, doneAt: Date? = nil, validatedAt: Date? = nil, exit: String? = nil, log: String? = nil) {
        self.id = id
        self.title = title
        self.validation = validation.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty }
        self.task = task
        self.state = state
        self.doneAt = doneAt
        self.validatedAt = validatedAt
        self.exit = exit
        self.log = log
    }

    public static func newID() -> String {
        String(format: "%08x", UInt32.random(in: 0...UInt32.max))
    }

    private enum CodingKeys: String, CodingKey { case id, title, validation, task, state, doneAt, validatedAt, exit, log }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decodeIfPresent(String.self, forKey: .id)).flatMap { $0 } ?? Milestone.newID()
        title = try container.decode(String.self, forKey: .title)
        validation = (try? container.decodeIfPresent(String.self, forKey: .validation)).flatMap { $0 }
        task = (try? container.decodeIfPresent(TaskID.self, forKey: .task)).flatMap { $0 }
        state = (try? container.decodeIfPresent(State.self, forKey: .state)).flatMap { $0 } ?? .open
        doneAt = (try? container.decodeIfPresent(Date.self, forKey: .doneAt)).flatMap { $0 }
        validatedAt = (try? container.decodeIfPresent(Date.self, forKey: .validatedAt)).flatMap { $0 }
        exit = (try? container.decodeIfPresent(String.self, forKey: .exit)).flatMap { $0 }
        log = (try? container.decodeIfPresent(String.self, forKey: .log)).flatMap { $0 }
    }
}

/// A task whose brief is a goal, reached through milestones (spec §4.3). Scope stores the milestones and runs their
/// validation; the orchestrator plans them, opens one child task at a time, and marks each done.
public struct Mission: Codable, Sendable, Equatable, Hashable {
    /// How much of a validation's output is kept on the record.
    public static let logLimit = 8 * 1024
    /// How long a validation command may run.
    public static let validationTimeout: Duration = .seconds(1800)

    public var milestones: [Milestone]

    public init(milestones: [Milestone] = []) {
        self.milestones = milestones
    }

    private enum CodingKeys: String, CodingKey { case milestones }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        milestones = ((try? container.decodeIfPresent([Milestone].self, forKey: .milestones)) ?? nil) ?? []
    }

    /// `2/5`: reached milestones over named ones.
    public var progress: (reached: Int, total: Int) {
        (milestones.filter { $0.state.isComplete }.count, milestones.count)
    }

    /// The first milestone not reached yet, if any.
    public var next: Milestone? {
        milestones.first { !$0.state.isComplete }
    }

    /// `3/5 milestones`, or `no milestones yet`.
    public var caption: String {
        let (reached, total) = progress
        return total == 0 ? "no milestones yet" : "\(reached)/\(total) milestones"
    }

    /// Adds a milestone at the end. The title is trimmed; an empty one is refused.
    public mutating func add(title: String, validation: String? = nil, task: TaskID? = nil) -> Result<Milestone, MissionError> {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return .failure(.emptyTitle) }
        let milestone = Milestone(title: title, validation: validation, task: task)
        milestones.append(milestone)
        return .success(milestone)
    }

    /// The milestone `reference` names: its 1-based number, its id, or its title whatever the case.
    public func index(of reference: String) -> Int? {
        let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        if let number = Int(trimmed), (1...milestones.count).contains(number) { return number - 1 }
        if let found = milestones.firstIndex(where: { $0.id == trimmed }) { return found }
        return milestones.firstIndex { $0.title.caseInsensitiveCompare(trimmed) == .orderedSame }
    }

    /// Marks a milestone done at `date`: `done` outright when there is nothing to validate, `done` awaiting the
    /// validation otherwise. A milestone already reached is refused: marking it twice would hide a failed re-run.
    public mutating func markDone(_ index: Int, task: TaskID? = nil, at date: Date) -> Result<Milestone, MissionError> {
        guard milestones.indices.contains(index) else { return .failure(.noSuchMilestone) }
        var milestone = milestones[index]
        guard milestone.state != .validated else { return .failure(.alreadyReached(milestone.title)) }
        if let task { milestone.task = task }
        milestone.state = .done
        milestone.doneAt = date
        milestone.exit = nil
        milestone.log = nil
        milestone.validatedAt = nil
        milestones[index] = milestone
        return .success(milestone)
    }

    /// Records what the validation said: `validated` on exit 0, `failed` otherwise, with the end of its output.
    public mutating func applyValidation(_ index: Int, succeeded: Bool, exit: String, output: String, at date: Date) {
        guard milestones.indices.contains(index) else { return }
        milestones[index].state = succeeded ? .validated : .failed
        milestones[index].validatedAt = date
        milestones[index].exit = exit
        milestones[index].log = Mission.tail(output)
    }

    /// The end of `output`, within `logLimit`, cut at a line.
    public static func tail(_ output: String) -> String? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.utf8.count > logLimit else { return trimmed }
        var kept = String(decoding: trimmed.utf8.suffix(logLimit), as: UTF8.self)
        if let newline = kept.firstIndex(of: "\n") { kept = String(kept[kept.index(after: newline)...]) }
        return "…\n" + kept
    }

    /// The message the milestone's thread gets when its validation fails.
    public static func failureMessage(milestone: Milestone, command: String) -> String {
        var lines = ["[Scope: the validation of milestone “\(milestone.title)” failed (\(milestone.exit ?? "failed")).]",
                     "Command: `\(command)`", "Fix what fails, then mark the milestone done again (`scope task milestone done`)."]
        if let log = milestone.log {
            lines.append("")
            lines.append("```")
            lines.append(log)
            lines.append("```")
        }
        return lines.joined(separator: "\n")
    }
}

public enum MissionError: Error, Sendable, Equatable, CustomStringConvertible {
    case emptyTitle
    case noSuchMilestone
    case alreadyReached(String)

    public var description: String {
        switch self {
        case .emptyTitle: "a milestone needs a title"
        case .noSuchMilestone: "no such milestone"
        case .alreadyReached(let title): "the milestone “\(title)” is already validated"
        }
    }
}
