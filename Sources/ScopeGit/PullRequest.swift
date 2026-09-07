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

    public var id: Int { number }

    public init(
        number: Int, title: String, author: String, headRefName: String, baseRefName: String,
        isDraft: Bool = false, reviewDecision: ReviewDecision = .none, checks: Checks = .none,
        updatedAt: Date = .now, url: URL, isCrossRepository: Bool = false, headOwner: String? = nil,
        mergeable: Mergeable = .unknown
    ) {
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
        "statusCheckRollup", "updatedAt", "url", "isCrossRepository", "headRepositoryOwner", "mergeable",
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
        var pending = false
        for check in checks {
            let state = (check.conclusion ?? check.state ?? check.status ?? "").uppercased()
            switch state {
            case "FAILURE", "ERROR", "CANCELLED", "TIMED_OUT", "ACTION_REQUIRED", "STARTUP_FAILURE":
                return .failing
            case "SUCCESS", "NEUTRAL", "SKIPPED", "STALE":
                continue
            case "", "PENDING", "EXPECTED", "QUEUED", "IN_PROGRESS", "WAITING", "REQUESTED":
                pending = true
            default:
                // A check that is not completed (no conclusion yet) is pending whatever the status literal.
                if check.conclusion == nil, check.state == nil { pending = true }
            }
        }
        return pending ? .pending : .passing
    }

    struct DTO: Decodable {
        struct Login: Decodable { var login: String }
        struct Check: Decodable {
            var status: String?
            var conclusion: String?
            var state: String?
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
            headOwner: dto.headRepositoryOwner?.login, mergeable: mergeable
        )
    }
}
