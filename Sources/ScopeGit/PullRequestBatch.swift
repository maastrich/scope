import Foundation
import ScopeCore

/// A repository on github.com, as GraphQL names it.
public struct GitHubRepository: Sendable, Hashable, CustomStringConvertible {
    public let owner: String
    public let name: String

    public init(owner: String, name: String) {
        self.owner = owner
        self.name = name
    }

    public var description: String { "\(owner)/\(name)" }

    /// GitHub names are case-insensitive: `Acme/API` and `acme/api` are one repository, asked about once.
    public static func == (lhs: GitHubRepository, rhs: GitHubRepository) -> Bool {
        lhs.owner.lowercased() == rhs.owner.lowercased() && lhs.name.lowercased() == rhs.name.lowercased()
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(owner.lowercased())
        hasher.combine(name.lowercased())
    }

    /// The repository `gh pr list` would ask in a checkout, from its remotes (`git config --get-regexp
    /// '^remote\..*\.(url|gh-resolved)$'`): the one `gh repo set-default` chose, else the first of `upstream`,
    /// `github`, `origin`, then the others — the order `gh` sorts remotes in.
    ///
    /// `nil` when that remote is not on github.com (GitHub Enterprise, an ssh alias, a local path): only `gh` knows
    /// how to reach those, so the caller keeps asking it branch by branch.
    public static func resolve(remoteConfig: String) -> GitHubRepository? {
        var urls: [(remote: String, url: String)] = []
        var resolved: (remote: String, value: String)?
        for line in remoteConfig.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2, parts[0].hasPrefix("remote.") else { continue }
            let key = parts[0].dropFirst("remote.".count)
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            if key.hasSuffix(".gh-resolved") {
                if resolved == nil { resolved = (String(key.dropLast(".gh-resolved".count)), value) }
            } else if key.hasSuffix(".url") {
                urls.append((String(key.dropLast(".url".count)), value))
            }
        }
        if let resolved {
            // `base`: this remote is the one. Otherwise the value names the repository itself (`owner/name`).
            if resolved.value == "base" {
                return urls.first { $0.remote == resolved.remote }.flatMap { repository(remote: $0.url) }
            }
            let parts = resolved.value.split(separator: "/").map(String.init)
            return parts.count == 2 ? GitHubRepository(owner: parts[0], name: parts[1]) : nil
        }
        func rank(_ remote: String) -> Int {
            switch remote {
            case "upstream": 0
            case "github": 1
            case "origin": 2
            default: 3
            }
        }
        let first = urls.enumerated().min { lhs, rhs in
            (rank(lhs.element.remote), lhs.offset) < (rank(rhs.element.remote), rhs.offset)
        }
        return first.flatMap { repository(remote: $0.element.url) }
    }

    static func repository(remote url: String) -> GitHubRepository? {
        guard let info = RemoteInfo(remote: url), let owner = info.owner,
              let host = info.host?.lowercased(), host == "github.com" || host == "ssh.github.com" else { return nil }
        return GitHubRepository(owner: owner, name: info.name)
    }
}

/// Every branch lookup of a refresh pass as one GraphQL query: an alias per repository, an alias per branch inside
/// it, each answering what `gh pr list --state all --head <branch>` answers — one `gh` process and one request for
/// the whole fleet instead of one per (sandbox, branch).
public enum PullRequestBatch {
    /// One question: the pull requests of `repository` whose head is `branch`.
    public struct Lookup: Sendable, Hashable {
        public let repository: GitHubRepository
        public let branch: String

        public init(repository: GitHubRepository, branch: String) {
            self.repository = repository
            self.branch = branch
        }
    }

    /// What one lookup came to. A failure here is about that repository alone: the query as a whole answered.
    public enum Outcome: Sendable, Equatable {
        case found([PullRequest])
        case failed(GhFailure)
    }

    public struct Answer: Sendable, Equatable {
        public var outcomes: [Lookup: Outcome] = [:]

        public init(outcomes: [Lookup: Outcome] = [:]) {
            self.outcomes = outcomes
        }

        public subscript(lookup: Lookup) -> Outcome? { outcomes[lookup] }
    }

    /// Pull requests asked per branch, as `GhClient.prsForBranch` does.
    public static let perBranch = 10
    /// Lookups per query; more go out as a second one. GitHub bounds a query by its nodes, and a rollup is up to a
    /// hundred of them per pull request.
    public static let maximumLookups = 50

    /// `lookups` without repeats, in order, cut into queries.
    public static func chunks(_ lookups: [Lookup], size: Int = maximumLookups) -> [[Lookup]] {
        var seen = Set<Lookup>()
        let unique = lookups.filter { seen.insert($0).inserted }
        return stride(from: 0, to: unique.count, by: max(1, size)).map { Array(unique[$0..<min($0 + max(1, size), unique.count)]) }
    }

    /// Repositories in order of first appearance (`r0`, `r1` …), each with its branches (`b0`, `b1` …): the query is
    /// built from this and the answer read back through it.
    static func aliases(for lookups: [Lookup]) -> [(alias: String, repository: GitHubRepository, branches: [(alias: String, lookup: Lookup)])] {
        var order: [GitHubRepository] = []
        var branches: [GitHubRepository: [Lookup]] = [:]
        for lookup in lookups {
            if branches[lookup.repository] == nil { order.append(lookup.repository) }
            if branches[lookup.repository]?.contains(lookup) != true { branches[lookup.repository, default: []].append(lookup) }
        }
        return order.enumerated().map { index, repository in
            ("r\(index)", repository, (branches[repository] ?? []).enumerated().map { ("b\($0.offset)", $0.element) })
        }
    }

    /// The query for `lookups`. Names go in as string literals, escaped: a branch may hold a quote.
    public static func query(for lookups: [Lookup]) -> String {
        var text = "query {\n"
        for entry in aliases(for: lookups) {
            text += "  \(entry.alias): repository(owner: \(literal(entry.repository.owner)), name: \(literal(entry.repository.name))) {\n"
            for branch in entry.branches {
                text += "    \(branch.alias): pullRequests(headRefName: \(literal(branch.lookup.branch)), first: \(perBranch), "
                    + "states: [OPEN, MERGED, CLOSED], orderBy: {field: CREATED_AT, direction: DESC}) { nodes { ...pr } }\n"
            }
            text += "  }\n"
        }
        return text + "}\n" + fragment
    }

    /// The fields of `PullRequest.jsonFields`, as `gh` itself asks for them: its `statusCheckRollup` is the rollup of
    /// the last commit, and a `StatusContext` has no start but its creation.
    static let fragment = """
    fragment pr on PullRequest {
      number title author { __typename login } headRefName headRefOid baseRefName isDraft reviewDecision updatedAt url
      isCrossRepository headRepositoryOwner { login } mergeable state createdAt mergedAt closedAt additions deletions
      statusCheckRollup: commits(last: 1) { nodes { commit { statusCheckRollup { contexts(first: 100) { nodes {
        __typename
        ... on CheckRun { name status conclusion detailsUrl startedAt checkSuite { workflowRun { workflow { name } } } }
        ... on StatusContext { context state targetUrl createdAt }
      } } } } } }
    }
    """

    /// A GraphQL string literal, which escapes as JSON does.
    static func literal(_ value: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Parsing

    /// Reads the answer to `query(for: lookups)`. `gh api graphql` prints it even when it exits 1 because one
    /// repository could not be resolved: `data` then holds the others, and that one's lookups fail on their own.
    ///
    /// Throws when there is no `data` at all (a rate limit, an outage): `GhError.failed` with GitHub's messages,
    /// which `GhFailure.classify` reads.
    public static func parse(json: Data, lookups: [Lookup]) throws -> Answer {
        let response = try decoder.decode(Response.self, from: json)
        let errors = response.errors ?? []
        guard let data = response.data else {
            let message = errors.compactMap(\.message).joined(separator: "\n")
            throw GhError.failed(command: command, message: message.isEmpty ? "no data in the answer" : message)
        }
        // A rate limit can come with partial data; nothing in it is worth more than backing off.
        if let limited = errors.first(where: { ($0.type ?? "").uppercased() == "RATE_LIMITED" }) {
            throw GhError.failed(command: command, message: limited.message ?? "rate limit exceeded")
        }
        var answer = Answer()
        for entry in aliases(for: lookups) {
            let repository = data[entry.alias] ?? nil
            for branch in entry.branches {
                if let connection = repository?[branch.alias] ?? nil {
                    let found = (connection.nodes ?? []).compactMap { $0 }.map { PullRequest(dto: $0.dto) }
                    answer.outcomes[branch.lookup] = .found(found.sorted { $0.number > $1.number })
                } else {
                    let error = errors.first { $0.path?.first == entry.alias && ($0.path?.count == 1 || $0.path?.dropFirst().first == branch.alias) }
                        ?? errors.first { $0.path?.first == entry.alias }
                    answer.outcomes[branch.lookup] = .failed(cause(of: error))
                }
            }
        }
        return answer
    }

    static let command = "gh api graphql"

    /// Why one repository of an answered query has no data. Never a global cause: the other repositories answered,
    /// so whatever is wrong (a repository gone, an organisation asking for SAML) is wrong with this one.
    static func cause(of error: GraphQLError?) -> GhFailure {
        guard let error else { return .other }
        if (error.type ?? "").uppercased() == "NOT_FOUND" { return .notFound }
        let cause = GhFailure.classify(message: error.message ?? "") ?? .other
        return cause.isGlobal ? .other : cause
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    struct Response: Decodable {
        var data: [String: [String: Connection?]?]?
        var errors: [GraphQLError]?
    }

    struct GraphQLError: Decodable {
        var type: String?
        var message: String?
        var path: [String]?

        private enum CodingKeys: String, CodingKey { case type, message, path }

        init(type: String? = nil, message: String? = nil, path: [String]? = nil) {
            self.type = type
            self.message = message
            self.path = path
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            type = try? container.decodeIfPresent(String.self, forKey: .type)
            message = try? container.decodeIfPresent(String.self, forKey: .message)
            // A path may hold list indexes; only the aliases at its head are read.
            path = (try? container.decodeIfPresent([PathPart].self, forKey: .path))?.map(\.text)
        }

        private struct PathPart: Decodable {
            var text: String
            init(from decoder: any Decoder) throws {
                let container = try decoder.singleValueContainer()
                text = (try? container.decode(String.self)) ?? (try? container.decode(Int.self)).map(String.init) ?? ""
            }
        }
    }

    struct Connection: Decodable {
        var nodes: [Node?]?
    }

    /// One pull request as GraphQL shapes it; `dto` is the same thing as `gh pr list --json` prints it.
    struct Node: Decodable {
        struct Actor: Decodable {
            var __typename: String?
            var login: String
        }
        struct Commits: Decodable {
            struct Entry: Decodable { var commit: Commit? }
            struct Commit: Decodable { var statusCheckRollup: Rollup? }
            struct Rollup: Decodable { var contexts: Contexts? }
            struct Contexts: Decodable { var nodes: [Context?]? }
            var nodes: [Entry?]?
        }
        struct Context: Decodable {
            struct Suite: Decodable { var workflowRun: Run? }
            struct Run: Decodable { var workflow: Workflow? }
            struct Workflow: Decodable { var name: String? }
            var __typename: String?
            var name: String?
            var status: String?
            var conclusion: String?
            var detailsUrl: String?
            var startedAt: Date?
            var checkSuite: Suite?
            var context: String?
            var state: String?
            var targetUrl: String?
            var createdAt: Date?
        }
        var number: Int
        var title: String
        var author: Actor?
        var headRefName: String
        var headRefOid: String?
        var baseRefName: String
        var isDraft: Bool?
        var reviewDecision: String?
        var updatedAt: Date?
        var url: URL
        var isCrossRepository: Bool?
        var headRepositoryOwner: Actor?
        var mergeable: String?
        var state: String?
        var createdAt: Date?
        var mergedAt: Date?
        var closedAt: Date?
        var additions: Int?
        var deletions: Int?
        var statusCheckRollup: Commits?

        var dto: PullRequest.DTO {
            let contexts = statusCheckRollup?.nodes?.compactMap { $0 }.first?.commit?.statusCheckRollup?.contexts?.nodes ?? []
            let checks = contexts.compactMap { $0 }.map { context in
                PullRequest.DTO.Check(
                    status: context.status, conclusion: context.conclusion, state: context.state, name: context.name,
                    context: context.context, workflowName: context.checkSuite?.workflowRun?.workflow?.name,
                    detailsUrl: context.detailsUrl, targetUrl: context.targetUrl,
                    startedAt: context.startedAt ?? context.createdAt)
            }
            // `gh` prints a bot's login as `app/<login>`.
            let login = author.map { $0.__typename == "Bot" ? "app/\($0.login)" : $0.login }
            return PullRequest.DTO(
                number: number, title: title, author: login.map(PullRequest.DTO.Login.init(login:)),
                headRefName: headRefName, headRefOid: headRefOid, baseRefName: baseRefName, isDraft: isDraft,
                reviewDecision: reviewDecision, statusCheckRollup: checks, updatedAt: updatedAt, url: url,
                isCrossRepository: isCrossRepository,
                headRepositoryOwner: headRepositoryOwner.map { PullRequest.DTO.Login(login: $0.login) },
                mergeable: mergeable, state: state, createdAt: createdAt, mergedAt: mergedAt, closedAt: closedAt,
                additions: additions, deletions: deletions)
        }
    }
}

public extension GitClient {
    /// `GitHubRepository.resolve` on the remotes of this repository, read `at` a worktree of it.
    func gitHubRepository(at worktree: URL? = nil) async -> GitHubRepository? {
        var arguments: [String] = []
        if let worktree { arguments += ["-C", worktree.filesystemPath] }
        arguments += ["config", "--get-regexp", #"^remote\..*\.(url|gh-resolved)$"#]
        guard let result = try? await run(arguments, timeout: .seconds(10), allowFailure: true), result.succeeded else { return nil }
        return GitHubRepository.resolve(remoteConfig: result.stdoutText)
    }

    /// Where the remotes have `branches`, as the last push or fetch left them: `refs/remotes/<remote>/<branch> <sha>`
    /// lines, sorted. It changes when one of them is pushed, which is what makes a task whose pull requests are all
    /// merged or closed worth asking GitHub about again.
    func remoteHeads(at worktree: URL? = nil, branches: [String]) async -> String {
        guard !branches.isEmpty else { return "" }
        var arguments: [String] = []
        if let worktree { arguments += ["-C", worktree.filesystemPath] }
        arguments += ["for-each-ref", "--format=%(refname) %(objectname)"] + branches.map { "refs/remotes/*/\($0)" }
        guard let result = try? await run(arguments, timeout: .seconds(10), allowFailure: true), result.succeeded else { return "" }
        return result.stdoutText.split(whereSeparator: \.isNewline).map(String.init).sorted().joined(separator: "\n")
    }
}
