import Foundation

/// One open pull request as listed by `gh pr list --json …` (spec §4.4: "see and switch pull requests").
public struct PullRequest: Sendable, Equatable, Hashable, Identifiable {
    public enum ReviewDecision: String, Sendable, Equatable, Hashable {
        case approved, changesRequested, reviewRequired, none
    }

    /// The `statusCheckRollup` folded into one state, once the runs replaced by newer ones are set aside
    /// (`CheckResolution`): a failure beats a pending check, which beats a cancellation, which beats success.
    public enum Checks: String, Codable, Sendable, Equatable, Hashable {
        case passing, failing, pending, none
        /// Nothing failed nor runs, but a check was cancelled without a newer run taking its place: not green.
        case cancelled
    }

    public enum Mergeable: String, Sendable, Equatable, Hashable {
        case mergeable, conflicting, unknown
    }

    public enum State: String, Codable, Sendable, Equatable, Hashable {
        case open, merged, closed
    }

    public let state: State

    public let number: Int
    public let title: String
    /// GitHub login of the author (`app/dependabot` for bots).
    public let author: String
    public let headRefName: String
    /// The commit at the head of the pull request, as GitHub last saw it: once merged, what the merge took.
    public let headRefOid: String?
    public let baseRefName: String
    public let isDraft: Bool
    public let reviewDecision: ReviewDecision
    public let checks: Checks
    public let updatedAt: Date
    public let url: URL
    /// The head lives in a fork: the branch is not on `origin`, only `pull/<n>/head` is.
    public let isCrossRepository: Bool
    /// Login of the owner of the head repository (the fork owner for a cross-repository PR).
    public let headOwner: String?
    public let mergeable: Mergeable
    /// Every check of the rollup, in the order `gh` listed them, without the cancelled ones a newer run of the same
    /// job replaced; `checks` is their fold.
    public let checkRuns: [PullRequestCheck]
    /// When it was opened, merged and closed, as GitHub dates them: what a task's timeline marks.
    public let createdAt: Date?
    public let mergedAt: Date?
    public let closedAt: Date?
    /// Lines added and removed over the whole pull request, as GitHub counts them; absent from an older reading.
    public let additions: Int?
    public let deletions: Int?

    public var id: Int { number }

    public init(
        number: Int, title: String, author: String, headRefName: String, baseRefName: String,
        isDraft: Bool = false, reviewDecision: ReviewDecision = .none, checks: Checks = .none,
        updatedAt: Date = .now, url: URL, isCrossRepository: Bool = false, headOwner: String? = nil,
        mergeable: Mergeable = .unknown, checkRuns: [PullRequestCheck] = [], state: State = .open,
        createdAt: Date? = nil, mergedAt: Date? = nil, closedAt: Date? = nil,
        additions: Int? = nil, deletions: Int? = nil, headRefOid: String? = nil
    ) {
        self.additions = additions
        self.deletions = deletions
        self.checkRuns = checkRuns
        self.createdAt = createdAt
        self.mergedAt = mergedAt
        self.closedAt = closedAt
        self.state = state
        self.number = number
        self.title = title
        self.author = author
        self.headRefName = headRefName
        self.headRefOid = headRefOid
        self.baseRefName = baseRefName
        self.isDraft = isDraft
        self.reviewDecision = reviewDecision
        self.checks = checks
        self.updatedAt = updatedAt
        self.url = url
        self.isCrossRepository = isCrossRepository
        self.headOwner = headOwner
        self.mergeable = mergeable
    }

    /// The fields requested from `gh`.
    public static let jsonFields = [
        "number", "title", "author", "headRefName", "headRefOid", "baseRefName", "isDraft", "reviewDecision",
        "statusCheckRollup", "updatedAt", "url", "isCrossRepository", "headRepositoryOwner", "mergeable", "state",
        "createdAt", "mergedAt", "closedAt", "additions", "deletions",
    ].joined(separator: ",")

    // MARK: Parsing

    /// Parses the output of `gh pr list --json …` (an array).
    public static func parse(json: Data) throws -> [PullRequest] {
        try decoder.decode([DTO].self, from: json).map(PullRequest.init(dto:))
    }

    /// Parses the output of `gh pr view --json …` (a single object).
    public static func parseOne(json: Data) throws -> PullRequest {
        PullRequest(dto: try decoder.decode(DTO.self, from: json))
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// The pull request with its cancelled checks GitHub says were cancelled for a newer run (`supersededJobs`, job
    /// ids) read as pending: what one question per cancelled job adds to the rollup (`CheckResolution`).
    public func following(supersededJobs: Set<Int>) -> PullRequest {
        let runs = CheckResolution.following(checkRuns, supersededJobs: supersededJobs)
        guard runs != checkRuns else { return self }
        return PullRequest(
            number: number, title: title, author: author, headRefName: headRefName, baseRefName: baseRefName,
            isDraft: isDraft, reviewDecision: reviewDecision, checks: CheckResolution.summarize(runs.map(\.state)),
            updatedAt: updatedAt, url: url, isCrossRepository: isCrossRepository, headOwner: headOwner,
            mergeable: mergeable, checkRuns: runs, state: state, createdAt: createdAt, mergedAt: mergedAt,
            closedAt: closedAt, additions: additions, deletions: deletions, headRefOid: headRefOid
        )
    }

    /// Folds the rollup entries (`CheckRun` with `status` / `conclusion`, `StatusContext` with `state`), the
    /// cancelled ones a newer run replaced set aside.
    static func summarize(checks: [DTO.Check]) -> Checks {
        CheckResolution.summarize(CheckResolution.resolve(checks.map { check(of: $0) }).map(\.state))
    }

    static func state(of check: DTO.Check) -> PullRequestCheck.State {
        switch (check.conclusion ?? check.state ?? check.status ?? "").uppercased() {
        case "CANCELLED":
            return .cancelled
        case "FAILURE", "ERROR", "TIMED_OUT", "ACTION_REQUIRED", "STARTUP_FAILURE":
            return .failing
        case "SUCCESS":
            return .passing
        case "NEUTRAL", "SKIPPED", "STALE":
            return .skipped
        case "", "PENDING", "EXPECTED", "QUEUED", "IN_PROGRESS", "WAITING", "REQUESTED":
            return .pending
        default:
            // A check that is not completed (no conclusion yet) is pending whatever the status literal.
            return check.conclusion == nil && check.state == nil ? .pending : .passing
        }
    }

    struct DTO: Decodable {
        struct Login: Decodable { var login: String }
        /// A `CheckRun` (name, workflowName, detailsUrl, status, conclusion) or a `StatusContext` (context,
        /// targetUrl, state) of the rollup.
        struct Check: Decodable {
            var status: String?
            var conclusion: String?
            var state: String?
            var name: String?
            var context: String?
            var workflowName: String?
            var detailsUrl: String?
            var targetUrl: String?
            var startedAt: Date?
        }
        var number: Int
        var title: String
        var author: Login?
        var headRefName: String
        var headRefOid: String?
        var baseRefName: String
        var isDraft: Bool?
        var reviewDecision: String?
        var statusCheckRollup: [Check]?
        var updatedAt: Date?
        var url: URL
        var isCrossRepository: Bool?
        var headRepositoryOwner: Login?
        var mergeable: String?
        var state: String?
        var createdAt: Date?
        var mergedAt: Date?
        var closedAt: Date?
        var additions: Int?
        var deletions: Int?
    }

    init(dto: DTO) {
        let decision: ReviewDecision = switch (dto.reviewDecision ?? "").uppercased() {
        case "APPROVED": .approved
        case "CHANGES_REQUESTED": .changesRequested
        case "REVIEW_REQUIRED": .reviewRequired
        default: .none
        }
        let mergeable: Mergeable = switch (dto.mergeable ?? "").uppercased() {
        case "MERGEABLE": .mergeable
        case "CONFLICTING": .conflicting
        default: .unknown
        }
        let runs = CheckResolution.resolve((dto.statusCheckRollup ?? []).map { check in
            Self.check(of: check, number: dto.number, pullRequestURL: dto.url)
        })
        self.init(
            number: dto.number, title: dto.title, author: dto.author?.login ?? "",
            headRefName: dto.headRefName, baseRefName: dto.baseRefName, isDraft: dto.isDraft ?? false,
            reviewDecision: decision, checks: CheckResolution.summarize(runs.map(\.state)),
            updatedAt: dto.updatedAt ?? .distantPast, url: dto.url, isCrossRepository: dto.isCrossRepository ?? false,
            headOwner: dto.headRepositoryOwner?.login, mergeable: mergeable,
            checkRuns: runs,
            state: State(rawValue: (dto.state ?? "").lowercased()) ?? .open,
            createdAt: Self.real(dto.createdAt), mergedAt: Self.real(dto.mergedAt), closedAt: Self.real(dto.closedAt),
            additions: dto.additions, deletions: dto.deletions,
            headRefOid: dto.headRefOid.flatMap { $0.isEmpty ? nil : $0 }
        )
    }

    /// One rollup entry as a check, its Actions job link tagged with the pull request (`pullRequestLink`) when known.
    static func check(of check: DTO.Check, number: Int? = nil, pullRequestURL: URL? = nil) -> PullRequestCheck {
        let url = (check.detailsUrl ?? check.targetUrl).flatMap { $0.isEmpty ? nil : URL(string: $0) }
        return PullRequestCheck(
            name: check.name ?? check.context ?? "check",
            workflow: check.workflowName.flatMap { $0.isEmpty ? nil : $0 },
            state: state(of: check),
            detailsURL: url.map { url in
                guard let number, let pullRequestURL else { return url }
                return ActionsJob.pullRequestLink(url, number: number, pullRequestURL: pullRequestURL)
            },
            startedAt: real(check.startedAt)
        )
    }

    /// GraphQL answers a date that never happened with `null`, but some `gh` builds print the zero time instead.
    static func real(_ date: Date?) -> Date? {
        guard let date, date > Date(timeIntervalSince1970: 0) else { return nil }
        return date
    }

    /// `owner/name` of the repository a pull request URL points into (`https://github.com/owner/name/pull/12`),
    /// so `gh` can be told which repository to talk to whatever checkout it runs in.
    public static func repository(fromURL url: URL) -> String? {
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 4, parts[2] == "pull" else { return nil }
        return "\(parts[0])/\(parts[1])"
    }
}
