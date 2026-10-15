import Foundation

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

    /// Where a task an agent creates is filed, and whether the task the agent sits in should be filed with it.
    ///
    /// The topic asked for wins. Otherwise the child takes the parent task's topic; a parent with none lends its own
    /// name to both, so a task that splits its work keeps the pieces next to it without anyone thinking about it.
    /// Outside any task (an orchestrator at the scope root) there is nothing to inherit: it names the topic itself.
    public static func inherit(requested: String?, parentTopic: String?, parentName: String?)
        -> (child: String?, parent: String?) {
        if let requested = normalize(requested) { return (requested, nil) }
        if let parentTopic = normalize(parentTopic) { return (parentTopic, nil) }
        guard let name = normalize(parentName) else { return (nil, nil) }
        return (name, name)
    }

    /// A run of the sidebar: one task on its own, or the tasks of a topic under one row.
    public enum Entry<ID: Hashable>: Hashable {
        case task(ID)
        case topic(String, [ID])
    }

    /// `tasks` in their order, with every task of a topic gathered where the first of them stands. A topic holding a
    /// single task is still a group: whoever named it meant one, and a second task is usually on its way.
    public static func entries<ID: Hashable>(_ tasks: [(id: ID, topic: String?)]) -> [Entry<ID>] {
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
            entries[slot[key]!] = .topic(names[key]!, members[key]!)
        }
        return entries.compactMap { $0 }
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
