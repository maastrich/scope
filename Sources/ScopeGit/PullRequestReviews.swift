import Foundation

/// What was said on a pull request — reviews, line comments, conversation — in one `gh api graphql` call, with the
/// viewer's login: what the review trigger reads to decide whether the task's thread has something to address.
public struct PullRequestReviewActivity: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case review, inline, conversation
    }

    public struct Item: Sendable, Equatable {
        public var id: String
        public var kind: Kind
        public var author: String
        public var body: String
        public var at: Date
        public var url: URL?
        public var state: String?
        public var path: String?
        public var line: Int?
        /// A line comment whose thread is resolved, or answered by the viewer since, or that is itself the viewer's
        /// reply in a thread someone else opened.
        public var handled: Bool
        /// GitHub's `authorAssociation`: `OWNER`, `MEMBER`, `COLLABORATOR`, `CONTRIBUTOR`, `NONE`, …
        public var association: String?

        public init(id: String, kind: Kind, author: String, body: String, at: Date, url: URL? = nil, state: String? = nil,
                    path: String? = nil, line: Int? = nil, handled: Bool = false, association: String? = nil) {
            self.association = association
            self.id = id
            self.kind = kind
            self.author = author
            self.body = body
            self.at = at
            self.url = url
            self.state = state
            self.path = path
            self.line = line
            self.handled = handled
        }
    }

    public var viewer: String?
    public var items: [Item]

    public init(viewer: String?, items: [Item]) {
        self.viewer = viewer
        self.items = items
    }

    static let query = """
    query($owner: String!, $name: String!, $number: Int!) {
      viewer { login }
      repository(owner: $owner, name: $name) {
        pullRequest(number: $number) {
          reviews(last: 30) { nodes { id author { login } authorAssociation body state submittedAt url } }
          comments(last: 30) { nodes { id author { login } authorAssociation body createdAt url } }
          reviewThreads(last: 50) {
            nodes { isResolved comments(first: 20) { nodes { id author { login } authorAssociation body createdAt url path line originalLine } } }
          }
        }
      }
    }
    """

    private struct Response: Decodable {
        struct Login: Decodable { var login: String? }
        struct Review: Decodable { var id: String; var author: Login?; var authorAssociation: String?; var body: String?; var state: String?; var submittedAt: Date?; var url: URL? }
        struct Comment: Decodable {
            var id: String; var author: Login?; var authorAssociation: String?; var body: String?; var createdAt: Date?; var url: URL?
            var path: String?; var line: Int?; var originalLine: Int?
        }
        struct Nodes<T: Decodable>: Decodable { var nodes: [T]? }
        struct Thread: Decodable { var isResolved: Bool?; var comments: Nodes<Comment>? }
        struct PR: Decodable { var reviews: Nodes<Review>?; var comments: Nodes<Comment>?; var reviewThreads: Nodes<Thread>? }
        struct Repo: Decodable { var pullRequest: PR? }
        struct DataField: Decodable { var viewer: Login?; var repository: Repo? }
        var data: DataField?
    }

    public static func parse(json data: Data) throws -> PullRequestReviewActivity {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let response = try decoder.decode(Response.self, from: data)
        let viewer = response.data?.viewer?.login
        let pr = response.data?.repository?.pullRequest
        func isViewer(_ login: String?) -> Bool {
            guard let viewer, let login else { return false }
            return viewer.caseInsensitiveCompare(login) == .orderedSame
        }
        var items: [Item] = []
        for review in pr?.reviews?.nodes ?? [] {
            guard let at = review.submittedAt else { continue }
            items.append(Item(id: review.id, kind: .review, author: review.author?.login ?? "ghost", body: review.body ?? "",
                              at: at, url: review.url, state: review.state, association: review.authorAssociation))
        }
        for comment in pr?.comments?.nodes ?? [] {
            guard let at = comment.createdAt else { continue }
            items.append(Item(id: comment.id, kind: .conversation, author: comment.author?.login ?? "ghost",
                              body: comment.body ?? "", at: at, url: comment.url, association: comment.authorAssociation))
        }
        for thread in pr?.reviewThreads?.nodes ?? [] {
            let comments = thread.comments?.nodes ?? []
            let lastViewerReply = comments.indices.last { $0 > 0 && isViewer(comments[$0].author?.login) }
            for (index, comment) in comments.enumerated() {
                guard let at = comment.createdAt else { continue }
                let handled = (thread.isResolved ?? false)
                    || (lastViewerReply.map { index < $0 } ?? false)
                    || (index > 0 && isViewer(comment.author?.login))
                items.append(Item(id: comment.id, kind: .inline, author: comment.author?.login ?? "ghost",
                                  body: comment.body ?? "", at: at, url: comment.url, path: comment.path,
                                  line: comment.line ?? comment.originalLine, handled: handled,
                                  association: comment.authorAssociation))
            }
        }
        return PullRequestReviewActivity(viewer: viewer, items: items)
    }
}

extension GhClient {
    /// Reviews, line comments and conversation of pull request `number` of `repo` (`owner/name`), with the viewer.
    public func reviewActivity(number: Int, repo: String, in checkout: URL) async throws -> PullRequestReviewActivity {
        let parts = repo.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { throw GhError.failed(command: "gh api graphql", message: "not owner/name: \(repo)") }
        let arguments = ["api", "graphql", "-f", "query=\(PullRequestReviewActivity.query)", "-F", "owner=\(parts[0])",
                         "-F", "name=\(parts[1])", "-F", "number=\(number)"]
        return try await json(arguments, in: checkout, parse: PullRequestReviewActivity.parse(json:))
    }
}
