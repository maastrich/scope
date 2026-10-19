import Foundation

/// Which task a name points at — `scope task archive <slug>`, `scope_task_close {"task": …}` — when the slug is
/// not enough: a slug is unique within a scope, archived tasks included, but two scopes can each have one.
///
/// Before this, the archive and close commands took the first task of that slug in creation order, whatever its
/// scope and state: an archived `health` in one scope hid a live `health` in another, and `scope task archive
/// health` answered *archived* having touched nothing. Now an id is exact, a slug is narrowed by `--scope` when
/// given, then by what the command wants (a live task to archive, an archived one to restore), then by the
/// caller's own scope; what is still shared is refused with the spellings that would settle it.
public enum TaskLookup {
    public struct Candidate: Equatable, Sendable {
        public var id: String
        public var slug: String
        public var scopeID: String
        public var scopeSlug: String
        public var isArchived: Bool

        public init(id: String, slug: String, scopeID: String, scopeSlug: String, isArchived: Bool) {
            self.id = id
            self.slug = slug
            self.scopeID = scopeID
            self.scopeSlug = scopeSlug
            self.isArchived = isArchived
        }

        /// `acme/health`: how a shared slug is told apart in an answer.
        public var qualified: String { "\(scopeSlug)/\(slug)" }
    }

    /// What the command is after when a slug names both a live task and an archived one.
    public enum Preference: Sendable {
        /// Archive, close, topic, checkpoints: the task still open.
        case live
        /// Restore: the one put away.
        case archived
    }

    public enum Outcome: Equatable, Sendable {
        case found(Candidate)
        /// Nothing of that id or slug (in that scope).
        case none
        /// Several tasks the query does not tell apart.
        case ambiguous([Candidate])
    }

    /// - Parameters:
    ///   - scopeID: the scope `--scope` resolved to, when given.
    ///   - callerScopeID: the scope of the thread asking, when it asks from one.
    public static func resolve(_ query: String, among tasks: [Candidate], preferring preference: Preference,
                               scopeID: String? = nil, callerScopeID: String? = nil) -> Outcome {
        if let exact = tasks.first(where: { $0.id == query }) { return .found(exact) }
        var candidates = tasks.filter { $0.slug == query }
        if let scopeID { candidates = candidates.filter { $0.scopeID == scopeID } }
        if candidates.count <= 1 { return candidates.first.map(Outcome.found) ?? .none }
        let wanted = candidates.filter { $0.isArchived == (preference == .archived) }
        if wanted.count == 1 { return .found(wanted[0]) }
        let pool = wanted.isEmpty ? candidates : wanted
        if let own = pool.first(where: { $0.scopeID == callerScopeID }) { return .found(own) }
        return .ambiguous(pool)
    }
}
