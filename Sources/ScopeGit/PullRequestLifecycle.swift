import Foundation

/// One check of a pull request, as the rollup lists it.
public struct PullRequestCheck: Sendable, Equatable, Hashable, Identifiable {
    public enum State: String, Sendable, Equatable, Hashable {
        case passing, failing, pending
        /// Neutral, skipped or stale: counts for nothing.
        case skipped
    }

    public let name: String
    /// The GitHub Actions workflow the job belongs to, for a check run of one.
    public let workflow: String?
    public let state: State
    /// Where the check's page is: an Actions job, or whatever a third-party status points at.
    public let detailsURL: URL?

    public init(name: String, workflow: String? = nil, state: State, detailsURL: URL? = nil) {
        self.name = name
        self.workflow = workflow
        self.state = state
        self.detailsURL = detailsURL
    }

    public var id: String { "\(workflow ?? "")/\(name)/\(detailsURL?.absoluteString ?? "")" }

    /// `workflow / name`, or the name alone.
    public var title: String { workflow.map { "\($0) / \(name)" } ?? name }

    /// The Actions run and job behind the check, `nil` for anything that is not a GitHub Actions job — a
    /// third-party status has no log `gh` can fetch.
    public var actionsJob: ActionsJob? { detailsURL.flatMap(ActionsJob.init(detailsURL:)) }
}

/// A GitHub Actions run, and one of its jobs when known.
public struct ActionsJob: Sendable, Equatable, Hashable {
    public var run: Int
    public var job: Int?

    public init(run: Int, job: Int? = nil) {
        self.run = run
        self.job = job
    }

    /// `https://github.com/<owner>/<repo>/actions/runs/<run>[/job/<job>]` (also `/jobs/`, and trailing query
    /// strings); `nil` for any other URL.
    public init?(detailsURL url: URL) {
        let parts = url.pathComponents.filter { $0 != "/" }
        guard let actions = parts.firstIndex(of: "actions"), actions + 2 < parts.count, parts[actions + 1] == "runs",
              let run = Int(parts[actions + 2]) else { return nil }
        self.run = run
        let jobIndex = actions + 3
        if jobIndex + 1 < parts.count, ["job", "jobs"].contains(parts[jobIndex]), let job = Int(parts[jobIndex + 1]) {
            self.job = job
        } else {
            self.job = nil
        }
    }
}

/// How `gh pr merge` merges.
public enum MergeMethod: String, Sendable, Equatable, CaseIterable {
    case merge, squash, rebase

    /// The method to use given what the repository allows: the order GitHub's own merge button offers them.
    public static func preferred(mergeCommit: Bool, squash: Bool, rebase: Bool) -> MergeMethod? {
        if mergeCommit { return .merge }
        if squash { return .squash }
        if rebase { return .rebase }
        return nil
    }
}

/// What a task's thread is told about its pull request: pure text, so what an agent reads is under test.
public enum PullRequestPrompts {
    /// Lines of a failed log sent to the thread. The failure is almost always at the end; the rest costs tokens.
    public static let logLines = 150
    public static let logCharacters = 12_000

    /// The end of a `gh run view --log-failed` output, each line stripped of its `job<TAB>step<TAB>timestamp`
    /// prefix, bounded in lines and characters.
    public static func logTail(_ log: String, lines: Int = logLines, characters: Int = logCharacters) -> String {
        var body = Substring(log)
        // Trailing newlines would count as lines and push real ones out of the budget.
        while body.hasSuffix("\n") { body = body.dropLast() }
        let cleaned = body.split(separator: "\n", omittingEmptySubsequences: false).map { cleanLine(String($0)) }
        var tail = cleaned.suffix(lines).joined(separator: "\n")
        if tail.count > characters { tail = String(tail.suffix(characters)) }
        return tail
    }

    static func cleanLine(_ line: String) -> String {
        let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
        guard fields.count == 3 else { return line }
        let rest = fields[2]
        // `2026-09-11T08:12:03.1234567Z message`
        if let space = rest.firstIndex(of: " "), rest[..<space].contains("T"), rest[..<space].hasSuffix("Z") {
            return String(rest[rest.index(after: space)...])
        }
        return String(rest)
    }

    public static func checkFailed(_ check: PullRequestCheck, pullRequest number: Int, log: String?) -> String {
        var text = "The check “\(check.title)” failed on pull request #\(number)."
        if let log, !log.isEmpty {
            text += " Here is the end of its log:\n\n```\n\(logTail(log))\n```\n\n"
        } else {
            text += " Its log could not be fetched\(check.detailsURL.map { "; it is at \($0.absoluteString)" } ?? "").\n\n"
        }
        text += "Find the cause, fix it, run the relevant tests locally, then commit and push."
        return text
    }

    public static func fixConflicts(pullRequest number: Int, base: String, branch: String) -> String {
        """
        Pull request #\(number) has conflicts with \(base). Bring \(base) into \(branch): run \
        `git fetch origin` then `git merge origin/\(base)`, resolve every conflict, run the tests, then commit \
        the merge and push \(branch). Do not rebase and do not force-push.
        """
    }
}
