import Foundation

/// Who filed a task under its topic, or out of any.
public enum TopicSource: String, Codable, Sendable, Hashable {
    /// The user, in the app, or an agent (`--topic`, `scope task topic`): never undone by Scope.
    case explicit
    /// Scope, grouping related tasks (`TopicAttribution`).
    case automatic
}

/// A topic: the few words several tasks of one piece of work share, so the sidebar files them together.
///
/// A label on `TaskRecord`, not an entity: nothing to create first, to rename in two places or to leave behind
/// when its last task goes. Two spellings that differ only in case or spacing are one topic, so an agent writing
/// `Auth rework` and another `auth  rework` still land in the same group.
public enum TaskTopic {
    /// Longer than this is a sentence, not a name for a group row.
    public static let maxLength = 60

    /// Trimmed, inner whitespace collapsed, cut at `maxLength`; `nil` when nothing is left.
    public static func normalize(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let words = raw.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return nil }
        let joined = words.joined(separator: " ")
        return joined.count > maxLength
            ? String(joined.prefix(maxLength)).trimmingCharacters(in: .whitespaces)
            : joined
    }

    /// What two spellings of one topic have in common.
    public static func key(_ topic: String) -> String {
        (normalize(topic) ?? "").lowercased()
    }

    /// The tasks that move with `root` when its topic changes: those it started, and theirs, still filed where it is
    /// filed now (both without a topic counts). That is how they got there — `inherit` — so they are the same piece
    /// of work; one filed elsewhere since was put there on purpose and stays, and so does what hangs under it.
    public static func followers<ID: Hashable>(of root: ID, in tasks: [(id: ID, parent: ID?, topic: String?)]) -> [ID] {
        let current = Dictionary(tasks.map { ($0.id, normalize($0.topic).map(key)) }) { first, _ in first }
        guard let rootKey = current[root] else { return [] }
        let children = Dictionary(grouping: tasks.filter { $0.parent != nil }, by: { $0.parent! })
        var result: [ID] = []
        var seen: Set<ID> = [root]
        var queue = [root]
        while !queue.isEmpty {
            let parent = queue.removeFirst()
            for child in children[parent] ?? [] where !seen.contains(child.id) && current[child.id] == rootKey {
                seen.insert(child.id)
                result.append(child.id)
                queue.append(child.id)
            }
        }
        return result
    }

    /// A run of the sidebar: one task on its own, or the tasks of a topic under one row.
    public enum Entry<ID: Hashable>: Hashable {
        case task(ID)
        case topic(String, [ID])

        var isTask: Bool {
            if case .task = self { true } else { false }
        }
    }

    /// The tasks standing flat first, in their order, then the topics, each with every one of its tasks and ordered by
    /// where its first task stands. Flat tasks go on top because a topic's tasks are not indented: a task on its own
    /// right after a group read as one of its members. A topic left with a single task is no group: the task stands
    /// flat, like any task on its own — a row spent on a group of one says nothing. It keeps the label (`scope summary`
    /// groups by it, and the next sibling regroups under it), and a topic in `kept` (one whose orchestrator thread is
    /// open) keeps its row whatever its size.
    public static func entries<ID: Hashable>(_ tasks: [(id: ID, topic: String?)], kept: Set<String> = []) -> [Entry<ID>] {
        var order: [String] = []
        var names: [String: String] = [:]
        var members: [String: [ID]] = [:]
        var entries: [Entry<ID>?] = []
        var slot: [String: Int] = [:]
        for task in tasks {
            guard let topic = normalize(task.topic) else {
                entries.append(.task(task.id))
                continue
            }
            let key = key(topic)
            if members[key] == nil {
                order.append(key)
                names[key] = topic
                slot[key] = entries.count
                entries.append(nil)
            }
            members[key, default: []].append(task.id)
        }
        for key in order {
            let ids = members[key]!
            entries[slot[key]!] = ids.count > 1 || kept.contains(key) ? .topic(names[key]!, ids) : .task(ids[0])
        }
        let all = entries.compactMap { $0 }
        return all.filter(\.isTask) + all.filter { !$0.isTask }
    }

    /// The distinct topics of `topics`, first spelling kept, sorted for a menu.
    public static func distinct(_ topics: [String?]) -> [String] {
        var seen: [String: String] = [:]
        for topic in topics.compactMap(normalize) where seen[key(topic)] == nil {
            seen[key(topic)] = topic
        }
        return seen.values.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}
