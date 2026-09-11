import Foundation

/// One open pull request as listed by `gh pr list --json …` (spec §4.4: "see and switch pull requests").
public struct PullRequest: Sendable, Equatable, Hashable, Identifiable {
    public enum ReviewDecision: String, Sendable, Equatable, Hashable {
        case approved, changesRequested, reviewRequired, none
    }

    /// The `statusCheckRollup` folded into one state: a failure beats a pending check, which beats success.
    public enum Checks: String, Sendable, Equatable, Hashable {
        case passing, failing, pending, none
    }

    public enum Mergeable: String, Sendable, Equatable, Hashable {
        case mergeable, conflicting, unknown
    }

    public enum State: String, Sendable, Equatable, Hashable {
        case open, merged, closed
    }

    public let state: State

    public let number: Int
    public let title: String
    /// GitHub login of the author (`app/dependabot` for bots).
    public let author: String
    public let headRefName: String
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
    /// Every check of the rollup, in the order `gh` listed them; `checks` is their fold.
    public let checkRuns: [PullRequestCheck]

    public var id: Int { number }

    public init(
        number: Int, title: String, author: String, headRefName: String, baseRefName: String,
        isDraft: Bool = false, reviewDecision: ReviewDecision = .none, checks: Checks = .none,
        updatedAt: Date = .now, url: URL, isCrossRepository: Bool = false, headOwner: String? = nil,
        mergeable: Mergeable = .unknown, checkRuns: [PullRequestCheck] = [], state: State = .open
    ) {
        self.checkRuns = checkRuns
        self.state = state
        self.number = number
        self.title = title
        self.author = author
        self.headRefName = headRefName
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
        "number", "title", "author", "headRefName", "baseRefName", "isDraft", "reviewDecision",
        "statusCheckRollup", "updatedAt", "url", "isCrossRepository", "headRepositoryOwner", "mergeable", "state",
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

    /// Folds the rollup entries (`CheckRun` with `status` / `conclusion`, `StatusContext` with `state`).
    static func summarize(checks: [DTO.Check]) -> Checks {
        guard !checks.isEmpty else { return .none }
        let states = checks.map(state(of:))
        if states.contains(.failing) { return .failing }
        return states.contains(.pending) ? .pending : .passing
    }

    static func state(of check: DTO.Check) -> PullRequestCheck.State {
        switch (check.conclusion ?? check.state ?? check.status ?? "").uppercased() {
        case "FAILURE", "ERROR", "CANCELLED", "TIMED_OUT", "ACTION_REQUIRED", "STARTUP_FAILURE":
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
        }
        var number: Int
        var title: String
        var author: Login?
        var headRefName: String
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
        self.init(
            number: dto.number, title: dto.title, author: dto.author?.login ?? "",
            headRefName: dto.headRefName, baseRefName: dto.baseRefName, isDraft: dto.isDraft ?? false,
            reviewDecision: decision, checks: Self.summarize(checks: dto.statusCheckRollup ?? []),
            updatedAt: dto.updatedAt ?? .distantPast, url: dto.url, isCrossRepository: dto.isCrossRepository ?? false,
            headOwner: dto.headRepositoryOwner?.login, mergeable: mergeable,
            checkRuns: (dto.statusCheckRollup ?? []).map { check in
                PullRequestCheck(
                    name: check.name ?? check.context ?? "check",
                    workflow: check.workflowName.flatMap { $0.isEmpty ? nil : $0 },
                    state: Self.state(of: check),
                    detailsURL: (check.detailsUrl ?? check.targetUrl).flatMap { $0.isEmpty ? nil : URL(string: $0) }
                )
            },
            state: State(rawValue: (dto.state ?? "").lowercased()) ?? .open
        )
    }

    /// `owner/name` of the repository a pull request URL points into (`https://github.com/owner/name/pull/12`),
    /// so `gh` can be told which repository to talk to whatever checkout it runs in.
    public static func repository(fromURL url: URL) -> String? {
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 4, parts[2] == "pull" else { return nil }
        return "\(parts[0])/\(parts[1])"
    }
}
