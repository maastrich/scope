import Foundation

/// Which tasks belong in one topic, decided from what links them — a pure function of the open tasks and their
/// links, in the style of `AssistTriggers`, run when a task is created and when its pull requests change.
///
/// The rules:
/// - **A task on its own gets no topic.** Nothing is filed at creation; a task with no sibling stays flat.
/// - **The topic is born with the sibling.** When two tasks are linked and neither has a topic, Scope creates one,
///   names it after what they share, and files both. When one of them already has a topic, the other joins it.
/// - **Strong links are deterministic**: a task created from another (`parentTask`), stacked pull requests (one
///   task's base branch is another's head), the same issue, the same pull request. The **weak link** — a brief
///   about the same thing — is the assistant's call (`TopicPick`) and comes in as a `.brief` link.
/// - Same repository or same files never link two tasks on their own: in a one-repository scope every task would
///   collapse into one topic. They are context for the assistant, not a link.
/// - **Explicit choices win.** A task the user or an agent filed (or took out of any topic) is never moved; it can
///   lend its topic to the tasks linked to it, never take another.
public enum TopicAttribution {
    /// A task as the attribution sees it.
    public struct Member: Sendable, Equatable {
        public var id: String
        public var name: String
        public var topic: String?
        /// `TaskRecord.topicIsExplicit`.
        public var explicit: Bool
        public var parent: String?
        /// The issue's URL: numbers repeat across repositories.
        public var issue: String?
        /// Pull request URLs.
        public var pullRequests: [String]
        /// `repo|branch` of every branch the task works on, its pull requests' heads included.
        public var heads: Set<String>
        /// `repo|branch` its pull requests are based on.
        public var bases: Set<String>
        public var createdAt: Date

        public init(id: String, name: String, topic: String? = nil, explicit: Bool = false, parent: String? = nil,
                    issue: String? = nil, pullRequests: [String] = [], heads: Set<String> = [], bases: Set<String> = [],
                    createdAt: Date = .distantPast) {
            self.id = id
            self.name = name
            self.topic = TaskTopic.normalize(topic)
            self.explicit = explicit
            self.parent = parent
            self.issue = issue
            self.pullRequests = pullRequests
            self.heads = heads
            self.bases = bases
            self.createdAt = createdAt
        }

        /// The task of `record`, its links read from the record.
        public init(_ record: TaskRecord) {
            let first = record.repos.first?.repoRelativePath ?? "."
            var heads: Set<String> = []
            for repo in record.repos {
                heads.insert("\(repo.repoRelativePath)|\(repo.branch)")
                for worktree in repo.worktrees { heads.insert("\(repo.repoRelativePath)|\(worktree.branch)") }
            }
            var bases: Set<String> = []
            for link in record.pullRequests {
                let repo = link.repo ?? first
                if let head = link.headRefName { heads.insert("\(repo)|\(head)") }
                if let base = link.baseRefName { bases.insert("\(repo)|\(base)") }
            }
            self.init(id: record.id.rawValue, name: record.name, topic: record.topic, explicit: record.topicIsExplicit,
                      parent: record.parentTask?.rawValue, issue: record.issue?.url.absoluteString,
                      pullRequests: record.pullRequests.map(\.url.absoluteString), heads: heads, bases: bases,
                      createdAt: record.createdAt)
        }
    }

    public enum LinkKind: String, Sendable, Equatable {
        case parent, stack, issue, pullRequest, brief
    }

    /// Two tasks that go together, and why. `name` is the shared subject the assistant read in a `.brief` link.
    public struct Link: Sendable, Equatable {
        public var a: String
        public var b: String
        public var kind: LinkKind
        public var name: String?

        public init(_ a: String, _ b: String, kind: LinkKind, name: String? = nil) {
            self.a = a
            self.b = b
            self.kind = kind
            self.name = name
        }
    }

    public enum Decision: Sendable, Equatable {
        /// No topic yet among them: create one and file all of `tasks`. `name` is the assistant's when it gave one;
        /// `nil` asks the caller to name it (`TopicName`).
        case create(tasks: [String], name: String?)
        /// File `tasks` under the existing `topic`.
        case file(tasks: [String], under: String)
    }

    /// The deterministic links among `members`.
    public static func strongLinks(_ members: [Member]) -> [Link] {
        var links: [Link] = []
        let ids = Set(members.map(\.id))
        for (index, member) in members.enumerated() {
            if let parent = member.parent, ids.contains(parent), parent != member.id {
                links.append(Link(parent, member.id, kind: .parent))
            }
            for other in members[(index + 1)...] {
                if let issue = member.issue, issue == other.issue {
                    links.append(Link(member.id, other.id, kind: .issue))
                } else if !Set(member.pullRequests).isDisjoint(with: other.pullRequests) {
                    links.append(Link(member.id, other.id, kind: .pullRequest))
                } else if !member.bases.isDisjoint(with: other.heads) || !other.bases.isDisjoint(with: member.heads) {
                    links.append(Link(member.id, other.id, kind: .stack))
                }
            }
        }
        return links
    }

    /// What to do so linked tasks share a topic. `members` are the open tasks of one scope; `links` the strong ones
    /// (`strongLinks`) plus any the assistant found. Idempotent: run again on its own result, it decides nothing.
    ///
    /// Per group of linked tasks: the tasks that can move are those with no topic that nobody filed by hand (taken
    /// out of a topic counts). They go under the topic the group already has — an explicit one first, then the most
    /// shared, the oldest task's on a tie — or, when none of them has one, under a new topic created for at least
    /// two of them. A group whose movable tasks are a single one with no topic to join stays as it is: a task is
    /// never filed alone.
    ///
    /// A task already under a topic Scope gave stays there: the link that put it there may have been the
    /// assistant's, which is not kept, and a new link must not pull it away from the sibling it was filed with.
    /// `refiling` (the migration) moves those too, when they are alone under their topic: a topic two open tasks
    /// share was a group someone meant, and the migration does not split it.
    public static func decide(_ members: [Member], links: [Link], refiling: Bool = false) -> [Decision] {
        let byID = Dictionary(members.map { ($0.id, $0) }) { first, _ in first }
        var parent: [String: String] = [:]
        func root(_ id: String) -> String {
            var id = id
            while let next = parent[id], next != id { id = next }
            return id
        }
        var names: [String: String] = [:]
        for link in links where byID[link.a] != nil && byID[link.b] != nil && link.a != link.b {
            let (ra, rb) = (root(link.a), root(link.b))
            if ra != rb { parent[rb] = ra }
            if let name = TopicName.clean(link.name) { names[link.a] = name; names[link.b] = name }
        }
        let linked = members.filter { parent[$0.id] != nil || parent.values.contains($0.id) }
        let groups = Dictionary(grouping: linked, by: { root($0.id) })
        // How many open tasks hold each topic: the migration only moves a task out of a topic it holds alone.
        var sizes: [String: Int] = [:]
        for member in members { if let topic = member.topic { sizes[TaskTopic.key(topic), default: 0] += 1 } }
        var decisions: [Decision] = []
        let ordered = groups.values
            .map { $0.sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) } }
            .sorted { ($0[0].createdAt, $0[0].id) < ($1[0].createdAt, $1[0].id) }
        for group in ordered where group.count > 1 {
            let movable = group.filter { !$0.explicit && ($0.topic == nil || (refiling && (sizes[TaskTopic.key($0.topic!)] ?? 0) < 2)) }
            guard !movable.isEmpty else { continue }
            if let target = target(of: group) {
                let moving = movable.filter { $0.topic.map(TaskTopic.key) != TaskTopic.key(target) }.map(\.id)
                if !moving.isEmpty { decisions.append(.file(tasks: moving, under: target)) }
            } else if movable.count > 1 {
                decisions.append(.create(tasks: movable.map(\.id), name: movable.lazy.compactMap { names[$0.id] }.first))
            }
        }
        return decisions
    }

    /// The topic a group already has: an explicit one wins, then the one most of its tasks share, then the oldest's.
    static func target(of group: [Member]) -> String? {
        let explicit = group.filter { $0.explicit && $0.topic != nil }
        let pool = explicit.isEmpty ? group.filter { $0.topic != nil } : explicit
        guard !pool.isEmpty else { return nil }
        var counts: [String: Int] = [:]
        for member in pool { counts[TaskTopic.key(member.topic!), default: 0] += 1 }
        let best = counts.values.max()!
        return pool.first { counts[TaskTopic.key($0.topic!)] == best }?.topic
    }

    /// The tasks a new one could belong with by its brief, for the assistant to choose from: the open tasks of the
    /// scope other than it, newest first, at most `limit` — the on-device model has little room.
    public static func candidates(for id: String, among members: [Member], limit: Int = 8) -> [Member] {
        Array(members.filter { $0.id != id }.sorted { $0.createdAt > $1.createdAt }.prefix(limit))
    }

    // MARK: Migration

    /// `scope topics regroup`: the same decisions over tasks filed before the rules existed, whose topics count as
    /// explicit otherwise. Topics recorded as explicit (`TopicSource.explicit`) still never move. Opt-in, and a dry
    /// run unless asked.
    public static func regroup(_ records: [TaskRecord]) -> [Decision] {
        let members = records.filter { !$0.isArchived }.map { record in
            var member = Member(record)
            member.explicit = record.topicSource == .explicit
            return member
        }
        return decide(members, links: strongLinks(members), refiling: true)
    }
}

/// How a topic is named: 1 to 3 words for the subject the tasks share, never a task's title, and the existing
/// topic reused when the new name is one of its spellings.
public enum TopicName {
    public static let maxWords = 3

    /// The model's answer made a name: trimmed of quotes and punctuation, at most `maxWords` words. `nil` when
    /// nothing is left or the answer is "none".
    public static func clean(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
            .union(CharacterSet(charactersIn: "\"'`“”‘’«»")))
        let words = trimmed.split(whereSeparator: \.isWhitespace).prefix(maxWords)
        guard !words.isEmpty else { return nil }
        let name = words.joined(separator: " ")
        return name.lowercased() == "none" ? nil : TaskTopic.normalize(name)
    }

    /// Words that say nothing about a subject.
    static let stopwords: Set<String> = [
        "a", "an", "the", "and", "or", "of", "for", "to", "in", "on", "with", "from", "by", "at", "into", "its", "it",
        "le", "la", "les", "un", "une", "des", "du", "de", "et", "ou", "en", "au", "aux", "pour", "sur", "dans", "par",
        "add", "fix", "make", "update", "use", "new", "support", "feat", "chore", "docs", "refactor",
    ]

    /// Near-synonyms folded onto one word, so `Authentication` and `auth` are one topic.
    static let synonyms: [String: String] = [
        "authentication": "auth", "authn": "auth", "login": "auth", "signin": "auth",
        "documentation": "doc", "docs": "doc",
        "interface": "ui", "frontend": "ui",
        "tests": "test", "testing": "test",
        "refacto": "rework", "refactoring": "rework", "redesign": "rework", "overhaul": "rework",
        "perf": "performance", "speed": "performance",
        "config": "configuration", "settings": "configuration", "preferences": "configuration", "reglage": "configuration",
        "ci": "pipeline",
        "bugs": "bug", "bugfix": "bug", "bugfixes": "bug",
    ]

    /// What two spellings of one subject have in common: case, accents, punctuation, plurals, word order, small words
    /// and near-synonyms set aside. Wider than `TaskTopic.key`, which only folds case and spacing.
    public static func canonical(_ name: String) -> String {
        let folded = name.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        let words = folded.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        var kept = Set<String>()
        for word in words {
            var word = synonyms[word] ?? word
            if word.count > 3, word.hasSuffix("s"), !word.hasSuffix("ss") { word.removeLast() }
            word = synonyms[word] ?? word
            if !stopwords.contains(word) { kept.insert(word) }
        }
        return kept.isEmpty ? TaskTopic.key(name) : kept.sorted().joined(separator: " ")
    }

    /// `proposed`, or the existing topic it is a spelling of.
    public static func reuse(_ proposed: String, among existing: [String]) -> String {
        let key = canonical(proposed)
        return existing.first { canonical($0) == key } ?? proposed
    }

    /// A name without the assistant: the words the tasks' names and branches share, in the order the oldest task
    /// says them; failing that, the oldest task's two most telling words — never its whole title.
    public static func fallback(names: [String], branches: [String] = []) -> String? {
        func words(_ text: String) -> [String] {
            text.split { !$0.isLetter && !$0.isNumber }.map(String.init)
                .filter { $0.count > 2 && !stopwords.contains($0.lowercased()) && !$0.allSatisfy(\.isNumber) }
        }
        let sources = zip(names, names.indices.map { $0 < branches.count ? branches[$0] : "" }).map { "\($0) \($1)" }
        guard let first = sources.first else { return nil }
        let sets = sources.map { Set(words($0).map { canonical($0) }) }
        let shared = sets.dropFirst().reduce(sets[0]) { $0.intersection($1) }
        var seen = Set<String>()
        let ordered = words(first).filter { shared.contains(canonical($0)) && seen.insert(canonical($0)).inserted }
        if !ordered.isEmpty { return TaskTopic.normalize(ordered.prefix(maxWords).joined(separator: " ").lowercased()) }
        return TaskTopic.normalize(words(names[0]).prefix(2).joined(separator: " ").lowercased())
    }
}
