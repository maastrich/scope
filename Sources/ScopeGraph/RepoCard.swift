import Foundation

/// Which generation level produced a card (spec §4.6).
public enum GenerationLevel: String, Codable, Sendable, Equatable {
    /// README + manifests + git log, no AI.
    case level0
    /// The default driver in headless mode.
    case level1
}

/// A relation between two repos of the scope.
public struct Relation: Codable, Sendable, Equatable, Hashable {
    public enum Kind: String, Codable, Sendable, Equatable, Hashable {
        case dependsOn = "depends_on"
        case consumedBy = "consumed_by"
    }

    public var kind: Kind
    /// Graph key of the other repo (its path relative to the scope root).
    public var repo: String

    public init(kind: Kind, repo: String) {
        self.kind = kind
        self.repo = repo
    }
}

/// One repository card of the graph (spec §4.6).
///
/// `edited == true` marks a card the user changed by hand: generation never overwrites it.
/// Every array is optional on disk so a hand-edited file can omit what it does not know.
public struct RepoCard: Codable, Sendable, Equatable {
    public var name: String
    /// `owner/repo` or the origin URL.
    public var remote: String?
    public var defaultBranch: String?
    /// One to three sentences.
    public var purpose: String?
    /// Languages / frameworks / tools, lowercase (`node`, `typescript`, `rust`).
    public var stack: [String]
    /// Relative paths of the main entry points.
    public var entrypoints: [String]
    public var related: [Relation]
    /// Command to run after creating a sandbox (`pnpm install`).
    public var setup: String?
    /// Command that runs the tests (`cargo test`).
    public var test: String?
    /// Command to run before a sandbox is removed (`docker compose down`). Never generated: only a person knows
    /// what a sandbox leaves running.
    public var teardown: String?
    public var tags: [String]
    /// Committer date of the last commit.
    public var lastActivity: Date?
    /// `true` once the user edited the card; generation then leaves it alone.
    public var edited: Bool
    /// Level that produced the current content; `nil` for a fully manual card.
    public var generatedBy: GenerationLevel?

    public init(
        name: String,
        remote: String? = nil,
        defaultBranch: String? = nil,
        purpose: String? = nil,
        stack: [String] = [],
        entrypoints: [String] = [],
        related: [Relation] = [],
        setup: String? = nil,
        test: String? = nil,
        teardown: String? = nil,
        tags: [String] = [],
        lastActivity: Date? = nil,
        edited: Bool = false,
        generatedBy: GenerationLevel? = nil
    ) {
        self.teardown = teardown
        self.name = name
        self.remote = remote
        self.defaultBranch = defaultBranch
        self.purpose = purpose
        self.stack = stack
        self.entrypoints = entrypoints
        self.related = related
        self.setup = setup
        self.test = test
        self.tags = tags
        self.lastActivity = lastActivity
        self.edited = edited
        self.generatedBy = generatedBy
    }

    private enum CodingKeys: String, CodingKey {
        case name, remote, purpose, stack, entrypoints, related, setup, test, teardown, tags, edited
        case defaultBranch = "default_branch"
        case lastActivity = "last_activity"
        case generatedBy = "generated_by"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        remote = try c.decodeIfPresent(String.self, forKey: .remote)
        defaultBranch = try c.decodeIfPresent(String.self, forKey: .defaultBranch)
        purpose = try c.decodeIfPresent(String.self, forKey: .purpose)
        stack = try c.decodeIfPresent([String].self, forKey: .stack) ?? []
        entrypoints = try c.decodeIfPresent([String].self, forKey: .entrypoints) ?? []
        related = try c.decodeIfPresent([Relation].self, forKey: .related) ?? []
        setup = try c.decodeIfPresent(String.self, forKey: .setup)
        test = try c.decodeIfPresent(String.self, forKey: .test)
        teardown = try c.decodeIfPresent(String.self, forKey: .teardown)
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        lastActivity = try c.decodeIfPresent(Date.self, forKey: .lastActivity)
        edited = try c.decodeIfPresent(Bool.self, forKey: .edited) ?? false
        generatedBy = try c.decodeIfPresent(GenerationLevel.self, forKey: .generatedBy)
    }

    /// Field-by-field merge of a freshly generated card over `self`: a generated value wins when
    /// present (non-nil, non-empty), otherwise the existing one is kept. `edited` is preserved.
    public func merging(generated: RepoCard) -> RepoCard {
        var merged = self
        merged.name = generated.name
        merged.remote = generated.remote ?? remote
        merged.defaultBranch = generated.defaultBranch ?? defaultBranch
        merged.purpose = generated.purpose ?? purpose
        merged.stack = generated.stack.isEmpty ? stack : generated.stack
        merged.entrypoints = generated.entrypoints.isEmpty ? entrypoints : generated.entrypoints
        merged.related = generated.related.isEmpty ? related : generated.related
        merged.setup = generated.setup ?? setup
        merged.test = generated.test ?? test
        merged.teardown = generated.teardown ?? teardown
        merged.tags = generated.tags.isEmpty ? tags : generated.tags
        merged.lastActivity = generated.lastActivity ?? lastActivity
        merged.generatedBy = generated.generatedBy ?? generatedBy
        return merged
    }
}

/// The graph of one scope: `<home>/graph/<scope-slug>.json` (spec §3).
public struct ScopeGraph: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public var version: Int
    public var scopeSlug: String
    public var generatedAt: Date?
    /// Keyed by the repo path relative to the scope root (`"."` for a repo scope).
    public var repos: [String: RepoCard]
    /// Cache key of the last generation per repo key (HEAD sha + README hash + manifests hash).
    public var cacheKeys: [String: String]

    public init(
        version: Int = ScopeGraph.currentVersion,
        scopeSlug: String,
        generatedAt: Date? = nil,
        repos: [String: RepoCard] = [:],
        cacheKeys: [String: String] = [:]
    ) {
        self.version = version
        self.scopeSlug = scopeSlug
        self.generatedAt = generatedAt
        self.repos = repos
        self.cacheKeys = cacheKeys
    }

    private enum CodingKeys: String, CodingKey {
        case version, repos
        case scopeSlug = "scope_slug"
        case generatedAt = "generated_at"
        case cacheKeys = "cache_keys"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        scopeSlug = try c.decode(String.self, forKey: .scopeSlug)
        generatedAt = try c.decodeIfPresent(Date.self, forKey: .generatedAt)
        repos = try c.decodeIfPresent([String: RepoCard].self, forKey: .repos) ?? [:]
        cacheKeys = try c.decodeIfPresent([String: String].self, forKey: .cacheKeys) ?? [:]
    }

    /// `true` when the stored cache key of `key` equals `cacheKey` (nothing to regenerate).
    public func isCached(_ key: String, cacheKey: String) -> Bool {
        cacheKeys[key] == cacheKey
    }

    /// Applies a generated card. A card with `edited == true` is never overwritten (only its cache
    /// key is refreshed); otherwise the generated fields are merged over the existing ones.
    public mutating func applyGenerated(_ card: RepoCard, for key: String, cacheKey: String) {
        cacheKeys[key] = cacheKey
        guard let existing = repos[key] else {
            repos[key] = card
            return
        }
        guard !existing.edited else { return }
        repos[key] = existing.merging(generated: card)
    }

    /// Stores a user-edited card, flagged so generation leaves it alone.
    public mutating func setManual(_ card: RepoCard, for key: String) {
        var manual = card
        manual.edited = true
        repos[key] = manual
    }

    /// Drops the manual flag so the next generation refreshes the card.
    public mutating func resetToGenerated(_ key: String) {
        repos[key]?.edited = false
    }

    /// Removes a repo that is no longer in the scope.
    public mutating func remove(_ key: String) {
        repos[key] = nil
        cacheKeys[key] = nil
    }
}
