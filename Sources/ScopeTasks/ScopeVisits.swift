import Foundation
import ScopeCore

/// When the owner last looked at each scope, and what its tasks' pull requests were then: the baseline
/// `ReturnDigest` measures a return against. UI state, not configuration — `<home>/scope-visits.json`.
public struct ScopeVisits: Codable, Sendable, Equatable {
    /// Schema version written by this build. Anything else reads as no visits: the next return just says nothing.
    /// 2: a task keeps every one of its pull requests, not one.
    public static let currentVersion = 2

    public struct Visit: Codable, Sendable, Equatable {
        /// The moment the owner stopped looking: switched away, or the app left the front.
        public var lastSeen: Date
        /// The pull requests of the scope's tasks that had any then, by task id.
        public var pullRequests: [String: [PullRequestSnapshot]]

        public init(lastSeen: Date, pullRequests: [TaskID: [PullRequestSnapshot]] = [:]) {
            self.lastSeen = lastSeen
            self.pullRequests = Dictionary(uniqueKeysWithValues: pullRequests.map { ($0.key.rawValue, $0.value) })
        }

        /// `pullRequests` keyed by task id again; a key that is not one is dropped.
        public var seenPullRequests: [TaskID: [PullRequestSnapshot]] {
            Dictionary(uniqueKeysWithValues: pullRequests.compactMap { key, value in
                TaskID(rawValue: key).map { ($0, value) }
            })
        }
    }

    public var version: Int
    /// By scope id.
    public var scopes: [String: Visit]

    public init(scopes: [ScopeID: Visit] = [:]) {
        version = Self.currentVersion
        self.scopes = Dictionary(uniqueKeysWithValues: scopes.map { ($0.key.rawValue, $0.value) })
    }

    public subscript(scope: ScopeID) -> Visit? {
        get { scopes[scope.rawValue] }
        set { scopes[scope.rawValue] = newValue }
    }

    /// Keeps the scopes still declared.
    public mutating func retain(_ declared: Set<ScopeID>) {
        scopes = scopes.filter { declared.contains(ScopeID(rawValue: $0.key)) }
    }
}

/// Owner of `<home>/scope-visits.json`. Written when the owner leaves a scope or the app, a few times an hour at
/// most, so straight to disk.
public struct ScopeVisitStore: Sendable {
    public let url: URL

    public init(home: URL) {
        url = ScopeHome.scopeVisitsURL(home: home)
    }

    /// The saved visits; none when the file is missing, unreadable or from another version.
    public func load() -> ScopeVisits {
        guard let visits = try? JSONStore.load(ScopeVisits.self, from: url, fractionalSeconds: true),
              visits.version == ScopeVisits.currentVersion else { return ScopeVisits() }
        return visits
    }

    public func save(_ visits: ScopeVisits) {
        do {
            try JSONStore.save(visits, to: url, fractionalSeconds: true)
        } catch {
            Log.app.error("scope-visits.json write failed: \(String(describing: error), privacy: .public)")
        }
    }
}
