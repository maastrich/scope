import Foundation
import Testing
import ScopeCore
@testable import ScopeGit

@Suite struct PullRequestBatchTests {
    private static let cli = GitHubRepository(owner: "cli", name: "cli")
    private static let gone = GitHubRepository(owner: "cli", name: "no-such-repo-xyz")
    /// The lookups the fixtures were recorded with.
    private static let lookups = [
        PullRequestBatch.Lookup(repository: cli, branch: PullRequestBatchFixtures.branch),
        PullRequestBatch.Lookup(repository: cli, branch: "no-such-branch-xyz"),
        PullRequestBatch.Lookup(repository: gone, branch: "main"),
    ]

    @Test func oneAliasPerRepositoryAndPerBranch() {
        let query = PullRequestBatch.query(for: Self.lookups)
        let connection = "first: 10, states: [OPEN, MERGED, CLOSED], orderBy: {field: CREATED_AT, direction: DESC}) { nodes { ...pr } }"
        let expected = """
        query {
          r0: repository(owner: "cli", name: "cli") {
            b0: pullRequests(headRefName: "\(PullRequestBatchFixtures.branch)", \(connection)
            b1: pullRequests(headRefName: "no-such-branch-xyz", \(connection)
          }
          r1: repository(owner: "cli", name: "no-such-repo-xyz") {
            b0: pullRequests(headRefName: "main", \(connection)
          }
        }

        """ + PullRequestBatch.fragment
        #expect(query == expected)
    }

    @Test func theFragmentAsksForEveryFieldGhPrListDoes() {
        // `statusCheckRollup` and the two logins are objects in GraphQL; the rest goes by the same name.
        for field in PullRequest.jsonFields.split(separator: ",") {
            #expect(PullRequestBatch.fragment.contains(String(field)), "\(field) is not asked for")
        }
    }

    @Test func namesAreEscapedAndRepeatsAskedOnce() {
        let odd = PullRequestBatch.Lookup(repository: Self.cli, branch: #"feat/"quoted""#)
        let sameRepository = PullRequestBatch.Lookup(repository: GitHubRepository(owner: "CLI", name: "Cli"), branch: "main")
        let query = PullRequestBatch.query(for: [odd, sameRepository, odd])
        #expect(query.contains(#"headRefName: "feat/\"quoted\"""#))
        #expect(query.contains("b1: ") && !query.contains("b2: ") && !query.contains("r1: "))
        #expect(PullRequestBatch.chunks([odd, sameRepository, odd]).map(\.count) == [2])
        #expect(PullRequestBatch.chunks(Self.lookups, size: 2).map(\.count) == [2, 1])
        #expect(PullRequestBatch.chunks([]).isEmpty)
    }

    @Test func aRecordedAnswerReadsLikeGhPrList() throws {
        let answer = try PullRequestBatch.parse(json: Data(PullRequestBatchFixtures.answer.utf8), lookups: Self.lookups)
        let listed = try PullRequest.parse(json: Data(PullRequestBatchFixtures.list.utf8))
        #expect(listed.count == 1)
        // Field for field what `gh pr list --head` printed: the bot's login, the rollup, the dates.
        #expect(answer[Self.lookups[0]] == .found(listed))
        guard case .found(let prs) = answer[Self.lookups[0]], let pr = prs.first else { Issue.record("nothing found"); return }
        #expect(pr.author == "app/dependabot" && pr.state == .merged && pr.reviewDecision == .approved)
        #expect(pr.checkRuns.count == 3 && pr.checks == .passing && pr.checkRuns.last?.workflow == "Lint")
        #expect(pr.mergedAt != nil && pr.headRefOid?.count == 40)
    }

    @Test func aBranchWithoutPullRequestIsAnAnswerAndAMissingRepositoryFailsAlone() throws {
        let answer = try PullRequestBatch.parse(json: Data(PullRequestBatchFixtures.answer.utf8), lookups: Self.lookups)
        #expect(answer[Self.lookups[1]] == .found([]))
        #expect(answer[Self.lookups[2]] == .failed(.notFound))
        #expect(answer.outcomes.count == 3)
        // What `gh` said of it on stderr reads the same way.
        #expect(GhFailure.classify(exitCode: 1, stderr: PullRequestBatchFixtures.stderr) == .notFound)
    }

    @Test func anAnswerWithoutDataThrowsWhatGitHubSaid() {
        #expect(throws: GhError.self) {
            try PullRequestBatch.parse(json: Data(PullRequestBatchFixtures.refused.utf8), lookups: Self.lookups)
        }
        let limited = #"{"errors":[{"type":"RATE_LIMITED","message":"API rate limit exceeded for user ID 1."}]}"#
        do {
            _ = try PullRequestBatch.parse(json: Data(limited.utf8), lookups: Self.lookups)
            Issue.record("a rate limit is not an answer")
        } catch {
            #expect(GhFailure.classify(error: error) == .rateLimit)
        }
        // Partial data does not make a rate limit less of one.
        let partial = #"{"data":{"r0":null,"r1":null},"errors":[{"type":"RATE_LIMITED","path":["r0"],"message":"API rate limit exceeded"}]}"#
        #expect(throws: GhError.self) { try PullRequestBatch.parse(json: Data(partial.utf8), lookups: Self.lookups) }
        #expect(throws: (any Error).self) { try PullRequestBatch.parse(json: Data("{".utf8), lookups: Self.lookups) }
    }

    @Test func aRepositoryErrorNeverReadsAsAnOutage() {
        typealias GraphQLError = PullRequestBatch.GraphQLError
        #expect(PullRequestBatch.cause(of: GraphQLError(type: "NOT_FOUND", message: "Could not resolve to a Repository")) == .notFound)
        // An organisation asking for SAML is wrong with that repository: the others answered.
        #expect(PullRequestBatch.cause(of: GraphQLError(type: "FORBIDDEN", message: "Resource protected by organization SAML enforcement.")) == .other)
        #expect(PullRequestBatch.cause(of: nil) == .other)
    }

    /// Not recorded: a commit status (`StatusContext`) beside a check run, and a pull request without any rollup.
    @Test func statusContextsAndMissingRollups() throws {
        let json = #"""
        {"data":{"r0":{"b0":{"nodes":[
          {"number":7,"title":"With a status","author":{"__typename":"User","login":"alice"},"headRefName":"feat/x","headRefOid":"6f1c2d3e4b5a69788796a5b4c3d2e1f001122334",
           "baseRefName":"main","isDraft":false,"reviewDecision":null,"updatedAt":"2026-09-02T10:00:00Z","url":"https://github.com/acme/api/pull/7",
           "isCrossRepository":true,"headRepositoryOwner":{"login":"alice"},"mergeable":"CONFLICTING","state":"OPEN","createdAt":"2026-09-01T10:00:00Z",
           "mergedAt":null,"closedAt":null,"additions":4,"deletions":2,
           "statusCheckRollup":{"nodes":[{"commit":{"statusCheckRollup":{"contexts":{"nodes":[
             {"__typename":"CheckRun","name":"build","status":"IN_PROGRESS","conclusion":null,"detailsUrl":"https://github.com/acme/api/actions/runs/1/job/2","startedAt":"2026-09-02T09:00:00Z","checkSuite":{"workflowRun":null}},
             {"__typename":"StatusContext","context":"ci/deploy","state":"FAILURE","targetUrl":"https://deploy.example/1","createdAt":"2026-09-02T09:30:00Z"}
           ]}}}}]}},
          {"number":6,"title":"No checks","author":null,"headRefName":"feat/x","headRefOid":"","baseRefName":"main","url":"https://github.com/acme/api/pull/6",
           "state":"CLOSED","statusCheckRollup":{"nodes":[{"commit":{"statusCheckRollup":null}}]}}
        ]}}}}
        """#
        let lookup = PullRequestBatch.Lookup(repository: GitHubRepository(owner: "acme", name: "api"), branch: "feat/x")
        let answer = try PullRequestBatch.parse(json: Data(json.utf8), lookups: [lookup])
        guard case .found(let prs) = answer[lookup] else { Issue.record("nothing found"); return }
        #expect(prs.map(\.number) == [7, 6])
        #expect(prs[0].checks == .failing && prs[0].checkRuns.map(\.name) == ["build", "ci/deploy"])
        #expect(prs[0].checkRuns[1].startedAt == ISO8601DateFormatter().date(from: "2026-09-02T09:30:00Z"))
        #expect(prs[0].isCrossRepository && prs[0].headOwner == "alice" && prs[0].mergeable == .conflicting && prs[0].mergedAt == nil)
        #expect(prs[1].checks == .none && prs[1].state == .closed && prs[1].author == "" && prs[1].headRefOid == nil)
    }

    @Test func theRepositoryIsTheOneGhWouldAsk() {
        func resolve(_ config: String) -> String? { GitHubRepository.resolve(remoteConfig: config)?.description }
        #expect(resolve("remote.origin.url https://github.com/acme/api.git") == "acme/api")
        #expect(resolve("remote.origin.url git@github.com:acme/api.git") == "acme/api")
        // A fork: the pull requests live upstream.
        #expect(resolve("remote.origin.url git@github.com:alice/api.git\nremote.upstream.url https://github.com/acme/api") == "acme/api")
        // `gh repo set-default` wins over the order.
        #expect(resolve("remote.origin.url git@github.com:alice/api.git\nremote.origin.gh-resolved base\nremote.upstream.url https://github.com/acme/api") == "alice/api")
        #expect(resolve("remote.origin.url git@github.com:alice/api.git\nremote.origin.gh-resolved acme/tools") == "acme/tools")
        #expect(resolve("remote.mirror.url https://github.com/acme/mirror\nremote.origin.url https://github.com/acme/api") == "acme/api")
        // Elsewhere than github.com, only `gh` knows how to reach it.
        #expect(resolve("remote.origin.url https://github.example.com/acme/api.git") == nil)
        #expect(resolve("remote.origin.url work:acme/api.git") == nil)
        #expect(resolve("remote.origin.url /srv/git/api.git") == nil)
        #expect(resolve("") == nil)
        #expect(GitHubRepository(owner: "Acme", name: "API") == GitHubRepository(owner: "acme", name: "api"))
    }
}
