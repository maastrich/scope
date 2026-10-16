import Foundation

/// One attempt of a brief run several ways (best-of-N): which it is in its family, and what the family was
/// called before `· attempt N` was appended, so *Keep this one* can hand the kept task the plain name back.
///
/// Stored on `TaskRecord`: the topic alone would not do, the user may rename it, and the name's suffix is a display
/// convention, not an identity.
public struct TaskAttempt: Codable, Sendable, Equatable, Hashable {
    /// Shared by the N tasks of one `task new --attempts N`.
    public var group: String
    /// 1-based.
    public var index: Int
    public var count: Int
    /// The brief's name and branch: what the kept task goes back to.
    public var baseName: String
    public var baseBranch: String
    /// What this attempt was asked to run on, when the request said: shown before any thread exists to tell.
    public var model: String?
    public var driver: String?

    public init(group: String, index: Int, count: Int, baseName: String, baseBranch: String,
                model: String? = nil, driver: String? = nil) {
        self.group = group
        self.index = index
        self.count = count
        self.baseName = baseName
        self.baseBranch = baseBranch
        self.model = model
        self.driver = driver
    }
}

/// The kept task remembers the choice: the Inbox tells it once, and the hover card can say where it came from.
public struct TaskAttemptsKept: Codable, Sendable, Equatable, Hashable {
    public var count: Int
    public var at: Date
    /// The archived siblings' branches, kept, so the item can name them.
    public var otherBranches: [String]

    public init(count: Int, at: Date, otherBranches: [String] = []) {
        self.count = count
        self.at = at
        self.otherBranches = otherBranches
    }
}

/// Naming and planning of a brief run N ways. Pure; the git and task steps live in `TaskManager` and the app.
public enum TaskAttempts {
    /// More than this and the comparison stops fitting a window, and the budget would refuse anyway.
    public static let maxCount = 9

    /// A request that cannot be turned into attempts, in words for the caller.
    public struct Refusal: Error, Sendable, Equatable, CustomStringConvertible {
        public let message: String
        public init(_ message: String) { self.message = message }
        public var description: String { message }
    }

    /// `<name> · attempt 3`
    public static func name(base: String, index: Int) -> String {
        "\(base) · attempt \(index)"
    }

    /// `<branch>-a3`
    public static func branch(base: String, index: Int) -> String {
        "\(base)-a\(index)"
    }

    /// `<slug>-a3`
    public static func slug(base: String, index: Int) -> String {
        "\(base)-a\(index)"
    }

    /// The topic the N tasks are filed under: the brief's name, as a topic can spell it.
    public static func topic(for baseName: String) -> String? {
        TaskTopic.normalize(baseName)
    }

    /// The `-aN` an attempt's branch carries, taken off: `feat/x-a2` → `feat/x`. A branch without one is returned as is.
    public static func plainBranch(_ branch: String) -> String {
        guard let range = branch.range(of: #"-a[1-9][0-9]*$"#, options: .regularExpression) else { return branch }
        return String(branch[..<range.lowerBound])
    }

    /// What each of `count` attempts runs on, from the lists the caller gave: none means the default for every
    /// attempt, one value means that one for every attempt, `count` values means one each. Anything else is a
    /// mistake worth naming rather than guessing which attempt was meant to get what.
    public static func assign(_ values: [String], count: Int, what: String) -> Result<[String?], Refusal> {
        let cleaned = values.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        switch cleaned.count {
        case 0: return .success(Array(repeating: nil, count: count))
        case 1: return .success(Array(repeating: cleaned[0], count: count))
        case count: return .success(cleaned.map { Optional($0) })
        default:
            return .failure(Refusal("\(cleaned.count) \(what) for \(count) attempts: give one for all, or one per attempt"))
        }
    }

    /// One line of the plan per attempt, for a dry run and the answer: `attempt 2 · claude-opus-5-5 · feat/x-a2`.
    public struct Plan: Sendable, Equatable {
        public var index: Int
        public var name: String
        public var slug: String
        public var branch: String
        public var model: String?
        public var driver: String?
    }

    /// The N tasks a request turns into. `count` of 1 is not an attempt at all: the caller takes the plain path.
    public static func plan(count: Int, name: String, slug: String, branch: String,
                            models: [String], drivers: [String]) -> Result<[Plan], Refusal> {
        guard count >= 2 else { return .failure(Refusal("attempts must be 2 or more; without it, a task is one attempt")) }
        guard count <= maxCount else { return .failure(Refusal("at most \(maxCount) attempts; more would not compare")) }
        let eachModel: [String?]
        let eachDriver: [String?]
        switch assign(models, count: count, what: "models") {
        case .failure(let refusal): return .failure(refusal)
        case .success(let assigned): eachModel = assigned
        }
        switch assign(drivers, count: count, what: "drivers") {
        case .failure(let refusal): return .failure(refusal)
        case .success(let assigned): eachDriver = assigned
        }
        return .success((1...count).map { index in
            Plan(index: index, name: Self.name(base: name, index: index), slug: Self.slug(base: slug, index: index),
                 branch: Self.branch(base: branch, index: index), model: eachModel[index - 1], driver: eachDriver[index - 1])
        })
    }

    // MARK: Comparison

    /// One column of the Compare view, as pure values the app fills from its task, threads and token meter.
    public struct Column: Sendable, Equatable, Identifiable {
        public var id: String
        public var index: Int
        public var name: String
        public var branch: String
        public var model: String?
        public var driver: String?
        public var status: String
        public var tokens: Int?
        /// Seconds the agents of the task spent in turns.
        public var agentSeconds: TimeInterval
        public var filesChanged: Int
        public var additions: Int
        public var deletions: Int
        /// What the last reply says about tests, when it says anything (`testsRun`).
        public var tests: String?
        /// The opening of the deliverable: the last reply, or the report file.
        public var excerpt: String?
        public var isArchived: Bool

        public init(id: String, index: Int, name: String, branch: String, model: String? = nil, driver: String? = nil,
                    status: String, tokens: Int? = nil, agentSeconds: TimeInterval = 0, filesChanged: Int = 0,
                    additions: Int = 0, deletions: Int = 0, tests: String? = nil, excerpt: String? = nil,
                    isArchived: Bool = false) {
            self.id = id
            self.index = index
            self.name = name
            self.branch = branch
            self.model = model
            self.driver = driver
            self.status = status
            self.tokens = tokens
            self.agentSeconds = agentSeconds
            self.filesChanged = filesChanged
            self.additions = additions
            self.deletions = deletions
            self.tests = tests
            self.excerpt = excerpt
            self.isArchived = isArchived
        }

        /// `+12 −3`, or `no changes`.
        public var changes: String {
            additions == 0 && deletions == 0 ? "no changes" : "+\(additions) −\(deletions)"
        }
    }

    /// What an agent's last reply says about tests, best effort: the first line that counts tests, suites or
    /// passes, cut short. Agents word it a hundred ways; a line is worth more than a wrong number.
    public static func testsRun(in reply: String?, limit: Int = 72) -> String? {
        guard let reply else { return nil }
        let pattern = #"(?i)\b(\d+)\s+(tests?|specs?|suites?|passed|passing|failed|failing|examples?|assertions?)\b|\b(tests?|suites?)\s+(passed|pass|green|failed|fail)\b|\ball\s+(tests?|suites?)\s+(pass|passed|green)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        for raw in reply.components(separatedBy: .newlines) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            while let first = line.first, "#>*-_`|".contains(first) { line.removeFirst() }
            line = line.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
                .trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil else { continue }
            return line.count > limit ? String(line.prefix(limit - 1)) + "…" : line
        }
        return nil
    }

    /// The first `lines` non-blank lines of a deliverable, Markdown markers kept (a heading reads as one), blank
    /// lines dropped: the column has a few lines, not a page.
    public static func excerpt(_ text: String?, lines: Int = 6, limit: Int = 480) -> String? {
        guard let text else { return nil }
        var kept: [String] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            kept.append(line)
            if kept.count == lines { break }
        }
        let joined = kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !joined.isEmpty else { return nil }
        return joined.count > limit ? String(joined.prefix(limit - 1)) + "…" : joined
    }

    /// `3m 20s`, `47s`, `1h 05m`; `—` for nothing.
    public static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        guard total > 0 else { return "—" }
        if total < 60 { return "\(total)s" }
        if total < 3600 { return "\(total / 60)m \(String(format: "%02d", total % 60))s" }
        return "\(total / 3600)h \(String(format: "%02d", (total % 3600) / 60))m"
    }

    /// The two sides of the diff pane, and the keys that pick them: a digit for the left, ⇧digit for the right,
    /// `0` for the base on the right. Pure so the view only forwards keys.
    public struct Selection: Sendable, Equatable {
        /// Index of the attempt on the left, 1-based.
        public var left: Int
        /// Index of the attempt on the right, or `nil` for the base.
        public var right: Int?

        public init(left: Int, right: Int?) {
            self.left = left
            self.right = right
        }

        /// A sensible start: the first attempt against the base.
        public static let initial = Selection(left: 1, right: nil)

        /// The selection after key `digit` (0...9) with or without ⇧, among `count` attempts; `nil` when the
        /// key means nothing here (a digit past N).
        public func pressing(digit: Int, shift: Bool, count: Int) -> Selection? {
            if digit == 0 { return Selection(left: left, right: nil) }
            guard (1...count).contains(digit) else { return nil }
            return shift ? Selection(left: left, right: digit) : Selection(left: digit, right: right)
        }
    }
}
